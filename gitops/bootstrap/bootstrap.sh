#!/usr/bin/env bash
# gitops/bootstrap/bootstrap.sh - RFC #25 Decision 1.
#
# Closes the chicken-and-egg gap a freshly-`terraform apply`'d cell is left
# with: a running, empty managed Argo CD capability with zero registered
# clusters, and an access entry that carries only the two built-in
# Argo-CD-capability-management policies (letting it manage itself, not
# arbitrary cluster objects) until infra/foundation's
# aws_eks_access_policy_association grants it cluster-admin too. This
# script writes the three Kubernetes objects that let the capability
# discover its own cluster and have something to deliver to it. It never
# calls an AWS API directly; every AWS-side fact it needs comes from
# `terraform output -json`, read once, passed in by the caller so this
# script cannot drift from what Terraform actually built.
#
# Usage:
#   bootstrap.sh --tf-outputs <(terraform output -json) [--revision REV]
#
# --tf-outputs is required and is the *only* way this script learns about
# the cell (never several flags that could individually go stale - Decision
# 1). It must be a path to the JSON `terraform output -json` prints, from
# infra/foundation, applied with var.argocd set.
#
# --revision (default: stable) is the Git revision of this repository every
# platform Application and cells Application is pinned to, until the first
# PR adding a new chart registry moves `stable` past this PR's own commit
# (Decision 6). Pass the PR branch's own tip here before `stable` exists.
#
# Idempotent: re-running with the same inputs changes nothing; re-running
# with a different --revision updates the registration Secret's annotation
# and the root Application's targetRevision together (Decision 1
# Acceptance Criteria). Re-running after a PR adds a chart registry is
# required so the `platform` AppProject's sourceRepos picks it up
# (Decision 6) - this script recomputes sourceRepos from this checkout's
# own gitops/addons/*/addon.yaml every run, never hand-maintained.
#
# Safety: aborts before writing anything if the live kubeconfig's server
# does not match --tf-outputs' cluster_endpoint, or if a cell-registration
# Secret already exists and names a different cluster_arn (Decision 1).

set -euo pipefail

usage() {
  echo "Usage: $0 --tf-outputs <path-or-process-substitution> [--revision REV]" >&2
  exit 1
}

TF_OUTPUTS=""
REVISION="stable"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tf-outputs)
      TF_OUTPUTS="${2:-}"
      shift 2
      ;;
    --revision)
      REVISION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

[[ -n "${TF_OUTPUTS}" ]] || usage
[[ -n "${REVISION}" ]] || usage

for bin in kubectl jq git; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "prerequisite: ${bin} not found" >&2; exit 1; }
done

[[ -r "${TF_OUTPUTS}" ]] || { echo "cannot read --tf-outputs: ${TF_OUTPUTS}" >&2; exit 1; }
TF_JSON="$(cat "${TF_OUTPUTS}")"

tf_out() {
  local key="$1"
  local v
  v="$(echo "${TF_JSON}" | jq -r --arg k "${key}" '.[$k].value // empty')"
  [[ -n "${v}" && "${v}" != "null" ]] || { echo "terraform output ${key} is missing or null; was this cell applied with var.argocd set?" >&2; exit 1; }
  echo "${v}"
}

CLUSTER_NAME="$(tf_out cluster_name)"
CLUSTER_ENDPOINT="$(tf_out cluster_endpoint)"
CLUSTER_ARN="$(tf_out cluster_arn)"
REGION="$(tf_out region)"
ARGOCD_NAMESPACE="$(tf_out argocd_namespace)"
INTERRUPTION_QUEUE="$(tf_out karpenter_interruption_queue_name)"
NODE_ROLE="$(tf_out karpenter_node_role_name)"

# --- Safety check 1: the kubeconfig in use really is this cell's own ------
LIVE_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
[[ -n "${LIVE_SERVER}" ]] || { echo "no current kubeconfig context; run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}" >&2; exit 1; }
[[ "${LIVE_SERVER}" == "${CLUSTER_ENDPOINT}" ]] || {
  echo "current kubeconfig server does not match --tf-outputs' cluster_endpoint; this looks like the wrong cluster's kubeconfig" >&2
  exit 1
}

# --- Safety check 2: never overwrite a different cluster's registration ---
# set -e/pipefail would otherwise abort here on "not found" (exit 1), which
# is an expected outcome on a first bootstrap, not an error: guard it with
# an explicit existence check instead of relying on `|| true` inside a
# pipeline. A transient failure (API server timeout, a permissions error,
# anything other than the Secret genuinely not existing) must NOT be read
# the same way: proceeding to write on a `kubectl get` failure for the
# wrong reason is exactly the write this safety check exists to prevent.
EXISTING_SERVER=""
GET_SECRET_ERR="$(mktemp)"
if kubectl get secret cell-registration -n "${ARGOCD_NAMESPACE}" >/dev/null 2>"${GET_SECRET_ERR}"; then
  EXISTING_SERVER="$(kubectl get secret cell-registration -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.data.server}' | base64 -d)"
else
  if ! grep -q "NotFound" "${GET_SECRET_ERR}"; then
    echo "could not check for an existing cell-registration Secret in namespace ${ARGOCD_NAMESPACE} (not a \"not found\" response): $(cat "${GET_SECRET_ERR}")" >&2
    rm -f "${GET_SECRET_ERR}"
    exit 1
  fi
fi
rm -f "${GET_SECRET_ERR}"
if [[ -n "${EXISTING_SERVER}" && "${EXISTING_SERVER}" != "${CLUSTER_ARN}" ]]; then
  echo "a cell-registration Secret already exists in namespace ${ARGOCD_NAMESPACE} naming a different cluster (${EXISTING_SERVER}); refusing to overwrite it with ${CLUSTER_ARN}" >&2
  exit 1
fi

# --- Resolve this script's own repository checkout ------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_URL="https://github.com/littlemex/distai-platform.git"

echo "bootstrapping cell ${CLUSTER_NAME} (namespace ${ARGOCD_NAMESPACE}, revision ${REVISION})" >&2

# --- Object 1: the registration Secret -------------------------------------
# server carries the cluster ARN, never an API server URL or
# kubernetes.default.svc (Facts checked). stringData.name is the field the
# Cluster generator exposes as {{name}} - not a second, redundant
# annotation (Decision 2).
kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cell-registration
  labels:
    argocd.argoproj.io/secret-type: cluster
  annotations:
    distai.dev.annotations/revision: "${REVISION}"
    distai.dev.annotations/region: "${REGION}"
    distai.dev.annotations/karpenter-interruption-queue: "${INTERRUPTION_QUEUE}"
    distai.dev.annotations/karpenter-node-role: "${NODE_ROLE}"
type: Opaque
stringData:
  name: "${CLUSTER_NAME}"
  server: "${CLUSTER_ARN}"
  project: platform
EOF

# --- Object 2: the platform AppProject --------------------------------------
# sourceRepos is computed from this checkout's own gitops/addons/*/addon.yaml
# at HEAD, never hand-maintained (Decision 6/7): this repository itself,
# plus every addon's own repoURL, deduplicated. A PR adding a new chart
# registry only takes effect once bootstrap.sh is re-run from a checkout at
# or after that PR's merge.
ADDON_REPOS="$( { grep -h '^repoURL:' "${REPO_ROOT}"/gitops/addons/*/addon.yaml 2>/dev/null || true; } \
  | sed -E 's/^repoURL:[[:space:]]*//; s/^"(.*)"$/\1/' | sort -u)"

SOURCE_REPOS_YAML="    - \"${REPO_URL}\""
while IFS= read -r repo; do
  [[ -n "${repo}" ]] || continue
  SOURCE_REPOS_YAML="${SOURCE_REPOS_YAML}
    - \"${repo}\""
done <<< "${ADDON_REPOS}"

kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
spec:
  description: "Admin-only project for every platform-delivered Application (RFC #25)."
  sourceNamespaces:
    - "${ARGOCD_NAMESPACE}"
  sourceRepos:
${SOURCE_REPOS_YAML}
  destinations:
    - name: "${CLUSTER_NAME}"
      namespace: "*"
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
EOF

# --- Object 3: the root Application -----------------------------------------
# Templated from gitops/bootstrap/root-application.yaml: __REVISION__,
# __CLUSTER_NAME__ and __ARGOCD_NAMESPACE__ are the only placeholders, so a
# --revision-only re-run updates targetRevision here and the Secret's
# annotation above together (Decision 1 Acceptance Criteria).
# "|" delimiter, not "/": REVISION is a git ref, and this repository's own
# branch naming convention (feat/..., test/..., fix/...) always contains a
# "/" -- a "/"-delimited s/// breaks ("unknown option to `s'") the instant
# REVISION has one, which is every real --revision this script is ever
# run with before a PR merges (Decision 6). "|" is not confirmed illegal
# in a git ref name the way space/~/^/:/?/*/[ are (`git check-ref-format`),
# and "&" is special in sed's own replacement text regardless of
# delimiter, so REVISION is escaped for both before use, rather than
# assumed never to contain them.
REVISION_SED_ESCAPED="$(printf '%s' "${REVISION}" | sed -e 's/[\&|]/\\&/g')"
sed \
  -e "s|__REVISION__|${REVISION_SED_ESCAPED}|g" \
  -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
  -e "s|__ARGOCD_NAMESPACE__|${ARGOCD_NAMESPACE}|g" \
  "${SCRIPT_DIR}/root-application.yaml" \
  | kubectl apply -n "${ARGOCD_NAMESPACE}" -f -

echo "bootstrap complete: cell-registration Secret, platform AppProject and root Application applied in namespace ${ARGOCD_NAMESPACE}" >&2
