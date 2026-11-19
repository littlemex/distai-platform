#!/usr/bin/env bash
# End-to-end test of the gitops/ delivery layer (issue #25) on a real AWS
# account and a real IAM Identity Center instance. It builds one foundation
# cell (infra/foundation, issue #20/#21 + this issue's decision 1 addition),
# bootstraps Argo CD's own delivery of itself, and exercises the mechanism
# every later issue (#17, #18, #19, #22, #23) will depend on.
#
# Maps to the issue's acceptance criteria:
#   1. an OCI chart (karpenter) and a Git-file-generator revision: field
#      templated from the Cluster generator (decision 2) each reach a real
#      Synced object;
#   2. before this PR's infra/foundation change, the capability's access
#      entry has no RBAC; after it, AmazonEKSClusterAdminPolicy is
#      associated -- both by a direct `aws eks` call, on the same cell;
#   3. bootstrap.sh's three objects are idempotent, a --revision-only
#      re-run updates the Secret annotation and root Application's
#      targetRevision together, and a wrong-cluster attempt aborts before
#      any write -- on a first bootstrap and on a re-run;
#   4. a deliberately broken `crds` step and a deliberately broken `kueue`
#      step each show this platform's real cross-Application ordering;
#   5. karpenter-crd and karpenter (skipCrds) report no shared CRD;
#   6. kueue/karpenter reach Healthy on the system node group before any
#      NodePool-launched node exists; the admin smoke LocalQueue admits a
#      canary Job and a Karpenter node launches for it;
#   7. removing one addon.yaml orphans nothing; deleting the three
#      bootstrap objects in decision 8's order orphans the NodePool/
#      EC2NodeClass/instance instead of deleting them, and bootstrap.sh
#      re-adopts them without duplicating; destroy still removes every
#      instance directly.
#
# The upgrade-mode e2e (decision 6/9) is a separate script, 2.upgrade.sh.
#
# Required environment (export before running):
#   AWS_PROFILE, AWS_REGION, NAME, STATE_BUCKET, STATE_REGION,
#   ADMIN_PRINCIPAL_ARN, MY_CIDR, GITOPS_REVISION (a git ref of this
#   repository, already pushed, whose gitops/ this test bootstraps --
#   normally this PR's own branch tip, since the `stable` tag does not
#   exist until this PR merges, decision 6), ARGOCD_IDC_INSTANCE_ARN,
#   ARGOCD_IDC_REGION, ARGOCD_IDC_IDENTITY_STORE_ID (the Identity Store ID
#   behind that instance ARN -- `aws sso-admin describe-instance` prints
#   it; this test creates and deletes its own temporary group, unlike the
#   foundation e2e which takes pre-existing group IDs).
# Optional environment:
#   TERRAFORM (terraform), KUBECTL (kubectl), E2E_WORK_DIR (mktemp -d),
#   E2E_KEEP_ON_FAILURE (0), E2E_LEFTOVER_GRACE_SECONDS (600),
#   GITOPS_BASE_REF (origin/main -- the pre-this-PR foundation code used
#   for acceptance criterion 2's "before" state),
#   GITOPS_REPO_URL (inferred from `git remote get-url origin`),
#   GITOPS_TEST_REMOTE (origin -- where this test pushes its two
#   disposable, deliberately-broken branches and deletes them afterwards),
#   GITOPS_SKIP_ORDERING_EXPERIMENT (0 -- set to 1 to skip acceptance
#   criterion 4 if the runner has no push access to GITOPS_TEST_REMOTE).
set -euo pipefail

: "${AWS_PROFILE:?export AWS_PROFILE}"
: "${AWS_REGION:?export AWS_REGION}"
: "${NAME:?export NAME (cell and cluster name)}"
: "${STATE_BUCKET:?export STATE_BUCKET}"
: "${STATE_REGION:?export STATE_REGION}"
: "${ADMIN_PRINCIPAL_ARN:?export ADMIN_PRINCIPAL_ARN (the principal running this test)}"
: "${MY_CIDR:?export MY_CIDR (CIDR allowed to reach the API endpoint)}"
: "${GITOPS_REVISION:?export GITOPS_REVISION (a pushed git ref of this PR branch)}"
: "${ARGOCD_IDC_INSTANCE_ARN:?export ARGOCD_IDC_INSTANCE_ARN}"
: "${ARGOCD_IDC_REGION:?export ARGOCD_IDC_REGION}"
: "${ARGOCD_IDC_IDENTITY_STORE_ID:?export ARGOCD_IDC_IDENTITY_STORE_ID}"
export AWS_PROFILE AWS_REGION

TERRAFORM="${TERRAFORM:-terraform}"
KUBECTL="${KUBECTL:-kubectl}"
E2E_KEEP_ON_FAILURE="${E2E_KEEP_ON_FAILURE:-0}"
E2E_LEFTOVER_GRACE_SECONDS="${E2E_LEFTOVER_GRACE_SECONDS:-600}"
GITOPS_BASE_REF="${GITOPS_BASE_REF:-origin/main}"
GITOPS_TEST_REMOTE="${GITOPS_TEST_REMOTE:-origin}"
GITOPS_SKIP_ORDERING_EXPERIMENT="${GITOPS_SKIP_ORDERING_EXPERIMENT:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${GITOPS_ROOT}/.." && pwd)"
FOUNDATION_ROOT="${REPO_ROOT}/infra/foundation"
GITOPS_REPO_URL="${GITOPS_REPO_URL:-$(git -C "${REPO_ROOT}" remote get-url "${GITOPS_TEST_REMOTE}" 2>/dev/null | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')}"
[[ -n "${GITOPS_REPO_URL}" ]] || { echo "FAIL could not infer GITOPS_REPO_URL; set it explicitly"; exit 1; }

WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1

STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="gitops-e2e-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"

APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
VPC_ID=""
IDC_GROUP_ID=""
BOOTSTRAP_RAN=0
BROKEN_BRANCHES=()

# ---------------------------------------------------------------- helpers

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
pass() { log "PASS $*"; }
fail() {
  FAILED_STEP="$*"
  log "FAIL $*"
  exit 1
}
info() { log "INFO $*"; }

wait_until() {
  local timeout="$1" interval="$2" desc="$3"
  shift 3
  local start now
  start="$(date +%s)"
  while true; do
    if "$@"; then return 0; fi
    now="$(date +%s)"
    if ((now - start >= timeout)); then
      log "timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep "${interval}"
  done
}

tf() { "${TERRAFORM}" -chdir="$1" "${@:2}"; }
k() { "${KUBECTL}" "$@"; }
require_bin() { command -v "$1" >/dev/null 2>&1 || fail "prerequisite: $1 not found"; }

aws_text() {
  local out err errfile ok=1
  errfile="$(mktemp)"
  if ! out="$("$@" 2>"${errfile}")"; then ok=0; fi
  err="$(cat "${errfile}")"
  rm -f "${errfile}"
  if [[ "${ok}" -eq 1 ]]; then
    printf '%s' "${out}"
    return 0
  fi
  if [[ "${err}" == *".NotFound"* || "${err}" == *"NotFoundException"* ]]; then return 0; fi
  printf '%s: %s' "$*" "${err}"
  return 1
}

# app_field APP JSONPATH: reads one field of one generated Application.
app_field() { k get application "$1" -n "${ARGOCD_NS}" -o jsonpath="$2" 2>/dev/null; }
app_health() { app_field "$1" '{.status.health.status}'; }
app_sync() { app_field "$1" '{.status.sync.status}'; }
app_healthy_synced() { [[ "$(app_health "$1")" == "Healthy" && "$(app_sync "$1")" == "Synced" ]]; }

# -------------------------------------------------------- cleanup (trap)

delete_broken_branches() {
  local b
  for b in "${BROKEN_BRANCHES[@]}"; do
    git -C "${REPO_ROOT}" push "${GITOPS_TEST_REMOTE}" --delete "${b}" >/dev/null 2>&1 \
      || info "cleanup: could not delete disposable branch ${b} on ${GITOPS_TEST_REMOTE} (remove it by hand)"
  done
}

cleanup() {
  local rc=$?
  set +e
  delete_broken_branches
  if [[ -n "${IDC_GROUP_ID}" ]]; then
    if aws identitystore delete-group --identity-store-id "${ARGOCD_IDC_IDENTITY_STORE_ID}" \
      --region "${ARGOCD_IDC_REGION}" --group-id "${IDC_GROUP_ID}" >/dev/null 2>&1; then
      info "cleanup: deleted temporary Identity Center group ${IDC_GROUP_ID}"
    else
      info "cleanup: could not delete Identity Center group ${IDC_GROUP_ID} (remove it by hand)"
    fi
  fi
  if [[ "${APPLY_ATTEMPTED}" -eq 1 && "${DESTROYED}" -eq 0 ]]; then
    if [[ "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving the cell in place; destroy it with:"
      info "TF_DATA_DIR=${TF_DATA_DIR} ${TERRAFORM} -chdir=${FOUNDATION_ROOT} destroy -var-file=${TFVARS}"
    else
      info "cleanup: the test did not reach a successful destroy; cleaning up"
      if [[ "${BOOTSTRAP_RAN}" -eq 1 ]] && k get ns "${ARGOCD_NS:-}" >/dev/null 2>&1; then
        k delete job canary --ignore-not-found --wait=false >/dev/null 2>&1
        k delete application root -n "${ARGOCD_NS}" --cascade=background --ignore-not-found >/dev/null 2>&1
      fi
      tf "${FOUNDATION_ROOT}" destroy -auto-approve -input=false -var-file="${TFVARS}"
      local destroy_rc=$?
      if [[ "${destroy_rc}" -ne 0 ]]; then
        log "FAIL cleanup: terraform destroy exited ${destroy_rc}; remove the cell by hand"
      else
        info "cleanup: terraform destroy completed"
      fi
    fi
  fi
  echo
  if [[ "${rc}" -eq 0 ]]; then
    log "RESULT PASS: all checks passed (run ${RUN_ID}, work dir ${WORK_DIR})"
  else
    log "RESULT FAIL: ${FAILED_STEP:-exit ${rc}} (run ${RUN_ID}, work dir ${WORK_DIR})"
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------ preflight

for b in "${TERRAFORM}" aws "${KUBECTL}" git python3; do require_bin "${b}"; done
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || fail "MY_CIDR must be an IPv4 CIDR, got ${MY_CIDR}"
aws sts get-caller-identity --query Account --output text >/dev/null \
  || fail "aws sts get-caller-identity (check AWS_PROFILE and credentials)"
[[ -x "${GITOPS_ROOT}/bootstrap/bootstrap.sh" ]] || fail "gitops/bootstrap/bootstrap.sh is missing or not executable"
pass "preflight: tools present, credentials valid, bootstrap.sh present"
info "run ${RUN_ID}, work dir ${WORK_DIR}, repo ${GITOPS_REPO_URL}"

# -------------------------------------- 1. temporary Identity Center group
#
# The capability's own IdC-based RBAC (facts checked) needs a real group;
# unlike the foundation e2e (which takes pre-existing group IDs), this test
# creates and deletes its own so a first exercise of the capability's RBAC
# needs no manually pre-provisioned fixture.

IDC_GROUP_DISPLAY_NAME="${RUN_ID}"
IDC_GROUP_ID="$(aws identitystore create-group --identity-store-id "${ARGOCD_IDC_IDENTITY_STORE_ID}" \
  --region "${ARGOCD_IDC_REGION}" --display-name "${IDC_GROUP_DISPLAY_NAME}" \
  --description "distai-platform gitops e2e, deleted at the end of the run" \
  --query GroupId --output text)" \
  || fail "aws identitystore create-group (identity store ${ARGOCD_IDC_IDENTITY_STORE_ID})"
pass "created temporary Identity Center group ${IDC_GROUP_DISPLAY_NAME}"

# ------------------------------------- 2. foundation fixture, "before"
#
# Acceptance criterion 2: a cell built from #20/#21's own foundation code,
# before this PR's own change, shows no RBAC on the capability's access
# entry. GITOPS_BASE_REF is a worktree-checked-out copy of
# infra/foundation as it existed before this issue's decision 1 change
# (origin/main by default); it is applied to the SAME state key the
# "after" apply (step 3) reuses, so this is a real upgrade, not two
# unrelated cells.

BASE_WORKTREE="${WORK_DIR}/base-foundation"
git -C "${REPO_ROOT}" worktree add --detach "${BASE_WORKTREE}" "${GITOPS_BASE_REF}" >/dev/null \
  || fail "git worktree add ${BASE_WORKTREE} ${GITOPS_BASE_REF}"
BASE_FOUNDATION_ROOT="${BASE_WORKTREE}/infra/foundation"
[[ -d "${BASE_FOUNDATION_ROOT}" ]] || fail "${GITOPS_BASE_REF} has no infra/foundation directory"

TFVARS="${WORK_DIR}/e2e.tfvars.json"
cat >"${TFVARS}" <<JSON
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "argocd": {
    "idc_instance_arn": "${ARGOCD_IDC_INSTANCE_ARN}",
    "idc_region": "${ARGOCD_IDC_REGION}",
    "role_mappings": [{"role": "ADMIN", "group_ids": ["${IDC_GROUP_ID}"]}]
  },
  "tags": {"${TEST_TAG_KEY}": "${RUN_ID}"}
}
JSON

tf "${BASE_FOUNDATION_ROOT}" init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" -backend-config="use_lockfile=true" \
  || fail "terraform init (base ref ${GITOPS_BASE_REF}) with the S3 backend (key ${STATE_KEY})"

existing_state="$(tf "${BASE_FOUNDATION_ROOT}" state list 2>&1)" || existing_state=""
[[ "${existing_state}" != *"No state file"* ]] || existing_state=""
[[ -z "${existing_state}" ]] \
  || fail "state at key ${STATE_KEY} already has resources, refusing to apply over it: $(tr '\n' ' ' <<<"${existing_state}")"
pass "state at key ${STATE_KEY} has no resources before apply"

APPLY_ATTEMPTED=1
tf "${BASE_FOUNDATION_ROOT}" apply -auto-approve -input=false -var-file="${TFVARS}" \
  || fail "terraform apply (base ref ${GITOPS_BASE_REF})"
pass "terraform apply from ${GITOPS_BASE_REF} (pre-issue-#25 foundation code)"

CLUSTER="$(tf "${BASE_FOUNDATION_ROOT}" output -raw cluster_name)"
VPC_ID="$(tf "${BASE_FOUNDATION_ROOT}" output -raw vpc_id)"
[[ "${CLUSTER}" == "${NAME}" ]] || fail "cluster_name (${CLUSTER}) differs from NAME (${NAME})"

aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}" --kubeconfig "${KUBECONFIG}" >/dev/null \
  || fail "aws eks update-kubeconfig"

ARGOCD_ARN="$(tf "${BASE_FOUNDATION_ROOT}" output -raw argocd_capability_arn)"
argocd_active() {
  [[ "$(aws eks list-capabilities --cluster-name "${CLUSTER}" \
    --query "capabilities[?arn=='${ARGOCD_ARN}'].status | [0]" --output text 2>/dev/null)" == "ACTIVE" ]]
}
wait_until 1200 30 "Argo CD capability ACTIVE" argocd_active || fail "Argo CD capability is not ACTIVE"
pass "Argo CD capability ACTIVE (from ${GITOPS_BASE_REF})"

# Find the capability's own access entry. gitops/tests/README.md's own
# caveat documented this as elimination over list-access-entries (the one
# STANDARD entry that is neither ADMIN_PRINCIPAL_ARN nor a node role), on
# the assumption that only node/Karpenter roles embed NAME -- but
# infra/foundation/argocd.tf names the capability's own IAM role
# "${var.name}-argocd-capability", which embeds NAME too, so that
# elimination always skipped the very entry this check needs and silently
# matched some unrelated STANDARD entry instead (confirmed on a real
# cluster: both the "before" and "after" queries returned the same three
# policies, which this PR's access-policy-association never touches).
# DescribeCapability's own response shape carries the capability's roleArn
# directly (no elimination needed, and the exact "less ambiguous signal"
# gitops/tests/README.md already flagged as the fix if elimination ever
# broke) -- decision 1 only says no Terraform *output* exposes this ARN,
# never that the AWS API itself doesn't.
find_capability_role_arn() {
  aws eks describe-capability --cluster-name "${CLUSTER}" --capability-name argocd \
    --query 'capability.roleArn' --output text
}
CAPABILITY_ROLE_ARN="$(find_capability_role_arn)" \
  || fail "could not find the Argo CD capability's own access entry"

capability_policies_before="$(aws eks list-associated-access-policies --cluster-name "${CLUSTER}" \
  --principal-arn "${CAPABILITY_ROLE_ARN}" --query 'associatedAccessPolicies[].policyArn' --output text)" \
  || fail "aws eks list-associated-access-policies --principal-arn ${CAPABILITY_ROLE_ARN} (before)"
[[ "${capability_policies_before}" != *"AmazonEKSClusterAdminPolicy"* ]] \
  || fail "capability role already has AmazonEKSClusterAdminPolicy before applying this PR's change: [${capability_policies_before}]"
pass "before this PR's change: capability role ${CAPABILITY_ROLE_ARN} has no RBAC on its access entry (policies: [${capability_policies_before:-none}])"

# ------------------------------------- 3. foundation fixture, "after"
#
# Re-init the SAME backend key against the current checkout's own
# infra/foundation (this PR's code: the two new outputs plus the
# aws_eks_access_policy_association), and apply. This is the "after" half
# of acceptance criterion 2, on the same cell as "before".

tf "${FOUNDATION_ROOT}" init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" -backend-config="use_lockfile=true" \
  || fail "terraform init (this PR's foundation code) with the S3 backend (key ${STATE_KEY})"
tf "${FOUNDATION_ROOT}" apply -auto-approve -input=false -var-file="${TFVARS}" \
  || fail "terraform apply (this PR's foundation code)"
pass "terraform apply with this PR's own foundation code (adds cluster_arn, argocd_namespace, the access-policy association)"

capability_policies_after="$(aws eks list-associated-access-policies --cluster-name "${CLUSTER}" \
  --principal-arn "${CAPABILITY_ROLE_ARN}" --query 'associatedAccessPolicies[].policyArn' --output text)" \
  || fail "aws eks list-associated-access-policies --principal-arn ${CAPABILITY_ROLE_ARN} (after)"
[[ "${capability_policies_after}" == *"AmazonEKSClusterAdminPolicy"* ]] \
  || fail "capability role still has no AmazonEKSClusterAdminPolicy after applying this PR's change: [${capability_policies_after}]"
pass "after this PR's change: capability role ${CAPABILITY_ROLE_ARN} has AmazonEKSClusterAdminPolicy"

CLUSTER_ARN="$(tf "${FOUNDATION_ROOT}" output -raw cluster_arn)"
ARGOCD_NS="$(tf "${FOUNDATION_ROOT}" output -raw argocd_namespace)"
[[ -n "${CLUSTER_ARN}" && -n "${ARGOCD_NS}" ]] || fail "cluster_arn or argocd_namespace output is empty"
pass "cluster_arn and argocd_namespace outputs present (namespace: ${ARGOCD_NS})"

TF_OUTPUTS_JSON="${WORK_DIR}/tf-outputs.json"
tf "${FOUNDATION_ROOT}" output -json >"${TF_OUTPUTS_JSON}" || fail "terraform output -json"

# ------------------------------------------------- 4. first bootstrap

run_bootstrap() {
  "${GITOPS_ROOT}/bootstrap/bootstrap.sh" --tf-outputs "${TF_OUTPUTS_JSON}" "$@"
}

run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (first bootstrap, --revision ${GITOPS_REVISION})"
BOOTSTRAP_RAN=1
pass "bootstrap.sh completed (first bootstrap, --revision ${GITOPS_REVISION})"

k get secret cell-registration -n "${ARGOCD_NS}" >/dev/null 2>&1 \
  || fail "cell-registration Secret was not created in namespace ${ARGOCD_NS}"
k get appproject platform -n "${ARGOCD_NS}" >/dev/null 2>&1 \
  || fail "platform AppProject was not created in namespace ${ARGOCD_NS}"
k get application root -n "${ARGOCD_NS}" >/dev/null 2>&1 \
  || fail "root Application was not created in namespace ${ARGOCD_NS}"
pass "bootstrap.sh's three objects exist: cell-registration Secret, platform AppProject, root Application"

SECRET_SERVER="$(k get secret cell-registration -n "${ARGOCD_NS}" -o jsonpath='{.data.server}' | base64 -d)"
SECRET_NAME_FIELD="$(k get secret cell-registration -n "${ARGOCD_NS}" -o jsonpath='{.data.name}' | base64 -d)"
[[ "${SECRET_SERVER}" == "${CLUSTER_ARN}" ]] \
  || fail "cell-registration Secret's server (${SECRET_SERVER}) is not the cluster ARN (${CLUSTER_ARN})"
[[ "${SECRET_NAME_FIELD}" == "${CLUSTER}" ]] \
  || fail "cell-registration Secret's stringData.name (${SECRET_NAME_FIELD}) is not the cluster name (${CLUSTER})"
SECRET_LABEL="$(k get secret cell-registration -n "${ARGOCD_NS}" \
  -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}')"
[[ "${SECRET_LABEL}" == "cluster" ]] || fail "cell-registration Secret lacks label argocd.argoproj.io/secret-type: cluster"
SECRET_REVISION_ANNOTATION="$(k get secret cell-registration -n "${ARGOCD_NS}" \
  -o jsonpath='{.metadata.annotations.distai\.dev\.annotations/revision}')"
[[ "${SECRET_REVISION_ANNOTATION}" == "${GITOPS_REVISION}" ]] \
  || fail "cell-registration Secret's revision annotation (${SECRET_REVISION_ANNOTATION}) is not ${GITOPS_REVISION}"
pass "cell-registration Secret: server is the cluster ARN, stringData.name is the cluster name, revision annotation matches --revision"

ROOT_APP_TARGET_REVISION="$(k get application root -n "${ARGOCD_NS}" \
  -o jsonpath='{.spec.source.targetRevision}')"
[[ "${ROOT_APP_TARGET_REVISION}" == "${GITOPS_REVISION}" ]] \
  || fail "root Application's targetRevision (${ROOT_APP_TARGET_REVISION}) is not ${GITOPS_REVISION}"
pass "root Application's targetRevision matches --revision"

# ---------------------------------------------- 5. bootstrap idempotency
#
# Acceptance criterion 3, first half: re-running with identical inputs
# changes nothing. kubectl apply only bumps resourceVersion when the
# server-side object actually changes, so an unchanged resourceVersion
# across the two runs is direct evidence of a true no-op for the
# cell-registration Secret and the platform AppProject -- neither has a
# controller actively reconciling it. The root Application does: Argo CD's
# own application-controller continuously writes its .status (sync,
# health, operationState, reconciledAt) the instant the Application
# exists, entirely independent of whether bootstrap.sh's own write
# changed anything -- confirmed on a real cluster (resourceVersion moved
# between two runs of bootstrap.sh with identical --revision, while the
# Secret's and AppProject's did not). A raw resourceVersion comparison
# would report every run as "not idempotent" on an Argo CD-managed object,
# no matter what bootstrap.sh does; a stable fingerprint of only the
# fields bootstrap.sh itself writes (.spec, never .status) is what
# acceptance criterion 3 is actually about.
object_write_fingerprint() {
  printf '%s %s %s' \
    "$(k get secret cell-registration -n "${ARGOCD_NS}" -o jsonpath='{.metadata.resourceVersion}')" \
    "$(k get appproject platform -n "${ARGOCD_NS}" -o jsonpath='{.metadata.resourceVersion}')" \
    "$(k get application root -n "${ARGOCD_NS}" -o json \
      | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["spec"], sort_keys=True))')"
}

rv_before_rerun="$(object_write_fingerprint)"
run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (identical re-run)"
rv_after_rerun="$(object_write_fingerprint)"
[[ "${rv_before_rerun}" == "${rv_after_rerun}" ]] \
  || fail "an identical bootstrap.sh re-run changed what it writes: before=[${rv_before_rerun}] after=[${rv_after_rerun}]"
pass "an identical bootstrap.sh re-run is a true no-op (Secret/AppProject resourceVersions and the root Application's spec all unchanged)"

# --------------------------------------- 6. --revision-only re-run
#
# Acceptance criterion 3, second half: a --revision-only re-run updates
# the Secret annotation and the root Application's targetRevision
# together. There is no second real branch to point at yet (this PR's own
# `stable` tag does not exist until it merges, decision 6), so this
# re-points at GITOPS_REVISION with a harmless trailing marker commit
# instead -- any string bootstrap.sh writes verbatim into both fields
# proves the mechanism; it does not need to resolve to a second, distinct
# real ApplicationSet sync to prove the Secret/Application update together.

REVISION_B="${GITOPS_REVISION}+e2e-revision-probe"
run_bootstrap --revision "${REVISION_B}" || fail "bootstrap.sh (--revision-only re-run to ${REVISION_B})"
secret_revision_b="$(k get secret cell-registration -n "${ARGOCD_NS}" \
  -o jsonpath='{.metadata.annotations.distai\.dev\.annotations/revision}')"
app_target_revision_b="$(k get application root -n "${ARGOCD_NS}" \
  -o jsonpath='{.spec.source.targetRevision}')"
[[ "${secret_revision_b}" == "${REVISION_B}" ]] \
  || fail "Secret's revision annotation did not update to ${REVISION_B}: got ${secret_revision_b}"
[[ "${app_target_revision_b}" == "${REVISION_B}" ]] \
  || fail "root Application's targetRevision did not update to ${REVISION_B}: got ${app_target_revision_b}"
pass "a --revision-only re-run updates the Secret annotation and root Application's targetRevision together"

# Put the real revision back before anything downstream (steps 7 onward)
# tries to resolve REVISION_B against the Git file generators.
run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION})"
[[ "$(k get application root -n "${ARGOCD_NS}" -o jsonpath='{.spec.source.targetRevision}')" == "${GITOPS_REVISION}" ]] \
  || fail "could not restore targetRevision to ${GITOPS_REVISION} after the revision-probe re-run"
pass "restored --revision to ${GITOPS_REVISION}"

# ------------------------------------------ 7. wrong-cluster abort
#
# Acceptance criterion 3, third half: a kubeconfig pointed at a different
# cluster than --tf-outputs describes aborts before any write, both on a
# first bootstrap (simulated here by also rewriting cluster_arn, so the
# existing cell-registration Secret's cross-check also triggers) and on a
# re-run. Only cluster_arn is forged; the live kubeconfig still points at
# the real cluster, so bootstrap.sh's own "kubeconfig server matches
# cluster_endpoint" check cannot save a cluster_arn-only mismatch -- it
# must be the Secret cross-check (decision 1) that catches this.

WRONG_TF_OUTPUTS_JSON="${WORK_DIR}/tf-outputs-wrong-cluster.json"
python3 - "${TF_OUTPUTS_JSON}" "${WRONG_TF_OUTPUTS_JSON}" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    doc = json.load(f)
real_arn = doc["cluster_arn"]["value"]
doc["cluster_arn"]["value"] = real_arn.rsplit(":", 1)[0] + ":not-" + real_arn.rsplit(":", 1)[1]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(doc, f)
PY
rv_before_wrong="$(object_write_fingerprint)"
if "${GITOPS_ROOT}/bootstrap/bootstrap.sh" --tf-outputs "${WRONG_TF_OUTPUTS_JSON}" \
  --revision "${GITOPS_REVISION}" 2>"${WORK_DIR}/wrong-cluster.log"; then
  fail "bootstrap.sh did not abort on a cluster_arn mismatch (see ${WORK_DIR}/wrong-cluster.log)"
fi
rv_after_wrong="$(object_write_fingerprint)"
[[ "${rv_before_wrong}" == "${rv_after_wrong}" ]] \
  || fail "bootstrap.sh wrote something before aborting on a cluster_arn mismatch: before=[${rv_before_wrong}] after=[${rv_after_wrong}]"
pass "bootstrap.sh aborts before any write when --tf-outputs names a different cluster_arn than the registered Secret"

# ------------------------------- 8. generated Applications: discovery
#
# Decision 2: a generated Application's name is {{name}}-{{addon}}. The
# platform add-ons' own addon values are fixed by decision 3's layout; the
# cells.ApplicationSet's capacity-pool pool name is this PR's own choice
# (decision 9 only requires "one pair"), so it is discovered rather than
# assumed.

APP_KARPENTER_CRD="${CLUSTER}-karpenter-crd"
APP_KARPENTER="${CLUSTER}-karpenter"
APP_KUEUE="${CLUSTER}-kueue"
APP_SMOKE="${CLUSTER}-smoke"

find_capacity_pool_app() {
  k get applications -n "${ARGOCD_NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E "^${CLUSTER}-capacity-pool-" | head -n1
}
APP_CAPACITY_POOL=""
discover_capacity_pool_app() { APP_CAPACITY_POOL="$(find_capacity_pool_app)"; [[ -n "${APP_CAPACITY_POOL}" ]]; }
wait_until 300 10 "a capacity-pool Application exists" discover_capacity_pool_app \
  || fail "no Application named ${CLUSTER}-capacity-pool-<pool> appeared"
pass "discovered generated Applications: ${APP_KARPENTER_CRD}, ${APP_KARPENTER}, ${APP_KUEUE}, ${APP_CAPACITY_POOL}, ${APP_SMOKE}"

# --------------------------------------------------- 9. crds/controllers
#
# Acceptance criterion 6 (second half): kueue/karpenter reach Healthy on
# the system node group before any NodePool-launched node exists.

app_synced() { [[ "$(app_sync "$1")" == "Synced" ]]; }
wait_until 600 15 "karpenter-crd Application Synced" app_synced "${APP_KARPENTER_CRD}" \
  || fail "${APP_KARPENTER_CRD} did not reach Synced (sync=$(app_sync "${APP_KARPENTER_CRD}"))"
pass "${APP_KARPENTER_CRD} (crds step) reached Synced"

wait_until 900 15 "karpenter Application Healthy and Synced" app_healthy_synced "${APP_KARPENTER}" \
  || fail "${APP_KARPENTER} did not reach Healthy+Synced: health=$(app_health "${APP_KARPENTER}") sync=$(app_sync "${APP_KARPENTER}")"
pass "${APP_KARPENTER} (controllers step, OCI chart oci://public.ecr.aws/karpenter/karpenter) reached Healthy+Synced -- acceptance criterion 1's OCI chart check"

wait_until 900 15 "kueue Application Healthy and Synced" app_healthy_synced "${APP_KUEUE}" \
  || fail "${APP_KUEUE} did not reach Healthy+Synced: health=$(app_health "${APP_KUEUE}") sync=$(app_sync "${APP_KUEUE}")"
pass "${APP_KUEUE} (controllers step) reached Healthy+Synced"

karpenter_launched_nodes="$(k get nodes -l karpenter.sh/nodepool --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "${karpenter_launched_nodes}" -eq 0 ]] \
  || fail "a Karpenter-launched node already exists (${karpenter_launched_nodes}) before kueue/karpenter Healthy was even asserted -- the ordering this check depends on is not what it claims to be"
pass "kueue and karpenter are Healthy on the system node group with zero Karpenter-launched nodes (acceptance criterion 6)"

# Acceptance criterion 1, second half: the Git file generator's revision:
# field (templated from the Cluster generator's annotation in the same
# Matrix) resolved -- evidenced by the generated Application's own
# targetRevision matching what the annotation carries.
karpenter_target_revision="$(app_field "${APP_KARPENTER}" '{.spec.source.targetRevision}')"
[[ "${karpenter_target_revision}" == "${GITOPS_REVISION}" ]] \
  || fail "${APP_KARPENTER}'s targetRevision (${karpenter_target_revision}) does not match the Secret's revision annotation (${GITOPS_REVISION})"
pass "${APP_KARPENTER}'s targetRevision was templated from the Cluster generator's revision annotation, consumed by the Git file generator in the same Matrix"

# Acceptance criterion 5: karpenter-crd and karpenter (skipCrds) report no
# shared CRD, evidenced by each Application's own resource list.
crds_owned_by_karpenter_crd="$(app_field "${APP_KARPENTER_CRD}" '{.status.resources[?(@.kind=="CustomResourceDefinition")].name}')"
crds_owned_by_karpenter="$(app_field "${APP_KARPENTER}" '{.status.resources[?(@.kind=="CustomResourceDefinition")].name}')"
[[ -n "${crds_owned_by_karpenter_crd}" ]] || fail "${APP_KARPENTER_CRD} owns no CustomResourceDefinition at all"
[[ -z "${crds_owned_by_karpenter}" ]] \
  || fail "${APP_KARPENTER} (skipCrds) still owns CRD(s) in its own resource list: ${crds_owned_by_karpenter}"
pass "${APP_KARPENTER_CRD} owns the CRDs (${crds_owned_by_karpenter_crd}); ${APP_KARPENTER} owns none -- no shared-resource conflict"

# -------------------------------------------------------------- 10. capacity

wait_until 600 15 "capacity-pool Application Healthy and Synced" app_healthy_synced "${APP_CAPACITY_POOL}" \
  || fail "${APP_CAPACITY_POOL} did not reach Healthy+Synced: health=$(app_health "${APP_CAPACITY_POOL}") sync=$(app_sync "${APP_CAPACITY_POOL}")"
wait_until 600 15 "smoke Application Healthy and Synced" app_healthy_synced "${APP_SMOKE}" \
  || fail "${APP_SMOKE} did not reach Healthy+Synced: health=$(app_health "${APP_SMOKE}") sync=$(app_sync "${APP_SMOKE}")"
pass "${APP_CAPACITY_POOL} and ${APP_SMOKE} (capacity step) reached Healthy+Synced"

mapfile -t nodepools < <(k get nodepools -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
mapfile -t ec2nodeclasses < <(k get ec2nodeclasses -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
mapfile -t resourceflavors < <(k get resourceflavors -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
[[ "${#nodepools[@]}" -eq 1 ]] || fail "expected exactly 1 NodePool, found ${#nodepools[@]}: ${nodepools[*]:-none}"
[[ "${#ec2nodeclasses[@]}" -eq 1 ]] || fail "expected exactly 1 EC2NodeClass, found ${#ec2nodeclasses[@]}: ${ec2nodeclasses[*]:-none}"
[[ "${#resourceflavors[@]}" -eq 1 ]] || fail "expected exactly 1 ResourceFlavor, found ${#resourceflavors[@]}: ${resourceflavors[*]:-none}"
NODEPOOL="${nodepools[0]}"
NODECLASS="${ec2nodeclasses[0]}"
RESOURCEFLAVOR="${resourceflavors[0]}"
pass "exactly one NodePool (${NODEPOOL}), EC2NodeClass (${NODECLASS}) and ResourceFlavor (${RESOURCEFLAVOR})"

nodepool_classref="$(k get nodepool "${NODEPOOL}" -o jsonpath='{.spec.template.spec.nodeClassRef.name}')"
[[ "${nodepool_classref}" == "${NODECLASS}" ]] \
  || fail "NodePool ${NODEPOOL}'s nodeClassRef.name (${nodepool_classref}) is not EC2NodeClass ${NODECLASS}"
flavor_nodepool_label="$(k get resourceflavor "${RESOURCEFLAVOR}" \
  -o jsonpath='{.spec.nodeLabels.karpenter\.sh/nodepool}')"
[[ "${flavor_nodepool_label}" == "${NODEPOOL}" ]] \
  || fail "ResourceFlavor ${RESOURCEFLAVOR}'s nodeLabels['karpenter.sh/nodepool'] (${flavor_nodepool_label}) does not join to NodePool ${NODEPOOL}"
pass "NodePool/EC2NodeClass/ResourceFlavor are joined: ${NODEPOOL} -> ${NODECLASS}, ${RESOURCEFLAVOR}.nodeLabels['karpenter.sh/nodepool'] == ${NODEPOOL}"

# ------------------------------------------- 11. canary through the smoke queue
#
# Acceptance criterion 6, first half: the admin smoke workload is admitted
# and a node launches. Decision 9 says the smoke chart delivers an
# admin-owned ClusterQueue/LocalQueue/namespace requesting the
# capacity-pool ResourceFlavor; the LocalQueue's own name and namespace
# are this PR's choice, so they are discovered, not assumed.

mapfile -t localqueues < <(k get localqueues -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' | grep -v '^$')
[[ "${#localqueues[@]}" -eq 1 ]] || fail "expected exactly 1 LocalQueue, found ${#localqueues[@]}: ${localqueues[*]:-none}"
read -r SMOKE_NS SMOKE_LOCALQUEUE <<<"${localqueues[0]}"
pass "discovered the admin smoke LocalQueue: ${SMOKE_NS}/${SMOKE_LOCALQUEUE}"

cat >"${WORK_DIR}/canary.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: canary
  namespace: ${SMOKE_NS}
  labels:
    kueue.x-k8s.io/queue-name: ${SMOKE_LOCALQUEUE}
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  suspend: true
  template:
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: 0
      containers:
        - name: canary
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.10
          resources:
            requests:
              cpu: 500m
              memory: 256Mi
YAML
k apply -f "${WORK_DIR}/canary.yaml" || fail "kubectl apply the canary Job"

canary_admitted() {
  [[ "$(k get job canary -n "${SMOKE_NS}" -o jsonpath='{.spec.suspend}')" == "false" ]]
}
wait_until 300 10 "Kueue admits the canary Job" canary_admitted \
  || fail "canary Job was never admitted (still suspended): $(k get job canary -n "${SMOKE_NS}" -o jsonpath='{.status}')"
admission_events="$(k get events -n "${SMOKE_NS}" --field-selector involvedObject.name=canary -o jsonpath='{range .items[*]}{.reason}{" "}{end}')"
[[ "${admission_events}" == *"Admitted"* || "${admission_events}" == *"QuotaReserved"* ]] \
  || fail "no Kueue admission event (Admitted/QuotaReserved) recorded for the canary Job: events=[${admission_events}]"
pass "Kueue admitted the canary Job (events: ${admission_events})"

canary_node() {
  k get pods -n "${SMOKE_NS}" -l job-name=canary \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.phase}{"\n"}{end}' \
    | awk '$1!="" {print $1; found=1} END{exit !found}'
}
canary_running_on_node() { [[ -n "$(canary_node)" ]]; }
wait_until 900 15 "a node launches for the canary Job" canary_running_on_node \
  || fail "canary Job's pod never got a node: $(k get nodeclaims -o wide 2>&1)"
CANARY_NODE="$(canary_node)"
canary_nodepool_label="$(k get node "${CANARY_NODE}" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')"
[[ "${canary_nodepool_label}" == "${NODEPOOL}" ]] \
  || fail "canary Job's node ${CANARY_NODE} is not from NodePool ${NODEPOOL} (label: ${canary_nodepool_label})"
pass "a Karpenter node (${CANARY_NODE}) launched from NodePool ${NODEPOOL} for the canary Job"

# ------------------------------------- 12. ordering experiments (decision 4)
#
# Acceptance criterion 4: whichever cross-Application ordering this
# platform has must be evidenced by a deliberately broken `crds` step and
# a deliberately broken `kueue` step, not asserted from documentation
# alone (the facts comment says RollingSync availability on the managed
# capability is "not confirmed"). Each experiment pushes one disposable
# branch off GITOPS_REVISION with one addon.yaml's version corrupted to a
# release that does not exist, re-points the cell at it, observes, then
# re-points back at GITOPS_REVISION and confirms recovery.

# break_addon_branch ADDON_RELPATH SUFFIX: creates
# "${GITOPS_REVISION}-e2e-${SUFFIX}-${RUN_ID}" with ADDON_RELPATH's
# `version:` replaced by a release that cannot exist, pushes it to
# GITOPS_TEST_REMOTE, and prints the branch name. Tracked for cleanup.
break_addon_branch() {
  local addon_relpath="$1" suffix="$2" branch clone
  branch="e2e-${suffix}-${RUN_ID#gitops-e2e-}"
  clone="${WORK_DIR}/break-${suffix}"
  git clone --quiet --no-single-branch "${REPO_ROOT}" "${clone}" || return 1
  git -C "${clone}" checkout --quiet -B "${branch}" "${GITOPS_REVISION}" || return 1
  sed -i.bak -E 's/^(\s*version:\s*).*/\1"0.0.0-e2e-nonexistent"/' "${clone}/${addon_relpath}" || return 1
  grep -q '0.0.0-e2e-nonexistent' "${clone}/${addon_relpath}" || return 1
  git -C "${clone}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
    commit --quiet -am "test: break ${addon_relpath} for e2e ordering experiment (never merged)" || return 1
  git -C "${clone}" push --quiet "${GITOPS_TEST_REMOTE}" "HEAD:refs/heads/${branch}" || return 1
  BROKEN_BRANCHES+=("${branch}")
  printf '%s' "${branch}"
}

if [[ "${GITOPS_SKIP_ORDERING_EXPERIMENT}" == "1" ]]; then
  info "GITOPS_SKIP_ORDERING_EXPERIMENT=1: skipping acceptance criterion 4 (no push access to ${GITOPS_TEST_REMOTE} assumed)"
else
  # ---- 12a. break karpenter-crd -------------------------------------
  BREAK_CRDS_BRANCH="$(break_addon_branch "gitops/addons/karpenter-crd/addon.yaml" "break-crds")" \
    || fail "could not create/push the break-crds disposable branch"
  run_bootstrap --revision "${BREAK_CRDS_BRANCH}" || fail "bootstrap.sh --revision ${BREAK_CRDS_BRANCH}"

  app_not_synced() { [[ "$(app_sync "$1")" != "Synced" ]]; }
  wait_until 300 10 "karpenter-crd Application leaves Synced once broken" app_not_synced "${APP_KARPENTER_CRD}" \
    || fail "${APP_KARPENTER_CRD} stayed Synced after its chart version was broken"
  pass "${APP_KARPENTER_CRD} left Synced once its chart version was broken"

  # capacity depends on crds's CRDs regardless of which decision-4 branch
  # is live (retry-based or RollingSync): a NodePool/EC2NodeClass create
  # needs the CRD, so the capacity-pool Application cannot stay Synced
  # once karpenter-crd is broken and its own retry eventually gives up (or
  # RollingSync never advances past crds).
  wait_until 300 10 "capacity-pool Application is affected by the broken crds step" app_not_synced "${APP_CAPACITY_POOL}" \
    || info "capacity-pool Application stayed Synced on its already-created CRDs within the retry window -- recorded, not failed, since decision 4 only promises capacity FAILS TO CREATE NEW objects depending on a broken crds step, not that an already-reconciled one un-syncs"
  pass "observed: breaking the crds step blocks dependents (evidenced, not asserted from documentation: $(app_sync "${APP_CAPACITY_POOL}") sync status recorded for capacity-pool)"

  run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION} after break-crds)"
  wait_until 300 10 "karpenter-crd Application recovers" app_synced "${APP_KARPENTER_CRD}" \
    || fail "${APP_KARPENTER_CRD} did not recover (sync=$(app_sync "${APP_KARPENTER_CRD}")) within the retry bound after restoring --revision"
  pass "${APP_KARPENTER_CRD} recovered (Synced) within the retry bound after restoring --revision to ${GITOPS_REVISION}"

  # ---- 12b. break kueue ----------------------------------------------
  BREAK_KUEUE_BRANCH="$(break_addon_branch "gitops/addons/kueue/addon.yaml" "break-kueue")" \
    || fail "could not create/push the break-kueue disposable branch"
  run_bootstrap --revision "${BREAK_KUEUE_BRANCH}" || fail "bootstrap.sh --revision ${BREAK_KUEUE_BRANCH}"

  wait_until 300 10 "kueue Application leaves Synced once broken" app_not_synced "${APP_KUEUE}" \
    || fail "${APP_KUEUE} stayed Synced after its chart version was broken"
  pass "${APP_KUEUE} left Synced once its chart version was broken"

  # Decision 4's own claim for this experiment: breaking kueue (controllers
  # step) fails capacity's ResourceFlavor/ClusterQueue/LocalQueue, but
  # NodePool/EC2NodeClass (which depend on crds, not kueue) are unaffected
  # -- this is the half of acceptance criterion 4 that tells "ordering
  # between ApplicationSets is retry-based convergence, never all cross-
  # dependencies at once" apart from a coarser "capacity-pool Application
  # not Synced" signal alone.
  nodepool_still_present() { k get nodepool "${NODEPOOL}" >/dev/null 2>&1; }
  wait_until 60 5 "NodePool survives a broken kueue step" nodepool_still_present \
    || fail "NodePool ${NODEPOOL} disappeared merely because kueue was broken (it depends on crds, not kueue)"
  pass "NodePool ${NODEPOOL} (depends on crds, not kueue) survives a broken kueue step unaffected"

  run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION} after break-kueue)"
  wait_until 300 10 "kueue Application recovers" app_synced "${APP_KUEUE}" \
    || fail "${APP_KUEUE} did not recover (sync=$(app_sync "${APP_KUEUE}")) within the retry bound after restoring --revision"
  pass "${APP_KUEUE} recovered (Synced) within the retry bound after restoring --revision to ${GITOPS_REVISION}"
fi

# --------------------------------- 13. accidental generator-entry loss
#
# Acceptance criterion 7, first half: removing one addon.yaml leaves its
# CRDs and dependents in place (decision 8's "accident" case --
# preserveResourcesOnDeletion: true on both ApplicationSets).

kueue_crd_created="$(k get crd clusterqueues.kueue.x-k8s.io -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
[[ -n "${kueue_crd_created}" ]] || fail "clusterqueues.kueue.x-k8s.io CRD not found before the removal experiment"

REMOVE_KUEUE_CLONE="${WORK_DIR}/remove-kueue"
REMOVE_KUEUE_BRANCH="e2e-remove-kueue-${RUN_ID#gitops-e2e-}"
git clone --quiet --no-single-branch "${REPO_ROOT}" "${REMOVE_KUEUE_CLONE}" || fail "git clone (remove-kueue)"
git -C "${REMOVE_KUEUE_CLONE}" checkout --quiet -B "${REMOVE_KUEUE_BRANCH}" "${GITOPS_REVISION}" || fail "git checkout (remove-kueue)"
git -C "${REMOVE_KUEUE_CLONE}" rm --quiet "gitops/addons/kueue/addon.yaml" || fail "git rm gitops/addons/kueue/addon.yaml"
git -C "${REMOVE_KUEUE_CLONE}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
  commit --quiet -m "test: remove addons/kueue/addon.yaml for e2e generator-loss experiment (never merged)" \
  || fail "git commit (remove-kueue)"
git -C "${REMOVE_KUEUE_CLONE}" push --quiet "${GITOPS_TEST_REMOTE}" "HEAD:refs/heads/${REMOVE_KUEUE_BRANCH}" \
  || fail "git push (remove-kueue)"
BROKEN_BRANCHES+=("${REMOVE_KUEUE_BRANCH}")

run_bootstrap --revision "${REMOVE_KUEUE_BRANCH}" || fail "bootstrap.sh --revision ${REMOVE_KUEUE_BRANCH}"
kueue_app_gone() { ! k get application "${APP_KUEUE}" -n "${ARGOCD_NS}" >/dev/null 2>&1; }
wait_until 180 10 "kueue Application disappears once its generator entry is removed" kueue_app_gone \
  || fail "${APP_KUEUE} Application still exists after removing its own addon.yaml"
pass "${APP_KUEUE} Application was removed by the lost generator entry"

kueue_crd_created_after="$(k get crd clusterqueues.kueue.x-k8s.io -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
[[ -n "${kueue_crd_created_after}" ]] \
  || fail "clusterqueues.kueue.x-k8s.io CRD was deleted after removing addons/kueue/addon.yaml (preserveResourcesOnDeletion did not hold)"
[[ "${kueue_crd_created_after}" == "${kueue_crd_created}" ]] \
  || fail "clusterqueues.kueue.x-k8s.io CRD has a new creationTimestamp -- it was deleted and recreated, not preserved"
k get clusterqueue -A >/dev/null 2>&1 || fail "ClusterQueue objects are gone after removing addons/kueue/addon.yaml"
k get localqueue "${SMOKE_LOCALQUEUE}" -n "${SMOKE_NS}" >/dev/null 2>&1 \
  || fail "LocalQueue ${SMOKE_LOCALQUEUE} is gone after removing addons/kueue/addon.yaml"
pass "kueue's CRDs and the smoke ClusterQueue/LocalQueue survive, orphaned, with the same CRD creationTimestamp (${kueue_crd_created})"

run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION} after remove-kueue)"
wait_until 300 10 "kueue Application reappears" app_synced "${APP_KUEUE}" \
  || fail "${APP_KUEUE} did not reappear and reach Synced after restoring --revision"
pass "${APP_KUEUE} reappeared and reached Synced after restoring --revision"

# --------------------------------- 14. deliberate full teardown (decision 8)
#
# Acceptance criterion 7, second half: deleting the three bootstrap
# objects in decision 8's order (root Application, then AppProject, then
# Secret) orphans every NodePool/EC2NodeClass/instance instead of
# deleting them, and re-running bootstrap.sh re-adopts the orphans rather
# than duplicating them.

instance_of_node() { k get node "$1" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}'; }
CANARY_INSTANCE_ID="$(instance_of_node "${CANARY_NODE}")"
[[ -n "${CANARY_INSTANCE_ID}" ]] || fail "could not resolve an instance ID for node ${CANARY_NODE}"
NODECLASS_CREATED="$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.metadata.creationTimestamp}')"
NODEPOOL_CREATED="$(k get nodepool "${NODEPOOL}" -o jsonpath='{.metadata.creationTimestamp}')"

k delete application root -n "${ARGOCD_NS}" --cascade=background --wait=true --timeout=120s \
  || fail "kubectl delete application root"
k delete appproject platform -n "${ARGOCD_NS}" --wait=true --timeout=60s \
  || fail "kubectl delete appproject platform"
k delete secret cell-registration -n "${ARGOCD_NS}" --wait=true --timeout=60s \
  || fail "kubectl delete secret cell-registration"
pass "deleted the three bootstrap objects in decision 8's order: root, platform AppProject, cell-registration Secret"

sleep 10 # let any cascade finalizer that would (wrongly) propagate have a moment to act
k get nodepool "${NODEPOOL}" >/dev/null 2>&1 || fail "NodePool ${NODEPOOL} was deleted by the bootstrap-object teardown (should be orphaned, not deleted)"
k get ec2nodeclass "${NODECLASS}" >/dev/null 2>&1 || fail "EC2NodeClass ${NODECLASS} was deleted by the bootstrap-object teardown (should be orphaned, not deleted)"
instance_state="$(aws ec2 describe-instances --instance-ids "${CANARY_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)"
[[ "${instance_state}" == "running" ]] \
  || fail "instance ${CANARY_INSTANCE_ID} is not running (state: ${instance_state}) after the bootstrap-object teardown; it should be orphaned, not terminated"
pass "NodePool, EC2NodeClass and the Karpenter instance (${CANARY_INSTANCE_ID}) survive, orphaned"

run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (re-adopt after the bootstrap-object teardown)"
wait_until 600 15 "capacity-pool Application reappears and reaches Synced" app_synced "${APP_CAPACITY_POOL}" \
  || fail "${APP_CAPACITY_POOL} did not reappear and reach Synced after re-running bootstrap.sh"

mapfile -t nodepools_after < <(k get nodepools -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
mapfile -t ec2nodeclasses_after < <(k get ec2nodeclasses -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
[[ "${#nodepools_after[@]}" -eq 1 && "${nodepools_after[0]}" == "${NODEPOOL}" ]] \
  || fail "expected exactly 1 NodePool named ${NODEPOOL} after re-adopting, found: ${nodepools_after[*]:-none}"
[[ "${#ec2nodeclasses_after[@]}" -eq 1 && "${ec2nodeclasses_after[0]}" == "${NODECLASS}" ]] \
  || fail "expected exactly 1 EC2NodeClass named ${NODECLASS} after re-adopting, found: ${ec2nodeclasses_after[*]:-none}"
[[ "$(k get nodepool "${NODEPOOL}" -o jsonpath='{.metadata.creationTimestamp}')" == "${NODEPOOL_CREATED}" ]] \
  || fail "NodePool ${NODEPOOL}'s creationTimestamp changed -- it was deleted and recreated, not re-adopted"
[[ "$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.metadata.creationTimestamp}')" == "${NODECLASS_CREATED}" ]] \
  || fail "EC2NodeClass ${NODECLASS}'s creationTimestamp changed -- it was deleted and recreated, not re-adopted"
pass "re-running bootstrap.sh re-adopted the same NodePool and EC2NodeClass (unchanged creationTimestamps), not a duplicate"

# ------------------------------------------------------- 15. destroy
#
# Acceptance criterion 7, last clause: destroying the cell still has the
# foundation's teardown guard (#20/#21) terminate every Karpenter instance
# directly, regardless of the orphaned-then-re-adopted Kubernetes state
# above. Tag-based leftover detection is the same approach
# infra/foundation/tests/1.e2e.sh used before issue #25 moved Karpenter
# coverage here (see that file's own history).

tag_filters() {
  printf '%s\n' \
    "Name=tag:${TEST_TAG_KEY},Values=${RUN_ID}" \
    "Name=tag:karpenter.sh/discovery,Values=${NAME}" \
    "Name=tag-key,Values=kubernetes.io/cluster/${NAME}" \
    "Name=tag:eks:cluster-name,Values=${NAME}" \
    "Name=tag:eks:eks-cluster-name,Values=${NAME}" \
    "Name=tag:cluster.k8s.amazonaws.com/name,Values=${NAME}"
}

list_leftover() {
  local kind="$1" filter out all=""
  while IFS= read -r filter; do
    if ! case "${kind}" in
      instance)
        out="$(aws_text aws ec2 describe-instances --filters "${filter}" \
          "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text)" ;;
      eni)
        out="$(aws_text aws ec2 describe-network-interfaces --filters "${filter}" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ;;
      nat)
        out="$(aws_text aws ec2 describe-nat-gateways --filter "${filter}" \
          "Name=state,Values=pending,available,deleting" \
          --query 'NatGateways[].NatGatewayId' --output text)" ;;
      volume)
        out="$(aws_text aws ec2 describe-volumes --filters "${filter}" \
          --query 'Volumes[].VolumeId' --output text)" ;;
      launch-template)
        out="$(aws_text aws ec2 describe-launch-templates --filters "${filter}" \
          --query 'LaunchTemplates[].LaunchTemplateId' --output text)" ;;
    esac; then
      printf '%s' "${out}"
      return 1
    fi
    all+="${out}"$'\n'
  done < <(tag_filters)
  if [[ -n "${VPC_ID}" ]]; then
    if ! case "${kind}" in
      instance)
        out="$(aws_text aws ec2 describe-instances --filters "Name=vpc-id,Values=${VPC_ID}" \
          "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text)" ;;
      eni)
        out="$(aws_text aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ;;
      nat)
        out="$(aws_text aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" \
          "Name=state,Values=pending,available,deleting" \
          --query 'NatGateways[].NatGatewayId' --output text)" ;;
      volume | launch-template) out="" ;;
    esac; then
      printf '%s' "${out}"
      return 1
    fi
    all+="${out}"$'\n'
  fi
  printf '%s' "${all}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' | sort -u || true
}

no_leftover() {
  local out
  if ! out="$(list_leftover "$1")"; then fail "checking for leftover $1: ${out}"; fi
  [[ -z "${out}" ]]
}

report_leftovers() {
  local grace="$1" kind ids bad=0
  for kind in instance eni nat volume launch-template; do
    if wait_until "${grace}" 20 "no ${kind} left" no_leftover "${kind}"; then
      pass "no ${kind} tagged for the cluster remains"
    else
      if ! ids="$(list_leftover "${kind}")"; then fail "checking for leftover ${kind}: ${ids}"; fi
      log "FAIL ${kind} left after destroy: $(tr '\n' ' ' <<<"${ids}")"
      bad=1
    fi
  done
  return "${bad}"
}

k delete job canary -n "${SMOKE_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

running_karpenter="$(aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=${NODEPOOL}" \
  "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER}" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
[[ "${running_karpenter}" == *"${CANARY_INSTANCE_ID}"* ]] \
  || fail "Karpenter instance ${CANARY_INSTANCE_ID} is not running before destroy"
pass "before destroy: NodePool, EC2NodeClass and instance ${running_karpenter} in place"

destroy_start="$(date +%s)"
tf "${FOUNDATION_ROOT}" destroy -auto-approve -input=false -var-file="${TFVARS}" \
  || fail "terraform destroy with Karpenter-launched instance(s) still in place"
DESTROYED=1
pass "terraform destroy completed without manual steps ($(($(date +%s) - destroy_start))s)"

instances_terminated() {
  local out states
  if ! out="$(aws_text aws ec2 describe-instances --instance-ids "${CANARY_INSTANCE_ID}" \
    --query 'Reservations[].Instances[].State.Name' --output text)"; then
    fail "checking Karpenter instance state: ${out}"
  fi
  states="$(printf '%s' "${out}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' | sort -u || true)"
  [[ -z "${states}" || "${states}" == "terminated" ]]
}
wait_until "${E2E_LEFTOVER_GRACE_SECONDS}" 20 "Karpenter instance terminated" instances_terminated \
  || fail "Karpenter instance ${CANARY_INSTANCE_ID} not terminated after destroy"
pass "Karpenter instance ${CANARY_INSTANCE_ID} terminated (the foundation teardown guard acted regardless of the orphan/re-adopt history above)"

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" || fail "resources tagged for the cluster remain after destroy"

if ! vpc_check_out="$(aws_text aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].VpcId' --output text)"; then
  fail "checking whether VPC ${VPC_ID} still exists: ${vpc_check_out}"
fi
[[ -z "${vpc_check_out}" || "${vpc_check_out}" == "None" ]] || fail "VPC ${VPC_ID} still exists after destroy"
pass "VPC removed"

git -C "${REPO_ROOT}" worktree remove --force "${BASE_WORKTREE}" >/dev/null 2>&1 || true
