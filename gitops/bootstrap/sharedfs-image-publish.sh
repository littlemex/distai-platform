#!/usr/bin/env bash
# gitops/bootstrap/sharedfs-image-publish.sh - #18.
#
# littlemex/sharedfs ships no image or Helm chart of its own (#18's own
# Facts checked, 2026-11-26: no Git tag, no GitHub Release, no
# image-publishing workflow at the pinned commit this script builds). This
# script builds its controller binary (which also serves as the preparer
# image - see gitops/charts/sharedfs-controller/README.md) at a pinned
# commit and pushes it, by digest, to the one ECR repository
# infra/foundation's fsx.tf creates for this cell when var.shared_fsx_lustre
# is set (sharedfs_controller_ecr_repository_url). It then records the
# resulting image@digest on the cell-registration Secret's own annotation
# (gitops/bootstrap/bootstrap.sh's own distai.dev.annotations/
# sharedfs-controller-image), which the sharedfs catalog entry's own cell
# marker file reads through valuesFrom - never a literal value in any
# committed gitops/ file, the same reason the repository URL itself is never
# committed.
#
# Uses ko (github.com/ko-build/ko): it builds a Go binary straight into an
# OCI image and pushes it over the registry HTTP API, with no Docker daemon
# at all - this script needs to run on whatever machine a cell operator has
# AWS and kubectl access from, and a Docker (or other container-build)
# daemon is not something this script can assume is already installed or
# that its own caller is willing to install. Go and ko are fetched here
# instead, verified by checksum, into a throwaway temp directory this
# script's own trap removes - never installed anywhere persistent, so
# running this script leaves nothing behind on the machine it ran on
# besides the image it published.
#
# Usage:
#   sharedfs-image-publish.sh --ecr-repository-url URL --region REGION \
#     --cluster-registration-namespace NAMESPACE [--commit SHA]
#
# Prerequisites: kubectl context pointed at the cell (checked below: the
# cell-registration Secret bootstrap.sh itself writes must already exist
# and, if it already names an ECR repository, must name this same one -
# run this only right after bootstrap.sh, against the same context); an
# AWS identity with ecr:GetAuthorizationToken and push permissions on the
# named repository (it is not this script's job to grant it).

set -euo pipefail

SHAREDFS_REPO="https://github.com/littlemex/sharedfs.git"
# #18's own pinned commit (the Issue body's own citation,
# https://github.com/littlemex/sharedfs/tree/c19eb1fd6b8a1d493081ec8b862b02955b015299):
# the exact commit gitops/charts/sharedfs-controller's CRDs/RBAC/policy
# templates were ported from. Bumping this (a deliberate version bump, not
# a default) needs re-checking that port by hand, the same way a Helm chart
# version bump elsewhere in gitops/ needs its own addon.yaml comment
# updated (gitops/README.md's own Versioning section).
DEFAULT_COMMIT="c19eb1fd6b8a1d493081ec8b862b02955b015299"

# Pinned, checksummed toolchain fetch (matches runner/runner.yaml's own
# convention: every tool this platform downloads is verified against a
# published checksum before use, never piped straight into sh). Versions
# current as of 2026-11-26; bump deliberately, with a new checksum, the
# same way runner.yaml's own header documents doing so.
GO_VERSION="1.27.4"
GO_SHA256="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840" # go.dev/dl/?mode=json, go1.27.4.linux-amd64.tar.gz, checked 2026-11-26
KO_VERSION="0.19.1" # github.com/ko-build/ko's latest release tag, checked 2026-11-26 (go.mod module path at this tag is still github.com/google/ko)

usage() {
  echo "Usage: $0 --ecr-repository-url URL --region REGION --cluster-registration-namespace NAMESPACE [--commit SHA]" >&2
  exit 1
}

ECR_REPOSITORY_URL=""
REGION=""
ARGOCD_NAMESPACE=""
COMMIT="${DEFAULT_COMMIT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ecr-repository-url) ECR_REPOSITORY_URL="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --cluster-registration-namespace) ARGOCD_NAMESPACE="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "${ECR_REPOSITORY_URL}" && -n "${REGION}" && -n "${ARGOCD_NAMESPACE}" ]] || usage

for bin in kubectl aws git curl sha256sum jq; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "prerequisite: ${bin} not found" >&2; exit 1; }
done

# Safety check: this script's own usage comment says "run this only right
# after bootstrap.sh, against the same context" but does not itself verify
# that - unlike bootstrap.sh's own two safety checks (kubeconfig server
# matches --tf-outputs; an existing registration Secret must name the same
# cluster), which this script has no --tf-outputs to check against the
# same way. The weaker, but still real, check available here: the
# cell-registration Secret bootstrap.sh itself writes in
# ${ARGOCD_NAMESPACE} must already exist (bootstrap.sh runs first - this
# script's own usage comment), and if it already carries a
# sharedfs-controller-ecr-repository-url annotation, that value must match
# --ecr-repository-url exactly. A mismatch here means the live kubectl
# context is pointed at a different cell than the one --ecr-repository-url
# names - proceeding would push this build to one cluster's ECR repository
# and then patch a different cluster's own Secret annotation to point at
# it, silently.
SECRET_JSON="$(kubectl get secret cell-registration -n "${ARGOCD_NAMESPACE}" -o json)" || {
  echo "no cell-registration Secret in namespace ${ARGOCD_NAMESPACE} - run bootstrap.sh against this context first" >&2
  exit 1
}
RECORDED_ECR_URL="$(echo "${SECRET_JSON}" | jq -r '.metadata.annotations["distai.dev.annotations/sharedfs-controller-ecr-repository-url"] // empty')"
if [[ -n "${RECORDED_ECR_URL}" && "${RECORDED_ECR_URL}" != "${ECR_REPOSITORY_URL}" ]]; then
  echo "cell-registration Secret in namespace ${ARGOCD_NAMESPACE} already names a different ECR repository (${RECORDED_ECR_URL}) than --ecr-repository-url (${ECR_REPOSITORY_URL}); this looks like the wrong cluster's kubeconfig context" >&2
  exit 1
fi

WORK="$(mktemp -d)"
# chmod before rm: `go mod download` (inside `go install` below) marks
# every module it fetches into GOPATH/pkg/mod read-only (Go's own
# documented module cache behavior, so a build cannot accidentally
# mutate an immutable dependency) - plain `rm -rf` cannot remove a
# read-only tree it does not own write access to, and failed outright on
# the runner, 2026-11-26 (thousands of "Permission denied" lines, one per
# cached file). `go clean -modcache` is the documented fix but needs the
# Go toolchain still on PATH at trap time, which this trap cannot assume
# (an early failure, before Go is even fetched, must still clean up);
# chmod -R u+w first works unconditionally and needs nothing but coreutils.
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

echo "fetching Go ${GO_VERSION} (checksummed)" >&2
curl -fsSL -o "${WORK}/go.tar.gz" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
echo "${GO_SHA256}  ${WORK}/go.tar.gz" | sha256sum -c -
tar -C "${WORK}" -xzf "${WORK}/go.tar.gz"
export PATH="${WORK}/go/bin:${WORK}/gopath/bin:${PATH}"
export GOPATH="${WORK}/gopath"
export GOCACHE="${WORK}/gocache"

echo "installing ko ${KO_VERSION} (go install verifies the module checksum against the Go checksum database, sum.golang.org, on every build - no separate manual checksum needed for a Go-module install, unlike the raw tarball above)" >&2
go install "github.com/google/ko@v${KO_VERSION}"

echo "cloning littlemex/sharedfs at ${COMMIT}" >&2
git clone --quiet "${SHAREDFS_REPO}" "${WORK}/sharedfs"
git -C "${WORK}/sharedfs" checkout --quiet "${COMMIT}"

REGISTRY_HOST="${ECR_REPOSITORY_URL%%/*}"
echo "authenticating to ${REGISTRY_HOST} (no Docker daemon: writing a plain config.json basic-auth entry via DOCKER_CONFIG, which go-containerregistry - ko's own push library - reads directly)" >&2
# DOCKER_CONFIG (not $HOME): go-containerregistry's default keychain reads
# $DOCKER_CONFIG/config.json when set, the same as the Docker CLI itself.
# An earlier version of this script instead pointed $HOME at a fresh,
# empty directory for this - which also redirects the AWS CLI's own
# config/credentials lookup there. With AWS_PROFILE=default set (this
# platform's own runner convention - see runner/README.md) and no
# ~/.aws/config at all in that fresh directory, `aws ecr
# get-login-password` on the next line failed outright ("The config
# profile (default) could not be found", confirmed on the runner,
# 2026-11-26) before ko ever ran. DOCKER_CONFIG only changes where
# go-containerregistry looks for registry credentials; it leaves
# $HOME, and so the AWS CLI's own credential resolution (the runner's
# IAM role via IMDS), untouched.
export DOCKER_CONFIG="${WORK}/docker-config"
mkdir -p "${DOCKER_CONFIG}"
TOKEN="$(aws ecr get-login-password --region "${REGION}")"
AUTH_B64="$(printf 'AWS:%s' "${TOKEN}" | base64 | tr -d '\n')"
cat > "${DOCKER_CONFIG}/config.json" <<EOF
{"auths":{"${REGISTRY_HOST}":{"auth":"${AUTH_B64}"}}}
EOF

echo "building and pushing with ko (distroless/static:nonroot base, matching sharedfs's own Dockerfile)" >&2
export KO_DOCKER_REPO="${ECR_REPOSITORY_URL}"
# KO_DEFAULTBASEIMAGE (not a --base-image flag): `ko build --help` at
# this pinned version (v0.19.1, confirmed on the runner, 2026-11-26) has
# no such flag at all ("Error: unknown flag: --base-image") - ko's own
# docs name the base image only as a .ko.yaml key (defaultBaseImage) or
# this environment variable, which its own docs say takes precedence
# over the YAML key; the environment variable needs no extra file in
# this already-throwaway work directory.
# Pinned by digest, not the floating :nonroot tag: this is the base of a
# security-sensitive, privileged (its own ServiceAccount, cluster-wide
# Role, admission-policy guard) controller image, and distroless/static's
# own tag is mutable upstream - re-running this script months apart could
# otherwise pull a silently different base with no record of which one a
# past run actually shipped. Digest confirmed live against GCR's own v2
# API (`docker-content-digest` response header for
# gcr.io/distroless/static:nonroot), 2026-11-26; bump deliberately, with a
# freshly re-checked digest, the same way GO_SHA256/KO_VERSION above are
# bumped.
export KO_DEFAULTBASEIMAGE="gcr.io/distroless/static:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5"
# --bare (not --tags): KO_DOCKER_REPO above is already this cell's one,
# fixed ECR repository name; ko's default behavior without --bare appends
# the Go import path ("/cmd") to it, which would push to a second,
# nonexistent repository name ECR never auto-creates. --tags is left at
# ko's own default (the tag matters only for a human `docker pull` by
# tag; every consumer here addresses the image by digest - see this
# repository's own ECR resource comment on why its tag mutability is
# MUTABLE, not IMMUTABLE, so re-running this script is safe).
IMAGE_REF="$(cd "${WORK}/sharedfs" && ko build ./cmd \
  --platform=linux/amd64 \
  --bare)"

echo "published: ${IMAGE_REF}" >&2

echo "recording distai.dev.annotations/sharedfs-controller-image on the cell-registration Secret (namespace ${ARGOCD_NAMESPACE})" >&2
kubectl patch secret cell-registration -n "${ARGOCD_NAMESPACE}" --type merge \
  -p "{\"metadata\":{\"annotations\":{\"distai.dev.annotations/sharedfs-controller-image\":\"${IMAGE_REF}\"}}}"

echo "done: ${IMAGE_REF}" >&2
