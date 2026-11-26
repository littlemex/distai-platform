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
# -- this platform's own rule (gitops/README.md, AGENTS.md section 4's
# runner-only testing convention, and the EC2 test runner's own pinned tool
# list) is that nothing on a developer machine runs a container build; this
# script is written to run on that same EC2 runner, which has neither
# Docker nor Go pre-installed, so both are fetched here, verified by
# checksum, into a throwaway temp directory this script's own trap removes -
# never installed into the runner's own persistent tool set (runner/
# runner.yaml), which other owners share.
#
# Usage:
#   sharedfs-image-publish.sh --ecr-repository-url URL --region REGION \
#     --cluster-registration-namespace NAMESPACE [--commit SHA]
#
# Prerequisites: kubectl context pointed at the cell (the same safety check
# bootstrap.sh itself performs is not repeated here - run this only right
# after bootstrap.sh, against the same context); an AWS identity with
# ecr:GetAuthorizationToken and push permissions on the named repository
# (the EC2 runner's own role has this; it is not this script's job to grant
# it).

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

for bin in kubectl aws git curl sha256sum; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "prerequisite: ${bin} not found" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

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
echo "authenticating to ${REGISTRY_HOST} (no Docker daemon: writing a plain ~/.docker/config.json basic-auth entry, which go-containerregistry - ko's own push library - reads directly)" >&2
export HOME="${WORK}/home"
mkdir -p "${HOME}/.docker"
TOKEN="$(aws ecr get-login-password --region "${REGION}")"
AUTH_B64="$(printf 'AWS:%s' "${TOKEN}" | base64 | tr -d '\n')"
cat > "${HOME}/.docker/config.json" <<EOF
{"auths":{"${REGISTRY_HOST}":{"auth":"${AUTH_B64}"}}}
EOF

echo "building and pushing with ko (distroless/static:nonroot base, matching sharedfs's own Dockerfile)" >&2
export KO_DOCKER_REPO="${ECR_REPOSITORY_URL}"
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
  --base-image=gcr.io/distroless/static:nonroot \
  --bare)"

echo "published: ${IMAGE_REF}" >&2

echo "recording distai.dev.annotations/sharedfs-controller-image on the cell-registration Secret (namespace ${ARGOCD_NAMESPACE})" >&2
kubectl patch secret cell-registration -n "${ARGOCD_NAMESPACE}" --type merge \
  -p "{\"metadata\":{\"annotations\":{\"distai.dev.annotations/sharedfs-controller-image\":\"${IMAGE_REF}\"}}}"

echo "done: ${IMAGE_REF}" >&2
