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
# Acceptance Criteria). Re-running after a PR adds a chart registry or a
# new addon namespace is required so the `platform` AppProject's
# sourceRepos and destinations pick it up (Decision 6) - this script
# recomputes both from this checkout's own gitops/addons/*/addon.yaml and
# gitops/addon-catalog/*/addon.yaml every run, never hand-maintained.
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

# Like tf_out, but for an output that is legitimately null on every cell
# that did not set var.shared_fsx_lustre (#18) - printing nothing rather
# than aborting, since most cells have no shared FSx for Lustre file
# system at all and this script must keep bootstrapping Argo CD for them
# exactly as it did before #18 existed.
tf_out_optional() {
  local key="$1"
  echo "${TF_JSON}" | jq -r --arg k "${key}" '.[$k].value // empty'
}

CLUSTER_NAME="$(tf_out cluster_name)"
CLUSTER_ENDPOINT="$(tf_out cluster_endpoint)"
CLUSTER_ARN="$(tf_out cluster_arn)"
REGION="$(tf_out region)"
ARGOCD_NAMESPACE="$(tf_out argocd_namespace)"
INTERRUPTION_QUEUE="$(tf_out karpenter_interruption_queue_name)"
NODE_ROLE="$(tf_out karpenter_node_role_name)"

# #18: empty string on a cell with no var.shared_fsx_lustre - see
# tf_out_optional's own comment. gitops/charts/sharedfs-shares and the
# sharedfs catalog entry's own marker file read these back through this
# Secret's annotations (below), never a literal value in a committed
# gitops/ file: the ECR repository URL contains this account's ID, and
# the file-system identity is itself cell-specific.
FSX_FILE_SYSTEM_ID="$(tf_out_optional shared_fsx_lustre_file_system_id)"
FSX_DNS_NAME="$(tf_out_optional shared_fsx_lustre_dns_name)"
FSX_MOUNT_NAME="$(tf_out_optional shared_fsx_lustre_mount_name)"
FSX_STORAGE_CAPACITY_GIB="$(tf_out_optional shared_fsx_lustre_storage_capacity_gib)"
SHAREDFS_CONTROLLER_ECR_REPOSITORY_URL="$(tf_out_optional sharedfs_controller_ecr_repository_url)"
# Not a Terraform output at all: gitops/bootstrap/sharedfs-image-publish.sh
# (run once per cell, after this script, only on a cell with
# var.shared_fsx_lustre set) writes this annotation itself, the same
# "read the live Secret, patch forward" idiom team-onboard.sh already uses
# for its own impersonation flag. Empty here on a first run, and on every
# cell that never runs that script at all.
EXISTING_SHAREDFS_IMAGE=""
if kubectl get secret cell-registration -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  EXISTING_SHAREDFS_IMAGE="$(kubectl get secret cell-registration -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.metadata.annotations.distai\.dev\.annotations/sharedfs-controller-image}' 2>/dev/null || true)"
fi

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
    distai.dev.annotations/sharedfs-fsx-file-system-id: "${FSX_FILE_SYSTEM_ID}"
    distai.dev.annotations/sharedfs-fsx-dns-name: "${FSX_DNS_NAME}"
    distai.dev.annotations/sharedfs-fsx-mount-name: "${FSX_MOUNT_NAME}"
    distai.dev.annotations/sharedfs-fsx-storage-capacity-gib: "${FSX_STORAGE_CAPACITY_GIB}"
    distai.dev.annotations/sharedfs-controller-ecr-repository-url: "${SHAREDFS_CONTROLLER_ECR_REPOSITORY_URL}"
    distai.dev.annotations/sharedfs-controller-image: "${EXISTING_SHAREDFS_IMAGE}"
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

# destinations.namespace is computed the same way sourceRepos is (Decision
# 6/7): every namespace: value this checkout's own gitops/addons/*/addon.yaml
# and gitops/addon-catalog/*/addon.yaml declare, deduplicated, plus this
# capability's own namespace (the registration Secret, the AppProject and the
# root Application all live there - Object 1/3 above). A per-cell opt-in file
# (gitops/cells/<cluster>/addons/*.yaml) is required to repeat its catalog
# entry's own namespace byte-for-byte (check_addon_catalog_sync.py, #41
# Decision 3), so it never introduces a namespace outside this set without
# that check failing first. This closes the independent review findings
# tracked as #63 (security-axis pass, filed as a private report "SA1"):
# previously every Application in this AppProject could target *any*
# namespace in the cluster, which is wider than the role_mappings.ADMIN
# identity actually needs, since every admin-delivered Application's own
# namespace is already a declared, reviewed fact in this checkout, not a
# runtime choice.
# Also scans gitops/cells/*/{capacity-pool,smoke,sharedfs}/*.yaml (#63, a
# review of an earlier version of this fix found that cells.
# ApplicationSet.yaml's own per-cell parameter files - which use this same
# AppProject - declare namespaces (distai-smoke, every capacity-pool
# pool's own namespace) this grep did not scan at all, since it looked
# only at gitops/addons/ and gitops/addon-catalog/; #18 adds the sharedfs
# glob to cells.ApplicationSet.yaml itself, so it is scanned here too, for
# the same reason).
ADDON_NAMESPACES="$( { grep -h '^namespace:' "${REPO_ROOT}"/gitops/addons/*/addon.yaml "${REPO_ROOT}"/gitops/addon-catalog/*/addon.yaml "${REPO_ROOT}"/gitops/cells/*/capacity-pool/*.yaml "${REPO_ROOT}"/gitops/cells/*/smoke/*.yaml "${REPO_ROOT}"/gitops/cells/*/sharedfs/*.yaml 2>/dev/null || true; } \
  | sed -E 's/^namespace:[[:space:]]*//; s/^"(.*)"$/\1/' | sort -u)"

# kube-system is always included, not only when some addon.yaml happens to
# declare it as its own primary namespace (#63: the same review
# found that Karpenter's and Kueue's own pinned charts each render a
# second RBAC object - a leader-election Role/RoleBinding - directly into
# kube-system regardless of either chart's own configured namespace,
# confirmed by rendering both; the previous version of this script only
# included kube-system because karpenter/addon.yaml happens to also set
# namespace: kube-system as its own primary value - true today, but an
# accident this script should not depend on staying true).
DESTINATIONS_YAML="    - name: \"${CLUSTER_NAME}\"
      namespace: \"${ARGOCD_NAMESPACE}\"
    - name: \"${CLUSTER_NAME}\"
      namespace: \"kube-system\""
while IFS= read -r ns; do
  [[ -n "${ns}" && "${ns}" != "${ARGOCD_NAMESPACE}" && "${ns}" != "kube-system" ]] || continue
  DESTINATIONS_YAML="${DESTINATIONS_YAML}
    - name: \"${CLUSTER_NAME}\"
      namespace: \"${ns}\""
done <<< "${ADDON_NAMESPACES}"

# clusterResourceWhitelist/namespaceResourceWhitelist are no longer "*"/"*"
# (#63, filed as "SA1" item 1): appproject-whitelist.yaml, next to this
# script, is the one hand-maintained, reviewed list of every (group, kind)
# pair this checkout's own addons actually render, derived by `helm
# template`-ing every one of them - never a dynamic render at bootstrap
# time itself (a wrong OCI credential, a transient registry outage, or a
# values key this script's own inputs cannot supply would then fail
# bootstrap outright over a permissions list, not narrow anything real).
# gitops/tests/check_appproject_whitelist.py performs the same
# render-and-collect pass as a static check, so a PR adding an addon that
# renders a kind missing from that file fails in CI, not at apply time.
APPPROJECT_WHITELIST="$(cat "${SCRIPT_DIR}/appproject-whitelist.yaml")"

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
${DESTINATIONS_YAML}
$(printf '%s\n' "${APPPROJECT_WHITELIST}" | grep -v '^#' | sed '/^[[:space:]]*$/d' | sed 's/^/  /')
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
