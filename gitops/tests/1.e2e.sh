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
#   8. (issue #28, only with GITOPS_RUN_ACCEL_E2E=1) the `accelerators`
#      step: on this script's own cell (the GPU cell) and on a second,
#      separately built Trainium cell, the device-plugin release reaches
#      Healthy+Synced, the method-labeled NodePool launches a real spot
#      node, a Layer 1 pod requesting one whole device (nvidia.com/gpu: 1,
#      aws.amazon.com/neuron: 1 -- never neuroncore) runs, `nvidia-smi -L`
#      / `neuron-ls` inside it report exactly one device, and no pod of the
#      other method's advertiser DaemonSet runs on that node; both cells
#      are destroyed with the same tagged-leftover sweep.
#
# GITOPS_RUN_ACCEL_E2E=1 coupling: this script's existing single cell
# (NAME) IS the GPU accelerator cell. NAME must equal dp-a19-gpu
# (ACCEL_GPU_CELL_NAME) for the checked-in gitops/cells/dp-a19-gpu/ fixture
# to apply, and every existing step (1-15) then runs unchanged against that
# cell's own single `gpu` NodePool and smoke queue; the preflight refuses
# any other NAME. The GPU cell's Region is AWS_REGION (g7.2xlarge spot is
# widely available; the issue's capacity survey names us-east-1). The
# Trainium cell is a second foundation cell (same infra/foundation module,
# same bootstrap.sh flow, own state key, TF_DATA_DIR and kubeconfig under
# E2E_WORK_DIR) in ACCEL_TRN_REGION, built after the GPU cell is destroyed
# (steps 16-19), reusing this run's ARGOCD_IDC_* inputs and temporary
# Identity Center group (Identity Center stays in ARGOCD_IDC_REGION while
# the cluster lives in ACCEL_TRN_REGION).
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
#   GITOPS_REPO_URL (inferred from `git remote get-url origin` -- read-only
#   clone source for every disposable branch below),
#   GITOPS_TEST_REPO_URL (https://github.com/littlemex/distai-platform.git
#   -- the push target for this test's own disposable branches; override
#   to run against a fork you have write access to),
#   GITOPS_TEST_TOKEN_SSM_PARAM (/relay/github/distai-platform) and
#   GITOPS_TEST_TOKEN_SSM_REGION (us-east-1) -- a GitHub token with
#   Contents: write on GITOPS_TEST_REPO_URL, read fresh from SSM Parameter
#   Store (SecureString) at each push/delete, never written to disk,
#   .git/config or a log (see push_disposable_branch()),
#   GITOPS_SKIP_ORDERING_EXPERIMENT (0 -- set to 1 to skip acceptance
#   criterion 4 if this token cannot write to GITOPS_TEST_REPO_URL; the
#   step 13 generator-entry-loss experiment and 2.upgrade.sh's own two
#   disposable branches have no such bypass, since their own acceptance
#   criteria need exactly this write),
#   GITOPS_RUN_ACCEL_E2E (0 -- set to 1 to add issue #28's accelerator
#   checks, item 8 above; 0 leaves this script's #25 behavior unchanged).
# Required only when GITOPS_RUN_ACCEL_E2E=1:
#   ACCEL_GPU_TEST_IMAGE -- an image with `nvidia-smi` on PATH (e.g. a
#   CUDA base image; the NVIDIA container runtime injects the binary for
#   images that request the `utility` driver capability) and `sleep`; no
#   repository file pins one, so this test does not guess a tag;
#   ACCEL_TRN_TEST_IMAGE -- an image with `neuron-ls` (aws-neuronx-tools)
#   on PATH and `sleep`, e.g. a Neuron deep learning container; same
#   reason for having no default.
# Optional when GITOPS_RUN_ACCEL_E2E=1:
#   ACCEL_GPU_CELL_NAME (dp-a19-gpu -- NAME must equal it),
#   ACCEL_TRN_CELL_NAME (dp-a19-trn -- the second cell's name; must have a
#   checked-in gitops/cells/<name>/capacity-pool/ fixture),
#   ACCEL_TRN_REGION (ap-southeast-4 -- where trn2.3xlarge spot is
#   available), ACCEL_POD_TIMEOUT_SECONDS (1800 -- how long a Layer 1 pod
#   may take to reach Running, spot launch and driver/plugin start
#   included).
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
GITOPS_SKIP_ORDERING_EXPERIMENT="${GITOPS_SKIP_ORDERING_EXPERIMENT:-0}"
GITOPS_TEST_REPO_URL="${GITOPS_TEST_REPO_URL:-https://github.com/littlemex/distai-platform.git}"
GITOPS_TEST_TOKEN_SSM_PARAM="${GITOPS_TEST_TOKEN_SSM_PARAM:-/relay/github/distai-platform}"
GITOPS_TEST_TOKEN_SSM_REGION="${GITOPS_TEST_TOKEN_SSM_REGION:-us-east-1}"
GITOPS_RUN_ACCEL_E2E="${GITOPS_RUN_ACCEL_E2E:-0}"
ACCEL_GPU_CELL_NAME="${ACCEL_GPU_CELL_NAME:-dp-a19-gpu}"
ACCEL_TRN_CELL_NAME="${ACCEL_TRN_CELL_NAME:-dp-a19-trn}"
ACCEL_TRN_REGION="${ACCEL_TRN_REGION:-ap-southeast-4}"
ACCEL_POD_TIMEOUT_SECONDS="${ACCEL_POD_TIMEOUT_SECONDS:-1800}"
ACCEL_GPU_TEST_IMAGE="${ACCEL_GPU_TEST_IMAGE:-}"
ACCEL_TRN_TEST_IMAGE="${ACCEL_TRN_TEST_IMAGE:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${GITOPS_ROOT}/.." && pwd)"
FOUNDATION_ROOT="${REPO_ROOT}/infra/foundation"
GITOPS_REPO_URL="${GITOPS_REPO_URL:-$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')}"
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

# Issue #28: the second (Trainium) cell's own state, parallel to the first
# cell's TFVARS/APPLY_ATTEMPTED/DESTROYED/VPC_ID/BOOTSTRAP_RAN above. Its
# own TF_DATA_DIR and kubeconfig keep the first cell's untouched: the two
# cells are never driven through one Terraform data dir or one kubeconfig.
ACCEL_TEST_NS="distai-accel-e2e"
TRN_STATE_KEY="distai-platform/${ACCEL_TRN_REGION}/${ACCEL_TRN_CELL_NAME}/foundation"
TRN_TF_DATA_DIR="${WORK_DIR}/.terraform-trn"
TRN_KUBECONFIG="${WORK_DIR}/kubeconfig-trn"
TRN_TFVARS="${WORK_DIR}/e2e-trn.tfvars.json"
TRN_APPLY_ATTEMPTED=0
TRN_DESTROYED=0
TRN_BOOTSTRAP_RAN=0
TRN_VPC_ID=""
TRN_ARGOCD_NS=""

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

# ------------------------------------- authenticated disposable branches
#
# Every branch this test ever pushes lives under refs/heads/e2e/<RUN_ID>/*
# -- this run's own namespace, never anywhere else -- and is deleted again
# before the run ends, success or failure. The GitHub token (Contents:
# write on GITOPS_TEST_REPO_URL only, per the distai-platform skill) is
# read fresh from SSM at each push/delete through a one-shot GIT_ASKPASS
# script, never written to disk beyond that script's own short lifetime,
# never in .git/config, never on a command line, and never under `set -x`
# (every block below runs with it off, restored after).

# assert_disposable_ref BRANCH: the guard. Refuses anything outside this
# run's own e2e/<RUN_ID>/* namespace before push_disposable_branch() or
# delete_disposable_branch() ever shells out.
assert_disposable_ref() {
  case "$1" in
    "e2e/${RUN_ID}/"*) return 0 ;;
    *)
      echo "refusing to touch refs/heads/$1: outside this run's own e2e/${RUN_ID}/* namespace" >&2
      return 1
      ;;
  esac
}

# github_askpass_script: writes a one-shot GIT_ASKPASS helper that prints
# the token read fresh from SSM, and prints its path. The token exists in
# this process' memory only long enough to write the file; the file is
# deleted by the caller immediately after the one git command that needs
# it. Returns non-zero (printing nothing) if the token cannot be read, so
# a caller's `||` always sees a real failure instead of an empty path.
github_askpass_script() {
  local token askpass
  token="$(aws ssm get-parameter --with-decryption --name "${GITOPS_TEST_TOKEN_SSM_PARAM}" \
    --region "${GITOPS_TEST_TOKEN_SSM_REGION}" --query Parameter.Value --output text 2>/dev/null)" || return 1
  [[ -n "${token}" && "${token}" != "None" ]] || return 1
  askpass="$(mktemp)"
  chmod 700 "${askpass}"
  { set +x
    {
      printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in\n'
      printf '  Username*) echo %q ;;\n' "x-access-token"
      printf '  *) echo %q ;;\n' "${token}"
      printf 'esac\n'
    } >"${askpass}"
  } 2>/dev/null
  token=""
  printf '%s' "${askpass}"
}

# push_disposable_branch CLONE_DIR BRANCH: pushes CLONE_DIR's HEAD to
# refs/heads/BRANCH on GITOPS_TEST_REPO_URL.
push_disposable_branch() {
  local clone="$1" branch="$2" askpass rc
  assert_disposable_ref "${branch}" || return 1
  askpass="$(github_askpass_script)" || { echo "could not read the GitHub token from SSM (${GITOPS_TEST_TOKEN_SSM_PARAM})" >&2; return 1; }
  ( set +x
    GIT_ASKPASS="${askpass}" GIT_TERMINAL_PROMPT=0 \
      git -C "${clone}" push --quiet "${GITOPS_TEST_REPO_URL}" "HEAD:refs/heads/${branch}" )
  rc=$?
  rm -f "${askpass}"
  return "${rc}"
}

# delete_disposable_branch BRANCH: deletes refs/heads/BRANCH on
# GITOPS_TEST_REPO_URL. Runs from REPO_ROOT (any local git repo works;
# this never touches REPO_ROOT's own refs, only the remote's).
delete_disposable_branch() {
  local branch="$1" askpass rc
  assert_disposable_ref "${branch}" || return 1
  askpass="$(github_askpass_script)" || { echo "could not read the GitHub token from SSM (${GITOPS_TEST_TOKEN_SSM_PARAM})" >&2; return 1; }
  ( set +x
    GIT_ASKPASS="${askpass}" GIT_TERMINAL_PROMPT=0 \
      git -C "${REPO_ROOT}" push --quiet "${GITOPS_TEST_REPO_URL}" --delete "${branch}" )
  rc=$?
  rm -f "${askpass}"
  return "${rc}"
}

# checkout_revision_as CLONE_DIR NEW_BRANCH REVISION: `-B` with an
# explicit start point does not get `git checkout <name>`'s own DWIM
# auto-tracking-branch creation (confirmed on a real clone: `checkout -B x
# feat/25-delivery-bootstrap` fails "unknown revision", while plain
# `checkout feat/25-delivery-bootstrap` succeeds) -- a fresh clone of
# GITOPS_REPO_URL only has GITOPS_REVISION as a remote-tracking ref,
# never a local branch. Tries the bare name first (works for a tag, or a
# commit SHA already reachable), falling back to "origin/<name>" (the
# common case: GITOPS_REVISION is a branch).
checkout_revision_as() {
  local clone="$1" branch="$2" revision="$3"
  git -C "${clone}" checkout --quiet -B "${branch}" "${revision}" 2>/dev/null \
    || git -C "${clone}" checkout --quiet -B "${branch}" "origin/${revision}"
}

# report_stale_disposable_branches: preflight hygiene. Lists every remote
# e2e/* branch older than a day (informational -- a run that was killed
# before its own EXIT trap ran leaves branches only a human, or this
# check, ever lists again) and actively deletes only the ones already in
# this run's own e2e/${RUN_ID}/* namespace (by construction none exist
# yet at preflight time; this guards a RUN_ID collision, not the normal
# case).
report_stale_disposable_branches() {
  local token api_repo branches_json
  token="$(aws ssm get-parameter --with-decryption --name "${GITOPS_TEST_TOKEN_SSM_PARAM}" \
    --region "${GITOPS_TEST_TOKEN_SSM_REGION}" --query Parameter.Value --output text 2>/dev/null)" || { info "could not read the GitHub token from SSM; skipping the stale e2e/ branch check"; return 0; }
  api_repo="$(sed -E 's#^https://github.com/##; s#\.git$##' <<<"${GITOPS_TEST_REPO_URL}")"
  branches_json="$(curl -fsS -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${api_repo}/branches?per_page=100" 2>/dev/null)" || branches_json="[]"
  while IFS=$'\t' read -r name age_days; do
    [[ -n "${name}" ]] || continue
    info "found remote disposable branch refs/heads/${name} (${age_days}d old) -- reported for visibility, deleted only if it is this run's own"
    if [[ "${name}" == "e2e/${RUN_ID}/"* ]]; then
      delete_disposable_branch "${name}" \
        && info "cleanup: deleted stale branch refs/heads/${name} from this run's own namespace" \
        || info "cleanup: could not delete stale branch refs/heads/${name} from this run's own namespace (remove it by hand)"
    fi
  done < <(printf '%s' "${branches_json}" | GITHUB_TOKEN_FOR_DATES="${token}" API_REPO="${api_repo}" python3 -c '
import json, os, sys, urllib.request, datetime
docs = json.load(sys.stdin) if sys.stdin.readable() else []
token = os.environ.get("GITHUB_TOKEN_FOR_DATES", "")
api_repo = os.environ.get("API_REPO", "")
now = datetime.datetime.now(datetime.timezone.utc)
for b in (docs or []):
    name = b.get("name", "")
    if not name.startswith("e2e/"):
        continue
    sha = (b.get("commit") or {}).get("sha", "")
    date_str = ""
    if sha and api_repo:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{api_repo}/commits/{sha}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                commit = json.load(resp)
            date_str = commit["commit"]["committer"]["date"]
        except Exception:
            date_str = ""
    age_days = -1
    if date_str:
        try:
            dt = datetime.datetime.fromisoformat(date_str.replace("Z", "+00:00"))
            age_days = (now - dt).days
        except Exception:
            age_days = -1
    if age_days >= 1 or age_days == -1:
        print(f"{name}\t{age_days}")
')
  token=""
}

# -------------------------------------------------------- cleanup (trap)

delete_broken_branches() {
  local b
  for b in "${BROKEN_BRANCHES[@]}"; do
    delete_disposable_branch "${b}" >/dev/null 2>&1 \
      || info "cleanup: could not delete disposable branch refs/heads/${b} on ${GITOPS_TEST_REPO_URL} (remove it by hand)"
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
        k delete namespace "${ACCEL_TEST_NS}" --ignore-not-found --wait=false >/dev/null 2>&1
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
  if [[ "${TRN_APPLY_ATTEMPTED}" -eq 1 && "${TRN_DESTROYED}" -eq 0 ]]; then
    if [[ "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving the Trainium cell ${ACCEL_TRN_CELL_NAME} in place; destroy it with:"
      info "TF_DATA_DIR=${TRN_TF_DATA_DIR} AWS_REGION=${ACCEL_TRN_REGION} ${TERRAFORM} -chdir=${FOUNDATION_ROOT} destroy -var-file=${TRN_TFVARS}"
    else
      info "cleanup: the Trainium cell ${ACCEL_TRN_CELL_NAME} did not reach a successful destroy; cleaning up"
      if [[ "${TRN_BOOTSTRAP_RAN}" -eq 1 ]] && KUBECONFIG="${TRN_KUBECONFIG}" k get ns "${TRN_ARGOCD_NS:-}" >/dev/null 2>&1; then
        KUBECONFIG="${TRN_KUBECONFIG}" k delete namespace "${ACCEL_TEST_NS}" --ignore-not-found --wait=false >/dev/null 2>&1
        KUBECONFIG="${TRN_KUBECONFIG}" k delete application root -n "${TRN_ARGOCD_NS}" --cascade=background --ignore-not-found >/dev/null 2>&1
      fi
      TF_DATA_DIR="${TRN_TF_DATA_DIR}" AWS_REGION="${ACCEL_TRN_REGION}" \
        tf "${FOUNDATION_ROOT}" destroy -auto-approve -input=false -var-file="${TRN_TFVARS}"
      local trn_destroy_rc=$?
      if [[ "${trn_destroy_rc}" -ne 0 ]]; then
        log "FAIL cleanup: terraform destroy of the Trainium cell exited ${trn_destroy_rc}; remove it by hand"
      else
        info "cleanup: terraform destroy of the Trainium cell completed"
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

for b in "${TERRAFORM}" aws "${KUBECTL}" git curl python3; do require_bin "${b}"; done
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || fail "MY_CIDR must be an IPv4 CIDR, got ${MY_CIDR}"
aws sts get-caller-identity --query Account --output text >/dev/null \
  || fail "aws sts get-caller-identity (check AWS_PROFILE and credentials)"
[[ -x "${GITOPS_ROOT}/bootstrap/bootstrap.sh" ]] || fail "gitops/bootstrap/bootstrap.sh is missing or not executable"
pass "preflight: tools present, credentials valid, bootstrap.sh present"
if [[ "${GITOPS_RUN_ACCEL_E2E}" == "1" ]]; then
  [[ "${NAME}" == "${ACCEL_GPU_CELL_NAME}" ]] \
    || fail "GITOPS_RUN_ACCEL_E2E=1: NAME (${NAME}) must equal ACCEL_GPU_CELL_NAME (${ACCEL_GPU_CELL_NAME}) -- this script's own cell is the GPU accelerator cell, and only gitops/cells/${ACCEL_GPU_CELL_NAME}/ carries its method-labeled pool"
  # verify/cb-batch addition (not for merge): ACCEL_SKIP_TRN=1 runs the GPU half only, against
  # any fixture name (not just issue #28's own dp-a19-gpu), so a Capacity-Block dry run can use a
  # unique cell name per run (dp-cbp-r1, -r2, ...) instead of colliding, account-wide, on the IAM
  # role names issue #28's own live dp-a19-gpu cell already owns. Default (ACCEL_SKIP_TRN unset or
  # 0) is byte-for-byte the original, unchanged behavior: both names are still forced to
  # dp-a19-gpu/dp-a19-trn and both fixtures and test images are still required.
  if [[ "${ACCEL_SKIP_TRN:-0}" == "1" ]]; then
    compgen -G "${GITOPS_ROOT}/cells/${ACCEL_GPU_CELL_NAME}/capacity-pool/*.yaml" >/dev/null \
      || fail "GITOPS_RUN_ACCEL_E2E=1 ACCEL_SKIP_TRN=1: no gitops/cells/${ACCEL_GPU_CELL_NAME}/capacity-pool/*.yaml in this checkout"
    [[ -n "${ACCEL_GPU_TEST_IMAGE}" ]] || fail "GITOPS_RUN_ACCEL_E2E=1: export ACCEL_GPU_TEST_IMAGE (an image with nvidia-smi on PATH)"
    pass "preflight (GITOPS_RUN_ACCEL_E2E=1 ACCEL_SKIP_TRN=1): GPU cell ${NAME} in ${AWS_REGION}, Trainium half skipped, fixture and test image present"
  else
    [[ "${ACCEL_GPU_CELL_NAME}" == "dp-a19-gpu" && "${ACCEL_TRN_CELL_NAME}" == "dp-a19-trn" ]] \
      || fail "GITOPS_RUN_ACCEL_E2E=1: issue #28's fixtures are gitops/cells/dp-a19-gpu/ and gitops/cells/dp-a19-trn/; got ACCEL_GPU_CELL_NAME=${ACCEL_GPU_CELL_NAME} ACCEL_TRN_CELL_NAME=${ACCEL_TRN_CELL_NAME}"
    for accel_cell in "${ACCEL_GPU_CELL_NAME}" "${ACCEL_TRN_CELL_NAME}"; do
      compgen -G "${GITOPS_ROOT}/cells/${accel_cell}/capacity-pool/*.yaml" >/dev/null \
        || fail "GITOPS_RUN_ACCEL_E2E=1: no gitops/cells/${accel_cell}/capacity-pool/*.yaml in this checkout"
    done
    [[ -n "${ACCEL_GPU_TEST_IMAGE}" ]] || fail "GITOPS_RUN_ACCEL_E2E=1: export ACCEL_GPU_TEST_IMAGE (an image with nvidia-smi on PATH)"
    [[ -n "${ACCEL_TRN_TEST_IMAGE}" ]] || fail "GITOPS_RUN_ACCEL_E2E=1: export ACCEL_TRN_TEST_IMAGE (an image with neuron-ls on PATH)"
    [[ "${ACCEL_TRN_REGION}" != "${AWS_REGION}" || "${ACCEL_TRN_CELL_NAME}" != "${NAME}" ]] \
      || fail "GITOPS_RUN_ACCEL_E2E=1: the Trainium cell must differ from the GPU cell"
    pass "preflight (GITOPS_RUN_ACCEL_E2E=1): GPU cell ${NAME} in ${AWS_REGION}, Trainium cell ${ACCEL_TRN_CELL_NAME} in ${ACCEL_TRN_REGION}, fixtures and test images present"
  fi
fi
info "run ${RUN_ID}, work dir ${WORK_DIR}, repo ${GITOPS_REPO_URL}"
report_stale_disposable_branches

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
# Matrix) resolved -- evidenced by a generated Application's own
# targetRevision matching what the annotation carries. This must be
# APP_CAPACITY_POOL (cells.ApplicationSet), not APP_KARPENTER
# (platform.ApplicationSet): decision 2's own template sets a registry
# add-on's targetRevision to "{{ .version }}" (the chart's own SemVer,
# "1.15.2" here) because its source is the chart registry, never this
# platform repository -- confirmed on a real cluster, where it was
# exactly "1.15.2", not GITOPS_REVISION. cells.ApplicationSet's own
# template instead sets targetRevision directly from the revision
# annotation (its source *is* this repository), which is the one real
# evidence this criterion needs.
capacity_pool_target_revision="$(app_field "${APP_CAPACITY_POOL}" '{.spec.source.targetRevision}')"
[[ "${capacity_pool_target_revision}" == "${GITOPS_REVISION}" ]] \
  || fail "${APP_CAPACITY_POOL}'s targetRevision (${capacity_pool_target_revision}) does not match the Secret's revision annotation (${GITOPS_REVISION})"
pass "${APP_CAPACITY_POOL}'s targetRevision was templated from the Cluster generator's revision annotation, consumed by the Git file generator in the same Matrix"

# Acceptance criterion 5: karpenter-crd and karpenter (skipCrds) report no
# shared CRD, evidenced by each Application's own resource list.
crds_owned_by_karpenter_crd="$(app_field "${APP_KARPENTER_CRD}" '{.status.resources[?(@.kind=="CustomResourceDefinition")].name}')"
crds_owned_by_karpenter="$(app_field "${APP_KARPENTER}" '{.status.resources[?(@.kind=="CustomResourceDefinition")].name}')"
[[ -n "${crds_owned_by_karpenter_crd}" ]] || fail "${APP_KARPENTER_CRD} owns no CustomResourceDefinition at all"
[[ -z "${crds_owned_by_karpenter}" ]] \
  || fail "${APP_KARPENTER} (skipCrds) still owns CRD(s) in its own resource list: ${crds_owned_by_karpenter}"
pass "${APP_KARPENTER_CRD} owns the CRDs (${crds_owned_by_karpenter_crd}); ${APP_KARPENTER} owns none -- no shared-resource conflict"

# -------------------------------------------------------------- 10. capacity

wait_until 900 15 "capacity-pool Application Healthy and Synced" app_healthy_synced "${APP_CAPACITY_POOL}" \
  || fail "${APP_CAPACITY_POOL} did not reach Healthy+Synced: health=$(app_health "${APP_CAPACITY_POOL}") sync=$(app_sync "${APP_CAPACITY_POOL}")"
wait_until 900 15 "smoke Application Healthy and Synced" app_healthy_synced "${APP_SMOKE}" || {
  # Diagnostic-only addition (verify/cb-batch, not for merge): a 2026-11-20
  # dry run found this specific app stuck at OutOfSync for the full 900s
  # when the smoke chart's ClusterQueue carries a second resourceGroup
  # (the gpuQuota opt-in). Capture the live object and ArgoCD's own
  # per-resource diff BEFORE the fail/teardown destroys the evidence, so
  # the root cause can actually be read back, not just "it timed out."
  info "smoke Application did not converge -- dumping diagnostics to the log before failing (not just to disk, since teardown may prune the work dir)"
  echo "=== DIAG: ${APP_SMOKE} status.resources ==="
  k -n argocd get application "${APP_SMOKE}" -o jsonpath='{.status.resources}' 2>&1 || true
  echo "=== DIAG: ${APP_SMOKE} status.conditions ==="
  k -n argocd get application "${APP_SMOKE}" -o jsonpath='{.status.conditions}' 2>&1 || true
  echo "=== DIAG: live ClusterQueue(s) ==="
  k get clusterqueue -o yaml 2>&1 || true
  echo "=== DIAG: end ==="
  fail "${APP_SMOKE} did not reach Healthy+Synced: health=$(app_health "${APP_SMOKE}") sync=$(app_sync "${APP_SMOKE}") -- see DIAG blocks above in this log"
}
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

# ------------------------------- 10a. accelerators on the GPU cell (#28)
#
# Issue #28 acceptance criteria 2, 4 and 5, NVIDIA half: this cell (NAME =
# dp-a19-gpu, enforced by the preflight) carries exactly one NodePool, the
# `gpu` pool labeled distai.dev/nvidia-gpu-method=device-plugin, so step 10
# above already found it as NODEPOOL.
#
# A bare Layer 1 pod, not a Kueue Job: the smoke ClusterQueue covers only
# cpu/memory (gitops/charts/smoke), so a Job requesting nvidia.com/gpu
# through it would never be admitted, and what these criteria are about is
# the advertiser and the node, not Kueue admission (step 11 covers that).
# The pod's nodeSelector names both the pool and the method label, so
# Karpenter can only satisfy it from a NodePool whose node template carries
# that label (#28 section C).
#
# check_accel_layer1 CELL NODEPOOL ADVERTISER_ADDON OTHER_ADDON LABEL RESOURCE IMAGE PROBE
# runs against whichever cluster KUBECONFIG/ARGOCD_NS/AWS_REGION currently
# name (the Trainium cell, step 18, calls it with those overridden for the
# duration of the call), and sets ACCEL_NODE to the node the pod ran on.
# PROBE is "nvidia" (nvidia-smi -L) or "neuron" (neuron-ls --json-output).
ACCEL_NODE=""
check_accel_layer1() {
  local cell="$1" nodepool="$2" advertiser_addon="$3" other_addon="$4" label="$5" resource="$6" image="$7" probe="$8"
  local app="${cell}-${advertiser_addon}" other_app="${cell}-${other_addon}"
  local label_jp="${label//./\\.}" resource_jp="${resource//./\\.}"
  local advertiser_ns other_ns wave np_label node node_label allocatable probe_out count pods_on_node node_capacity_type instance_type

  # Criterion 5: the accelerators step's device-plugin release is
  # Healthy+Synced before anything is asserted about it.
  wait_until 1200 15 "${app} Application Healthy and Synced" app_healthy_synced "${app}" \
    || fail "${app} did not reach Healthy+Synced: health=$(app_health "${app}") sync=$(app_sync "${app}")"
  wave="$(app_field "${app}" '{.metadata.labels.distai\.dev/wave}')"
  [[ "${wave}" == "accelerators" ]] || fail "${app}'s distai.dev/wave label is '${wave}', not 'accelerators'"
  pass "${app} (accelerators step) reached Healthy+Synced"

  # Default state (#28): every accel-* release is always present; the
  # other method's release exists too, it just matches no node here.
  other_app_exists() { [[ -n "$(app_field "${other_app}" '{.metadata.name}')" ]]; }
  wait_until 600 15 "${other_app} Application exists" other_app_exists \
    || fail "${other_app} Application was never generated (every accel-* add-on is always present, #28 Default state)"
  advertiser_ns="$(app_field "${app}" '{.spec.destination.namespace}')"
  other_ns="$(app_field "${other_app}" '{.spec.destination.namespace}')"
  [[ -n "${advertiser_ns}" && -n "${other_ns}" && "${advertiser_ns}" != "${other_ns}" ]] \
    || fail "${app} and ${other_app} need two distinct destination namespaces, got '${advertiser_ns}' and '${other_ns}'"
  pass "${other_app} exists alongside it (namespaces: ${advertiser_ns} vs ${other_ns})"

  np_label="$(k get nodepool "${nodepool}" -o jsonpath="{.spec.template.metadata.labels.${label_jp}}")"
  [[ "${np_label}" == "device-plugin" ]] \
    || fail "NodePool ${nodepool}'s spec.template.metadata.labels['${label}'] is '${np_label}', not device-plugin (#28 section C)"
  pass "NodePool ${nodepool} labels its nodes ${label}=device-plugin"

  k delete namespace "${ACCEL_TEST_NS}" --ignore-not-found --wait=true --timeout=300s >/dev/null 2>&1 || true
  cat >"${WORK_DIR}/accel-layer1-${cell}.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${ACCEL_TEST_NS}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
---
apiVersion: v1
kind: Pod
metadata:
  name: accel-layer1
  namespace: ${ACCEL_TEST_NS}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  nodeSelector:
    karpenter.sh/nodepool: ${nodepool}
    ${label}: device-plugin
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
    - key: aws.amazon.com/neuron
      operator: Exists
  containers:
    - name: probe
      image: ${image}
      command: ["sleep", "3600"]
      resources:
        limits:
          ${resource}: "1"
YAML
  k apply -f "${WORK_DIR}/accel-layer1-${cell}.yaml" || fail "kubectl apply the Layer 1 ${resource} pod on ${cell}"

  accel_pod_running() { [[ "$(k get pod accel-layer1 -n "${ACCEL_TEST_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]; }
  wait_until "${ACCEL_POD_TIMEOUT_SECONDS}" 20 "the Layer 1 ${resource} pod is Running" accel_pod_running \
    || fail "Layer 1 pod requesting ${resource}: 1 never reached Running on ${cell}: $(k get pod accel-layer1 -n "${ACCEL_TEST_NS}" -o jsonpath='{.status}' 2>&1) nodeclaims: $(k get nodeclaims -o wide 2>&1)"
  node="$(k get pod accel-layer1 -n "${ACCEL_TEST_NS}" -o jsonpath='{.spec.nodeName}')"
  [[ -n "${node}" ]] || fail "Layer 1 pod is Running but has no spec.nodeName"
  ACCEL_NODE="${node}"

  [[ "$(k get node "${node}" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')" == "${nodepool}" ]] \
    || fail "Layer 1 pod's node ${node} is not from NodePool ${nodepool}"
  node_label="$(k get node "${node}" -o jsonpath="{.metadata.labels.${label_jp}}")"
  [[ "${node_label}" == "device-plugin" ]] || fail "node ${node} carries ${label}='${node_label}', not device-plugin"
  allocatable="$(k get node "${node}" -o jsonpath="{.status.allocatable.${resource_jp}}")"
  [[ "${allocatable}" =~ ^[0-9]+$ && "${allocatable}" -ge 1 ]] \
    || fail "node ${node} advertises ${resource} allocatable='${allocatable}' (expected >= 1)"
  # Acceptance criteria 2/3 name a real spot node, not merely "whatever
  # Karpenter happened to pick" -- #28's own capacity-pool fixtures allow
  # only karpenter.sh/capacity-type=spot (no on-demand fallback), so this
  # is a real assertion on the node Karpenter actually launched, not a
  # restatement of the NodePool's own requirements.
  node_capacity_type="$(k get node "${node}" -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}')"
  [[ "${node_capacity_type}" == "spot" ]] \
    || fail "node ${node} has karpenter.sh/capacity-type='${node_capacity_type}', not spot (#28 acceptance criteria 2/3 name a spot node)"
  instance_type="$(k get node "${node}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')"
  pass "Layer 1 pod scheduled on ${node} (${instance_type}, capacity-type=spot, ${label}=device-plugin, allocatable ${resource}=${allocatable})"

  # Criteria 2/3: the device is usable from inside the pod.
  case "${probe}" in
    nvidia)
      probe_out="$(k exec -n "${ACCEL_TEST_NS}" accel-layer1 -c probe -- nvidia-smi -L 2>&1)" \
        || fail "kubectl exec nvidia-smi -L failed: ${probe_out}"
      count="$(grep -cE '^GPU [0-9]+: ' <<<"${probe_out}" || true)"
      ;;
    neuron)
      probe_out="$(k exec -n "${ACCEL_TEST_NS}" accel-layer1 -c probe -- neuron-ls --json-output 2>&1)" \
        || fail "kubectl exec neuron-ls --json-output failed: ${probe_out}"
      # neuron-ls --json-output prints one JSON entry per Neuron device the
      # container can see; accept either a top-level list or an object
      # wrapping one list, and print -1 for anything else so the
      # assertion below fails with the raw output.
      count="$(python3 -c '
import json, sys
try:
    doc = json.loads(sys.stdin.read())
except Exception:
    print(-1); sys.exit(0)
if isinstance(doc, dict):
    lists = [v for v in doc.values() if isinstance(v, list)]
    doc = lists[0] if len(lists) == 1 else None
print(len(doc) if isinstance(doc, list) else -1)
' <<<"${probe_out}")"
      ;;
    *) fail "check_accel_layer1: unknown probe '${probe}'" ;;
  esac
  [[ "${count}" == "1" ]] || fail "${probe} probe inside the Layer 1 pod reports ${count} device(s), expected exactly 1: ${probe_out}"
  pass "${probe} probe inside the Layer 1 pod reports exactly one device: $(head -n1 <<<"${probe_out}")"

  # Criterion 4: only the selected advertiser runs on this node. An
  # advertiser is a DaemonSet pod; the other method's release may run a
  # controller Deployment elsewhere, which advertises nothing.
  pods_on_node="$(k get pods -A --field-selector "spec.nodeName=${node}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.status.phase}{"\n"}{end}')" \
    || fail "kubectl get pods on node ${node}"
  awk -F'|' -v ns="${advertiser_ns}" '$1==ns && $3=="DaemonSet" && $4=="Running" {found=1} END{exit !found}' <<<"${pods_on_node}" \
    || fail "no Running DaemonSet pod of ${app} (namespace ${advertiser_ns}) on node ${node}: $(tr '\n' ' ' <<<"${pods_on_node}")"
  if awk -F'|' -v ns="${other_ns}" '$1==ns && $3=="DaemonSet" {found=1} END{exit !found}' <<<"${pods_on_node}"; then
    fail "a DaemonSet pod of ${other_app} (namespace ${other_ns}) runs on node ${node} next to ${app}'s -- two advertisers for one device class: $(tr '\n' ' ' <<<"${pods_on_node}")"
  fi
  pass "node ${node} runs ${app}'s advertiser (${advertiser_ns}) and no DaemonSet pod of ${other_app} (${other_ns})"

  k delete namespace "${ACCEL_TEST_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

if [[ "${GITOPS_RUN_ACCEL_E2E}" == "1" ]]; then
  check_accel_layer1 "${CLUSTER}" "${NODEPOOL}" accel-nvidia-device-plugin accel-nvidia-dra \
    distai.dev/nvidia-gpu-method nvidia.com/gpu "${ACCEL_GPU_TEST_IMAGE}" nvidia
  pass "GPU cell ${CLUSTER}: accelerators step verified on ${ACCEL_NODE} (#28 acceptance criteria 2, 4, 5)"
fi

# --------------------- verify/cb-batch dry-run hook (NOT part of #25/#28,
# not for merge; inserted on this verification-only branch so the Capacity
# Block batch steps in 3.cb-batch.sh can be dry-run against a real, live
# GPU cell before this script's own teardown at step 14-15 destroys it).
if [[ "${CB_BATCH_INLINE:-0}" == "1" ]]; then
  info "cb-batch dry run: invoking 3.cb-batch.sh inline against this live cell"
  CB_EVIDENCE_DIR="${WORK_DIR}/cb-evidence" \
    KUBECONFIG="${KUBECONFIG}" AWS_REGION="${AWS_REGION}" NAME="${CLUSTER}" \
    CB_STEPS="${CB_BATCH_STEPS:-20 21 22 24}" \
    bash "${GITOPS_ROOT}/tests/3.cb-batch.sh" 2>&1 | tee "${WORK_DIR}/cb-batch.log"
  CB_BATCH_EXIT="${PIPESTATUS[0]:-$?}"
  if [[ "${CB_BATCH_EXIT}" != "0" ]]; then
    info "cb-batch dry run exited ${CB_BATCH_EXIT} -- not fatal to this e2e script, logged for the dry-run report"
  fi
  info "cb-batch dry-run evidence: ${WORK_DIR}/cb-evidence (will be lost when this run's WORK_DIR is cleaned up unless copied out before teardown)"
fi

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

# Kueue's own QuotaReserved/Admitted events are recorded against the
# Workload object it creates for the Job (confirmed against Kueue's own
# source, tag v0.20.6: scheduler.go's recorder.Eventf(newWorkload, ...)
# for both; workload_controller.go's reportAdmittedWorkload the same way)
# -- never against the Job itself. The Job's own events
# (Suspended/CreatedWorkload/SuccessfulCreate/Resumed, all confirmed on a
# real cluster) are the Job controller's and Kueue's *job-integration*
# events, not the admission events this check is actually about. Discover
# the Workload the same way everything else cell-specific in this script
# is discovered (its own name is Kueue's to choose, never this test's),
# not assumed.
mapfile -t canary_workloads < <(k get workloads -n "${SMOKE_NS}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
[[ "${#canary_workloads[@]}" -eq 1 ]] || fail "expected exactly 1 Workload in ${SMOKE_NS} for the canary Job, found ${#canary_workloads[@]}: ${canary_workloads[*]:-none}"
CANARY_WORKLOAD="${canary_workloads[0]}"
admission_events="$(k get events -n "${SMOKE_NS}" --field-selector involvedObject.name="${CANARY_WORKLOAD}" -o jsonpath='{range .items[*]}{.reason}{" "}{end}')"
[[ "${admission_events}" == *"Admitted"* || "${admission_events}" == *"QuotaReserved"* ]] \
  || fail "no Kueue admission event (Admitted/QuotaReserved) recorded for Workload ${CANARY_WORKLOAD}: events=[${admission_events}]"
pass "Kueue admitted the canary Job via Workload ${CANARY_WORKLOAD} (events: ${admission_events})"

canary_node() {
  # "|", never " ", between nodeName and phase: awk's default
  # whitespace-splitting strips a line's leading blank before splitting
  # into fields, so an empty nodeName ("" followed by a space, then
  # "Pending") silently shifted the *phase* into $1 -- `$1!=""` was true
  # the instant the pod existed, long before any node was ever assigned,
  # and the bogus "Pending" was then used as a literal node name
  # (`kubectl get node Pending` -> NotFound, uncaught under set -e,
  # confirmed on a real cluster). A non-whitespace delimiter with -F
  # keeps an empty first field empty.
  k get pods -n "${SMOKE_NS}" -l job-name=canary \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{.status.phase}{"\n"}{end}' \
    | awk -F'|' '$1!="" {print $1; found=1} END{exit !found}'
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
# "e2e/${RUN_ID}/${SUFFIX}" with ADDON_RELPATH's `version:` replaced by a
# release that cannot exist, pushes it to GITOPS_TEST_REPO_URL, and
# prints the branch name. Tracked for cleanup.
break_addon_branch() {
  local addon_relpath="$1" suffix="$2" branch clone
  branch="e2e/${RUN_ID}/${suffix}"
  clone="${WORK_DIR}/break-${suffix}"
  # GITOPS_REPO_URL, never REPO_ROOT: cloning from a local filesystem path
  # makes the new clone's own "origin" that same local path (git's own
  # default for a local-path clone source), so a later `git push origin`
  # lands only inside this run's own local checkout -- never on GitHub,
  # where the ApplicationSet's Git generator actually reads from.
  # Confirmed on a real cluster: the push itself reported success, but
  # Argo CD's own error was consistent and permanent across 5+ minutes
  # ("unable to resolve '<branch>' to a commit SHA") because the branch
  # never existed on GitHub at all.
  git clone --quiet --no-single-branch "${GITOPS_REPO_URL}" "${clone}" || return 1
  checkout_revision_as "${clone}" "${branch}" "${GITOPS_REVISION}" || return 1
  sed -i.bak -E 's/^(\s*version:\s*).*/\1"0.0.0-e2e-nonexistent"/' "${clone}/${addon_relpath}" || return 1
  grep -q '0.0.0-e2e-nonexistent' "${clone}/${addon_relpath}" || return 1
  git -C "${clone}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
    commit --quiet -am "test: break ${addon_relpath} for e2e ordering experiment (never merged)" || return 1
  push_disposable_branch "${clone}" "${branch}" || return 1
  # Not BROKEN_BRANCHES+=(...) here: every caller of this function uses
  # command substitution ($(break_addon_branch ...)), which always runs
  # in a subshell -- an append here would only ever mutate that
  # subshell's own copy. Callers append the printed name themselves.
  printf '%s' "${branch}"
}

if [[ "${GITOPS_SKIP_ORDERING_EXPERIMENT}" == "1" ]]; then
  info "GITOPS_SKIP_ORDERING_EXPERIMENT=1: skipping acceptance criterion 4 (no push access to ${GITOPS_TEST_REPO_URL} assumed)"
else
  # ---- 12a. break karpenter-crd -------------------------------------
  # BREAK_CRDS_BRANCH="$(break_addon_branch ...)" runs the function in a
  # subshell (command substitution always forks one); BROKEN_BRANCHES+=
  # *inside* break_addon_branch() only ever mutated that subshell's own
  # copy of the array, never this shell's -- confirmed on a real run: the
  # branch was pushed, the whole run passed, and it was never deleted
  # (git ls-remote still showed it after the run exited 0). Track it here
  # instead, in the shell that actually runs delete_broken_branches().
  BREAK_CRDS_BRANCH="$(break_addon_branch "gitops/addons/karpenter-crd/addon.yaml" "break-crds")" \
    || fail "could not create/push the break-crds disposable branch"
  BROKEN_BRANCHES+=("${BREAK_CRDS_BRANCH}")
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
  # Same subshell-scoping note as break-crds above.
  BREAK_KUEUE_BRANCH="$(break_addon_branch "gitops/addons/kueue/addon.yaml" "break-kueue")" \
    || fail "could not create/push the break-kueue disposable branch"
  BROKEN_BRANCHES+=("${BREAK_KUEUE_BRANCH}")
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
REMOVE_KUEUE_BRANCH="e2e/${RUN_ID}/remove-kueue"
# GITOPS_REPO_URL, never REPO_ROOT -- see break_addon_branch()'s own comment.
git clone --quiet --no-single-branch "${GITOPS_REPO_URL}" "${REMOVE_KUEUE_CLONE}" || fail "git clone (remove-kueue)"
checkout_revision_as "${REMOVE_KUEUE_CLONE}" "${REMOVE_KUEUE_BRANCH}" "${GITOPS_REVISION}" || fail "git checkout (remove-kueue)"
git -C "${REMOVE_KUEUE_CLONE}" rm --quiet "gitops/addons/kueue/addon.yaml" || fail "git rm gitops/addons/kueue/addon.yaml"
git -C "${REMOVE_KUEUE_CLONE}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
  commit --quiet -m "test: remove addons/kueue/addon.yaml for e2e generator-loss experiment (never merged)" \
  || fail "git commit (remove-kueue)"
push_disposable_branch "${REMOVE_KUEUE_CLONE}" "${REMOVE_KUEUE_BRANCH}" || fail "git push (remove-kueue)"
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

# tag_filters/list_leftover/no_leftover/report_leftovers take the cell's
# own cluster name and VPC ID explicitly (issue #28 runs this sweep for two
# cells, the Trainium one in its own Region via AWS_REGION for the call);
# the first cell's own calls below pass NAME/VPC_ID, unchanged in effect.
# tag_filters CLUSTER_NAME
tag_filters() {
  local cluster_name="$1"
  printf '%s\n' \
    "Name=tag:${TEST_TAG_KEY},Values=${RUN_ID}" \
    "Name=tag:karpenter.sh/discovery,Values=${cluster_name}" \
    "Name=tag-key,Values=kubernetes.io/cluster/${cluster_name}" \
    "Name=tag:eks:cluster-name,Values=${cluster_name}" \
    "Name=tag:eks:eks-cluster-name,Values=${cluster_name}" \
    "Name=tag:cluster.k8s.amazonaws.com/name,Values=${cluster_name}"
}

# list_leftover KIND CLUSTER_NAME VPC_ID
list_leftover() {
  local kind="$1" cluster_name="$2" vpc_id="$3" filter out all=""
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
  done < <(tag_filters "${cluster_name}")
  if [[ -n "${vpc_id}" ]]; then
    if ! case "${kind}" in
      instance)
        out="$(aws_text aws ec2 describe-instances --filters "Name=vpc-id,Values=${vpc_id}" \
          "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text)" ;;
      eni)
        out="$(aws_text aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${vpc_id}" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ;;
      nat)
        out="$(aws_text aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${vpc_id}" \
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

# no_leftover KIND CLUSTER_NAME VPC_ID
no_leftover() {
  local out
  if ! out="$(list_leftover "$1" "$2" "$3")"; then fail "checking for leftover $1: ${out}"; fi
  [[ -z "${out}" ]]
}

# report_leftovers GRACE_SECONDS CLUSTER_NAME VPC_ID
report_leftovers() {
  local grace="$1" cluster_name="$2" vpc_id="$3" kind ids bad=0
  for kind in instance eni nat volume launch-template; do
    if wait_until "${grace}" 20 "no ${kind} left" no_leftover "${kind}" "${cluster_name}" "${vpc_id}"; then
      pass "no ${kind} tagged for the cluster ${cluster_name} remains"
    else
      if ! ids="$(list_leftover "${kind}" "${cluster_name}" "${vpc_id}")"; then fail "checking for leftover ${kind}: ${ids}"; fi
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

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" "${NAME}" "${VPC_ID}" || fail "resources tagged for the cluster remain after destroy"

if ! vpc_check_out="$(aws_text aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].VpcId' --output text)"; then
  fail "checking whether VPC ${VPC_ID} still exists: ${vpc_check_out}"
fi
[[ -z "${vpc_check_out}" || "${vpc_check_out}" == "None" ]] || fail "VPC ${VPC_ID} still exists after destroy"
pass "VPC removed"

# ------------------------- 16. Trainium cell: foundation (#28, opt-in)
#
# Issue #28 acceptance criteria 3, 4, 5 and 6, Neuron half. A second,
# genuinely separate foundation cell in ACCEL_TRN_REGION, built after the
# GPU cell above is gone (the two never need to coexist). Same module, same
# init/apply/update-kubeconfig/ACTIVE/bootstrap.sh flow as steps 2-4, from
# this checkout's own infra/foundation (no before/after RBAC experiment:
# that is #25's criterion 2, already covered on the first cell). Every
# Terraform and kubectl call for this cell is pointed at its own
# TF_DATA_DIR, kubeconfig and Region for the duration of that one call
# only, so nothing here can touch the first cell's state.

if [[ "${GITOPS_RUN_ACCEL_E2E}" == "1" && "${ACCEL_SKIP_TRN:-0}" != "1" ]]; then
  trn_tf() { TF_DATA_DIR="${TRN_TF_DATA_DIR}" AWS_REGION="${ACCEL_TRN_REGION}" tf "${FOUNDATION_ROOT}" "$@"; }
  trn() { KUBECONFIG="${TRN_KUBECONFIG}" AWS_REGION="${ACCEL_TRN_REGION}" ARGOCD_NS="${TRN_ARGOCD_NS}" CLUSTER="${ACCEL_TRN_CELL_NAME}" "$@"; }

  cat >"${TRN_TFVARS}" <<JSON
{
  "name": "${ACCEL_TRN_CELL_NAME}",
  "region": "${ACCEL_TRN_REGION}",
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

  trn_tf init -input=false -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" -backend-config="key=${TRN_STATE_KEY}" \
    -backend-config="region=${STATE_REGION}" -backend-config="use_lockfile=true" \
    || fail "terraform init (Trainium cell) with the S3 backend (key ${TRN_STATE_KEY})"
  trn_existing_state="$(trn_tf state list 2>&1)" || trn_existing_state=""
  [[ "${trn_existing_state}" != *"No state file"* ]] || trn_existing_state=""
  [[ -z "${trn_existing_state}" ]] \
    || fail "state at key ${TRN_STATE_KEY} already has resources, refusing to apply over it: $(tr '\n' ' ' <<<"${trn_existing_state}")"
  pass "state at key ${TRN_STATE_KEY} has no resources before apply"

  TRN_APPLY_ATTEMPTED=1
  trn_tf apply -auto-approve -input=false -var-file="${TRN_TFVARS}" \
    || fail "terraform apply (Trainium cell ${ACCEL_TRN_CELL_NAME} in ${ACCEL_TRN_REGION})"
  pass "terraform apply of the Trainium cell ${ACCEL_TRN_CELL_NAME} in ${ACCEL_TRN_REGION} (Identity Center in ${ARGOCD_IDC_REGION})"

  TRN_CLUSTER="$(trn_tf output -raw cluster_name)"
  TRN_VPC_ID="$(trn_tf output -raw vpc_id)"
  [[ "${TRN_CLUSTER}" == "${ACCEL_TRN_CELL_NAME}" ]] \
    || fail "Trainium cell's cluster_name (${TRN_CLUSTER}) differs from ACCEL_TRN_CELL_NAME (${ACCEL_TRN_CELL_NAME})"

  aws eks update-kubeconfig --name "${TRN_CLUSTER}" --region "${ACCEL_TRN_REGION}" --kubeconfig "${TRN_KUBECONFIG}" >/dev/null \
    || fail "aws eks update-kubeconfig (Trainium cell)"

  TRN_ARGOCD_ARN="$(trn_tf output -raw argocd_capability_arn)"
  CLUSTER="${TRN_CLUSTER}" ARGOCD_ARN="${TRN_ARGOCD_ARN}" AWS_REGION="${ACCEL_TRN_REGION}" \
    wait_until 1200 30 "Argo CD capability ACTIVE (Trainium cell)" argocd_active \
    || fail "Argo CD capability of the Trainium cell is not ACTIVE"
  pass "Argo CD capability ACTIVE on the Trainium cell"

  TRN_ARGOCD_NS="$(trn_tf output -raw argocd_namespace)"
  [[ -n "${TRN_ARGOCD_NS}" ]] || fail "Trainium cell's argocd_namespace output is empty"
  TRN_TF_OUTPUTS_JSON="${WORK_DIR}/tf-outputs-trn.json"
  trn_tf output -json >"${TRN_TF_OUTPUTS_JSON}" || fail "terraform output -json (Trainium cell)"

  KUBECONFIG="${TRN_KUBECONFIG}" AWS_REGION="${ACCEL_TRN_REGION}" "${GITOPS_ROOT}/bootstrap/bootstrap.sh" \
    --tf-outputs "${TRN_TF_OUTPUTS_JSON}" --revision "${GITOPS_REVISION}" \
    || fail "bootstrap.sh (Trainium cell, --revision ${GITOPS_REVISION})"
  TRN_BOOTSTRAP_RAN=1
  pass "bootstrap.sh completed on the Trainium cell (--revision ${GITOPS_REVISION})"

  # ---------------------------------- 17. Trainium cell: capacity (#28)
  #
  # Same shape as steps 8 and 10 on the first cell: the cell's one
  # capacity-pool Application (cells/dp-a19-trn/capacity-pool/trn.yaml)
  # Healthy+Synced, and exactly one NodePool to launch from.
  trn wait_until 600 10 "a capacity-pool Application exists (Trainium cell)" discover_capacity_pool_app \
    || fail "no Application named ${TRN_CLUSTER}-capacity-pool-<pool> appeared on the Trainium cell"
  TRN_APP_CAPACITY_POOL="${APP_CAPACITY_POOL}"
  trn wait_until 1200 15 "Trainium capacity-pool Application Healthy and Synced" app_healthy_synced "${TRN_APP_CAPACITY_POOL}" \
    || fail "${TRN_APP_CAPACITY_POOL} did not reach Healthy+Synced: health=$(trn app_health "${TRN_APP_CAPACITY_POOL}") sync=$(trn app_sync "${TRN_APP_CAPACITY_POOL}")"
  mapfile -t trn_nodepools < <(trn k get nodepools -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
  [[ "${#trn_nodepools[@]}" -eq 1 ]] || fail "expected exactly 1 NodePool on the Trainium cell, found ${#trn_nodepools[@]}: ${trn_nodepools[*]:-none}"
  TRN_NODEPOOL="${trn_nodepools[0]}"
  pass "${TRN_APP_CAPACITY_POOL} reached Healthy+Synced; exactly one NodePool (${TRN_NODEPOOL}) on the Trainium cell"

  # ------------------------------ 18. Trainium cell: accelerators (#28)
  #
  # aws.amazon.com/neuron (one whole device), never aws.amazon.com/neuroncore:
  # #19 E4a found Karpenter estimates neuroncore: 8 for trn2.3xlarge where
  # the node really has 4, so a neuroncore request is not a sound Layer 1
  # probe of the device plugin.
  trn check_accel_layer1 "${TRN_CLUSTER}" "${TRN_NODEPOOL}" accel-neuron-device-plugin accel-neuron-dra \
    distai.dev/neuron-method aws.amazon.com/neuron "${ACCEL_TRN_TEST_IMAGE}" neuron
  TRN_ACCEL_NODE="${ACCEL_NODE}"
  TRN_ACCEL_INSTANCE_ID="$(trn instance_of_node "${TRN_ACCEL_NODE}")"
  [[ -n "${TRN_ACCEL_INSTANCE_ID}" ]] || fail "could not resolve an instance ID for node ${TRN_ACCEL_NODE}"
  pass "Trainium cell ${TRN_CLUSTER}: accelerators step verified on ${TRN_ACCEL_NODE} (${TRN_ACCEL_INSTANCE_ID}) (#28 acceptance criteria 3, 4, 5)"

  # ---------------------------------- 19. Trainium cell: destroy (#28)
  #
  # Same teardown as step 15: terraform destroy with the Karpenter node
  # still in place, the instance terminated by the foundation's teardown
  # guard, then the same tagged-leftover sweep scoped to this cell's own
  # name, VPC and Region.
  trn k delete namespace "${ACCEL_TEST_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  trn_destroy_start="$(date +%s)"
  trn_tf destroy -auto-approve -input=false -var-file="${TRN_TFVARS}" \
    || fail "terraform destroy of the Trainium cell with a Karpenter-launched instance still in place"
  TRN_DESTROYED=1
  pass "terraform destroy of the Trainium cell completed without manual steps ($(($(date +%s) - trn_destroy_start))s)"

  CANARY_INSTANCE_ID="${TRN_ACCEL_INSTANCE_ID}" AWS_REGION="${ACCEL_TRN_REGION}" \
    wait_until "${E2E_LEFTOVER_GRACE_SECONDS}" 20 "Trainium Karpenter instance terminated" instances_terminated \
    || fail "Karpenter instance ${TRN_ACCEL_INSTANCE_ID} (Trainium cell) not terminated after destroy"
  pass "Karpenter instance ${TRN_ACCEL_INSTANCE_ID} (Trainium cell) terminated"

  AWS_REGION="${ACCEL_TRN_REGION}" report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" "${TRN_CLUSTER}" "${TRN_VPC_ID}" \
    || fail "resources tagged for the Trainium cell remain after destroy"

  if ! trn_vpc_check_out="$(AWS_REGION="${ACCEL_TRN_REGION}" aws_text aws ec2 describe-vpcs --vpc-ids "${TRN_VPC_ID}" --query 'Vpcs[0].VpcId' --output text)"; then
    fail "checking whether VPC ${TRN_VPC_ID} (Trainium cell) still exists: ${trn_vpc_check_out}"
  fi
  [[ -z "${trn_vpc_check_out}" || "${trn_vpc_check_out}" == "None" ]] || fail "VPC ${TRN_VPC_ID} (Trainium cell) still exists after destroy"
  pass "Trainium cell VPC removed"
fi

git -C "${REPO_ROOT}" worktree remove --force "${BASE_WORKTREE}" >/dev/null 2>&1 || true
