#!/usr/bin/env bash
# Upgrade-mode e2e for the gitops/ delivery layer, one layer up from
# infra/foundation's own upgrade e2e (issue #24's shape, reused here per
# issue #25 decision 6/9: "A version bump PR runs the same upgrade-mode
# e2e #24 defines for infra/foundation, one layer up, on one disposable
# test cell"). Builds one cell from GITOPS_REVISION, runs a canary, then
# exercises two upgrade scenarios against UPGRADE_TO_KARPENTER_VERSION:
#
#   A. a mismatched karpenter/karpenter-crd version bump is caught by the
#      mechanical version-pair check (decision 6) -- cheapest first (#16):
#      this never touches the cluster;
#   B. a matched bump (both charts moved to UPGRADE_TO_KARPENTER_VERSION
#      together) passes: no Application goes Degraded, the NodePool-
#      launched instance is not replaced, and the canary pod stays
#      Running throughout, sampled every few seconds during the re-point.
#
# The CRD-schema-diff assertion (issue #24's third check) is NOT exercised
# here and is not claimed met: no chart this PR delivers ships a true
# crds/-folder CRD applied by this layer (karpenter's own is skipped via
# skipCrds: true; karpenter-crd and kueue are both plain templates).
# Whichever future PR first ships one (most likely JobSet) owns that
# check's first real run.
#
# Required environment: the same as gitops/tests/1.e2e.sh (AWS_PROFILE,
# AWS_REGION, NAME, STATE_BUCKET, STATE_REGION, ADMIN_PRINCIPAL_ARN,
# MY_CIDR, GITOPS_REVISION, ARGOCD_IDC_INSTANCE_ARN, ARGOCD_IDC_REGION,
# ARGOCD_IDC_IDENTITY_STORE_ID), plus:
#   UPGRADE_TO_KARPENTER_VERSION -- a real, currently published Karpenter
#   version different from addons/karpenter/addon.yaml's pinned version
#   (check with `helm show chart oci://public.ecr.aws/karpenter/karpenter
#   --version <x>`); this test does not guess one, since "the next patch
#   exists" is not something to assume about an upstream release cadence.
# Optional: the same as 1.e2e.sh (TERRAFORM, KUBECTL, E2E_WORK_DIR,
# E2E_KEEP_ON_FAILURE, E2E_LEFTOVER_GRACE_SECONDS, GITOPS_REPO_URL,
# GITOPS_TEST_REPO_URL, GITOPS_TEST_TOKEN_SSM_PARAM,
# GITOPS_TEST_TOKEN_SSM_REGION). Unlike 1.e2e.sh's ordering experiment,
# this script's own two disposable branches have no skip flag: the
# mismatch and matched-bump experiments they drive are this script's
# entire purpose, so a token with Contents: write on GITOPS_TEST_REPO_URL
# is required here, not optional.
set -euo pipefail

: "${AWS_PROFILE:?export AWS_PROFILE}"
: "${AWS_REGION:?export AWS_REGION}"
: "${NAME:?export NAME (cell and cluster name)}"
: "${STATE_BUCKET:?export STATE_BUCKET}"
: "${STATE_REGION:?export STATE_REGION}"
: "${ADMIN_PRINCIPAL_ARN:?export ADMIN_PRINCIPAL_ARN}"
: "${MY_CIDR:?export MY_CIDR}"
: "${GITOPS_REVISION:?export GITOPS_REVISION (a pushed git ref of this PR branch)}"
: "${ARGOCD_IDC_INSTANCE_ARN:?export ARGOCD_IDC_INSTANCE_ARN}"
: "${ARGOCD_IDC_REGION:?export ARGOCD_IDC_REGION}"
: "${ARGOCD_IDC_IDENTITY_STORE_ID:?export ARGOCD_IDC_IDENTITY_STORE_ID}"
: "${UPGRADE_TO_KARPENTER_VERSION:?export UPGRADE_TO_KARPENTER_VERSION (a real Karpenter version different from the pinned one)}"
export AWS_PROFILE AWS_REGION

TERRAFORM="${TERRAFORM:-terraform}"
KUBECTL="${KUBECTL:-kubectl}"
E2E_KEEP_ON_FAILURE="${E2E_KEEP_ON_FAILURE:-0}"
E2E_LEFTOVER_GRACE_SECONDS="${E2E_LEFTOVER_GRACE_SECONDS:-600}"
GITOPS_TEST_REPO_URL="${GITOPS_TEST_REPO_URL:-https://github.com/littlemex/distai-platform.git}"
GITOPS_TEST_TOKEN_SSM_PARAM="${GITOPS_TEST_TOKEN_SSM_PARAM:-/relay/github/distai-platform}"
GITOPS_TEST_TOKEN_SSM_REGION="${GITOPS_TEST_TOKEN_SSM_REGION:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${GITOPS_ROOT}/.." && pwd)"
FOUNDATION_ROOT="${REPO_ROOT}/infra/foundation"
# Used (never REPO_ROOT, a local filesystem path) to clone the two
# disposable branches below: cloning from a local path makes the new
# clone's own "origin" that same local path (git's own default for a
# local-path clone source), so a later `git push origin` would land only
# inside this run's own local checkout, never on GitHub -- where the
# ApplicationSet's Git generator actually reads from (confirmed on a real
# cluster in 1.e2e.sh's own identical bug).
GITOPS_REPO_URL="${GITOPS_REPO_URL:-$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')}"
[[ -n "${GITOPS_REPO_URL}" ]] || { echo "FAIL could not infer GITOPS_REPO_URL; set it explicitly"; exit 1; }

WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1

STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="gitops-upgrade-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"

APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
VPC_ID=""
IDC_GROUP_ID=""
BOOTSTRAP_RAN=0
BROKEN_BRANCHES=()
DEGRADED_SEEN=""
CELL_FIXTURE_BRANCH=""

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
app_field() { k get application "$1" -n "${ARGOCD_NS}" -o jsonpath="$2" 2>/dev/null; }
app_health() { app_field "$1" '{.status.health.status}'; }
app_sync() { app_field "$1" '{.status.sync.status}'; }
app_healthy_synced() { [[ "$(app_health "$1")" == "Healthy" && "$(app_sync "$1")" == "Synced" ]]; }
app_synced() { [[ "$(app_sync "$1")" == "Synced" ]]; }
instance_of_node() { k get node "$1" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}'; }

# ------------------------------------- authenticated disposable branches
#
# Same mechanism as gitops/tests/1.e2e.sh's own (see its comment): every
# branch this test pushes lives under refs/heads/e2e/<RUN_ID>/*, deleted
# again before the run ends, success or failure. The token is read fresh
# from SSM at each push/delete through a one-shot GIT_ASKPASS script,
# never written to disk beyond that script's own short lifetime, never
# in .git/config, never on a command line, never under `set -x`.

assert_disposable_ref() {
  case "$1" in
    "e2e/${RUN_ID}/"*) return 0 ;;
    *)
      echo "refusing to touch refs/heads/$1: outside this run's own e2e/${RUN_ID}/* namespace" >&2
      return 1
      ;;
  esac
}

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
      # shellcheck disable=SC2016 # literal $1 for the generated askpass script, not this shell's
      printf 'case "$1" in\n'
      printf '  Username*) echo %q ;;\n' "x-access-token"
      printf '  *) echo %q ;;\n' "${token}"
      printf 'esac\n'
    } >"${askpass}"
  } 2>/dev/null
  token=""
  printf '%s' "${askpass}"
}

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

report_stale_disposable_branches() {
  local token api_repo branches_json curl_config token_file
  token="$(aws ssm get-parameter --with-decryption --name "${GITOPS_TEST_TOKEN_SSM_PARAM}" \
    --region "${GITOPS_TEST_TOKEN_SSM_REGION}" --query Parameter.Value --output text 2>/dev/null)" || { info "could not read the GitHub token from SSM; skipping the stale e2e/ branch check"; return 0; }
  api_repo="$(sed -E 's#^https://github.com/##; s#\.git$##' <<<"${GITOPS_TEST_REPO_URL}")"
  # Neither the curl header nor the Python helper below ever takes the token
  # on a command line or in an environment variable (both are visible to
  # any other process via `ps` for the command's lifetime): curl reads it
  # from a -K config file, and the Python helper reads it from a file path
  # named by an env var, never the token itself. Both files are mode 600
  # and removed immediately after use.
  curl_config="$(mktemp)"
  chmod 600 "${curl_config}"
  { set +x
    printf 'header = "Authorization: Bearer %s"\n' "${token}"
    printf 'header = "Accept: application/vnd.github+json"\n'
  } >"${curl_config}" 2>/dev/null
  branches_json="$(curl -fsS -K "${curl_config}" \
    "https://api.github.com/repos/${api_repo}/branches?per_page=100" 2>/dev/null)" || branches_json="[]"
  rm -f "${curl_config}"
  token_file="$(mktemp)"
  chmod 600 "${token_file}"
  { set +x; printf '%s' "${token}" >"${token_file}"; } 2>/dev/null
  while IFS=$'\t' read -r name age_days; do
    [[ -n "${name}" ]] || continue
    info "found remote disposable branch refs/heads/${name} (${age_days}d old) -- reported for visibility, deleted only if it is this run's own"
    if [[ "${name}" == "e2e/${RUN_ID}/"* ]]; then
      if delete_disposable_branch "${name}"; then
        info "cleanup: deleted stale branch refs/heads/${name} from this run's own namespace"
      else
        info "cleanup: could not delete stale branch refs/heads/${name} from this run's own namespace (remove it by hand)"
      fi
    fi
  done < <(printf '%s' "${branches_json}" | API_REPO="${api_repo}" TOKEN_FILE="${token_file}" python3 -c '
import json, os, sys, urllib.request, datetime
docs = json.load(sys.stdin) if sys.stdin.readable() else []
api_repo = os.environ.get("API_REPO", "")
token_file = os.environ.get("TOKEN_FILE", "")
with open(token_file, encoding="utf-8") as f:
    token = f.read()
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
  rm -f "${token_file}"
  token=""
}

# checkout_revision_as CLONE_DIR NEW_BRANCH REVISION: see 1.e2e.sh's own
# identical function for why -- `-B` with an explicit start point skips
# `git checkout <name>`'s DWIM auto-tracking-branch creation, and a fresh
# clone of GITOPS_REPO_URL only has GITOPS_REVISION as a remote-tracking
# ref, confirmed on a real clone.
checkout_revision_as() {
  local clone="$1" branch="$2" revision="$3"
  git -C "${clone}" checkout --quiet -B "${branch}" "${revision}" 2>/dev/null \
    || git -C "${clone}" checkout --quiet -B "${branch}" "origin/${revision}"
}

# ensure_cell_fixture: see 1.e2e.sh's own identical function for why --
# cells.ApplicationSet.yaml's Git file generator needs a
# gitops/cells/${NAME}/ directory at GITOPS_REVISION, this PR ships only
# gitops/cells/example-cell/, and every concurrent run needs its own NAME
# so it never collides with another owner's cell/state-lock/Identity
# Center group. Reassigns GITOPS_REVISION to a disposable branch (copying
# example-cell's fixture to NAME unchanged) when NAME has no fixture of
# its own at GITOPS_REVISION; a no-op otherwise.
ensure_cell_fixture() {
  local probe
  probe="$(mktemp -d)"
  git clone --quiet --no-single-branch "${GITOPS_REPO_URL}" "${probe}" || { rm -rf "${probe}"; return 1; }
  checkout_revision_as "${probe}" "fixture-probe" "${GITOPS_REVISION}" || { rm -rf "${probe}"; return 1; }
  if [[ -d "${probe}/gitops/cells/${NAME}" ]]; then
    rm -rf "${probe}"
    return 0
  fi
  if [[ ! -d "${probe}/gitops/cells/example-cell" ]]; then
    echo "gitops/cells/example-cell is missing at ${GITOPS_REVISION}; cannot derive a fixture for NAME=${NAME}" >&2
    rm -rf "${probe}"
    return 1
  fi
  cp -r "${probe}/gitops/cells/example-cell" "${probe}/gitops/cells/${NAME}" || { rm -rf "${probe}"; return 1; }
  git -C "${probe}" add "gitops/cells/${NAME}" || { rm -rf "${probe}"; return 1; }
  git -C "${probe}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
    commit --quiet -m "test: disposable cell fixture gitops/cells/${NAME}/, copied from example-cell (never merged)" \
    || { rm -rf "${probe}"; return 1; }
  CELL_FIXTURE_BRANCH="e2e/${RUN_ID}/cell-${NAME}"
  push_disposable_branch "${probe}" "${CELL_FIXTURE_BRANCH}" || { rm -rf "${probe}"; CELL_FIXTURE_BRANCH=""; return 1; }
  rm -rf "${probe}"
  BROKEN_BRANCHES+=("${CELL_FIXTURE_BRANCH}")
  GITOPS_REVISION="${CELL_FIXTURE_BRANCH}"
  return 0
}

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
        k delete application root -n "${ARGOCD_NS}" --cascade=background --ignore-not-found >/dev/null 2>&1
      fi
      if tf "${FOUNDATION_ROOT}" destroy -auto-approve -input=false -var-file="${TFVARS}"; then
        info "cleanup: terraform destroy completed"
      else
        log "FAIL cleanup: terraform destroy failed; remove the cell by hand"
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

for b in "${TERRAFORM}" aws "${KUBECTL}" git curl python3; do require_bin "${b}"; done
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || fail "MY_CIDR must be an IPv4 CIDR"
aws sts get-caller-identity --query Account --output text >/dev/null || fail "aws sts get-caller-identity"
pass "preflight: tools present, credentials valid"
info "run ${RUN_ID}, work dir ${WORK_DIR}, upgrading karpenter/karpenter-crd to ${UPGRADE_TO_KARPENTER_VERSION}"
report_stale_disposable_branches

# --------------------- A. mismatched version-pair check (cheapest first)
#
# Acceptance criterion 8, first half: catches a mismatched
# karpenter/karpenter-crd pair. This is the mechanical check decision 6
# requires ("checked mechanically") -- exercised here, before touching
# any cluster, against check_gitops_contract.py, the same check
# 0.static.sh runs on every commit.

MISMATCH_CLONE="${WORK_DIR}/mismatch"
git clone --quiet --no-single-branch "${GITOPS_REPO_URL}" "${MISMATCH_CLONE}" || fail "git clone (mismatch)"
git -C "${MISMATCH_CLONE}" checkout --quiet "${GITOPS_REVISION}" || fail "git checkout ${GITOPS_REVISION} (mismatch)"
sed -i.bak -E "s/^(\\s*version:\\s*).*/\\1\"${UPGRADE_TO_KARPENTER_VERSION}\"/" \
  "${MISMATCH_CLONE}/gitops/addons/karpenter/addon.yaml" \
  || fail "could not bump addons/karpenter/addon.yaml's version in the mismatch clone"
grep -q "${UPGRADE_TO_KARPENTER_VERSION}" "${MISMATCH_CLONE}/gitops/addons/karpenter/addon.yaml" \
  || fail "addons/karpenter/addon.yaml version bump did not take in the mismatch clone"
# addons/karpenter-crd/addon.yaml is deliberately left at its old version.

if python3 "${SCRIPT_DIR}/check_gitops_contract.py" "${MISMATCH_CLONE}" >"${WORK_DIR}/mismatch-check.log" 2>&1; then
  fail "check_gitops_contract.py did not catch the mismatched karpenter/karpenter-crd version pair (see ${WORK_DIR}/mismatch-check.log)"
fi
grep -q "pin the same version" "${WORK_DIR}/mismatch-check.log" \
  || fail "check_gitops_contract.py failed, but not on the version-pair check (see ${WORK_DIR}/mismatch-check.log)"
pass "check_gitops_contract.py's version-pair check caught the mismatched karpenter/karpenter-crd bump"

# ------------------------------------- A2. per-run cell fixture (any NAME)

ensure_cell_fixture || fail "could not prepare gitops/cells/${NAME}/ for this run (NAME=${NAME})"
if [[ -n "${CELL_FIXTURE_BRANCH}" ]]; then
  pass "pushed disposable cell fixture gitops/cells/${NAME}/ (copied from example-cell) to ${CELL_FIXTURE_BRANCH}; using it as this run's GITOPS_REVISION"
else
  pass "gitops/cells/${NAME}/ already exists at ${GITOPS_REVISION}; no disposable fixture needed"
fi

# ---------------------------------------- B0. build one cell at GITOPS_REVISION

IDC_GROUP_ID="$(aws identitystore create-group --identity-store-id "${ARGOCD_IDC_IDENTITY_STORE_ID}" \
  --region "${ARGOCD_IDC_REGION}" --display-name "${RUN_ID}" \
  --description "distai-platform gitops upgrade e2e, deleted at the end of the run" \
  --query GroupId --output text)" \
  || fail "aws identitystore create-group"
pass "created temporary Identity Center group ${RUN_ID}"

TFVARS="${WORK_DIR}/upgrade.tfvars.json"
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

tf "${FOUNDATION_ROOT}" init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" -backend-config="use_lockfile=true" \
  || fail "terraform init with the S3 backend (key ${STATE_KEY})"
existing_state="$(tf "${FOUNDATION_ROOT}" state list 2>&1)" || existing_state=""
[[ "${existing_state}" != *"No state file"* ]] || existing_state=""
[[ -z "${existing_state}" ]] || fail "state at key ${STATE_KEY} already has resources, refusing to apply over it"

APPLY_ATTEMPTED=1
tf "${FOUNDATION_ROOT}" apply -auto-approve -input=false -var-file="${TFVARS}" || fail "terraform apply"
pass "terraform apply"

CLUSTER="$(tf "${FOUNDATION_ROOT}" output -raw cluster_name)"
VPC_ID="$(tf "${FOUNDATION_ROOT}" output -raw vpc_id)"
ARGOCD_NS="$(tf "${FOUNDATION_ROOT}" output -raw argocd_namespace)"
ARGOCD_ARN="$(tf "${FOUNDATION_ROOT}" output -raw argocd_capability_arn)"
aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}" --kubeconfig "${KUBECONFIG}" >/dev/null \
  || fail "aws eks update-kubeconfig"
argocd_active() {
  [[ "$(aws eks list-capabilities --cluster-name "${CLUSTER}" \
    --query "capabilities[?arn=='${ARGOCD_ARN}'].status | [0]" --output text 2>/dev/null)" == "ACTIVE" ]]
}
wait_until 1200 30 "Argo CD capability ACTIVE" argocd_active || fail "Argo CD capability is not ACTIVE"
pass "Argo CD capability ACTIVE"

TF_OUTPUTS_JSON="${WORK_DIR}/tf-outputs.json"
tf "${FOUNDATION_ROOT}" output -json >"${TF_OUTPUTS_JSON}"
run_bootstrap() { "${GITOPS_ROOT}/bootstrap/bootstrap.sh" --tf-outputs "${TF_OUTPUTS_JSON}" "$@"; }
run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (first bootstrap, --revision ${GITOPS_REVISION})"
BOOTSTRAP_RAN=1
pass "bootstrap.sh completed at ${GITOPS_REVISION}"

APP_KARPENTER_CRD="${CLUSTER}-karpenter-crd"
APP_KARPENTER="${CLUSTER}-karpenter"
APP_KUEUE="${CLUSTER}-kueue"
find_capacity_pool_app() {
  k get applications -n "${ARGOCD_NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E "^${CLUSTER}-capacity-pool-" | head -n1
}
APP_CAPACITY_POOL=""
discover_capacity_pool_app() { APP_CAPACITY_POOL="$(find_capacity_pool_app)"; [[ -n "${APP_CAPACITY_POOL}" ]]; }
wait_until 300 10 "a capacity-pool Application exists" discover_capacity_pool_app || fail "no capacity-pool Application appeared"

wait_until 600 15 "karpenter-crd Synced" app_synced "${APP_KARPENTER_CRD}" || fail "${APP_KARPENTER_CRD} not Synced"
wait_until 900 15 "karpenter Healthy+Synced" app_healthy_synced "${APP_KARPENTER}" || fail "${APP_KARPENTER} not Healthy+Synced"
wait_until 900 15 "kueue Healthy+Synced" app_healthy_synced "${APP_KUEUE}" || fail "${APP_KUEUE} not Healthy+Synced"
wait_until 600 15 "capacity-pool Healthy+Synced" app_healthy_synced "${APP_CAPACITY_POOL}" || fail "${APP_CAPACITY_POOL} not Healthy+Synced"
pass "cell bootstrapped at ${GITOPS_REVISION}: karpenter-crd, karpenter, kueue and capacity-pool all converged"

mapfile -t nodepools < <(k get nodepools -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
[[ "${#nodepools[@]}" -eq 1 ]] || fail "expected exactly 1 NodePool, found ${#nodepools[@]}"
NODEPOOL="${nodepools[0]}"

mapfile -t localqueues < <(k get localqueues -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' | grep -v '^$')
[[ "${#localqueues[@]}" -eq 1 ]] || fail "expected exactly 1 LocalQueue, found ${#localqueues[@]}"
read -r SMOKE_NS SMOKE_LOCALQUEUE <<<"${localqueues[0]}"

cat >"${WORK_DIR}/canary.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: canary
  namespace: ${SMOKE_NS}
  labels:
    kueue.x-k8s.io/queue-name: ${SMOKE_LOCALQUEUE}
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  containers:
    - name: canary
      image: public.ecr.aws/eks-distro/kubernetes/pause:3.10
      resources:
        requests:
          cpu: 500m
          memory: 256Mi
YAML
k apply -f "${WORK_DIR}/canary.yaml" || fail "kubectl apply the canary Pod"
canary_running() { [[ "$(k get pod canary -n "${SMOKE_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]; }
wait_until 900 15 "canary Pod Running" canary_running || fail "canary Pod never reached Running"
CANARY_NODE="$(k get pod canary -n "${SMOKE_NS}" -o jsonpath='{.spec.nodeName}')"
CANARY_INSTANCE_ID="$(instance_of_node "${CANARY_NODE}")"
NODEPOOL_CREATED="$(k get nodepool "${NODEPOOL}" -o jsonpath='{.metadata.creationTimestamp}')"
pass "canary Pod Running on node ${CANARY_NODE} (instance ${CANARY_INSTANCE_ID})"

# ------------------------------------- B. matched version bump passes
#
# Acceptance criterion 8, second half: a matched bump passes the
# no-replacement and canary-pod-stays-Running assertions. Both
# addons/karpenter/addon.yaml and addons/karpenter-crd/addon.yaml move to
# UPGRADE_TO_KARPENTER_VERSION together; only the root Application's
# targetRevision and the registration Secret's revision annotation are
# re-pointed (decision 6: "re-point only that cell's root
# Application.spec.source.targetRevision and registration Secret's
# revision annotation ... never the shared stable tag").

UPGRADE_CLONE="${WORK_DIR}/upgrade-match"
UPGRADE_BRANCH="e2e/${RUN_ID}/upgrade-match"
git clone --quiet --no-single-branch "${GITOPS_REPO_URL}" "${UPGRADE_CLONE}" || fail "git clone (upgrade-match)"
checkout_revision_as "${UPGRADE_CLONE}" "${UPGRADE_BRANCH}" "${GITOPS_REVISION}" || fail "git checkout (upgrade-match)"
for f in addons/karpenter/addon.yaml addons/karpenter-crd/addon.yaml; do
  sed -i.bak -E "s/^(\\s*version:\\s*).*/\\1\"${UPGRADE_TO_KARPENTER_VERSION}\"/" "${UPGRADE_CLONE}/gitops/${f}" \
    || fail "could not bump ${f} in the upgrade-match clone"
  grep -q "${UPGRADE_TO_KARPENTER_VERSION}" "${UPGRADE_CLONE}/gitops/${f}" || fail "${f} version bump did not take"
done
if ! python3 "${SCRIPT_DIR}/check_gitops_contract.py" "${UPGRADE_CLONE}" >"${WORK_DIR}/upgrade-match-check.log" 2>&1; then
  fail "check_gitops_contract.py rejected the matched version bump (see ${WORK_DIR}/upgrade-match-check.log)"
fi
git -C "${UPGRADE_CLONE}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
  commit --quiet -am "test: bump karpenter/karpenter-crd to ${UPGRADE_TO_KARPENTER_VERSION} for e2e upgrade experiment (never merged)" \
  || fail "git commit (upgrade-match)"
push_disposable_branch "${UPGRADE_CLONE}" "${UPGRADE_BRANCH}" || fail "git push (upgrade-match)"
BROKEN_BRANCHES+=("${UPGRADE_BRANCH}")
pass "pushed the matched version bump to disposable branch ${UPGRADE_BRANCH}"

run_bootstrap --revision "${UPGRADE_BRANCH}" || fail "bootstrap.sh --revision ${UPGRADE_BRANCH}"
pass "re-pointed root Application's targetRevision and the registration Secret's revision annotation at ${UPGRADE_BRANCH}"

# Sample the canary pod and every tracked Application every few seconds
# while Argo CD syncs the bump, exactly as #24's upgrade e2e samples a
# canary Deployment during `terraform apply` -- an ordering bug would
# show as a dropped sample here, not only as a final-state check.
SAMPLE_UNTIL=$(($(date +%s) + 300))
while [[ "$(date +%s)" -lt "${SAMPLE_UNTIL}" ]]; do
  phase="$(k get pod canary -n "${SMOKE_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)"
  node="$(k get pod canary -n "${SMOKE_NS}" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
  [[ "${phase}" == "Running" ]] || fail "canary Pod left Running (phase=${phase}) during the version-bump sync"
  [[ "${node}" == "${CANARY_NODE}" ]] || fail "canary Pod moved to a different node (${node}) during the version-bump sync -- its NodePool-launched instance was replaced"
  for app in "${APP_KARPENTER_CRD}" "${APP_KARPENTER}" "${APP_KUEUE}" "${APP_CAPACITY_POOL}"; do
    h="$(app_health "${app}")"
    if [[ "${h}" == "Degraded" ]]; then
      DEGRADED_SEEN="${app} went Degraded during the sync"
      fail "${DEGRADED_SEEN}"
    fi
  done
  sleep 5
done
pass "sampled the canary Pod and every tracked Application every 5s for 300s: canary stayed Running on ${CANARY_NODE}, no Application went Degraded"

wait_until 900 15 "karpenter Healthy+Synced at ${UPGRADE_TO_KARPENTER_VERSION}" app_healthy_synced "${APP_KARPENTER}" \
  || fail "${APP_KARPENTER} did not reach Healthy+Synced at the new version"
pass "${APP_KARPENTER} reached Healthy+Synced after the version bump to ${UPGRADE_TO_KARPENTER_VERSION}"

# Healthy+Synced alone does not prove the bump actually took -- an
# ApplicationSet that silently kept the old generated Application would
# also read Healthy+Synced at its own (unchanged) version. For an OCI
# chart source, spec.source.targetRevision IS the chart version (never a
# git revision -- the same distinction the capacity-pool/revision check
# above relies on), so comparing it directly against
# UPGRADE_TO_KARPENTER_VERSION is the one assertion that actually proves
# the new chart version, not merely a healthy old one, is what synced.
karpenter_bumped_revision="$(app_field "${APP_KARPENTER}" '{.spec.source.targetRevision}')"
[[ "${karpenter_bumped_revision}" == "${UPGRADE_TO_KARPENTER_VERSION}" ]] \
  || fail "${APP_KARPENTER}'s targetRevision is ${karpenter_bumped_revision}, not the bumped ${UPGRADE_TO_KARPENTER_VERSION} -- Healthy+Synced was reached on the OLD version, the bump never actually applied"
karpenter_crd_bumped_revision="$(app_field "${APP_KARPENTER_CRD}" '{.spec.source.targetRevision}')"
[[ "${karpenter_crd_bumped_revision}" == "${UPGRADE_TO_KARPENTER_VERSION}" ]] \
  || fail "${APP_KARPENTER_CRD}'s targetRevision is ${karpenter_crd_bumped_revision}, not the bumped ${UPGRADE_TO_KARPENTER_VERSION}"
pass "${APP_KARPENTER} and ${APP_KARPENTER_CRD}'s own targetRevision both confirm the bump to ${UPGRADE_TO_KARPENTER_VERSION} actually applied, not merely that the old version stayed healthy"

[[ "$(k get nodepool "${NODEPOOL}" -o jsonpath='{.metadata.creationTimestamp}')" == "${NODEPOOL_CREATED}" ]] \
  || fail "NodePool ${NODEPOOL}'s creationTimestamp changed -- it was replaced, not merely upgraded"
final_phase="$(k get pod canary -n "${SMOKE_NS}" -o jsonpath='{.status.phase}')"
final_node="$(k get pod canary -n "${SMOKE_NS}" -o jsonpath='{.spec.nodeName}')"
[[ "${final_phase}" == "Running" && "${final_node}" == "${CANARY_NODE}" ]] \
  || fail "canary Pod is not Running on ${CANARY_NODE} after the version bump settled (phase=${final_phase}, node=${final_node})"
pass "no NodePool replacement and the canary Pod stayed Running on the same node throughout the matched version bump"
info "CRD-schema-diff check: not exercised (no chart this PR delivers applies a crds/-folder CRD; karpenter's own is skipped via skipCrds: true)"

run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION})"

# ------------------------------------------------------------- destroy

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
      instance) out="$(aws_text aws ec2 describe-instances --filters "${filter}" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)" ;;
      eni) out="$(aws_text aws ec2 describe-network-interfaces --filters "${filter}" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ;;
      nat) out="$(aws_text aws ec2 describe-nat-gateways --filter "${filter}" "Name=state,Values=pending,available,deleting" --query 'NatGateways[].NatGatewayId' --output text)" ;;
      volume) out="$(aws_text aws ec2 describe-volumes --filters "${filter}" --query 'Volumes[].VolumeId' --output text)" ;;
      launch-template) out="$(aws_text aws ec2 describe-launch-templates --filters "${filter}" --query 'LaunchTemplates[].LaunchTemplateId' --output text)" ;;
    esac; then
      printf '%s' "${out}"
      return 1
    fi
    all+="${out}"$'\n'
  done < <(tag_filters)
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

k delete pod canary -n "${SMOKE_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
destroy_start="$(date +%s)"
tf "${FOUNDATION_ROOT}" destroy -auto-approve -input=false -var-file="${TFVARS}" || fail "terraform destroy"
DESTROYED=1
pass "terraform destroy completed ($(($(date +%s) - destroy_start))s)"

instances_terminated() {
  local out states
  out="$(aws_text aws ec2 describe-instances --instance-ids "${CANARY_INSTANCE_ID}" --query 'Reservations[].Instances[].State.Name' --output text)" || fail "checking instance state: ${out}"
  states="$(printf '%s' "${out}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' | sort -u || true)"
  [[ -z "${states}" || "${states}" == "terminated" ]]
}
wait_until "${E2E_LEFTOVER_GRACE_SECONDS}" 20 "instance terminated" instances_terminated \
  || fail "instance ${CANARY_INSTANCE_ID} not terminated after destroy"
pass "instance ${CANARY_INSTANCE_ID} terminated"

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" || fail "resources tagged for the cluster remain after destroy"

if ! vpc_check_out="$(aws_text aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].VpcId' --output text)"; then
  fail "checking whether VPC ${VPC_ID} still exists: ${vpc_check_out}"
fi
[[ -z "${vpc_check_out}" || "${vpc_check_out}" == "None" ]] || fail "VPC ${VPC_ID} still exists after destroy"
pass "VPC removed"
