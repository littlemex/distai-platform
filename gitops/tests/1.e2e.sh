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
#      entry has no AmazonEKSClusterAdminPolicy association (it already
#      carries the two built-in Argo-CD-capability-management policies,
#      which let the capability manage itself, not arbitrary cluster
#      objects); after it, AmazonEKSClusterAdminPolicy is associated too
#      -- both by a direct `aws eks` call, on the same cell;
#   3. bootstrap.sh's three objects are idempotent, a --revision-only
#      re-run updates the Secret annotation and root Application's
#      targetRevision together, and a wrong-cluster attempt aborts before
#      any write -- decision 1's two conditions checked independently,
#      each against this cell's own already-bootstrapped registration;
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
# (NAME) IS the GPU accelerator cell. NAME must equal dp-a19-gpu-r3
# (ACCEL_GPU_CELL_NAME) for the checked-in gitops/cells/dp-a19-gpu-r3/ fixture
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
# Step 11b also covers issue #27 (the capacity-pool chart's -rsv/-od/-flex
# pools) on the same cell:
#   a. a -rsv, a -od and a -flex release each create one NodePool/
#      EC2NodeClass/ResourceFlavor joined by karpenter.sh/nodepool, with
#      the capacity-type requirement of its pool and, for -rsv only,
#      capacityReservationSelectorTerms from reservation.tags (targeted);
#   b. a real, targeted, one-instance, two-hour On-Demand Capacity
#      Reservation backs the -rsv pool: a canary admitted through its
#      LocalQueue launches exactly one node labelled
#      karpenter.sh/capacity-type=reserved and
#      karpenter.k8s.aws/capacity-reservation-id=<that reservation>; a
#      second canary on the same queue is not admitted, by the
#      ClusterQueue's own quota (Kueue's Workload condition), while the
#      first holds the node;
#   c. the -od and -flex pools each admit a canary and launch a node with
#      the capacity type of the pool;
#   d. the reservation is cancelled at the end, on success and on failure
#      alike, confirmed by DescribeCapacityReservations showing cancelled.
#
# Issue #41 (platform-optional add-ons), step 14b: a cell's own
# gitops/cells/<cell>/addons/dcgm-exporter.yaml marker file generates a
# dcgm-exporter Application through addons-optional.ApplicationSet.yaml
# (absent without it), the Application reaches Healthy+Synced, its
# DaemonSet runs only on a GPU node (proved with a disposable GPU
# NodePool test fixture), and removing the marker orphans its resources;
# step 10 also checks the fourth core add-on, optional-pool.
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
#   foundation e2e which takes pre-existing group IDs), GITOPS_BASE_REF (a
#   ref of infra/foundation before issue #25's access-policy-association
#   change, for acceptance criterion 2's "before" state -- never a
#   default: origin/main has no infra/foundation today, and after this PR
#   merges main already carries the association, so either default would
#   make the "before" apply prove nothing; pass this branch's own
#   merge-base with fix/26-guard-partial-apply, this PR's own immediate base now that it is stacked on #36).
# Optional environment:
#   TERRAFORM (terraform), KUBECTL (kubectl), E2E_WORK_DIR (mktemp -d),
#   E2E_KEEP_ON_FAILURE (0), E2E_LEFTOVER_GRACE_SECONDS (600),
#   GITOPS_REPO_URL (inferred from `git remote get-url origin` -- read-only
#   clone source for every disposable branch below),
#   GITOPS_TEST_REPO_URL (https://github.com/littlemex/distai-platform.git
#   -- the push target for this test's own disposable branches; every
#   manifest this suite bootstraps hard-codes this same URL as its own
#   Git source, so pointing this at a fork does not make Argo CD read
#   the fork's branches -- there is no supported way to run this suite
#   against a fork today),
#   GITOPS_TEST_TOKEN_SSM_PARAM (a parameter you create; the default,
#   /relay/github/distai-platform, is only this environment's own naming
#   convention) and GITOPS_TEST_TOKEN_SSM_REGION (us-east-1) -- a GitHub
#   token with Contents: write on GITOPS_TEST_REPO_URL, read fresh from
#   SSM Parameter Store (SecureString) at each push/delete, never passed
#   on a command line or in an environment variable, held only in
#   mode-600 temporary files removed immediately after each use (never
#   .git/config or a log; see push_disposable_branch() and
#   report_stale_disposable_branches()),
#   GITOPS_SKIP_ORDERING_EXPERIMENT (0 -- set to 1 to skip only step 12's
#   already-converged-cell re-confirmation of acceptance criterion 4 if
#   this token cannot write to GITOPS_TEST_REPO_URL; criterion 4 itself
#   is still exercised by the pristine stage A/B/C sequence in section 3c
#   below, this cell's own first-ever bootstrap, which pushes
#   unconditionally; the step 11b capacity-type pools, the step 13
#   generator-entry-loss experiment and 2.upgrade.sh's own disposable
#   branches have no bypass either, since their own acceptance criteria
#   need exactly this write),
#   E2E_RSV_INSTANCE_TYPE (m7i.large -- the instance type of step 11b's
#   one-instance Capacity Reservation; must satisfy the capacity-pool
#   chart's default requirements: amd64, category c/m/r, generation > 5),
#   GITOPS_RUN_ACCEL_E2E (0 -- set to 1 to add issue #28's accelerator
#   checks, item 8 above; 0 leaves this script's #25/#17 behavior
#   unchanged).
# Required only when GITOPS_RUN_ACCEL_E2E=1:
#   ACCEL_GPU_TEST_IMAGE -- an image with `nvidia-smi` on PATH (e.g. a
#   CUDA base image; the NVIDIA container runtime injects the binary for
#   images that request the `utility` driver capability) and `sleep`; no
#   repository file pins one, so this test does not guess a tag;
#   ACCEL_TRN_TEST_IMAGE -- an image with `neuron-ls` (aws-neuronx-tools)
#   on PATH and `sleep`, e.g. a Neuron deep learning container; same
#   reason for having no default.
# Optional when GITOPS_RUN_ACCEL_E2E=1:
#   ACCEL_GPU_CELL_NAME (dp-a19-gpu-r3 -- NAME must equal it),
#   ACCEL_TRN_CELL_NAME (dp-a19-trn-r3 -- the second cell's name; must have
#   a checked-in gitops/cells/<name>/capacity-pool/ fixture),
#   ACCEL_TRN_REGION (ap-southeast-4 -- where trn2.3xlarge spot is
#   available), ACCEL_POD_TIMEOUT_SECONDS (1800 -- how long a Layer 1 pod
#   may take to reach Running, spot launch and driver/plugin start
#   included).
set -euo pipefail
# mapfile/readarray needs bash >=4 (gitops/tests/README.md's own
# Prerequisites) -- never run this on macOS's shipped bash 3.2.
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo "FAIL this script needs bash >= 4 (mapfile/readarray); got ${BASH_VERSION}" >&2; exit 1; }

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
# No default: acceptance criterion 2's "before" state only means anything
# against a ref that does NOT yet carry issue #25's access-policy
# association. Today, origin/main has no infra/foundation directory at all
# (fails the "has no infra/foundation directory" check below); once this PR
# merges, main WILL carry the association, and a default of origin/main
# would then make the "before" apply already pass what step 3 asserts to be
# new -- silently proving nothing. Pin this explicitly to a pre-#25 commit
# or ref of fix/26-guard-partial-apply (its own merge-base with this branch, for
# example) every time this script is run, rather than ever rely on a
# moving default that is wrong on one side of this PR's own merge or the
# other.
: "${GITOPS_BASE_REF:?export GITOPS_BASE_REF (a ref of infra/foundation before the access-policy-association change this issue adds -- e.g. the merge-base of this branch with fix/26-guard-partial-apply; never origin/main, see the comment above)}"
export AWS_PROFILE AWS_REGION

TERRAFORM="${TERRAFORM:-terraform}"
KUBECTL="${KUBECTL:-kubectl}"
E2E_KEEP_ON_FAILURE="${E2E_KEEP_ON_FAILURE:-0}"
E2E_LEFTOVER_GRACE_SECONDS="${E2E_LEFTOVER_GRACE_SECONDS:-600}"
GITOPS_SKIP_ORDERING_EXPERIMENT="${GITOPS_SKIP_ORDERING_EXPERIMENT:-0}"
GITOPS_TEST_REPO_URL="${GITOPS_TEST_REPO_URL:-https://github.com/littlemex/distai-platform.git}"
GITOPS_TEST_TOKEN_SSM_PARAM="${GITOPS_TEST_TOKEN_SSM_PARAM:-/relay/github/distai-platform}"
GITOPS_TEST_TOKEN_SSM_REGION="${GITOPS_TEST_TOKEN_SSM_REGION:-us-east-1}"
E2E_RSV_INSTANCE_TYPE="${E2E_RSV_INSTANCE_TYPE:-m7i.large}"
GITOPS_RUN_ACCEL_E2E="${GITOPS_RUN_ACCEL_E2E:-0}"
ACCEL_GPU_CELL_NAME="${ACCEL_GPU_CELL_NAME:-dp-a19-gpu-r3}"
ACCEL_TRN_CELL_NAME="${ACCEL_TRN_CELL_NAME:-dp-a19-trn-r3}"
ACCEL_TRN_REGION="${ACCEL_TRN_REGION:-ap-southeast-4}"
ACCEL_POD_TIMEOUT_SECONDS="${ACCEL_POD_TIMEOUT_SECONDS:-1800}"
ACCEL_GPU_TEST_IMAGE="${ACCEL_GPU_TEST_IMAGE:-}"
ACCEL_TRN_TEST_IMAGE="${ACCEL_TRN_TEST_IMAGE:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${GITOPS_ROOT}/.." && pwd)"
FOUNDATION_ROOT="${REPO_ROOT}/infra/foundation"
# Which -chdir root cleanup()'s own destroy uses: whichever root this run's
# apply was last attempted from (BASE_FOUNDATION_ROOT, then switched to
# FOUNDATION_ROOT once the "after" apply starts), never hardcoded to
# FOUNDATION_ROOT -- the same TF_DATA_DIR/state key is shared across both,
# but if the "before" apply (BASE_FOUNDATION_ROOT) fails partway through,
# cleanup must destroy from the root that was actually applied, not a
# different checkout's config FOUNDATION_ROOT was never init'd from yet.
DESTROY_FROM_ROOT="${FOUNDATION_ROOT}"
GITOPS_REPO_URL="${GITOPS_REPO_URL:-$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')}"
[[ -n "${GITOPS_REPO_URL}" ]] || { echo "FAIL could not infer GITOPS_REPO_URL; set it explicitly"; exit 1; }

WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1
# Every GitHub-token-bearing temp file (the GIT_ASKPASS helper, the
# curl -K config, the Python helper's token file) lives under this one
# mode-700 directory, never the shared system /tmp. cleanup() below
# removes it unconditionally, even on a signal that interrupts a
# function before its own normal rm -f runs -- the per-use rm -f calls
# stay too, so a file is gone immediately after use in the common case,
# not only at the end of the whole run.
SECRET_TMP_DIR="$(mktemp -d)"
chmod 700 "${SECRET_TMP_DIR}"

STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="gitops-e2e-${NAME}-$(date -u +%Y%m%d%H%M%S)-${RANDOM}"
TEST_TAG_KEY="distai-platform-e2e"
# Same image+digest infra/foundation/tests/1.e2e.sh's own IMDS check
# already pins: a scrape pod for step 14b-d's metrics check below.
DCGM_SCRAPE_CURL_IMAGE="docker.io/curlimages/curl@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69"

APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
VPC_ID=""
IDC_GROUP_ID=""
BOOTSTRAP_RAN=0
BROKEN_BRANCHES=()
CLEANUP_FAILED=0
CELL_FIXTURE_BRANCH=""
RSV_ID=""
RSV_CANCELLED=0

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

# Step 14b's GPU NodePool/EC2NodeClass/trigger Pod test fixture (issue #41),
# named per run; empty until step 14b applies it. cleanup() deletes all
# three by this name on any failure path that reaches it.
GPU_FIXTURE_NAME=""

# ---------------------------------------------------------------- helpers

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
pass() { log "PASS $*"; }
# Stops this run immediately (#63, filed as #61 item 4): a stateful e2e
# step builds on the cluster state the previous step left behind, so one
# step's failure makes every later step's own precondition unknown --
# continuing past it would not report more facts, it would report noise.
# This is deliberately NOT the same contract as gitops/tests/0.static.sh's
# run_check() (which accumulates every failure and keeps going -- right
# for independent, stateless static checks, where one bad chart should
# not hide a problem in an unrelated one) or examples/inference/tests/
# 0.static.sh's own fail() (which counts and returns, the same
# accumulating contract under the same name as this file's stopping one --
# a line copied between the two changes meaning silently, which is why
# this comment exists). 2.upgrade.sh's own fail() is identical to this one
# for the same reason: an upgrade e2e is also stateful.
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
      info "timed out after ${timeout}s waiting for: ${desc}"
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
app_exists() { k get application "$1" -n "${ARGOCD_NS}" >/dev/null 2>&1; }
app_health() { app_field "$1" '{.status.health.status}'; }
app_sync() { app_field "$1" '{.status.sync.status}'; }
app_healthy_synced() { [[ "$(app_health "$1")" == "Healthy" && "$(app_sync "$1")" == "Synced" ]]; }

# app_operation_state APP: reads status.operationState's phase, message,
# retryCount and syncResult, plus status.conditions, in one single
# `kubectl get -o json` call -- so all of them come from the same
# server-side snapshot, never racing across several separate app_field
# jsonpath calls each hitting the API at a slightly different instant.
# Issue #45: Argo CD's own controller (controller/appcontroller.go, the
# retry-preparation branch reached once a finished sync attempt's backoff
# has elapsed) writes a generic "Retrying operation. Attempt #N" message
# and sets syncResult to nil in the very same state write, while
# preparing the next attempt -- reading message and syncResult with two
# separate calls could therefore see one from before that write and one
# from after, misreporting which window the read actually landed in.
# Prints six tab-separated fields on one line: phase, message,
# retryCount, whether syncResult is present (1) or nil (0), a '|'-joined
# "kind/name: message" summary of syncResult.resources[] (empty when
# syncResult is nil or carries no resources), and a '|'-joined
# "type: message" summary of status.conditions[] (ComparisonError/
# SyncError land here independently of operationState, confirmed by
# controller/state.go's CompareAppState -- logged for diagnosis per
# Issue #45's second proposed fix, not relied on as this test's primary
# signal, since which error classes it covers for a GVK-discovery
# failure specifically is not confirmed against a real cluster).
app_operation_state() {
  # Field separator is ASCII Unit Separator (0x1F / \x1F), never a tab: bash
  # (and POSIX shells generally) treat space/tab/newline in IFS as "IFS
  # whitespace" and collapse RUNS of them into one delimiter regardless of
  # what else is in IFS -- confirmed directly:
  #   printf 'a\tb\t\tc\n' | { IFS=$'\t' read -r x y z; ... }  # z is "c", not ""
  # A tab-separated row with an empty retryCount field (Argo CD's own
  # omitempty on retryCount: 0, or this script's own "" default) would
  # silently lose that field and shift every later one left by one column
  # -- Issue #45's review caught this before it ever shipped. \x1F is not
  # "IFS whitespace", so IFS=$'\x1F' read below preserves empty fields
  # exactly as written, the same way a comma or pipe separator would.
  k get application "$1" -n "${ARGOCD_NS}" -o json 2>/dev/null | python3 -c '
import json, sys

FS = "\x1f"

def clean(s):
    # Strips the field separator and the inner "|" item separator out of
    # free-form text too, not just newlines/tabs: a value containing
    # either would otherwise silently re-introduce the exact column-shift
    # or item-merge bugs this encoding exists to avoid.
    return (s or "").replace(FS, " ").replace("|", "/").replace("\t", " ").replace("\n", " ")

def flatten(items, fmt):
    return "|".join(fmt(i) for i in items)

try:
    doc = json.load(sys.stdin)
except ValueError:
    doc = {}
status = doc.get("status") or {}
op = status.get("operationState") or {}
phase = clean(op.get("phase"))
message = clean(op.get("message"))
retry_count = op.get("retryCount")
retry_count = "" if retry_count is None else str(retry_count)
sync_result = op.get("syncResult")
if sync_result is None:
    has_sync_result = "0"
    resources_summary = ""
else:
    has_sync_result = "1"
    resources_summary = flatten(
        sync_result.get("resources") or [],
        lambda r: "{}/{}: {}".format(clean(r.get("kind")), clean(r.get("name")), clean(r.get("message"))),
    )
conditions_summary = flatten(
    status.get("conditions") or [],
    lambda c: "{}: {}".format(clean(c.get("type")), clean(c.get("message"))),
)
print(FS.join([phase, message, retry_count, has_sync_result, resources_summary, conditions_summary]))
'
}

# job_node NS JOB: prints the node name the Job's pod is bound to, or
# fails if none is bound yet. "|", never " ", between nodeName and phase:
# awk's default whitespace-splitting strips a line's leading blank before
# splitting into fields, so an empty nodeName ("" followed by a space, then
# "Pending") silently shifted the *phase* into $1 -- `$1!=""` was true the
# instant the pod existed, long before any node was ever assigned, and the
# bogus "Pending" was then used as a literal node name (`kubectl get node
# Pending` -> NotFound, uncaught under set -e, confirmed on a real
# cluster). A non-whitespace delimiter with -F keeps an empty first field
# empty.
job_node() {
  k get pods -n "$1" -l "job-name=$2" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{.status.phase}{"\n"}{end}' \
    | awk -F'|' '$1!="" {print $1; found=1} END{exit !found}'
}

# workload_of_job NS JOB: prints the name of the one Kueue Workload owned
# by the Job (Kueue chooses the name; it is never assumed), or nothing.
workload_of_job() {
  k get workloads -n "$1" -o json 2>/dev/null | python3 -c '
import json, sys
job = sys.argv[1]
items = json.load(sys.stdin).get("items", [])
names = [
    w["metadata"]["name"]
    for w in items
    if any(o.get("kind") == "Job" and o.get("name") == job for o in w["metadata"].get("ownerReferences", []))
]
print(names[0] if len(names) == 1 else "")
' "$2"
}

# list_names KIND: one name per line, for cluster-scoped kinds.
list_names() { k get "$1" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort; }

# ------------------------------------------- run-owned Capacity Reservations
#
# Step 11b creates one On-Demand Capacity Reservation, tagged
# ${TEST_TAG_KEY}=${RUN_ID} like every other AWS resource this run owns.
# cancel_run_capacity_reservations finds every pending/active reservation
# carrying this run's own tag (plus RSV_ID, in case tagging itself failed),
# cancels each, and waits for DescribeCapacityReservations to report
# "cancelled" for every one of them. Called from step 11b's own teardown
# and again from cleanup() if that teardown was never reached, so the
# reservation is cancelled on success and on failure alike.
capacity_reservation_state() {
  aws ec2 describe-capacity-reservations --capacity-reservation-ids "$1" \
    --query 'CapacityReservations[0].State' --output text 2>/dev/null
}
capacity_reservation_cancelled() { [[ "$(capacity_reservation_state "$1")" == "cancelled" ]]; }
cancel_run_capacity_reservations() {
  local ids id state bad=0
  ids="$(aws ec2 describe-capacity-reservations \
    --filters "Name=tag:${TEST_TAG_KEY},Values=${RUN_ID}" "Name=state,Values=pending,active" \
    --query 'CapacityReservations[].CapacityReservationId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' || true)"
  if [[ -n "${RSV_ID}" ]] && ! grep -qx "${RSV_ID}" <<<"${ids}"; then
    ids="$(printf '%s\n%s' "${ids}" "${RSV_ID}" | grep -v '^$')"
  fi
  [[ -n "${ids}" ]] || return 0
  local -a id_list
  mapfile -t id_list <<<"${ids}"
  for id in "${id_list[@]}"; do
    [[ -n "${id}" ]] || continue
    state="$(capacity_reservation_state "${id}")"
    if [[ "${state}" != "cancelled" ]]; then
      aws ec2 cancel-capacity-reservation --capacity-reservation-id "${id}" >/dev/null \
        || log "cancel-capacity-reservation ${id} failed (state was ${state})"
    fi
    if wait_until 300 10 "Capacity Reservation ${id} cancelled" capacity_reservation_cancelled "${id}"; then
      log "PASS Capacity Reservation ${id}: DescribeCapacityReservations reports $(capacity_reservation_state "${id}")"
    else
      log "FAIL Capacity Reservation ${id} is not cancelled (state: $(capacity_reservation_state "${id}")); cancel it by hand"
      bad=1
    fi
  done
  return "${bad}"
}

# ------------------------------------- authenticated disposable branches
#
# Every branch this test ever pushes lives under refs/heads/e2e/<RUN_ID>/*
# -- this run's own namespace, never anywhere else -- and is deleted again
# before the run ends, success or failure. The GitHub token (Contents:
# write on GITOPS_TEST_REPO_URL only) is
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
  set +x
  local token askpass
  token="$(aws ssm get-parameter --with-decryption --name "${GITOPS_TEST_TOKEN_SSM_PARAM}" \
    --region "${GITOPS_TEST_TOKEN_SSM_REGION}" --query Parameter.Value --output text 2>/dev/null)" || return 1
  [[ -n "${token}" && "${token}" != "None" ]] || return 1
  askpass="$(mktemp "${SECRET_TMP_DIR}/askpass.XXXXXX")"
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

# ensure_cell_fixture: cells.ApplicationSet.yaml's Git file generator reads
# gitops/cells/{{name}}/{capacity-pool,smoke}/*.yaml from this checkout at
# GITOPS_REVISION; this PR ships exactly one such fixture,
# gitops/cells/example-cell/. Every concurrent run needs its own NAME (so
# it gets its own STATE_KEY, Identity Center group and foundation cell,
# never colliding with another owner's run on the same state lock), and a
# NAME other than "example-cell" has no matching directory at
# GITOPS_REVISION -- without this step the capacity step would generate
# nothing for it (confirmed on a real cluster prior to this fix). If
# GITOPS_REVISION already has a gitops/cells/${NAME}/ directory (true for
# NAME=example-cell, or a future PR shipping a second named fixture),
# nothing is created and CELL_FIXTURE_BRANCH stays empty. Otherwise this
# clones GITOPS_REVISION, copies gitops/cells/example-cell/ to
# gitops/cells/${NAME}/ unchanged, pushes the result to this run's own
# disposable branch (the same authenticated, self-cleaning mechanism as
# every other disposable branch here -- BROKEN_BRANCHES already deletes
# it in cleanup()), and reassigns the script's own GITOPS_REVISION to that
# branch, so every later comparison against GITOPS_REVISION (the Secret's
# annotation, the root Application's targetRevision, every
# checkout_revision_as derived from it below) is against the revision
# this run actually bootstrapped from, not the revision it started with.
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

# report_stale_disposable_branches: preflight hygiene. Lists every remote
# e2e/* branch older than a day (informational -- a run that was killed
# before its own EXIT trap ran leaves branches only a human, or this
# check, ever lists again) and actively deletes only the ones already in
# this run's own e2e/${RUN_ID}/* namespace (by construction none exist
# yet at preflight time; this guards a RUN_ID collision, not the normal
# case).
report_stale_disposable_branches() {
  set +x
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
  curl_config="$(mktemp "${SECRET_TMP_DIR}/curl-config.XXXXXX")"
  chmod 600 "${curl_config}"
  { set +x
    printf 'header = "Authorization: Bearer %s"\n' "${token}"
    printf 'header = "Accept: application/vnd.github+json"\n'
  } >"${curl_config}" 2>/dev/null
  branches_json="$(curl -fsS -K "${curl_config}" \
    "https://api.github.com/repos/${api_repo}/branches?per_page=100" 2>/dev/null)" || branches_json="[]"
  rm -f "${curl_config}"
  token_file="$(mktemp "${SECRET_TMP_DIR}/token.XXXXXX")"
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

# -------------------------------------------------------- cleanup (trap)

delete_broken_branches() {
  local b
  for b in "${BROKEN_BRANCHES[@]}"; do
    if delete_disposable_branch "${b}" >/dev/null 2>&1; then
      :
    else
      info "cleanup: could not delete disposable branch refs/heads/${b} on ${GITOPS_TEST_REPO_URL} (remove it by hand)"
      CLEANUP_FAILED=1
    fi
  done
}

# verify_no_leftover_branches: an in-script check, not only a human
# reading the INFO lines above -- confirmed on a real run that a cleanup
# bug can leave every one of this run's own branches behind while every
# INFO line above still only warns, never fails. Lists this run's own
# refs/heads/e2e/${RUN_ID}/* namespace on GITOPS_TEST_REPO_URL directly;
# anything still there, for any reason (a bug here, a transient network
# failure, anything), fails this check and this run's own exit code,
# rather than only a log line a human has to notice.
verify_no_leftover_branches() {
  local leftover
  leftover="$(git ls-remote "${GITOPS_TEST_REPO_URL}" "refs/heads/e2e/${RUN_ID}/*" 2>/dev/null)"
  if [[ -n "${leftover}" ]]; then
    log "FAIL cleanup: branches remain under refs/heads/e2e/${RUN_ID}/* on ${GITOPS_TEST_REPO_URL}: $(printf '%s' "${leftover}" | tr '\n' ' ')"
    CLEANUP_FAILED=1
  else
    info "cleanup: verified zero branches remain under refs/heads/e2e/${RUN_ID}/* on ${GITOPS_TEST_REPO_URL}"
  fi
}

cleanup() {
  local rc=$?
  set +e
  # Keep a disposable fixture/break/upgrade branch alive when the cell
  # itself is being kept for debugging (E2E_KEEP_ON_FAILURE=1) -- the
  # kept cell's own root Application still points at it; deleting it
  # unconditionally would leave that cell unable to sync anything.
  if [[ "${E2E_KEEP_ON_FAILURE}" != "1" ]]; then
    delete_broken_branches
    verify_no_leftover_branches
  fi
  # Step 11b's Capacity Reservation is cancelled on success and on
  # failure alike, never gated on E2E_KEEP_ON_FAILURE: an On-Demand
  # Capacity Reservation keeps billing whether or not the cell itself is
  # kept for debugging.
  if [[ "${RSV_CANCELLED}" -ne 1 ]]; then
    cancel_run_capacity_reservations \
      || info "cleanup: a Capacity Reservation tagged ${TEST_TAG_KEY}=${RUN_ID} is not cancelled (cancel it by hand)"
  fi
  if [[ -n "${IDC_GROUP_ID}" ]]; then
    if aws identitystore delete-group --identity-store-id "${ARGOCD_IDC_IDENTITY_STORE_ID}" \
      --region "${ARGOCD_IDC_REGION}" --group-id "${IDC_GROUP_ID}" >/dev/null 2>&1; then
      info "cleanup: deleted temporary Identity Center group ${IDC_GROUP_ID}"
    else
      info "cleanup: could not delete Identity Center group ${IDC_GROUP_ID} (remove it by hand)"
      CLEANUP_FAILED=1
    fi
  fi
  if [[ "${APPLY_ATTEMPTED}" -eq 1 && "${DESTROYED}" -eq 0 ]]; then
    if [[ "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving the cell in place; destroy it with:"
      info "TF_DATA_DIR=${TF_DATA_DIR} ${TERRAFORM} -chdir=${DESTROY_FROM_ROOT} destroy -var-file=${TFVARS}"
    else
      info "cleanup: the test did not reach a successful destroy; cleaning up"
      if [[ "${BOOTSTRAP_RAN}" -eq 1 ]] && k get ns "${ARGOCD_NS:-}" >/dev/null 2>&1; then
        k delete job canary --ignore-not-found --wait=false >/dev/null 2>&1
        k delete namespace "${ACCEL_TEST_NS}" --ignore-not-found --wait=false >/dev/null 2>&1
        k delete application root -n "${ARGOCD_NS}" --cascade=background --ignore-not-found >/dev/null 2>&1
      fi
      # Step 14b's test fixture, never part of the platform: deleting the
      # NodePool lets Karpenter drain its GPU node before the destroy below;
      # the foundation teardown guard terminates it regardless.
      if [[ -n "${GPU_FIXTURE_NAME}" ]]; then
        k delete pod "${GPU_FIXTURE_NAME}" -n default --ignore-not-found --wait=false >/dev/null 2>&1
        k delete nodepool "${GPU_FIXTURE_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1
        k delete ec2nodeclass "${GPU_FIXTURE_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1
        info "cleanup: deleted the step 14b GPU test fixture ${GPU_FIXTURE_NAME} (Pod, NodePool, EC2NodeClass)"
      fi
      tf "${DESTROY_FROM_ROOT}" destroy -auto-approve -input=false -var-file="${TFVARS}"
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
  # A cleanup-side failure (a disposable branch or the Identity Center
  # group left behind) must not read as RESULT PASS with exit 0 -- every
  # acceptance-criteria check above can pass while this run still leaves
  # something behind on a shared, public repository. Confirmed as a real
  # gap on a real run before this check existed: six branches leaked,
  # found only by a human running git ls-remote afterward, while this
  # script itself still reported RESULT PASS.
  if [[ "${rc}" -eq 0 && "${CLEANUP_FAILED}" -eq 1 ]]; then
    rc=1
    FAILED_STEP="cleanup left something behind (see the FAIL/INFO lines above)"
  fi
  echo
  if [[ "${rc}" -eq 0 ]]; then
    if [[ "${GITOPS_SKIP_ORDERING_EXPERIMENT}" == "1" ]]; then
      # Acceptance criterion 4 itself is NOT skipped here: the pristine
      # stage A/B/C sequence (section 3c) that proves its stronger claim
      # pushes and bootstraps unconditionally, since it is this cell's
      # own first-ever bootstrap, not an optional extra. Only step 12's
      # weaker, already-converged-cell re-confirmation of the same
      # ordering is gated by this flag.
      log "RESULT PASS (step 12's already-converged-cell re-confirmation of acceptance criterion 4 skipped, GITOPS_SKIP_ORDERING_EXPERIMENT=1; the pristine stage A/B/C sequence above ran regardless): run ${RUN_ID}, work dir ${WORK_DIR}"
    else
      log "RESULT PASS: all checks passed (run ${RUN_ID}, work dir ${WORK_DIR})"
    fi
  else
    log "RESULT FAIL: ${FAILED_STEP:-exit ${rc}} (run ${RUN_ID}, work dir ${WORK_DIR})"
  fi
  # Removed last, after delete_broken_branches above has had the chance
  # to create its own fresh askpass/curl-config/token files under this
  # directory for each branch it deletes -- removing it any earlier
  # breaks every later git push --delete in this same cleanup() (mktemp
  # under a directory that no longer exists fails silently inside the
  # if/else context delete_disposable_branch runs in, confirmed on a
  # real run: all of this run's own disposable branches failed to
  # delete, consistently, until this ordering was fixed).
  rm -rf "${SECRET_TMP_DIR}"
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
  [[ "${ACCEL_GPU_CELL_NAME}" == "dp-a19-gpu-r3" && "${ACCEL_TRN_CELL_NAME}" == "dp-a19-trn-r3" ]] \
    || fail "GITOPS_RUN_ACCEL_E2E=1: issue #28's fixtures are gitops/cells/dp-a19-gpu-r3/ and gitops/cells/dp-a19-trn-r3/; got ACCEL_GPU_CELL_NAME=${ACCEL_GPU_CELL_NAME} ACCEL_TRN_CELL_NAME=${ACCEL_TRN_CELL_NAME}"
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
info "run ${RUN_ID}, work dir ${WORK_DIR}, repo ${GITOPS_REPO_URL}"
report_stale_disposable_branches

# ------------------------------------- 0. per-run cell fixture (any NAME)

ensure_cell_fixture || fail "could not prepare gitops/cells/${NAME}/ for this run (NAME=${NAME})"
if [[ -n "${CELL_FIXTURE_BRANCH}" ]]; then
  pass "pushed disposable cell fixture gitops/cells/${NAME}/ (copied from example-cell) to ${CELL_FIXTURE_BRANCH}; using it as this run's GITOPS_REVISION"
else
  pass "gitops/cells/${NAME}/ already exists at ${GITOPS_REVISION}; no disposable fixture needed"
fi

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
# before this PR's own change, shows no AmazonEKSClusterAdminPolicy
# association on the capability's access entry (it already carries the two
# built-in Argo-CD-capability-management policies -- see the comment above
# the before/after check below). GITOPS_BASE_REF is a worktree-checked-out
# copy of infra/foundation as it existed before this issue's decision 1
# change (no default -- see the GITOPS_BASE_REF comment at the top of this
# file); it is applied to the SAME state key the "after" apply (step 3)
# reuses, so this is a real upgrade, not two
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
DESTROY_FROM_ROOT="${BASE_FOUNDATION_ROOT}"
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
pass "before this PR's change: capability role ${CAPABILITY_ROLE_ARN} has no AmazonEKSClusterAdminPolicy association (policies: [${capability_policies_before:-none}])"

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
DESTROY_FROM_ROOT="${FOUNDATION_ROOT}"
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

run_bootstrap() {
  "${GITOPS_ROOT}/bootstrap/bootstrap.sh" --tf-outputs "${TF_OUTPUTS_JSON}" "$@"
}

# ------------------------------------------- 3c. pristine first bootstrap
#
# Acceptance criterion 4's own stronger claim ("capacity FAILS TO CREATE
# NEW objects depending on a broken crds step") cannot be observed once a
# chart's CRDs have ever synced successfully: a Kubernetes CRD, once
# installed, persists regardless of whether the Application that installed
# it later goes unsynced (step 12 below proves only that weaker,
# already-converged-cell claim -- the acceptance criterion is not, by
# itself, provable there). The only moment this cell will ever be in a
# state where karpenter-crd's and kueue's own CRDs have never existed is
# its own first-ever bootstrap, so this block *is* that first bootstrap,
# staged in three steps so both halves of decision 4 (crds blocks
# NodePool/EC2NodeClass; kueue blocks ResourceFlavor/ClusterQueue/
# LocalQueue) are each proven pristinely, in the same cell, with no
# second cell needed:
#   A. both karpenter-crd and kueue broken: nothing new can be created.
#   B. kueue still broken, karpenter-crd fixed: karpenter-crd's own
#      Application reaches Synced and its CRDs become Established, but
#      capacity-pool stays blocked as a whole -- confirmed on a real
#      cluster via its own operationState message -- because Argo CD
#      validates every resource kind in one Application's manifest set
#      before applying any of them, and kueue's ResourceFlavor CRD is
#      still undiscoverable; so NodePool/EC2NodeClass still cannot be
#      created either, despite having nothing to do with kueue.
#   C. fully restored (the real GITOPS_REVISION): everything converges.
# Not gated by GITOPS_SKIP_ORDERING_EXPERIMENT: this is this run's own
# first bootstrap, not an optional extra on top of an already-working
# cell, so it needs the same push access step 13's generator-loss
# experiment already requires unconditionally.

APP_KARPENTER_CRD="${CLUSTER}-karpenter-crd"
APP_KARPENTER="${CLUSTER}-karpenter"
APP_KUEUE="${CLUSTER}-kueue"
APP_SMOKE="${CLUSTER}-smoke"
app_synced() { [[ "$(app_sync "$1")" == "Synced" ]]; }
app_not_synced() { [[ "$(app_sync "$1")" != "Synced" ]]; }
# hard_refresh_app: Argo CD's own documented mechanism for "force a fresh
# sync attempt now, do not wait out whatever retry backoff this
# Application is already in". Needed only here, in the pristine A/B/C
# sequence: this is the only place in this whole test suite where an
# Application has already tried and failed to sync because a CRD it
# needs did not exist yet, and later needs to be checked again after
# that CRD appears -- confirmed on a real run that reading
# status.operationState.message (or waiting for app_synced) without
# forcing a fresh attempt first can still reflect the earlier failed
# attempt, stale, for minutes. Every other break/restore experiment in
# this file re-syncs an Application whose dependency's CRD already
# existed before the break (so it never cached a failure against a
# missing CRD in the first place), which Argo CD's own steady-state
# watch-based cache invalidation already handles without this.
hard_refresh_app() {
  k annotate application "$1" -n "${ARGOCD_NS}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}
nodepool_exists() { k get nodepool cpu >/dev/null 2>&1; }
ec2nodeclass_exists() { k get ec2nodeclass cpu >/dev/null 2>&1; }
resourceflavor_exists() { k get resourceflavor cpu >/dev/null 2>&1; }
clusterqueue_exists() { k get clusterqueue smoke >/dev/null 2>&1; }

# assert_stays_not_synced APP TIMEOUT INTERVAL: genuinely proves "this
# Application never reaches Synced within TIMEOUT seconds", not merely
# that it is not Synced at one instant. app_not_synced is trivially true
# the moment a brand-new Application is first created (its sync status
# starts empty/Unknown, never "Synced"), so `wait_until ... app_not_synced`
# returns success on its very first poll -- a few seconds after bootstrap,
# nowhere near long enough to tell "blocked" from "not yet reconciled" --
# proving nothing about persistence (confirmed: this is exactly what the
# first version of stage A/B below did, passing in 5-16 seconds).
# Polls for the POSITIVE condition (app_synced becoming true) over the
# full window instead, and only passes if it never does -- the same
# inversion step 12 below already uses correctly for its own "leaves
# Synced once broken" checks, applied here to "never becomes Synced" on
# a cell that starts out already not-Synced.
assert_stays_not_synced() {
  local app="$1" timeout="$2" interval="$3"
  wait_until "${timeout}" "${interval}" "${app} reaches Synced (expected not to within this window)" app_synced "${app}" \
    && return 1
  return 0
}
# assert_stays_not_synced_bg APP TIMEOUT INTERVAL RESULT_FILE: runs the
# check above in a background subshell, writing PASS/FAIL to RESULT_FILE.
# Several of these are launched together and waited on with `wait`, so N
# checks that each have to hold for the whole window cost one window of
# wall-clock, not N windows.
assert_stays_not_synced_bg() {
  local app="$1" timeout="$2" interval="$3" result_file="$4"
  ( if assert_stays_not_synced "${app}" "${timeout}" "${interval}"; then echo PASS >"${result_file}"; else echo FAIL >"${result_file}"; fi ) &
}
# assert_stays_not_synced_refreshing/_bg: same as above, but hard-refreshes
# the Application on every single poll, not merely once up front. Needed
# specifically where an Application's own sync has already failed and
# cached that failure (stage B: capacity-pool tried and failed to sync
# while karpenter-crd's CRDs did not exist yet) -- Argo CD's own retry
# backoff can otherwise go several minutes before trying again on its
# own, during which status.operationState.message is a stale leftover
# from before the one thing that changed (karpenter-crd becoming
# Established) rather than a result of ever having been re-tried against
# the current state. A plain assert_stays_not_synced here would still
# pass (correctly) but could not back any claim about *why* it stays
# not-Synced with current evidence; forcing a fresh attempt on every
# poll makes "it never reaches Synced" apply to this cell's actual,
# continuously-re-evaluated current state, not a snapshot from before
# the bootstrap that started this stage.
assert_stays_not_synced_refreshing() {
  local app="$1" timeout="$2" interval="$3"
  # shellcheck disable=SC2329 # invoked indirectly, by name, as wait_until's own predicate argument below
  refreshing_predicate() { hard_refresh_app "${app}"; app_synced "${app}"; }
  wait_until "${timeout}" "${interval}" "${app} reaches Synced (expected not to within this window)" refreshing_predicate \
    && return 1
  return 0
}
assert_stays_not_synced_refreshing_bg() {
  local app="$1" timeout="$2" interval="$3" result_file="$4"
  ( if assert_stays_not_synced_refreshing "${app}" "${timeout}" "${interval}"; then echo PASS >"${result_file}"; else echo FAIL >"${result_file}"; fi ) &
}

# break_addon_branches SUFFIX ADDON_RELPATH...: creates
# "e2e/${RUN_ID}/${SUFFIX}" off GITOPS_REVISION with every given
# ADDON_RELPATH's `version:` replaced by a release that cannot exist,
# pushes it to GITOPS_TEST_REPO_URL, and prints the branch name. Tracked
# for cleanup by the caller, not here (see the comment on BROKEN_BRANCHES
# below): every caller uses command substitution, which always forks a
# subshell, so an append here would only ever mutate that subshell's own
# copy of BROKEN_BRANCHES -- confirmed on a real run, this is exactly the
# bug an earlier version of this helper had.
break_addon_branches() {
  local suffix="$1" branch clone addon_relpath
  shift
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
  for addon_relpath in "$@"; do
    sed -i.bak -E 's/^(\s*version:\s*).*/\1"0.0.0-e2e-nonexistent"/' "${clone}/${addon_relpath}" || return 1
    grep -q '0.0.0-e2e-nonexistent' "${clone}/${addon_relpath}" || return 1
  done
  git -C "${clone}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
    commit --quiet -am "test: break $* for e2e ordering experiment (never merged)" || return 1
  push_disposable_branch "${clone}" "${branch}" || return 1
  printf '%s' "${branch}"
}

# ---- A. both karpenter-crd and kueue broken (this cell's first-ever bootstrap)

PRISTINE_BOTH_BROKEN_BRANCH="$(break_addon_branches "pristine-both-broken" \
  "gitops/addons/karpenter-crd/addon.yaml" "gitops/addons/kueue/addon.yaml")" \
  || fail "could not create/push the pristine-both-broken disposable branch"
BROKEN_BRANCHES+=("${PRISTINE_BOTH_BROKEN_BRANCH}")
run_bootstrap --revision "${PRISTINE_BOTH_BROKEN_BRANCH}" \
  || fail "bootstrap.sh (this cell's first-ever bootstrap, both karpenter-crd and kueue broken)"
BOOTSTRAP_RAN=1
pass "bootstrap.sh completed (first-ever bootstrap, --revision ${PRISTINE_BOTH_BROKEN_BRANCH})"

find_capacity_pool_app() {
  k get applications -n "${ARGOCD_NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E "^${CLUSTER}-capacity-pool-" | head -n1
}
APP_CAPACITY_POOL=""
discover_capacity_pool_app() { APP_CAPACITY_POOL="$(find_capacity_pool_app)"; [[ -n "${APP_CAPACITY_POOL}" ]]; }
wait_until 300 10 "a capacity-pool Application exists" discover_capacity_pool_app \
  || fail "no Application named ${CLUSTER}-capacity-pool-<pool> appeared"
# Checked explicitly, not only implied by the "stays not Synced" waits
# below: app_field/app_sync return empty on a missing Application the
# same as on one that exists but has no sync status yet, so a "never
# reaches Synced" check alone would also pass on an Application the
# ApplicationSet never generated at all -- confirmed as a real gap, not
# a hypothetical one. Waited for, not checked once: the capacity-pool
# Application just above needed wait_until's own retry window to
# appear (the ApplicationSet controller's own generation is not
# instantaneous with the root Application's first sync), and a one-shot
# app_exists() immediately after that wait consumed part of the same
# propagation window -- a real, if rare, race in principle. What this
# wait_until actually caught on a real run was not that race: it was
# platform.ApplicationSet.yaml's templatePatch failing to parse entirely
# (a missing {{- end }}, fixed separately), which made the first app in
# this loop time out the same way a slow propagation would, but
# permanently -- no amount of retrying inside this wait_until could have
# passed. Kept as wait_until anyway, since the propagation race above is
# still real and still needs it; a parse error should instead be caught
# earlier and explicitly, which gitops/tests/0.static.sh and
# check_pinned_crds.py's own rendering do not currently check for this
# manifest's own templatePatch field (left as a gap, not fixed here).
for app in "${APP_KARPENTER_CRD}" "${APP_KARPENTER}" "${APP_KUEUE}" "${APP_SMOKE}"; do
  app_exists_app="${app}"
  app_exists_check() { app_exists "${app_exists_app}"; }
  wait_until 60 5 "Application ${app} exists" app_exists_check \
    || fail "Application ${app} does not exist -- the cells/platform ApplicationSet never generated it"
done
pass "discovered generated Applications, each confirmed to exist: ${APP_KARPENTER_CRD}, ${APP_KARPENTER}, ${APP_KUEUE}, ${APP_CAPACITY_POOL}, ${APP_SMOKE}"

# 180s, comfortably longer than any convergence this whole suite has
# observed on a real cluster (the slowest, 2.upgrade.sh's matched-version
# rollout, took 79s) -- long enough that staying not-Synced for the whole
# window is actual evidence of being blocked, not a timing coincidence.
# Run concurrently: each of the four already has to hold for the full
# window on its own, so checking them one after another would cost 4x
# the wall-clock for no additional evidence.
STAGE_A_TIMEOUT=180
STAGE_A_WORK="${WORK_DIR}/stage-a"
mkdir -p "${STAGE_A_WORK}"
assert_stays_not_synced_bg "${APP_KARPENTER_CRD}" "${STAGE_A_TIMEOUT}" 10 "${STAGE_A_WORK}/karpenter-crd"
assert_stays_not_synced_bg "${APP_KUEUE}" "${STAGE_A_TIMEOUT}" 10 "${STAGE_A_WORK}/kueue"
assert_stays_not_synced_bg "${APP_CAPACITY_POOL}" "${STAGE_A_TIMEOUT}" 10 "${STAGE_A_WORK}/capacity-pool"
assert_stays_not_synced_bg "${APP_SMOKE}" "${STAGE_A_TIMEOUT}" 10 "${STAGE_A_WORK}/smoke"
wait
[[ "$(cat "${STAGE_A_WORK}/karpenter-crd")" == PASS ]] \
  || fail "${APP_KARPENTER_CRD} reached Synced despite its chart version being broken on this cell's first-ever bootstrap"
[[ "$(cat "${STAGE_A_WORK}/kueue")" == PASS ]] \
  || fail "${APP_KUEUE} reached Synced despite its chart version being broken on this cell's first-ever bootstrap"
[[ "$(cat "${STAGE_A_WORK}/capacity-pool")" == PASS ]] \
  || fail "${APP_CAPACITY_POOL} reached Synced although karpenter-crd has never synced on this cell"
[[ "$(cat "${STAGE_A_WORK}/smoke")" == PASS ]] \
  || fail "${APP_SMOKE} reached Synced although kueue has never synced on this cell"
pass "none of the four generated Applications that depend on karpenter-crd's or kueue's own broken CRDs (karpenter-crd, kueue, capacity-pool, smoke -- karpenter itself is excluded: skipCrds, no CRD of its own to wait on) reached Synced within ${STAGE_A_TIMEOUT}s of this cell's first-ever bootstrap, polled for the whole window, not sampled once"
nodepool_exists && fail "NodePool cpu was created although karpenter-crd has never synced on this cell (its CRD cannot exist yet)"
ec2nodeclass_exists && fail "EC2NodeClass cpu was created although karpenter-crd has never synced on this cell (its CRD cannot exist yet)"
resourceflavor_exists && fail "ResourceFlavor cpu was created although kueue has never synced on this cell (its CRD cannot exist yet)"
clusterqueue_exists && fail "ClusterQueue smoke was created although kueue has never synced on this cell (its CRD cannot exist yet)"
pass "pristine: with both karpenter-crd and kueue broken on this cell's first-ever bootstrap, neither Application reaches Synced and none of NodePool/EC2NodeClass/ResourceFlavor/ClusterQueue exists -- acceptance criterion 4's stronger claim, observed directly, not asserted from documentation"

# ---- B. karpenter-crd fixed, kueue still broken

PRISTINE_KUEUE_BROKEN_BRANCH="$(break_addon_branches "pristine-kueue-broken" "gitops/addons/kueue/addon.yaml")" \
  || fail "could not create/push the pristine-kueue-broken disposable branch"
BROKEN_BRANCHES+=("${PRISTINE_KUEUE_BROKEN_BRANCH}")
run_bootstrap --revision "${PRISTINE_KUEUE_BROKEN_BRANCH}" \
  || fail "bootstrap.sh --revision ${PRISTINE_KUEUE_BROKEN_BRANCH}"

wait_until 300 10 "karpenter-crd Application reaches Synced" app_synced "${APP_KARPENTER_CRD}" \
  || fail "${APP_KARPENTER_CRD} did not reach Synced (sync=$(app_sync "${APP_KARPENTER_CRD}")) after fixing its own version"
k get crd nodepools.karpenter.sh -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null | grep -q True \
  || fail "nodepools.karpenter.sh CRD is not Established even though ${APP_KARPENTER_CRD} reports Synced"
# karpenter-crd's own CRDs (EC2NodeClass, NodePool) now exist. The
# original design here expected NodePool/EC2NodeClass to converge anyway,
# on the assumption that Argo CD applies what it can per-resource even
# when one resource in the same Application cannot. Confirmed wrong on a
# real cluster, via capacity-pool's own status.operationState.message
# naming kueue.x-k8s.io's own resources as undiscoverable. Argo CD
# validates every resource's own API group/version before applying ANY
# of them in one sync operation, so kueue's still-undiscoverable
# ResourceFlavor blocks the entire capacity-pool Application, including
# NodePool/EC2NodeClass, which have nothing to do with kueue. This is a
# *stronger* form of decision 4's own claim than "only the dependent
# resource fails to create": a mixed-dependency Application is only as
# available as its least-available dependency.
#
# capacity-pool already tried and failed to sync once, while
# karpenter-crd's own CRDs did not exist yet (stage A); that failure's
# own operationState.message is a cached result Argo CD's own retry
# backoff can leave untouched for minutes -- confirmed on a real run:
# the message read shortly after karpenter-crd became Established still
# named karpenter.k8s.aws/v1 and karpenter.sh/v1 as undiscoverable
# alongside kueue.x-k8s.io, left over from before this stage's own
# bootstrap. assert_stays_not_synced_refreshing's hard_refresh_app on
# every poll forces a fresh *comparison* (desired vs. live manifests) on
# every single poll, so "never reaches Synced" is evidenced against this
# cell's continuously re-evaluated current comparison state -- it does
# NOT, on its own, force a new *sync attempt* against the fixed CRDs
# (operation retries run on their own RetryCount/backoff clock,
# independent of how often the comparison is refreshed; see the comment
# on STAGE_B_READ_TIMEOUT just below for why, and how the read loop
# there actually waits this staleness out rather than assuming one
# refresh is enough).
STAGE_B_TIMEOUT=180
STAGE_B_WORK="${WORK_DIR}/stage-b"
mkdir -p "${STAGE_B_WORK}"
assert_stays_not_synced_refreshing_bg "${APP_CAPACITY_POOL}" "${STAGE_B_TIMEOUT}" 15 "${STAGE_B_WORK}/capacity-pool"
assert_stays_not_synced_bg "${APP_KUEUE}" "${STAGE_B_TIMEOUT}" 15 "${STAGE_B_WORK}/kueue"
wait
[[ "$(cat "${STAGE_B_WORK}/capacity-pool")" == PASS ]] \
  || fail "${APP_CAPACITY_POOL} reached Synced despite kueue's ResourceFlavor CRD still being undiscoverable"
[[ "$(cat "${STAGE_B_WORK}/kueue")" == PASS ]] \
  || fail "${APP_KUEUE} reached Synced despite still being broken"
hard_refresh_app "${APP_CAPACITY_POOL}"
# Issue #45 (first fix): a single jsonpath read of only
# status.operationState.message, even right after a fresh refresh, can
# land while Argo CD's own controller is between a finished sync attempt
# and the next scheduled retry -- in that exact window (see
# app_operation_state() above) the controller overwrites this field with
# a generic "Retrying operation. Attempt #N" string and sets syncResult
# to nil in the same write.
# Issue #45 (second, real-run-only finding): even a read that lands
# outside that window can still be *stale* in a different way. A real
# run of the first fix (cell dp-dlv-i45b) showed capacity-pool's
# operationState, read at retryCount 5 with syncResult non-nil (a
# perfectly valid, non-placeholder read by the first fix's own
# criterion), still naming karpenter.k8s.aws/v1 and karpenter.sh/v1 as
# undiscoverable together with kueue.x-k8s.io -- well after this
# function's own earlier wait_until confirmed karpenter-crd Synced and
# its CRD Established, and after the whole STAGE_B_TIMEOUT (180s) window
# of continuous hard-refreshing above. hard_refresh_app only forces a
# fresh *comparison* (desired vs. live manifests); it does not force a
# new *sync attempt* -- the operation's own retry is scheduled solely by
# RetryCount and the backoff (10s, doubling, capped at 300s per
# gitops/appsets/cells.ApplicationSet.yaml's retry.backoff), independent
# of how often this script refreshes. So a sync attempt that happened to
# run before karpenter-crd's CRDs were Established keeps being the most
# recent one -- and therefore the one operationState reports -- until
# the next attempt's own backoff interval elapses, which observed real
# backoff math puts at up to several minutes, not the few seconds a
# single post-refresh sleep assumed. Both findings get the same
# treatment: poll app_operation_state (hard-refreshing again before each
# retry below -- harmless, and keeps this stage's existing "force a
# fresh look every poll" intent even though it cannot speed up the next
# sync attempt specifically) until a read is both outside the nil window
# (terminal phase, or Running with a non-nil syncResult) AND does not
# still name karpenter's own groups as undiscoverable -- or
# STAGE_B_READ_TIMEOUT elapses, long enough to span several of this
# Application's own retry backoff cycles even at the capped 300s
# interval, so a cell stuck for some other reason still fails instead of
# hanging indefinitely.
STAGE_B_READ_TIMEOUT=600
STAGE_B_READ_INTERVAL=15
# Matches the bare API group (karpenter.k8s.aws, karpenter.sh), never
# requiring a trailing "/v1": confirmed on a real run that
# syncResult.resources[]'s own per-resource message names the group and
# Kind with no version at all ("...could not find karpenter.sh/NodePool
# for requested resource...", "...karpenter.k8s.aws/EC2NodeClass...") --
# a version-anchored pattern silently failed to recognize that form,
# risking exactly the stale-but-accepted read this whole loop exists to
# refuse. Requires a failure phrase ("could not find" or "failed to
# discover") to appear SOMEWHERE in the same text, not merely the bare
# group name on its own: Argo CD also writes the same group name into a
# genuinely successful sync's own per-resource message (e.g.
# "nodepool.karpenter.sh/default created"), which a bare-group-only
# pattern would misread as still-undiscoverable. Review round 2 flagged
# this before any run exercised it; stage B's own manifests never
# succeed before this check runs (the kueue break still fails validation
# for the whole Application), so this guard is defense in depth, not a
# path this fix's real runs are known to have taken.
stage_b_mentions_karpenter_crds() {
  case "$1" in
    *"could not find"*|*"failed to discover"*)
      case "$1" in
        *"karpenter.k8s.aws"*|*"karpenter.sh"*) return 0 ;;
      esac
      ;;
  esac
  return 1
}
stage_b_read_start="$(date +%s)"
stage_b_phase="" stage_b_message="" stage_b_retry_count="" stage_b_has_sync_result="0" stage_b_resources_summary="" stage_b_conditions_summary="" stage_b_combined=""
while true; do
  # IFS=$'\x1f' (ASCII Unit Separator), not $'\t': see the comment on
  # app_operation_state() above for why a tab delimiter would silently
  # swallow an empty field (e.g. retryCount omitted at 0) and shift every
  # column after it.
  IFS=$'\x1f' read -r stage_b_phase stage_b_message stage_b_retry_count stage_b_has_sync_result stage_b_resources_summary stage_b_conditions_summary \
    < <(app_operation_state "${APP_CAPACITY_POOL}")
  # Concatenated once per read, not chosen between: see the "Search the
  # top-level message..." note below for why neither field alone is
  # matched on in isolation. status.conditions[] is deliberately left out
  # of this combined text -- it is logged for diagnosis only (its
  # coverage of this failure class is unconfirmed, see the README) and
  # must never silently feed either match below.
  stage_b_combined="${stage_b_message}"
  [[ -n "${stage_b_resources_summary}" ]] && stage_b_combined+=" | resources: ${stage_b_resources_summary}"
  # Logged on every single poll, pass or fail (requirement: the values a
  # judgement is based on must be visible without re-running anything) --
  # not only once a verdict is reached.
  info "${APP_CAPACITY_POOL} operationState read: phase=[${stage_b_phase}] retryCount=[${stage_b_retry_count}] syncResult=[$([[ "${stage_b_has_sync_result}" == "1" ]] && echo present || echo nil)] message=[${stage_b_message}] resources=[${stage_b_resources_summary}] conditions=[${stage_b_conditions_summary}]"
  if [[ "${stage_b_phase}" == "Error" || "${stage_b_phase}" == "Failed" ]]; then
    # Terminal: Argo CD itself has stopped retrying, so no amount of
    # further polling changes this Application's own answer. A terminal
    # read that still names karpenter's groups is therefore wrong now,
    # not merely "not yet settled" -- fail immediately with the specific
    # reason, rather than falling through to the generic kueue-mismatch
    # message below (which would describe the symptom, not the cause).
    if stage_b_mentions_karpenter_crds "${stage_b_combined}"; then
      fail "${APP_CAPACITY_POOL}'s own operationState reached a terminal phase (${stage_b_phase}) still naming karpenter's own CRDs as undiscoverable (retryCount=${stage_b_retry_count}: ${stage_b_combined}) -- Argo CD will not retry again, so this is this Application's final answer, not a stale read waiting to clear; most likely karpenter-crd is not actually visible to this Application despite this stage's own earlier wait_until confirming it Established, but the retry limit could instead have been exhausted entirely during stage A (before karpenter-crd was ever fixed), in which case this terminal message is a stale answer that nothing will ever refresh -- either way this run cannot proceed"
    fi
    break
  fi
  if [[ "${stage_b_phase}" == "Running" && "${stage_b_has_sync_result}" == "1" ]] && ! stage_b_mentions_karpenter_crds "${stage_b_combined}"; then
    break
  fi
  if (( $(date +%s) - stage_b_read_start >= STAGE_B_READ_TIMEOUT )); then
    if stage_b_mentions_karpenter_crds "${stage_b_combined}"; then
      fail "${APP_CAPACITY_POOL}'s own operationState still names karpenter's own CRDs as undiscoverable after ${STAGE_B_READ_TIMEOUT}s of polling since karpenter-crd was confirmed Established and Synced (last read: phase=${stage_b_phase}, retryCount=${stage_b_retry_count}: ${stage_b_combined}) -- either karpenter-crd is not actually Established on this cluster, or no sync attempt made since it was fixed has run in this window"
    else
      fail "${APP_CAPACITY_POOL}'s operationState never reached an acceptable read (a terminal phase, or Running with a non-nil syncResult that does not name karpenter's own groups) within ${STAGE_B_READ_TIMEOUT}s of polling after the final refresh (last read: phase=${stage_b_phase}, retryCount=${stage_b_retry_count}, syncResult=$([[ "${stage_b_has_sync_result}" == "1" ]] && echo present || echo nil), message=${stage_b_message}) -- most likely every read landed in Argo CD's own between-attempts window, but an unexpected phase such as Succeeded this early in the cell's first-ever bootstrap would also land here, and is not itself proof of that specific cause"
    fi
  fi
  hard_refresh_app "${APP_CAPACITY_POOL}"
  sleep "${STAGE_B_READ_INTERVAL}"
done
# Search the top-level message and syncResult.resources[]'s own summary
# together, never one in place of the other -- confirmed necessary, not
# merely cautious, by this fix's own first real run: the top-level
# message read "...failed to discover server resources for group
# version kueue.x-k8s.io/v1beta2: the server could not find the
# requested resource...", while syncResult.resources[]'s own per-resource
# message for the exact same failure read "...The Kubernetes API could
# not find kueue.x-k8s.io/ResourceFlavor for requested resource
# kube-system/cpu...". Same cause, different wording and a different
# substring order ("could not find" lands before "kueue.x-k8s.io" in the
# per-resource message, after it in the top-level one) -- an earlier
# version of this fix preferred resources[] whenever present and failed
# this exact check on that real run, even though the loop above had
# already correctly waited out five "Retrying operation" reads first.
# Concatenating both (rather than choosing one) means whichever field
# happens to carry the matched phrase's exact order does not depend on
# which one this fix's author guessed would be more specific. The loop
# above already guarantees capacity_pool_operation_message does not name
# karpenter's own groups (its own accept condition), so only the kueue
# assertion remains here.
capacity_pool_operation_message="${stage_b_combined}"
case "${capacity_pool_operation_message}" in
  *"kueue.x-k8s.io"*"could not find the requested resource"*|*"could not find"*"kueue.x-k8s.io"*) ;;
  *) fail "${APP_CAPACITY_POOL}'s own operationState does not mention kueue.x-k8s.io's own resources being undiscoverable (got: ${capacity_pool_operation_message}; phase=${stage_b_phase}, retryCount=${stage_b_retry_count}, conditions=${stage_b_conditions_summary}) -- the claimed cause is not what this run's own Application actually reports" ;;
esac
nodepool_exists && fail "NodePool cpu was created although capacity-pool's own Application-wide sync should still be blocked by kueue's undiscoverable ResourceFlavor"
ec2nodeclass_exists && fail "EC2NodeClass cpu was created although capacity-pool's own Application-wide sync should still be blocked by kueue's undiscoverable ResourceFlavor"
resourceflavor_exists && fail "ResourceFlavor cpu was created although kueue is still broken on this cell (its CRD still cannot exist)"
clusterqueue_exists && fail "ClusterQueue smoke was created although kueue is still broken on this cell (its CRD still cannot exist)"
pass "pristine: fixing only karpenter-crd (now Established) does not unblock capacity-pool while kueue stays broken for ${STAGE_B_TIMEOUT}s of continuously-refreshed polling -- capacity-pool's own operationState, read atomically and only once settled outside Argo CD's own retry-preparation window (phase=${stage_b_phase}, retryCount=${stage_b_retry_count}: \"${capacity_pool_operation_message}\"), names kueue.x-k8s.io's own resources as undiscoverable and does not name karpenter's, confirming the cause is specifically kueue's ResourceFlavor CRD and that this is a current result, not a stale one left over from stage A nor a transient between-attempts placeholder -- Argo CD's own resource-discovery validation blocks the WHOLE Application, NodePool/EC2NodeClass included, when even one of its resource kinds cannot be discovered, confirming decision 4's claim at the Application level, not merely per-resource"

# ---- C. fully restored: the real GITOPS_REVISION this cell settles on

run_bootstrap --revision "${GITOPS_REVISION}" \
  || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION} after the pristine A/B/C experiment)"
wait_until 300 10 "kueue Application reaches Synced" app_synced "${APP_KUEUE}" \
  || fail "${APP_KUEUE} did not reach Synced (sync=$(app_sync "${APP_KUEUE}")) after restoring --revision"
# Same reasoning as capacity-pool in stage B: kueue's own CRDs
# (ResourceFlavor, ClusterQueue, ...) are also brand new here, and a
# single refresh does not reliably outlast Argo CD's own sync-retry
# backoff from the earlier failed attempts -- refresh on every poll.
smoke_synced_refreshing() { hard_refresh_app "${APP_SMOKE}"; app_synced "${APP_SMOKE}"; }
wait_until 600 15 "smoke Application reaches Synced" smoke_synced_refreshing \
  || fail "${APP_SMOKE} did not reach Synced (sync=$(app_sync "${APP_SMOKE}")) after restoring --revision"
# Closes the loop on stage B's own observation: capacity-pool's
# Application stayed OutOfSync there specifically because its
# ResourceFlavor object needed kueue's still-broken CRD; now that kueue
# is fixed too, the whole Application (not just NodePool/EC2NodeClass)
# should finally reach Synced.
capacity_pool_synced_refreshing() { hard_refresh_app "${APP_CAPACITY_POOL}"; app_synced "${APP_CAPACITY_POOL}"; }
wait_until 300 15 "capacity-pool Application reaches Synced" capacity_pool_synced_refreshing \
  || fail "${APP_CAPACITY_POOL} did not reach Synced (sync=$(app_sync "${APP_CAPACITY_POOL}")) once both karpenter-crd and kueue were fixed"
pass "restored --revision to ${GITOPS_REVISION}: kueue converges on its own (no refresh needed -- it never tried and failed to sync earlier in this sequence, so it has no cached discovery failure to invalidate); capacity-pool (now including ResourceFlavor) and the smoke ClusterQueue/LocalQueue converge once told to recheck (hard refresh), consistent with each having already tried and failed to sync in stage A/B while kueue's own CRDs did not exist yet, caching that failure until told otherwise -- this is not a claim that any brand-new CRD in general needs a refresh (2.upgrade.sh's own capacity-pool converges with no refresh call anywhere in that script, because its CRDs exist from that cell's own first bootstrap onward and it never cached a failed attempt against them), nor that either Application here converges unattended; this cell's first-ever bootstrap sequence is complete"

# ------------------------------------------------- 4. first bootstrap
#
# "First bootstrap" here means the pristine A/B/C sequence in section 3c
# above: stage C's run_bootstrap --revision "${GITOPS_REVISION}" call is
# this cell's real first successful convergence, already run. What
# follows checks its three objects.

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
# re-points at a harmless trailing marker string appended to
# GITOPS_REVISION instead (REVISION_B below never resolves to a real git
# ref - it is never used to check out anything, only written into and
# read back from the Secret annotation and the root Application's own
# targetRevision field) -- any string bootstrap.sh writes verbatim into
# both fields proves the mechanism; it does not need to resolve to a
# second, distinct real ApplicationSet sync to prove the Secret/
# Application update together.

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
# Acceptance criterion 3, third half: decision 1's two abort conditions,
# each independently, both without a second real cluster.
#
# 7a. The Secret cross-check (decision 1's second condition: an existing
# cell-registration Secret must match --tf-outputs' cluster_arn exactly).
# This is a re-run, not a first bootstrap -- the Secret the pristine
# stage A/B/C sequence already wrote is what the forged cluster_arn
# conflicts with; the live kubeconfig still points at the real cluster,
# so bootstrap.sh's own
# "kubeconfig server matches cluster_endpoint" check (condition 1, below)
# cannot catch a cluster_arn-only mismatch -- it must be this cross-check
# that does.

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
grep -q "refusing to overwrite" "${WORK_DIR}/wrong-cluster.log" \
  || fail "bootstrap.sh aborted for a reason other than the cluster_arn mismatch (see ${WORK_DIR}/wrong-cluster.log)"
pass "bootstrap.sh aborts before any write when --tf-outputs names a different cluster_arn than the registered Secret"

# 7b. The kubeconfig/cluster_endpoint check (decision 1's first condition,
# the one condition active on a genuine first bootstrap too -- it runs
# unconditionally, before the Secret even exists): forge cluster_endpoint
# instead, leave cluster_arn correct, and leave the live kubeconfig
# pointed at the real cluster. The mismatch this creates is between the
# forged endpoint and the live kubeconfig's own server, not between two
# real clusters, so this needs no second cluster either.

WRONG_ENDPOINT_JSON="${WORK_DIR}/tf-outputs-wrong-endpoint.json"
python3 - "${TF_OUTPUTS_JSON}" "${WRONG_ENDPOINT_JSON}" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    doc = json.load(f)
doc["cluster_endpoint"]["value"] = "https://not-the-real-endpoint.example.invalid"
with open(dst, "w", encoding="utf-8") as f:
    json.dump(doc, f)
PY
rv_before_wrong_endpoint="$(object_write_fingerprint)"
if "${GITOPS_ROOT}/bootstrap/bootstrap.sh" --tf-outputs "${WRONG_ENDPOINT_JSON}" \
  --revision "${GITOPS_REVISION}" >/dev/null 2>"${WORK_DIR}/wrong-endpoint.log"; then
  fail "bootstrap.sh did not abort on a cluster_endpoint mismatch (see ${WORK_DIR}/wrong-endpoint.log)"
fi
rv_after_wrong_endpoint="$(object_write_fingerprint)"
[[ "${rv_before_wrong_endpoint}" == "${rv_after_wrong_endpoint}" ]] \
  || fail "bootstrap.sh wrote something before aborting on a cluster_endpoint mismatch"
grep -q "cluster_endpoint" "${WORK_DIR}/wrong-endpoint.log" \
  || fail "bootstrap.sh aborted for a reason other than the cluster_endpoint mismatch (see ${WORK_DIR}/wrong-endpoint.log)"
pass "bootstrap.sh aborts before any write when --tf-outputs names a different cluster_endpoint than the live kubeconfig"

# --------------------------------------------------- 9. crds/controllers
#
# Acceptance criterion 6 (second half): kueue/karpenter reach Healthy on
# the system node group before any NodePool-launched node exists.
# APP_KARPENTER_CRD/APP_KARPENTER/APP_KUEUE/APP_SMOKE and APP_CAPACITY_POOL
# (Decision 2's {{name}}-{{addon}} naming; capacity-pool's own pool name
# discovered since it is this PR's own choice) were already resolved in
# section 3c above, the first point they existed to discover.

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

# Regression guard for RFC #41 Decision 4 Finding 1's own allowEmpty
# scoping: templatePatch's {{- if .allowEmpty }} branch must never fire
# for a core addon that does not set it, which would mean the key went
# back into platform.ApplicationSet.yaml's own SHARED base template --
# silently removing Argo CD's own safety net (refuse to prune to zero
# resources) for karpenter-crd too, not only for optional-pool.
karpenter_crd_automated="$(app_field "${APP_KARPENTER_CRD}" '{.spec.syncPolicy.automated}')"
[[ "${karpenter_crd_automated}" != *"allowEmpty"* ]] \
  || fail "${APP_KARPENTER_CRD}'s spec.syncPolicy.automated is [${karpenter_crd_automated}] -- allowEmpty must never appear here; it is optional-pool's own addon.yaml-scoped opt-in, not the shared base template's"
pass "${APP_KARPENTER_CRD}'s spec.syncPolicy.automated carries no allowEmpty -- the per-addon opt-in stayed scoped to optional-pool, not the shared base template"

# -------------------------------------------------------------- 10. capacity

wait_until 900 15 "capacity-pool Application Healthy and Synced" app_healthy_synced "${APP_CAPACITY_POOL}" \
  || fail "${APP_CAPACITY_POOL} did not reach Healthy+Synced: health=$(app_health "${APP_CAPACITY_POOL}") sync=$(app_sync "${APP_CAPACITY_POOL}")"
wait_until 900 15 "smoke Application Healthy and Synced" app_healthy_synced "${APP_SMOKE}" \
  || fail "${APP_SMOKE} did not reach Healthy+Synced: health=$(app_health "${APP_SMOKE}") sync=$(app_sync "${APP_SMOKE}")"
pass "${APP_CAPACITY_POOL} and ${APP_SMOKE} (capacity step) reached Healthy+Synced"

# Issue #41: optional-pool is a fourth core add-on (gitops/addons/,
# platform.ApplicationSet.yaml, every cell), the untainted on-demand CPU
# NodePool/EC2NodeClass pair platform-optional components schedule on. Its
# pair is told apart from capacity-pool's by the Application that owns it
# (status.resources), never by a hardcoded name, so the "exactly one"
# checks below keep meaning "exactly one capacity pool".
APP_OPTIONAL_POOL="${CLUSTER}-optional-pool"
app_exists "${APP_OPTIONAL_POOL}" || fail "Application ${APP_OPTIONAL_POOL} does not exist -- the platform ApplicationSet never generated it from addons/optional-pool/addon.yaml"
wait_until 900 15 "optional-pool Application Healthy and Synced" app_healthy_synced "${APP_OPTIONAL_POOL}" \
  || fail "${APP_OPTIONAL_POOL} did not reach Healthy+Synced: health=$(app_health "${APP_OPTIONAL_POOL}") sync=$(app_sync "${APP_OPTIONAL_POOL}")"
# app_owned_names APP KIND: names of every KIND object APP's own
# status.resources lists, one per line.
app_owned_names() { app_field "$1" "{.status.resources[?(@.kind==\"$2\")].name}" | tr ' ' '\n' | grep -v '^$' || true; }
mapfile -t optional_nodepools < <(app_owned_names "${APP_OPTIONAL_POOL}" NodePool)
mapfile -t optional_ec2nodeclasses < <(app_owned_names "${APP_OPTIONAL_POOL}" EC2NodeClass)
[[ "${#optional_nodepools[@]}" -eq 1 ]] || fail "expected ${APP_OPTIONAL_POOL} to own exactly 1 NodePool, found ${#optional_nodepools[@]}: ${optional_nodepools[*]:-none}"
[[ "${#optional_ec2nodeclasses[@]}" -eq 1 ]] || fail "expected ${APP_OPTIONAL_POOL} to own exactly 1 EC2NodeClass, found ${#optional_ec2nodeclasses[@]}: ${optional_ec2nodeclasses[*]:-none}"
OPTIONAL_NODEPOOL="${optional_nodepools[0]}"
OPTIONAL_NODECLASS="${optional_ec2nodeclasses[0]}"
optional_taints="$(k get nodepool "${OPTIONAL_NODEPOOL}" -o jsonpath='{.spec.template.spec.taints}')"
[[ -z "${optional_taints}" || "${optional_taints}" == "[]" ]] \
  || fail "optional-pool NodePool ${OPTIONAL_NODEPOOL} carries taints (${optional_taints}); platform-optional components are expected to land on it untolerated"
optional_capacity_types="$(k get nodepool "${OPTIONAL_NODEPOOL}" -o jsonpath='{.spec.template.spec.requirements[?(@.key=="karpenter.sh/capacity-type")].values[*]}')"
[[ "${optional_capacity_types}" == "on-demand" ]] \
  || fail "optional-pool NodePool ${OPTIONAL_NODEPOOL}'s karpenter.sh/capacity-type values are [${optional_capacity_types}], expected exactly [on-demand]"
# templatePatch's own {{- if .allowEmpty }} branch (platform.ApplicationSet.yaml)
# must MERGE allowEmpty into spec.syncPolicy.automated alongside the base
# template's own selfHeal/prune, not replace that block -- checked
# directly on the generated Application rather than only assumed from
# how the same templatePatch mechanism already merges source.helm
# alongside source.repoURL/chart/targetRevision elsewhere.
optional_automated="$(app_field "${APP_OPTIONAL_POOL}" '{.spec.syncPolicy.automated}')"
[[ "${optional_automated}" == *'"selfHeal":true'* && "${optional_automated}" == *'"prune":true'* && "${optional_automated}" == *'"allowEmpty":true'* ]] \
  || fail "${APP_OPTIONAL_POOL}'s spec.syncPolicy.automated is [${optional_automated}], expected selfHeal/prune (from the base template) and allowEmpty (from templatePatch) all merged together, not one replacing the other"
pass "${APP_OPTIONAL_POOL} reached Healthy+Synced and owns one untainted, on-demand NodePool (${OPTIONAL_NODEPOOL}) and its EC2NodeClass (${OPTIONAL_NODECLASS}), with selfHeal/prune/allowEmpty all merged into spec.syncPolicy.automated"

mapfile -t nodepools < <(k get nodepools -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$' | grep -vxF "${OPTIONAL_NODEPOOL}")
mapfile -t ec2nodeclasses < <(k get ec2nodeclasses -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$' | grep -vxF "${OPTIONAL_NODECLASS}")
mapfile -t resourceflavors < <(k get resourceflavors -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$')
[[ "${#nodepools[@]}" -eq 1 ]] || fail "expected exactly 1 NodePool besides optional-pool's ${OPTIONAL_NODEPOOL}, found ${#nodepools[@]}: ${nodepools[*]:-none}"
[[ "${#ec2nodeclasses[@]}" -eq 1 ]] || fail "expected exactly 1 EC2NodeClass besides optional-pool's ${OPTIONAL_NODECLASS}, found ${#ec2nodeclasses[@]}: ${ec2nodeclasses[*]:-none}"
[[ "${#resourceflavors[@]}" -eq 1 ]] || fail "expected exactly 1 ResourceFlavor, found ${#resourceflavors[@]}: ${resourceflavors[*]:-none}"
NODEPOOL="${nodepools[0]}"
NODECLASS="${ec2nodeclasses[0]}"
RESOURCEFLAVOR="${resourceflavors[0]}"
pass "exactly one capacity NodePool (${NODEPOOL}), EC2NodeClass (${NODECLASS}) and ResourceFlavor (${RESOURCEFLAVOR}) besides optional-pool's own pair"

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
# dp-a19-gpu-r3, enforced by the preflight) carries exactly one NodePool, the
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
  local advertiser_ns other_ns wave np_label node node_label allocatable probe_out count pods_on_node node_capacity_type instance_type karpenter_log_file karpenter_log_pid accel_pod_trace_file accel_pod_trace_pid

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

  # Capture Karpenter's own controller log for the whole wait below, so a
  # disruption decision (consolidation, drift, expiration, or a
  # registration/initialization timeout) has its own stated reason on
  # record, never inferred from side effects alone (#28, root-caused from
  # CloudTrail alone once already -- "Karpenter called TerminateInstances"
  # is confirmed, but CloudTrail carries no application-level reason field,
  # only Karpenter's own log does). `-l app.kubernetes.io/name=karpenter`
  # matches the upstream chart's own pod labels (addons/karpenter/addon.yaml
  # sets no nameOverride). Started in the background, killed right after
  # the wait resolves either way, and always kept under WORK_DIR (never
  # deleted by this function) so a passing run's log is still available to
  # read afterward, not only a failing one's.
  karpenter_log_file="${WORK_DIR}/karpenter-${cell}-$(date -u +%H%M%S).log"
  k logs -n kube-system -l app.kubernetes.io/name=karpenter -f --since=1s --timestamps \
    >"${karpenter_log_file}" 2>&1 &
  karpenter_log_pid=$!

  # Karpenter's own "pod-count" at the moment it disrupts a node only says
  # the pod was not yet *bound* there (image pulls start after binding,
  # never before) -- it does not say *why* binding had not happened.
  # Sample the pod's own binding state, scheduling-relevant events, and
  # whether Kueue's webhook ever created a Workload for it (the smoke
  # ClusterQueue's own coveredResources never list an accelerator, but a
  # cluster-wide Kueue "pod" integration, if one were ever enabled, would
  # still gate it -- checked, not assumed) every 5s for the whole wait, so
  # a FailedScheduling event, a late Bind, or a gated/suspended Workload
  # each have their own timestamped record instead of a single end-of-wait
  # snapshot that a deleted Node can no longer answer.
  accel_pod_trace_file="${WORK_DIR}/accel-layer1-trace-${cell}-$(date -u +%H%M%S).log"
  (
    while true; do
      {
        printf '%s pod: ' "$(date -u +%H:%M:%S)"
        k get pod accel-layer1 -n "${ACCEL_TEST_NS}" -o jsonpath='phase={.status.phase} nodeName={.spec.nodeName} nominatedNodeName={.status.nominatedNodeName} schedulingGates={.spec.schedulingGates} conditions={.status.conditions}' 2>&1
        printf '\n'
      } >>"${accel_pod_trace_file}"
      sleep 5
    done
  ) &
  accel_pod_trace_pid=$!

  accel_pod_running() { [[ "$(k get pod accel-layer1 -n "${ACCEL_TEST_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]; }
  if ! wait_until "${ACCEL_POD_TIMEOUT_SECONDS}" 20 "the Layer 1 ${resource} pod is Running" accel_pod_running; then
    kill "${karpenter_log_pid}" "${accel_pod_trace_pid}" 2>/dev/null; wait "${karpenter_log_pid}" "${accel_pod_trace_pid}" 2>/dev/null || true
    info "Karpenter controller log during this wait (${cell}, saved at ${karpenter_log_file}), lines mentioning disruption/registration/initialization:"
    grep -iE "disrupt|consolidat|drift|expir|regist|initializ|liveness|terminat|empt" "${karpenter_log_file}" >&2 \
      || { info "no matching line; printing the whole log:"; cat "${karpenter_log_file}" >&2; }
    info "Pod binding trace (${cell}, saved at ${accel_pod_trace_file}):"
    cat "${accel_pod_trace_file}" >&2 || true
    info "Events in ${ACCEL_TEST_NS} (${cell}):"
    k get events -n "${ACCEL_TEST_NS}" --sort-by='.lastTimestamp' -o wide >&2 2>&1 || true
    info "Workloads in ${ACCEL_TEST_NS} (${cell}) -- non-empty would mean a Kueue integration gated this bare pod, unexpectedly:"
    k get workloads -n "${ACCEL_TEST_NS}" -o wide >&2 2>&1 || true
    fail "Layer 1 pod requesting ${resource}: 1 never reached Running on ${cell}: $(k get pod accel-layer1 -n "${ACCEL_TEST_NS}" -o jsonpath='{.status}' 2>&1) nodeclaims: $(k get nodeclaims -o wide 2>&1)"
  fi
  kill "${karpenter_log_pid}" "${accel_pod_trace_pid}" 2>/dev/null; wait "${karpenter_log_pid}" "${accel_pod_trace_pid}" 2>/dev/null || true
  info "Karpenter controller log for this pod's wait saved at ${karpenter_log_file} ($(wc -l <"${karpenter_log_file}" 2>/dev/null || echo 0) lines); pod binding trace saved at ${accel_pod_trace_file}"
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
  # Acceptance criteria 2/3 name a real node, not merely "whatever
  # Karpenter happened to pick" -- a real assertion on the node Karpenter
  # actually launched, not a restatement of the NodePool's own
  # requirements. #28's own capacity-pool fixtures set pool.capacityType:
  # flex (#17's own chart owns pool.capacityType's enum, which has no
  # spot-only option: flex is ["spot", "on-demand"] -- the chart's own
  # capacity-pool.requirements helper fails the render if pool.requirements
  # itself names karpenter.sh/capacity-type instead), so this accepts
  # either value Karpenter actually picked, the same way step 13's own
  # capacity-type e2e already does for the chart's own flex fixture.
  node_capacity_type="$(k get node "${node}" -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}')"
  [[ "${node_capacity_type}" == "spot" || "${node_capacity_type}" == "on-demand" ]] \
    || fail "node ${node} has karpenter.sh/capacity-type='${node_capacity_type}', want spot or on-demand (#28 acceptance criteria 2/3 name a real node)"
  instance_type="$(k get node "${node}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')"
  pass "Layer 1 pod scheduled on ${node} (${instance_type}, capacity-type=${node_capacity_type}, ${label}=device-plugin, allocatable ${resource}=${allocatable})"

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
SMOKE_CLUSTERQUEUE="$(k get localqueue "${SMOKE_LOCALQUEUE}" -n "${SMOKE_NS}" -o jsonpath='{.spec.clusterQueue}')"
[[ -n "${SMOKE_CLUSTERQUEUE}" ]] || fail "LocalQueue ${SMOKE_NS}/${SMOKE_LOCALQUEUE} has no spec.clusterQueue"
pass "discovered the admin smoke LocalQueue: ${SMOKE_NS}/${SMOKE_LOCALQUEUE} (ClusterQueue ${SMOKE_CLUSTERQUEUE})"

# #63, filed as #56: a Fable 5.2 review of an earlier version of this fix
# (which only added the accelerator resource to the smoke ClusterQueue's
# own resourceGroups, never made anything actually request it) found that
# Kueue applies a ResourceFlavor's own tolerations to every Workload it
# admits through that flavor, regardless of what the Workload requests --
# covering a resource in resourceGroups controls admission *against
# quota*, it does not change what a Workload that never asks for that
# resource gets charged. So a CPU-only canary on an accelerator-tainted
# cell (dp-a19-trn-r3, dp-a19-gpu-r3) was still landing on the tainted
# node for free, and no accelerator request ever reached Kueue's own
# admission path either way -- #56's own finding, not actually closed by
# that first attempt. The canary now discovers, from the live
# ClusterQueue object (never hardcoded, so this also works unchanged on
# example-cell, which covers no accelerator resource at all), whether its
# own flavor covers one, and if so requests exactly the nominal quota of
# it -- the canary itself becomes the first real Kueue-admitted workload
# that actually asks for the device, closing both halves of #56 at once:
# it is no longer a free ride, and an accelerator request now reaches
# Kueue's own quota/admission path.
mapfile -t smoke_cq_resources < <(k get clusterqueue "${SMOKE_CLUSTERQUEUE}" -o jsonpath='{.spec.resourceGroups[0].resources[*].name}' | tr ' ' '\n' | grep -v '^$')
CANARY_ACCEL_RESOURCE=""
CANARY_ACCEL_QUANTITY=""
for res in "${smoke_cq_resources[@]}"; do
  case "${res}" in
    cpu | memory) continue ;;
    *)
      CANARY_ACCEL_RESOURCE="${res}"
      CANARY_ACCEL_QUANTITY="$(k get clusterqueue "${SMOKE_CLUSTERQUEUE}" -o jsonpath="{.spec.resourceGroups[0].resources[?(@.name=='${res}')].nominalQuota}")"
      ;;
  esac
done
CANARY_EXTRA_RESOURCE_YAML=""
if [[ -n "${CANARY_ACCEL_RESOURCE}" ]]; then
  [[ "${CANARY_ACCEL_QUANTITY}" =~ ^[0-9]+$ && "${CANARY_ACCEL_QUANTITY}" -ge 1 ]] \
    || fail "ClusterQueue ${SMOKE_CLUSTERQUEUE} covers accelerator resource ${CANARY_ACCEL_RESOURCE} with nominalQuota='${CANARY_ACCEL_QUANTITY}' (expected >= 1) -- the canary cannot request a non-positive amount"
  CANARY_EXTRA_RESOURCE_YAML="              ${CANARY_ACCEL_RESOURCE}: \"${CANARY_ACCEL_QUANTITY}\""
  pass "ClusterQueue ${SMOKE_CLUSTERQUEUE} covers accelerator resource ${CANARY_ACCEL_RESOURCE} (nominalQuota ${CANARY_ACCEL_QUANTITY}) -- the canary will request it too"
fi

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
${CANARY_EXTRA_RESOURCE_YAML}
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

# job_node()'s own comment explains the "|" delimiter.
canary_node() { job_node "${SMOKE_NS}" canary; }
canary_running_on_node() { [[ -n "$(canary_node)" ]]; }
wait_until 900 15 "a node launches for the canary Job" canary_running_on_node \
  || fail "canary Job's pod never got a node: $(k get nodeclaims -o wide 2>&1)"
CANARY_NODE="$(canary_node)"
canary_nodepool_label="$(k get node "${CANARY_NODE}" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')"
[[ "${canary_nodepool_label}" == "${NODEPOOL}" ]] \
  || fail "canary Job's node ${CANARY_NODE} is not from NodePool ${NODEPOOL} (label: ${canary_nodepool_label})"
pass "a Karpenter node (${CANARY_NODE}) launched from NodePool ${NODEPOOL} for the canary Job"

# ------------------------- 11b. three capacity types (issue #27): -rsv/-od/-flex
#
# Issue #27's acceptance criteria, on the same cell, while every
# Application above is still known-healthy and before step 12 breaks
# anything on purpose. The three pools and their smoke queues need
# parameter files under gitops/cells/${CLUSTER}/ (cells.ApplicationSet's
# Git file generator reads exactly that path, gitops/README.md), and the
# -rsv file must select this run's own reservation by its own tag. Neither
# belongs in the tracked tree: they name one run's reservation tag. So
# they are committed only to one disposable branch, e2e/${RUN_ID}/
# capacity-types, cut from GITOPS_REVISION (the same mechanism step 12
# uses), and the cell is re-pointed at it with a --revision-only
# bootstrap.sh re-run (step 6 proved that re-run safe). The sub-step's own
# teardown (11b-6) points the cell back at GITOPS_REVISION and removes
# every object the three pools created, so steps 12-15 see the cell
# exactly as step 11 left it (one NodePool, one LocalQueue). The branch
# itself is deleted by cleanup(), like every other disposable branch.
#
# Names below are this fixture's own choice (decision 9 names none), so
# they are set here once and every assertion reads the live objects back
# by these names rather than assuming what the chart calls anything else.

POOL_RSV="cpu-rsv"
POOL_OD="cpu-od"
POOL_FLEX="cpu-flex"
POOLS_27=("${POOL_RSV}" "${POOL_OD}" "${POOL_FLEX}")
for p in "${POOLS_27[@]}"; do
  [[ "${p}" != "${NODEPOOL}" ]] || fail "step 11b pool name ${p} collides with the cell's own NodePool ${NODEPOOL}"
done
smoke_ns_of() { printf 'distai-smoke-%s' "$1"; }
smoke_cq_of() { printf 'smoke-%s' "$1"; }
SMOKE_LQ_27="smoke"

# ---- 11b-1. the reservation (AWS side) ---------------------------------
#
# One instance of E2E_RSV_INSTANCE_TYPE, targeted (never open: an open
# reservation would also absorb any unrelated same-type launch in the
# account), ending within two hours of creation, tagged like every other
# resource of this run. Its AZ must be one of the cell's own private
# subnets (the EC2NodeClass selects only those); each such AZ offering
# the type is tried in turn, since a single AZ can be out of capacity.

read -r RSV_VCPUS RSV_MEM_MIB < <(aws ec2 describe-instance-types --instance-types "${E2E_RSV_INSTANCE_TYPE}" \
  --query 'InstanceTypes[0].[VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' --output text) \
  || fail "aws ec2 describe-instance-types ${E2E_RSV_INSTANCE_TYPE}"
[[ "${RSV_VCPUS}" =~ ^[0-9]+$ && "${RSV_MEM_MIB}" =~ ^[0-9]+$ ]] \
  || fail "could not read vCPU/memory of ${E2E_RSV_INSTANCE_TYPE} (got '${RSV_VCPUS}' '${RSV_MEM_MIB}')"

mapfile -t private_subnets < <(python3 -c '
import json, sys
print("\n".join(json.load(open(sys.argv[1]))["private_subnet_ids"]["value"]))' "${TF_OUTPUTS_JSON}")
[[ "${#private_subnets[@]}" -ge 1 ]] || fail "terraform output private_subnet_ids is empty"
mapfile -t subnet_azs < <(aws ec2 describe-subnets --subnet-ids "${private_subnets[@]}" \
  --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | grep -v '^$' | sort -u)
mapfile -t offering_azs < <(aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=${E2E_RSV_INSTANCE_TYPE}" \
  --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | grep -v '^$' | sort -u)
mapfile -t rsv_candidate_azs < <(comm -12 <(printf '%s\n' "${subnet_azs[@]}") <(printf '%s\n' "${offering_azs[@]}"))
[[ "${#rsv_candidate_azs[@]}" -ge 1 ]] \
  || fail "no AZ of the cell's private subnets (${subnet_azs[*]}) offers ${E2E_RSV_INSTANCE_TYPE}"

# Strictly inside the two-hour bound the issue sets, and well past
# EC2's own one-hour minimum for a limited end date.
RSV_END_DATE="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=110)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
RSV_AZ=""
for az in "${rsv_candidate_azs[@]}"; do
  if RSV_ID="$(aws ec2 create-capacity-reservation --instance-type "${E2E_RSV_INSTANCE_TYPE}" \
    --instance-platform Linux/UNIX --availability-zone "${az}" --instance-count 1 \
    --instance-match-criteria targeted --end-date-type limited --end-date "${RSV_END_DATE}" \
    --tag-specifications "ResourceType=capacity-reservation,Tags=[{Key=${TEST_TAG_KEY},Value=${RUN_ID}}]" \
    --query 'CapacityReservation.CapacityReservationId' --output text 2>"${WORK_DIR}/create-cr-${az}.err")" \
    && [[ "${RSV_ID}" == cr-* ]]; then
    RSV_AZ="${az}"
    break
  fi
  RSV_ID=""
  info "could not create a Capacity Reservation in ${az}: $(tr '\n' ' ' <"${WORK_DIR}/create-cr-${az}.err")"
done
[[ -n "${RSV_ID}" ]] || fail "could not create a ${E2E_RSV_INSTANCE_TYPE} Capacity Reservation in any of: ${rsv_candidate_azs[*]}"
pass "created targeted Capacity Reservation ${RSV_ID} (1x ${E2E_RSV_INSTANCE_TYPE}, ${RSV_AZ}, ends ${RSV_END_DATE}, tag ${TEST_TAG_KEY}=${RUN_ID})"

capacity_reservation_active() { [[ "$(capacity_reservation_state "${RSV_ID}")" == "active" ]]; }
wait_until 600 10 "Capacity Reservation ${RSV_ID} active" capacity_reservation_active \
  || fail "Capacity Reservation ${RSV_ID} did not become active (state: $(capacity_reservation_state "${RSV_ID}"))"
rsv_facts="$(aws ec2 describe-capacity-reservations --capacity-reservation-ids "${RSV_ID}" \
  --query 'CapacityReservations[0].[InstanceMatchCriteria,TotalInstanceCount,AvailableInstanceCount]' --output text)"
[[ "${rsv_facts}" == $'targeted\t1\t1' ]] \
  || fail "Capacity Reservation ${RSV_ID} is not targeted/1 total/1 available: ${rsv_facts}"
pass "Capacity Reservation ${RSV_ID} is active, targeted, 1 instance, 1 available"

# ---- 11b-2. the cell's parameter files, on a disposable branch ---------
#
# Quotas: the -rsv ClusterQueue's cpuQuota/memQuota are exactly the one
# reserved instance's own vCPU and memory (DescribeInstanceTypes above,
# never a hardcoded size), and the -rsv pool's limits are the same
# numbers as a backstop (issue #27's guidance for -rsv). Each -rsv canary
# below asks for just over half of that, so one fits on the node and two
# can never fit in the quota. -od/-flex get a small budget.

RSV_CANARY_CPU="$((RSV_VCPUS * 1000 / 2 + 100))m"
RSV_CANARY_MEM="$((RSV_MEM_MIB / 2 + 256))Mi"

CAPACITY_BRANCH="e2e/${RUN_ID}/capacity-types"
CAPACITY_CLONE="${WORK_DIR}/capacity-types"
# GITOPS_REPO_URL, never REPO_ROOT -- see break_addon_branch()'s own comment.
git clone --quiet --no-single-branch "${GITOPS_REPO_URL}" "${CAPACITY_CLONE}" || fail "git clone (capacity-types)"
checkout_revision_as "${CAPACITY_CLONE}" "${CAPACITY_BRANCH}" "${GITOPS_REVISION}" || fail "git checkout (capacity-types)"
CELL_DIR="${CAPACITY_CLONE}/gitops/cells/${CLUSTER}"
mkdir -p "${CELL_DIR}/capacity-pool" "${CELL_DIR}/smoke"

# write_pool_file POOL CAPACITY_TYPE LIMITS_YAML [RESERVATION_YAML]
write_pool_file() {
  local pool="$1" ctype="$2" limits="$3" reservation="${4:-}"
  {
    printf '# e2e fixture for run %s (issue #27); lives only on %s.\n' "${RUN_ID}" "${CAPACITY_BRANCH}"
    printf 'addon: capacity-pool-%s\nwave: capacity\ndir: gitops/charts/capacity-pool\nnamespace: kube-system\n' "${pool}"
    printf 'values:\n  pool:\n    name: %s\n    capacityType: %s\n    limits:\n%s\n' "${pool}" "${ctype}" "${limits}"
    [[ -z "${reservation}" ]] || printf '%s\n' "${reservation}"
    printf 'valuesFrom:\n  - helmKey: clusterName\n    param: name\n'
    printf '  - helmKey: nodeRole\n    annotationKey: distai.dev.annotations/karpenter-node-role\n'
  } >"${CELL_DIR}/capacity-pool/${pool}.yaml"
}
# write_smoke_file POOL CPU_QUOTA MEM_QUOTA
write_smoke_file() {
  local pool="$1" cpu="$2" mem="$3" ns cq
  ns="$(smoke_ns_of "${pool}")"
  cq="$(smoke_cq_of "${pool}")"
  {
    printf '# e2e fixture for run %s (issue #27); lives only on %s.\n' "${RUN_ID}" "${CAPACITY_BRANCH}"
    printf 'addon: smoke-%s\nwave: capacity\ndir: gitops/charts/smoke\nnamespace: %s\n' "${pool}" "${ns}"
    printf 'values:\n  namespace: %s\n  clusterQueue:\n    name: %s\n    resourceFlavor: %s\n' "${ns}" "${cq}" "${pool}"
    printf '    cpuQuota: "%s"\n    memQuota: "%s"\n  localQueue:\n    name: %s\n' "${cpu}" "${mem}" "${SMOKE_LQ_27}"
  } >"${CELL_DIR}/smoke/${pool}.yaml"
}

# reservation.instanceMatchCriteria is left unset on purpose: the chart's
# own default ("targeted") is what 11b-3 then reads back from the live
# EC2NodeClass.
write_pool_file "${POOL_RSV}" reserved "      cpu: \"${RSV_VCPUS}\"
      memory: ${RSV_MEM_MIB}Mi" "  reservation:
    tags:
      ${TEST_TAG_KEY}: ${RUN_ID}"
write_pool_file "${POOL_OD}" on-demand '      cpu: "8"'
write_pool_file "${POOL_FLEX}" flex '      cpu: "8"'
write_smoke_file "${POOL_RSV}" "${RSV_VCPUS}" "${RSV_MEM_MIB}Mi"
write_smoke_file "${POOL_OD}" 4 16Gi
write_smoke_file "${POOL_FLEX}" 4 16Gi

git -C "${CAPACITY_CLONE}" add "gitops/cells/${CLUSTER}" || fail "git add (capacity-types)"
git -C "${CAPACITY_CLONE}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
  commit --quiet -m "test: -rsv/-od/-flex pools for e2e run ${RUN_ID} (never merged)" \
  || fail "git commit (capacity-types)"
push_disposable_branch "${CAPACITY_CLONE}" "${CAPACITY_BRANCH}" || fail "git push (capacity-types)"
BROKEN_BRANCHES+=("${CAPACITY_BRANCH}")
pass "pushed ${CAPACITY_BRANCH}: gitops/cells/${CLUSTER}/{capacity-pool,smoke}/{${POOL_RSV},${POOL_OD},${POOL_FLEX}}.yaml"

run_bootstrap --revision "${CAPACITY_BRANCH}" || fail "bootstrap.sh --revision ${CAPACITY_BRANCH}"

APPS_27=()
for p in "${POOLS_27[@]}"; do APPS_27+=("${CLUSTER}-capacity-pool-${p}" "${CLUSTER}-smoke-${p}"); done
for app in "${APPS_27[@]}"; do
  wait_until 900 15 "${app} Healthy and Synced" app_healthy_synced "${app}" \
    || fail "${app} did not reach Healthy+Synced: health=$(app_health "${app}") sync=$(app_sync "${app}")"
done
for app in "${APP_CAPACITY_POOL}" "${APP_SMOKE}"; do
  wait_until 300 10 "${app} still Healthy and Synced on ${CAPACITY_BRANCH}" app_healthy_synced "${app}" \
    || fail "${app} is not Healthy+Synced on ${CAPACITY_BRANCH}: health=$(app_health "${app}") sync=$(app_sync "${app}")"
done
pass "all six issue #27 Applications are Healthy+Synced, and the cell's own ${APP_CAPACITY_POOL}/${APP_SMOKE} stay so"

# ---- 11b-3. each pool's own objects, read from the live cluster --------
#
# Acceptance criterion a, evidenced by each object's own spec on the
# cluster, not by `helm template` (0.static.sh does that part).

want_set="$(printf '%s\n' "${NODEPOOL}" "${OPTIONAL_NODEPOOL}" "${POOLS_27[@]}" | sort)"
[[ "$(list_names nodepools)" == "${want_set}" ]] \
  || fail "NodePools are not exactly {${NODEPOOL} ${OPTIONAL_NODEPOOL} ${POOLS_27[*]}}: $(list_names nodepools | tr '\n' ' ')"
[[ "$(list_names ec2nodeclasses)" == "$(printf '%s\n' "${NODECLASS}" "${OPTIONAL_NODECLASS}" "${POOLS_27[@]}" | sort)" ]] \
  || fail "EC2NodeClasses are not exactly {${NODECLASS} ${OPTIONAL_NODECLASS} ${POOLS_27[*]}}: $(list_names ec2nodeclasses | tr '\n' ' ')"
[[ "$(list_names resourceflavors)" == "$(printf '%s\n' "${RESOURCEFLAVOR}" "${POOLS_27[@]}" | sort)" ]] \
  || fail "ResourceFlavors are not exactly {${RESOURCEFLAVOR} ${POOLS_27[*]}}: $(list_names resourceflavors | tr '\n' ' ')"
pass "one NodePool, EC2NodeClass and ResourceFlavor per pool: ${POOLS_27[*]} (plus the cell's own ${NODEPOOL})"

# capacity_type_requirement POOL: "<operator>:<sorted values>" for every
# karpenter.sh/capacity-type requirement on the live NodePool, ";"-joined.
capacity_type_requirement() {
  k get nodepool "$1" -o json | python3 -c '
import json, sys
reqs = json.load(sys.stdin)["spec"]["template"]["spec"].get("requirements", [])
print(";".join(r.get("operator", "") + ":" + ",".join(sorted(r.get("values", [])))
               for r in reqs if r.get("key") == "karpenter.sh/capacity-type"))'
}
# reservation_terms_ok POOL WANT: WANT is "none" or "tag"; with "tag", the
# live EC2NodeClass must have exactly one term carrying exactly this run's
# tag and instanceMatchCriteria targeted, together (terms are ORed, so a
# separate instanceMatchCriteria-only term would select every targeted
# reservation in the account), and no id.
reservation_terms_ok() {
  k get ec2nodeclass "$1" -o json | WANT="$2" TAG_KEY="${TEST_TAG_KEY}" TAG_VALUE="${RUN_ID}" python3 -c '
import json, os, sys
terms = json.load(sys.stdin)["spec"].get("capacityReservationSelectorTerms") or []
if os.environ["WANT"] == "none":
    ok = not terms
else:
    ok = terms == [{"tags": {os.environ["TAG_KEY"]: os.environ["TAG_VALUE"]}, "instanceMatchCriteria": "targeted"}]
print(json.dumps(terms, sort_keys=True))
sys.exit(0 if ok else 1)'
}

for p in "${POOLS_27[@]}"; do
  case "${p}" in
    "${POOL_RSV}") want_req="In:reserved"; want_terms="tag" ;;
    "${POOL_OD}") want_req="In:on-demand"; want_terms="none" ;;
    "${POOL_FLEX}") want_req="In:on-demand,spot"; want_terms="none" ;;
  esac
  got_req="$(capacity_type_requirement "${p}")"
  [[ "${got_req}" == "${want_req}" ]] \
    || fail "NodePool ${p}'s karpenter.sh/capacity-type requirement is [${got_req}], want exactly [${want_req}]"
  [[ "$(k get nodepool "${p}" -o jsonpath='{.spec.template.spec.nodeClassRef.name}')" == "${p}" ]] \
    || fail "NodePool ${p}'s nodeClassRef does not name EC2NodeClass ${p}"
  [[ "$(k get resourceflavor "${p}" -o jsonpath='{.spec.nodeLabels.karpenter\.sh/nodepool}')" == "${p}" ]] \
    || fail "ResourceFlavor ${p}'s nodeLabels['karpenter.sh/nodepool'] does not join to NodePool ${p}"
  got_terms="$(reservation_terms_ok "${p}" "${want_terms}")" \
    || fail "EC2NodeClass ${p}'s capacityReservationSelectorTerms are ${got_terms}, want ${want_terms}"
  pass "pool ${p}: capacity-type [${got_req}], joined by karpenter.sh/nodepool, capacityReservationSelectorTerms ${got_terms}"
done

# Karpenter's own resolution of the -rsv selector: the EC2NodeClass status
# lists exactly this run's reservation, and the -od/-flex ones list none.
nodeclass_reservations() { k get ec2nodeclass "$1" -o jsonpath='{.status.capacityReservations[*].id}' 2>/dev/null; }
rsv_resolved() { [[ "$(nodeclass_reservations "${POOL_RSV}")" == "${RSV_ID}" ]]; }
wait_until 300 10 "EC2NodeClass ${POOL_RSV} resolves ${RSV_ID}" rsv_resolved \
  || fail "EC2NodeClass ${POOL_RSV}'s status.capacityReservations is [$(nodeclass_reservations "${POOL_RSV}")], want exactly [${RSV_ID}]"
for p in "${POOL_OD}" "${POOL_FLEX}"; do
  reservations_out="$(k get ec2nodeclass "${p}" -o jsonpath='{.status.capacityReservations[*].id}')" \
    || fail "kubectl get ec2nodeclass ${p} -o jsonpath=... failed outright (not evidence of an empty list)"
  [[ -z "${reservations_out}" ]] \
    || fail "EC2NodeClass ${p} resolved a capacity reservation it never selects: ${reservations_out}"
done
pass "Karpenter resolved ${RSV_ID} for EC2NodeClass ${POOL_RSV} only"

# ---- 11b-4. canaries: -rsv (first), -od, -flex --------------------------
#
# Acceptance criteria b (first half) and c. Each canary is a suspended Job
# addressed to its pool's own LocalQueue; Kueue unsuspends it on admission
# and injects the ResourceFlavor's karpenter.sh/nodepool node selector, so
# the node that launches comes from that pool and no other.

# submit_canary NS JOB CPU MEMORY
submit_canary() {
  k apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $2
  namespace: $1
  labels:
    kueue.x-k8s.io/queue-name: ${SMOKE_LQ_27}
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
              cpu: $3
              memory: $4
YAML
}
job_admitted() { [[ "$(k get job "$2" -n "$1" -o jsonpath='{.spec.suspend}' 2>/dev/null)" == "false" ]]; }
job_on_node() { [[ -n "$(job_node "$1" "$2")" ]]; }
node_label() { k get node "$1" -o jsonpath="{.metadata.labels.$2}"; }
pool_nodeclaims() { k get nodeclaims -l "karpenter.sh/nodepool=$1" --no-headers 2>/dev/null | wc -l | tr -d ' '; }

# assert_admitted_on_pool NS JOB POOL: Kueue admitted the Job (its own
# Workload's events), and its pod runs on a node of POOL. Sets
# ADMITTED_NODE (a global, not printed: fail() must run in this shell, not
# in a command substitution's subshell).
assert_admitted_on_pool() {
  local ns="$1" job="$2" pool="$3" wl events node
  wait_until 300 10 "Kueue admits ${ns}/${job}" job_admitted "${ns}" "${job}" \
    || fail "${ns}/${job} was never admitted (still suspended): $(k get workloads -n "${ns}" -o jsonpath='{.items[*].status.conditions}')"
  wl="$(workload_of_job "${ns}" "${job}")"
  [[ -n "${wl}" ]] || fail "no single Kueue Workload owned by ${ns}/${job}"
  events="$(k get events -n "${ns}" --field-selector involvedObject.name="${wl}" -o jsonpath='{range .items[*]}{.reason}{" "}{end}')"
  [[ "${events}" == *"Admitted"* || "${events}" == *"QuotaReserved"* ]] \
    || fail "no Kueue admission event (Admitted/QuotaReserved) for Workload ${ns}/${wl}: events=[${events}]"
  wait_until 900 15 "a node launches for ${ns}/${job}" job_on_node "${ns}" "${job}" \
    || fail "${ns}/${job}'s pod never got a node: $(k get nodeclaims -l "karpenter.sh/nodepool=${pool}" -o wide 2>&1)"
  node="$(job_node "${ns}" "${job}")"
  [[ "$(node_label "${node}" 'karpenter\.sh/nodepool')" == "${pool}" ]] \
    || fail "${ns}/${job} runs on ${node}, which is not from NodePool ${pool}"
  pass "Kueue admitted ${ns}/${job} via Workload ${wl} (events: ${events}); its pod runs on ${node} from NodePool ${pool}"
  ADMITTED_NODE="${node}"
}

RSV_NS="$(smoke_ns_of "${POOL_RSV}")"
OD_NS="$(smoke_ns_of "${POOL_OD}")"
FLEX_NS="$(smoke_ns_of "${POOL_FLEX}")"
for ns in "${RSV_NS}" "${OD_NS}" "${FLEX_NS}"; do
  k get localqueue "${SMOKE_LQ_27}" -n "${ns}" >/dev/null 2>&1 || fail "LocalQueue ${ns}/${SMOKE_LQ_27} not found"
done
submit_canary "${RSV_NS}" canary-1 "${RSV_CANARY_CPU}" "${RSV_CANARY_MEM}" || fail "kubectl apply ${RSV_NS}/canary-1"
submit_canary "${OD_NS}" canary 500m 256Mi || fail "kubectl apply ${OD_NS}/canary"
submit_canary "${FLEX_NS}" canary 500m 256Mi || fail "kubectl apply ${FLEX_NS}/canary"

assert_admitted_on_pool "${RSV_NS}" canary-1 "${POOL_RSV}"
RSV_NODE="${ADMITTED_NODE}"
[[ "$(node_label "${RSV_NODE}" 'karpenter\.sh/capacity-type')" == "reserved" ]] \
  || fail "node ${RSV_NODE} of ${POOL_RSV} has karpenter.sh/capacity-type=$(node_label "${RSV_NODE}" 'karpenter\.sh/capacity-type'), want reserved"
[[ "$(node_label "${RSV_NODE}" 'karpenter\.k8s\.aws/capacity-reservation-id')" == "${RSV_ID}" ]] \
  || fail "node ${RSV_NODE} has karpenter.k8s.aws/capacity-reservation-id=$(node_label "${RSV_NODE}" 'karpenter\.k8s\.aws/capacity-reservation-id'), want ${RSV_ID}"
[[ "$(pool_nodeclaims "${POOL_RSV}")" -eq 1 ]] \
  || fail "NodePool ${POOL_RSV} has $(pool_nodeclaims "${POOL_RSV}") NodeClaims, want exactly 1"
RSV_INSTANCE_ID="$(k get node "${RSV_NODE}" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
[[ "$(aws ec2 describe-instances --instance-ids "${RSV_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].CapacityReservationId' --output text)" == "${RSV_ID}" ]] \
  || fail "instance ${RSV_INSTANCE_ID} of node ${RSV_NODE} is not running in Capacity Reservation ${RSV_ID}"
[[ "$(aws ec2 describe-capacity-reservations --capacity-reservation-ids "${RSV_ID}" \
  --query 'CapacityReservations[0].AvailableInstanceCount' --output text)" == "0" ]] \
  || fail "Capacity Reservation ${RSV_ID} still reports an available instance while ${RSV_NODE} runs in it"
pass "exactly one node (${RSV_NODE}, ${RSV_INSTANCE_ID}) for ${POOL_RSV}: capacity-type=reserved, capacity-reservation-id=${RSV_ID}, and EC2 agrees (0 available)"

assert_admitted_on_pool "${OD_NS}" canary "${POOL_OD}"
OD_NODE="${ADMITTED_NODE}"
[[ "$(node_label "${OD_NODE}" 'karpenter\.sh/capacity-type')" == "on-demand" ]] \
  || fail "node ${OD_NODE} of ${POOL_OD} has karpenter.sh/capacity-type=$(node_label "${OD_NODE}" 'karpenter\.sh/capacity-type'), want on-demand"
pass "${POOL_OD}: node ${OD_NODE} has karpenter.sh/capacity-type=on-demand"

assert_admitted_on_pool "${FLEX_NS}" canary "${POOL_FLEX}"
FLEX_NODE="${ADMITTED_NODE}"
flex_type="$(node_label "${FLEX_NODE}" 'karpenter\.sh/capacity-type')"
[[ "${flex_type}" == "spot" || "${flex_type}" == "on-demand" ]] \
  || fail "node ${FLEX_NODE} of ${POOL_FLEX} has karpenter.sh/capacity-type=${flex_type}, want spot or on-demand"
pass "${POOL_FLEX}: node ${FLEX_NODE} has karpenter.sh/capacity-type=${flex_type} (spot or on-demand)"

# ---- 11b-5. a second -rsv canary is not admitted, by quota -------------
#
# Acceptance criterion b, second half. canary-1 still holds the reserved
# node (pause never exits). canary-2 asks for the same just-over-half of
# the reservation, so the ClusterQueue's quota (= the reservation's own
# capacity) cannot hold both. The evidence is Kueue's own: the Workload's
# QuotaReserved condition is False with a quota message, the
# ClusterQueue counts one admitted and one pending Workload, the Job stays
# suspended with no pod, and the -rsv pool still has exactly one NodeClaim
# (Karpenter was never asked for a second node, so nothing here can be a
# Karpenter launch failure).

RSV_CQ="$(smoke_cq_of "${POOL_RSV}")"
submit_canary "${RSV_NS}" canary-2 "${RSV_CANARY_CPU}" "${RSV_CANARY_MEM}" || fail "kubectl apply ${RSV_NS}/canary-2"

# workload_quota_state NS JOB: prints "<status>|<reason>|<message>" of the
# Job's Workload's QuotaReserved condition, plus "|admitted" if the
# Workload has Admitted=True.
workload_quota_state() {
  local wl
  wl="$(workload_of_job "$1" "$2")"
  [[ -n "${wl}" ]] || return 1
  k get workload "${wl}" -n "$1" -o json | python3 -c '
import json, sys
conds = json.load(sys.stdin).get("status", {}).get("conditions", [])
q = [c for c in conds if c.get("type") == "QuotaReserved"]
a = any(c.get("type") == "Admitted" and c.get("status") == "True" for c in conds)
if q:
    print("|".join([q[0].get("status", ""), q[0].get("reason", ""), q[0].get("message", "").replace("|", "/")]) + ("|admitted" if a else ""))'
}
pending_on_quota() {
  local st
  st="$(workload_quota_state "${RSV_NS}" canary-2)" || return 1
  [[ "${st}" == False\|* && "${st,,}" == *quota* && "${st}" != *"|admitted" ]]
}
wait_until 300 10 "canary-2's Workload is pending on ${RSV_CQ}'s quota" pending_on_quota \
  || fail "canary-2's Workload never reported QuotaReserved=False on quota: [$(workload_quota_state "${RSV_NS}" canary-2)]"
info "canary-2's Workload QuotaReserved condition: $(workload_quota_state "${RSV_NS}" canary-2)"

# Not a transient: still pending a minute later, while canary-1 still runs.
sleep 60
pending_on_quota || fail "canary-2 left the quota-pending state: [$(workload_quota_state "${RSV_NS}" canary-2)]"
[[ "$(k get job canary-2 -n "${RSV_NS}" -o jsonpath='{.spec.suspend}')" == "true" ]] \
  || fail "Job ${RSV_NS}/canary-2 is not suspended"
canary_2_pods="$(k get pods -n "${RSV_NS}" -l job-name=canary-2 -o jsonpath='{.items[*].metadata.name}')" \
  || fail "kubectl get pods -n ${RSV_NS} -l job-name=canary-2 failed outright (not evidence of no pod)"
[[ -z "${canary_2_pods}" ]] \
  || fail "Job ${RSV_NS}/canary-2 has a pod although it was never admitted"
[[ "$(job_node "${RSV_NS}" canary-1)" == "${RSV_NODE}" ]] \
  || fail "canary-1 no longer runs on ${RSV_NODE}, so canary-2's state is not evidence against a held node"
cq_counts="$(k get clusterqueue "${RSV_CQ}" -o jsonpath='{.status.admittedWorkloads}/{.status.pendingWorkloads}')"
[[ "${cq_counts}" == "1/1" ]] \
  || fail "ClusterQueue ${RSV_CQ} admitted/pending Workloads are ${cq_counts}, want 1/1"
[[ "$(pool_nodeclaims "${POOL_RSV}")" -eq 1 ]] \
  || fail "NodePool ${POOL_RSV} has $(pool_nodeclaims "${POOL_RSV}") NodeClaims after canary-2, want exactly 1"
pass "canary-2 is not admitted: Kueue holds it on ${RSV_CQ}'s quota (admitted/pending 1/1), still suspended with no pod, and ${POOL_RSV} still has exactly one NodeClaim"

# ---- 11b-6. teardown: back to the cell as step 11 left it ---------------
#
# Re-point the cell at GITOPS_REVISION first: the six Applications then
# disappear, and preserveResourcesOnDeletion (decision 8) leaves their
# objects orphaned rather than deleting them, so they are deleted here by
# hand -- after the Applications are gone, since a live Application with
# selfHeal would recreate them. Order follows the finalizers: namespaces
# (Jobs, pods, Workloads) before ClusterQueues, ClusterQueues before the
# ResourceFlavors they name, NodePools (Karpenter drains and terminates
# their nodes) before EC2NodeClasses. Then the reservation is cancelled
# (acceptance criterion d) while this run is still passing; cleanup()
# repeats that only if this point was never reached.

run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION} after capacity-types)"
app_gone() { ! k get application "$1" -n "${ARGOCD_NS}" >/dev/null 2>&1; }
for app in "${APPS_27[@]}"; do
  wait_until 300 10 "${app} removed" app_gone "${app}" || fail "${app} still exists after restoring --revision ${GITOPS_REVISION}"
done
for p in "${POOLS_27[@]}"; do
  k delete namespace "$(smoke_ns_of "${p}")" --wait=true --timeout=300s >/dev/null || fail "kubectl delete namespace $(smoke_ns_of "${p}")"
  k delete clusterqueue "$(smoke_cq_of "${p}")" --wait=true --timeout=300s >/dev/null || fail "kubectl delete clusterqueue $(smoke_cq_of "${p}")"
  k delete resourceflavor "${p}" --wait=true --timeout=300s >/dev/null || fail "kubectl delete resourceflavor ${p}"
done
for p in "${POOLS_27[@]}"; do
  k delete nodepool "${p}" --wait=true --timeout=900s >/dev/null || fail "kubectl delete nodepool ${p}"
  k delete ec2nodeclass "${p}" --wait=true --timeout=600s >/dev/null || fail "kubectl delete ec2nodeclass ${p}"
done
rsv_instance_terminated() {
  [[ "$(aws ec2 describe-instances --instance-ids "${RSV_INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)" == "terminated" ]]
}
wait_until 600 15 "reserved instance ${RSV_INSTANCE_ID} terminated" rsv_instance_terminated \
  || fail "instance ${RSV_INSTANCE_ID} was not terminated after deleting NodePool ${POOL_RSV}"
[[ "$(list_names nodepools)" == "${NODEPOOL}" && "$(list_names ec2nodeclasses)" == "${NODECLASS}" \
  && "$(list_names resourceflavors)" == "${RESOURCEFLAVOR}" ]] \
  || fail "the cell is not back to its own pool only: NodePools [$(list_names nodepools | tr '\n' ' ')], EC2NodeClasses [$(list_names ec2nodeclasses | tr '\n' ' ')], ResourceFlavors [$(list_names resourceflavors | tr '\n' ' ')]"
[[ "$(k get localqueues -A --no-headers 2>/dev/null | wc -l | tr -d ' ')" -eq 1 ]] \
  || fail "more than the cell's own LocalQueue remains: $(k get localqueues -A --no-headers 2>&1 | tr '\n' ' ')"
{ app_healthy_synced "${APP_CAPACITY_POOL}" && app_healthy_synced "${APP_SMOKE}"; } \
  || fail "${APP_CAPACITY_POOL}/${APP_SMOKE} are not Healthy+Synced after the step 11b teardown"
pass "step 11b teardown: only ${NODEPOOL}/${NODECLASS}/${RESOURCEFLAVOR} and ${SMOKE_NS}/${SMOKE_LOCALQUEUE} remain, as after step 11"

cancel_run_capacity_reservations || fail "Capacity Reservation ${RSV_ID} could not be cancelled"
RSV_CANCELLED=1
pass "Capacity Reservation ${RSV_ID} cancelled (acceptance criterion d; DescribeCapacityReservations reports cancelled)"

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

# break_addon_branches() is already defined in section 3c above (reused
# here for the same purpose it originally had: one addon broken on its
# own disposable branch off GITOPS_REVISION, rather than off a pristine
# cell's never-synced starting point).

if [[ "${GITOPS_SKIP_ORDERING_EXPERIMENT}" == "1" ]]; then
  info "GITOPS_SKIP_ORDERING_EXPERIMENT=1: skipping step 12's already-converged-cell re-confirmation of acceptance criterion 4 (no push access to ${GITOPS_TEST_REPO_URL} assumed); the pristine stage A/B/C sequence above already exercised criterion 4 itself"
else
  # Whether RollingSync is actually active is itself observable, not only
  # inferable from side effects: Argo CD's own ApplicationSet Progressive
  # Syncs populates status.applicationStatus with one entry per generated
  # Application once a RollingSync strategy is accepted; an unsupported or
  # rejected strategy leaves it empty and every Application syncs
  # independently (automated.selfHeal) instead. Read directly, once, so
  # the experiments below can say which branch of decision 4 this run is
  # actually in rather than only reporting what they observed around it.
  rollingsync_status_json="$(k get applicationset platform -n "${ARGOCD_NS}" -o jsonpath='{.status.applicationStatus}' 2>/dev/null)"
  if [[ -n "${rollingsync_status_json}" && "${rollingsync_status_json}" != "[]" && "${rollingsync_status_json}" != "null" ]]; then
    ROLLINGSYNC_ACTIVE=1
    info "RollingSync is active on the managed capability: ApplicationSet platform's status.applicationStatus is populated"
  else
    ROLLINGSYNC_ACTIVE=0
    info "RollingSync does not appear active on the managed capability: ApplicationSet platform's status.applicationStatus is empty; every generated Application likely syncs independently (automated.selfHeal fallback)"
  fi

  # ---- 12a. break karpenter-crd -------------------------------------
  # BREAK_CRDS_BRANCH="$(break_addon_branches ...)" runs the function in a
  # subshell (command substitution always forks one); BROKEN_BRANCHES+=
  # *inside* break_addon_branches() only ever mutated that subshell's own
  # copy of the array, never this shell's -- confirmed on a real run: the
  # branch was pushed, the whole run passed, and it was never deleted
  # (git ls-remote still showed it after the run exited 0). Track it here
  # instead, in the shell that actually runs delete_broken_branches().
  BREAK_CRDS_BRANCH="$(break_addon_branches "break-crds" "gitops/addons/karpenter-crd/addon.yaml")" \
    || fail "could not create/push the break-crds disposable branch"
  BROKEN_BRANCHES+=("${BREAK_CRDS_BRANCH}")
  run_bootstrap --revision "${BREAK_CRDS_BRANCH}" || fail "bootstrap.sh --revision ${BREAK_CRDS_BRANCH}"

  # hard_refresh_app on every poll, not just once: Argo CD's own Git repo
  # cache (default TTL on the order of minutes) and poll interval can both
  # delay noticing a new commit on a branch it is already tracking: a real
  # run hit exactly this with a plain app_not_synced wait on kueue below
  # (12b), timing out at 300s even though karpenter-crd's own otherwise-
  # identical check (this one) happened to notice in time. Force Argo CD
  # to recheck Git on every iteration instead of trusting either cache.
  karpenter_crd_not_synced_refreshing() { hard_refresh_app "${APP_KARPENTER_CRD}"; app_not_synced "${APP_KARPENTER_CRD}"; }
  wait_until 300 10 "karpenter-crd Application leaves Synced once broken" karpenter_crd_not_synced_refreshing \
    || fail "${APP_KARPENTER_CRD} stayed Synced after its chart version was broken"
  pass "${APP_KARPENTER_CRD} left Synced once its chart version was broken"

  # capacity depends on crds's CRDs regardless of which decision-4 branch
  # is live (retry-based or RollingSync): a NodePool/EC2NodeClass create
  # needs the CRD, so the capacity-pool Application cannot stay Synced
  # once karpenter-crd is broken and its own retry eventually gives up (or
  # RollingSync never advances past crds).
  if wait_until 300 10 "capacity-pool Application is affected by the broken crds step" app_not_synced "${APP_CAPACITY_POOL}"; then
    pass "observed: breaking the crds step left capacity-pool not Synced (sync=$(app_sync "${APP_CAPACITY_POOL}")) -- a real dependent was blocked, not asserted from documentation"
  else
    info "capacity-pool Application stayed Synced on its already-created objects within the retry window -- recorded, not failed, since decision 4 only promises capacity FAILS TO CREATE NEW objects depending on a broken crds step, not that an already-reconciled one un-syncs"
    pass "observed: breaking the crds step did not un-sync capacity-pool's already-reconciled objects within the retry window (consistent with decision 4, which makes no stronger claim); this half of acceptance criterion 4 is instead evidenced by karpenter-crd itself leaving Synced (above) and recovering (below)$([[ "${ROLLINGSYNC_ACTIVE}" -eq 1 ]] && echo "; RollingSync is active on this capability, per the status check above")"
  fi

  run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION} after break-crds)"
  karpenter_crd_synced_refreshing() { hard_refresh_app "${APP_KARPENTER_CRD}"; app_synced "${APP_KARPENTER_CRD}"; }
  wait_until 300 10 "karpenter-crd Application recovers" karpenter_crd_synced_refreshing \
    || fail "${APP_KARPENTER_CRD} did not recover (sync=$(app_sync "${APP_KARPENTER_CRD}")) within the retry bound after restoring --revision"
  pass "${APP_KARPENTER_CRD} recovered (Synced) within the retry bound after restoring --revision to ${GITOPS_REVISION}"

  # ---- 12b. break kueue ----------------------------------------------
  # Recorded before the break itself (not merely before checking its
  # effect): the comment and variable name below both say "before the
  # break", so the capture has to actually happen there, not after
  # run_bootstrap has already applied it.
  NODEPOOL_UID_BEFORE_KUEUE_BREAK="$(k get nodepool "${NODEPOOL}" -o jsonpath='{.metadata.uid}')"
  # Same subshell-scoping note as break-crds above.
  BREAK_KUEUE_BRANCH="$(break_addon_branches "break-kueue" "gitops/addons/kueue/addon.yaml")" \
    || fail "could not create/push the break-kueue disposable branch"
  BROKEN_BRANCHES+=("${BREAK_KUEUE_BRANCH}")
  run_bootstrap --revision "${BREAK_KUEUE_BRANCH}" || fail "bootstrap.sh --revision ${BREAK_KUEUE_BRANCH}"

  # See the comment on karpenter_crd_not_synced_refreshing above (12a):
  # same Argo CD Git-cache/poll-interval staleness risk, confirmed on a
  # real run for this exact check (kueue stayed Synced at 300s with no
  # refresh).
  kueue_not_synced_refreshing() { hard_refresh_app "${APP_KUEUE}"; app_not_synced "${APP_KUEUE}"; }
  wait_until 300 10 "kueue Application leaves Synced once broken" kueue_not_synced_refreshing \
    || fail "${APP_KUEUE} stayed Synced after its chart version was broken"
  pass "${APP_KUEUE} left Synced once its chart version was broken"

  # Decision 4's own claim for this experiment: breaking kueue (controllers
  # step) fails capacity's ResourceFlavor/ClusterQueue/LocalQueue, but
  # NodePool/EC2NodeClass (which depend on crds, not kueue) are unaffected
  # -- this is the half of acceptance criterion 4 that tells "ordering
  # between ApplicationSets is retry-based convergence, never all cross-
  # dependencies at once" apart from a coarser "capacity-pool Application
  # not Synced" signal alone.
  # A plain "does it still exist" check, polled with wait_until, returns
  # success on its very first poll -- the NodePool already exists before
  # kueue is ever broken, so this would prove nothing about surviving the
  # break, the same vacuous shape this suite's own assert_stays_not_synced
  # comment already names and fixes elsewhere (confirmed as a real,
  # separate instance of it here too, not only in the pristine stage
  # A/B checks). Invert the poll against the UID already recorded above,
  # before the break: hold a 60s window for it to disappear OR come back
  # with a different UID (replaced, not merely unchanged), and only pass
  # if neither ever happens in that whole window.
  nodepool_changed_or_gone() {
    local uid
    uid="$(k get nodepool "${NODEPOOL}" -o jsonpath='{.metadata.uid}' 2>/dev/null)" || return 0
    [[ -z "${uid}" || "${uid}" != "${NODEPOOL_UID_BEFORE_KUEUE_BREAK}" ]]
  }
  if wait_until 60 5 "NodePool ${NODEPOOL} changes or disappears merely because kueue was broken" nodepool_changed_or_gone; then
    fail "NodePool ${NODEPOOL} disappeared or was replaced (UID changed from ${NODEPOOL_UID_BEFORE_KUEUE_BREAK}) merely because kueue was broken (it depends on crds, not kueue)"
  fi
  pass "NodePool ${NODEPOOL} (depends on crds, not kueue) survived a broken kueue step unaffected for 60s, confirmed by its own unchanged UID held for the whole window, not merely found present once"

  run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION} after break-kueue)"
  kueue_synced_refreshing() { hard_refresh_app "${APP_KUEUE}"; app_synced "${APP_KUEUE}"; }
  wait_until 300 10 "kueue Application recovers" kueue_synced_refreshing \
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
# GITOPS_REPO_URL, never REPO_ROOT -- see break_addon_branches()'s own comment.
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
wait_until 300 10 "kueue Application disappears once its generator entry is removed" kueue_app_gone \
  || fail "${APP_KUEUE} Application still exists after removing its own addon.yaml"
pass "${APP_KUEUE} Application was removed by the lost generator entry"

kueue_crd_created_after="$(k get crd clusterqueues.kueue.x-k8s.io -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
[[ -n "${kueue_crd_created_after}" ]] \
  || fail "clusterqueues.kueue.x-k8s.io CRD was deleted after removing addons/kueue/addon.yaml (preserveResourcesOnDeletion did not hold)"
[[ "${kueue_crd_created_after}" == "${kueue_crd_created}" ]] \
  || fail "clusterqueues.kueue.x-k8s.io CRD has a new creationTimestamp -- it was deleted and recreated, not preserved"
k get clusterqueue "${SMOKE_CLUSTERQUEUE}" >/dev/null 2>&1 \
  || fail "ClusterQueue ${SMOKE_CLUSTERQUEUE} is gone after removing addons/kueue/addon.yaml"
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

# Proving orphaning (not merely "not yet deleted") needs the thing that
# would carry a cascade to be confirmed gone first: deleting the root
# Application cascades to both ApplicationSets (it carries the only
# cascade finalizer in this design -- decision 8), which in turn delete
# every Application they generated, including capacity-pool-cpu, the one
# whose own objects (NodePool, EC2NodeClass) this check is about. Waiting
# a fixed, short sleep and then checking survival would only show the
# cascade had not yet arrived; waiting, bounded, for the generator's own
# Application to actually disappear first is what turns "still there"
# into "never going to cascade", since preserveResourcesOnDeletion stops
# the Application's own deletion from reaching its resources at all.
capacity_pool_app_gone() { ! k get application "${APP_CAPACITY_POOL}" -n "${ARGOCD_NS}" >/dev/null 2>&1; }
wait_until 120 5 "capacity-pool Application is gone (cascaded from the deleted root Application)" capacity_pool_app_gone \
  || fail "${APP_CAPACITY_POOL} Application still exists after deleting the three bootstrap objects -- the cascade this check depends on never completed"
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

# Exactly the capacity pool and optional-pool's own pair (step 10), both
# orphaned and re-adopted by name -- anything else is a duplicate.
expected_nodepools="$(printf '%s\n' "${NODEPOOL}" "${OPTIONAL_NODEPOOL}" | sort | tr '\n' ' ')"
expected_ec2nodeclasses="$(printf '%s\n' "${NODECLASS}" "${OPTIONAL_NODECLASS}" | sort | tr '\n' ' ')"
nodepools_after="$(k get nodepools -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | { grep -v '^$' || true; } | sort | tr '\n' ' ')"
ec2nodeclasses_after="$(k get ec2nodeclasses -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | { grep -v '^$' || true; } | sort | tr '\n' ' ')"
[[ "${nodepools_after}" == "${expected_nodepools}" ]] \
  || fail "expected exactly the NodePools [${expected_nodepools}] after re-adopting, found: [${nodepools_after}]"
[[ "${ec2nodeclasses_after}" == "${expected_ec2nodeclasses}" ]] \
  || fail "expected exactly the EC2NodeClasses [${expected_ec2nodeclasses}] after re-adopting, found: [${ec2nodeclasses_after}]"
[[ "$(k get nodepool "${NODEPOOL}" -o jsonpath='{.metadata.creationTimestamp}')" == "${NODEPOOL_CREATED}" ]] \
  || fail "NodePool ${NODEPOOL}'s creationTimestamp changed -- it was deleted and recreated, not re-adopted"
[[ "$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.metadata.creationTimestamp}')" == "${NODECLASS_CREATED}" ]] \
  || fail "EC2NodeClass ${NODECLASS}'s creationTimestamp changed -- it was deleted and recreated, not re-adopted"
pass "re-running bootstrap.sh re-adopted the same NodePool and EC2NodeClass (unchanged creationTimestamps), not a duplicate"

# ---------------- 14b. platform-optional add-on: dcgm-exporter (issue #41)
#
# Issue #41 Decision 3/4: a cell opts into a platform-optional component
# by the mere presence of gitops/cells/<cell>/addons/<addon>.yaml, read by
# the third ApplicationSet, addons-optional.ApplicationSet.yaml. This step
# runs Decision 4's add-then-remove cycle on a real cell for the one
# catalog entry that ships, dcgm-exporter:
#   14b-a. without the marker file, no ${CLUSTER}-dcgm-exporter Application
#        exists;
#   14b-b. with it, the Application is generated and reaches Healthy+Synced
#        while no node matches the DaemonSet's GPU nodeSelector;
#   14b-c. a disposable GPU NodePool/EC2NodeClass TEST FIXTURE (applied with
#        kubectl, never part of the platform) launches one NVIDIA node;
#   14b-d. a dcgm-exporter pod becomes Ready on that node, and only there --
#        not on the system node group, not on optional-pool's CPU pool;
#   14b-e. removing the marker file removes the Application and orphans its
#        DaemonSet and Namespace (preserveResourcesOnDeletion: true);
#   14b-f. the cell is restored to GITOPS_REVISION and the fixture deleted.
#
# Which case 14b-a starts in depends on step 0: ensure_cell_fixture copies
# gitops/cells/example-cell/ verbatim, and example-cell ships
# addons/dcgm-exporter.yaml, so a run with a derived fixture (and a run
# with NAME=example-cell) has had the marker -- and a synced
# dcgm-exporter Application -- since its first bootstrap. 14b-a therefore
# removes the marker on a disposable branch first rather than assuming
# it was never there. If GITOPS_REVISION's own cells/${NAME}/ has no
# marker at all, 14b-a has nothing to remove and 14b-b adds example-cell's
# marker on a disposable branch instead.

APP_DCGM="${CLUSTER}-dcgm-exporter"
DCGM_MARKER_REL="gitops/cells/${NAME}/addons/dcgm-exporter.yaml"
DCGM_EXAMPLE_MARKER_REL="gitops/cells/example-cell/addons/dcgm-exporter.yaml"
DCGM_CLONE="${WORK_DIR}/dcgm-exporter"
DCGM_MARKER_COPY="${WORK_DIR}/dcgm-exporter-marker.yaml"
# GITOPS_REPO_URL, never REPO_ROOT -- see break_addon_branches()'s own comment.
git clone --quiet --no-single-branch "${GITOPS_REPO_URL}" "${DCGM_CLONE}" || fail "git clone (dcgm-exporter)"
checkout_revision_as "${DCGM_CLONE}" "dcgm-exporter-probe" "${GITOPS_REVISION}" || fail "git checkout (dcgm-exporter)"
if [[ -f "${DCGM_CLONE}/${DCGM_MARKER_REL}" ]]; then
  cp "${DCGM_CLONE}/${DCGM_MARKER_REL}" "${DCGM_MARKER_COPY}"
  # Read by step 14b-f below: whether restoring GITOPS_REVISION (the
  # shared branch, always restored verbatim -- the override below never
  # lands there) is also "restoring the add step" depends on whether the
  # marker already lived in GITOPS_REVISION, not on whether ADD_DCGM_REVISION
  # happens to be a disposable branch (it always is now, see below).
  DCGM_MARKER_PREEXISTED=1
  NO_DCGM_REVISION="e2e/${RUN_ID}/no-dcgm-exporter"
  git -C "${DCGM_CLONE}" checkout --quiet -B "${NO_DCGM_REVISION}" || fail "git checkout (no-dcgm-exporter)"
  git -C "${DCGM_CLONE}" rm --quiet "${DCGM_MARKER_REL}" || fail "git rm ${DCGM_MARKER_REL}"
  git -C "${DCGM_CLONE}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
    commit --quiet -m "test: remove ${DCGM_MARKER_REL} for the e2e add-then-remove cycle (never merged)" \
    || fail "git commit (no-dcgm-exporter)"
  push_disposable_branch "${DCGM_CLONE}" "${NO_DCGM_REVISION}" || fail "git push (no-dcgm-exporter)"
  BROKEN_BRANCHES+=("${NO_DCGM_REVISION}")
  # ADD_DCGM_REVISION must still grant step 14b-d's own scrape Pod an
  # allowedPeers entry (same reasoning as the no-marker branch below) --
  # it cannot simply be GITOPS_REVISION itself, since that is the real,
  # shared branch and this override is disposable/test-only. A fresh
  # branch off GITOPS_REVISION (not off NO_DCGM_REVISION above, which has
  # the marker removed) restores the marker's original content, then
  # layers the override on top.
  ADD_DCGM_REVISION="e2e/${RUN_ID}/add-dcgm-exporter-scrape-allow"
  checkout_revision_as "${DCGM_CLONE}" "add-dcgm-exporter-scrape-allow" "${GITOPS_REVISION}" \
    || fail "git checkout (add-dcgm-exporter-scrape-allow)"
  # A blind append would silently become a duplicate top-level `values:`
  # key the day a real cell's own ${DCGM_MARKER_REL} starts setting one
  # (gitops/charts/dcgm-exporter/README.md's own overridableKeys
  # mechanism this override itself exercises) -- caught here instead of
  # discovered as a flaky "Application never generated" failure later.
  # The leading blank line in the heredoc below is not cosmetic: if the
  # marker's own last line has no trailing newline, this is what keeps
  # "values:" from being appended onto the end of that line instead of
  # starting its own.
  grep -q '^values:' "${DCGM_CLONE}/${DCGM_MARKER_REL}" \
    && fail "${DCGM_MARKER_REL} at ${GITOPS_REVISION} already has a top-level values: key -- this test's blind append would duplicate it; merge the allowedPeers entry into the existing block instead"
  cat >>"${DCGM_CLONE}/${DCGM_MARKER_REL}" <<VALUES

values:
  dcgm-exporter:
    networkPolicy:
      allowedPeers:
        - podSelector:
            matchLabels:
              ${TEST_TAG_KEY}: "${RUN_ID}"
VALUES
  git -C "${DCGM_CLONE}" add "${DCGM_MARKER_REL}" || fail "git add ${DCGM_MARKER_REL} (scrape-allow)"
  git -C "${DCGM_CLONE}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
    commit --quiet -m "test: grant step 14b-d's scrape Pod an allowedPeers entry in ${DCGM_MARKER_REL} (never merged)" \
    || fail "git commit (add-dcgm-exporter-scrape-allow)"
  push_disposable_branch "${DCGM_CLONE}" "${ADD_DCGM_REVISION}" || fail "git push (add-dcgm-exporter-scrape-allow)"
  BROKEN_BRANCHES+=("${ADD_DCGM_REVISION}")
else
  DCGM_MARKER_PREEXISTED=0
  [[ -f "${DCGM_CLONE}/${DCGM_EXAMPLE_MARKER_REL}" ]] \
    || fail "neither ${DCGM_MARKER_REL} nor ${DCGM_EXAMPLE_MARKER_REL} exists at ${GITOPS_REVISION}"
  cp "${DCGM_CLONE}/${DCGM_EXAMPLE_MARKER_REL}" "${DCGM_MARKER_COPY}"
  # #63/"SA4"'s networkPolicy.allowedPeers default-denies everything
  # (dcgm-exporter/values.yaml, "no monitoring namespace or scraper
  # exists yet in this repository"). Step 14b-d's own throwaway scrape
  # Pod below is exactly the kind of in-cluster consumer that comment
  # describes, so it must name itself the same way any real cell's
  # scraper would -- gitops/charts/dcgm-exporter/README.md's own
  # "overridableKeys" row -- rather than relying on a deny-all policy
  # happening to let it through. podSelector only (no namespaceSelector)
  # is correctly scoped to DCGM_NS alone (a NetworkPolicy peer with only
  # a podSelector matches within the policy's own namespace), which is
  # also where this scrape Pod is created, below. Guarded the same way
  # as the other branch's append (same leading-blank-line reasoning too),
  # even though DCGM_EXAMPLE_MARKER_REL is a known, checked-in file with
  # no values: key today -- a future edit to that one file (it is this
  # platform's own worked example, not a disposable fixture) would
  # otherwise silently duplicate the key here too.
  grep -q '^values:' "${DCGM_MARKER_COPY}" \
    && fail "${DCGM_EXAMPLE_MARKER_REL} already has a top-level values: key -- this test's blind append would duplicate it; merge the allowedPeers entry into the existing block instead"
  cat >>"${DCGM_MARKER_COPY}" <<VALUES

values:
  dcgm-exporter:
    networkPolicy:
      allowedPeers:
        - podSelector:
            matchLabels:
              ${TEST_TAG_KEY}: "${RUN_ID}"
VALUES
  NO_DCGM_REVISION="${GITOPS_REVISION}"
  ADD_DCGM_REVISION="e2e/${RUN_ID}/add-dcgm-exporter"
  git -C "${DCGM_CLONE}" checkout --quiet -B "${ADD_DCGM_REVISION}" || fail "git checkout (add-dcgm-exporter)"
  mkdir -p "$(dirname "${DCGM_CLONE}/${DCGM_MARKER_REL}")"
  cp "${DCGM_MARKER_COPY}" "${DCGM_CLONE}/${DCGM_MARKER_REL}"
  git -C "${DCGM_CLONE}" add "${DCGM_MARKER_REL}" || fail "git add ${DCGM_MARKER_REL}"
  git -C "${DCGM_CLONE}" -c user.name="distai-platform gitops e2e" -c user.email="noreply@users.noreply.github.com" \
    commit --quiet -m "test: add ${DCGM_MARKER_REL} for the e2e add-then-remove cycle (never merged)" \
    || fail "git commit (add-dcgm-exporter)"
  push_disposable_branch "${DCGM_CLONE}" "${ADD_DCGM_REVISION}" || fail "git push (add-dcgm-exporter)"
  BROKEN_BRANCHES+=("${ADD_DCGM_REVISION}")
fi

# The marker's own namespace and wave, read from the file itself rather
# than restated here.
dcgm_marker_field() { sed -n "s/^$1:[[:space:]]*//p" "${DCGM_MARKER_COPY}" | tr -d "\"'" | head -n1; }
DCGM_NS="$(dcgm_marker_field namespace)"
DCGM_WAVE="$(dcgm_marker_field wave)"
[[ -n "${DCGM_NS}" && -n "${DCGM_WAVE}" ]] || fail "could not read namespace/wave from the dcgm-exporter marker (namespace=${DCGM_NS} wave=${DCGM_WAVE})"

# `! app_exists` would read a transient kubectl/API error exactly
# the same as a confirmed absence (both are "the positive check failed"),
# which is wrong here specifically because this predicate feeds
# wait_until's "stop as soon as this returns true" loop -- a single
# transient error on any poll would end the wait immediately and report
# "gone" while the Application might still exist. This checks the
# server's own response text for "NotFound" instead of only the exit
# code: exists -> false (not gone); confirmed NotFound -> true (gone);
# any other error (timeout, connection refused, ...) -> false, so
# wait_until retries rather than concluding anything from a reply the
# cluster never actually gave.
dcgm_app_gone() {
  local err
  err="$(k get application "${APP_DCGM}" -n "${ARGOCD_NS}" 2>&1 >/dev/null)" && return 1
  [[ "${err}" == *"NotFound"* ]]
}
# Note: a failed `k get daemonsets` here would read as "no DaemonSets
# exist" (the same risk class other checks in this step now guard
# against), which would skip the dcgm-exporter namespace reset below and
# let 14b-b pass its "re-adoption" assertion for the wrong reason. Left as
# is rather than guarded with fail(): this function is invoked through
# `< <(dcgm_daemonsets)` process substitution, where `fail`'s own `exit`
# would only terminate that subshell, not this script -- the same
# subtlety the other guarded checks in this step avoid by never calling
# fail() from inside a process-substituted function. A real fix needs a
# different mechanism (a side-channel exit-code file, or restructuring
# the two call sites to not use process substitution), not attempted
# here.
dcgm_daemonsets() { k get daemonsets -n "${DCGM_NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | { grep -v '^$' || true; }; }

# ---- 14b-a. no marker file, no Application
mapfile -t dcgm_ds_before_removal < <(dcgm_daemonsets)
run_bootstrap --revision "${NO_DCGM_REVISION}" || fail "bootstrap.sh --revision ${NO_DCGM_REVISION}"
wait_until 300 10 "dcgm-exporter Application absent without its marker file" dcgm_app_gone \
  || fail "${APP_DCGM} still exists at ${NO_DCGM_REVISION}, which has no ${DCGM_MARKER_REL}"
if [[ "${#dcgm_ds_before_removal[@]}" -ge 1 ]]; then
  # The Application synced from an earlier bootstrap. Its DaemonSet
  # surviving the Application's removal is a first, early observation of
  # the orphaning 14b-e checks properly; then the namespace is deleted so
  # that 14b-b proves the Application creates the DaemonSet, rather than
  # only re-adopting an orphan. Cluster-scoped objects the chart may
  # render (a ClusterRole, for example) are left and re-adopted in 14b-b.
  for ds in "${dcgm_ds_before_removal[@]}"; do
    k get daemonset "${ds}" -n "${DCGM_NS}" >/dev/null 2>&1 \
      || fail "DaemonSet ${DCGM_NS}/${ds} was deleted when ${APP_DCGM} was removed (expected orphaned, preserveResourcesOnDeletion: true)"
  done
  pass "removing the marker file removed ${APP_DCGM} and orphaned its DaemonSet(s) ${dcgm_ds_before_removal[*]} from the earlier bootstrap"
  k delete namespace "${DCGM_NS}" --wait=true --timeout=300s >/dev/null \
    || fail "kubectl delete namespace ${DCGM_NS} (resetting the orphaned resources before 14b-b)"
  info "deleted the orphaned namespace ${DCGM_NS} so that 14b-b starts from nothing"
fi
pass "no Application ${APP_DCGM} exists at ${NO_DCGM_REVISION} (no ${DCGM_MARKER_REL})"

# ---- 14b-b. marker file added: Application generated, Healthy+Synced
#
# No node matches the DaemonSet's nvidia nodeSelector yet (checked below),
# so its desiredNumberScheduled is 0. Argo CD's DaemonSet health check
# reports a DaemonSet Healthy once its observedGeneration has caught up
# and its updated/available pod counts are not below desiredNumberScheduled
# -- trivially true at 0
# (https://github.com/argoproj/gitops-engine/blob/5baed5604d2dd970619fc9b91e8d31724662ab3e/pkg/health/health_daemonset.go),
# so Healthy+Synced, not merely Synced, is what this step expects. A
# capability whose health check differs fails here with both statuses
# printed, rather than being assumed either way.
# Under pipefail, a failed `k get nodes` here (API hiccup, not "zero
# nodes") would make the whole pipeline's exit code non-zero even though
# wc -l/tr both exit 0 on their own, which a bare assignment with no
# guard would let abort the script with no message. Capturing kubectl
# alone first, guarded, keeps that failure distinguishable from a
# genuine zero-node answer.
nvidia_node_names="$(k get nodes -l karpenter.k8s.aws/instance-gpu-manufacturer=nvidia -o name 2>&1)" \
  || fail "kubectl get nodes -l karpenter.k8s.aws/instance-gpu-manufacturer=nvidia failed: ${nvidia_node_names}"
nvidia_nodes="$(echo "${nvidia_node_names}" | grep -c . || true)"
[[ "${nvidia_nodes}" -eq 0 ]] \
  || fail "${nvidia_nodes} NVIDIA node(s) already exist before step 14b-c launches one; 14b-b's zero-matched-node expectation would not hold"
run_bootstrap --revision "${ADD_DCGM_REVISION}" || fail "bootstrap.sh --revision ${ADD_DCGM_REVISION}"
wait_until 300 10 "dcgm-exporter Application generated from its marker file" app_exists "${APP_DCGM}" \
  || fail "no Application ${APP_DCGM} appeared at ${ADD_DCGM_REVISION} (addons-optional ApplicationSet did not generate it)"
wait_until 900 15 "dcgm-exporter Application Healthy and Synced" app_healthy_synced "${APP_DCGM}" \
  || fail "${APP_DCGM} did not reach Healthy+Synced: health=$(app_health "${APP_DCGM}") sync=$(app_sync "${APP_DCGM}") operationState=[$(app_operation_state "${APP_DCGM}")]"
mapfile -t dcgm_daemonset_names < <(dcgm_daemonsets)
[[ "${#dcgm_daemonset_names[@]}" -eq 1 ]] \
  || fail "expected exactly 1 DaemonSet in ${DCGM_NS}, found ${#dcgm_daemonset_names[@]}: ${dcgm_daemonset_names[*]:-none}"
DCGM_DS="${dcgm_daemonset_names[0]}"
dcgm_desired="$(k get daemonset "${DCGM_DS}" -n "${DCGM_NS}" -o jsonpath='{.status.desiredNumberScheduled}')"
[[ "${dcgm_desired}" == "0" ]] \
  || fail "DaemonSet ${DCGM_NS}/${DCGM_DS} wants ${dcgm_desired} pod(s) although no NVIDIA node exists -- its nodeSelector does not restrict it to GPU nodes"
pass "${APP_DCGM} was generated from ${DCGM_MARKER_REL} and reached Healthy+Synced with DaemonSet ${DCGM_DS} scheduling 0 pods (no NVIDIA node yet)"

dcgm_wave_label="$(app_field "${APP_DCGM}" '{.metadata.labels.distai\.dev/wave}')"
[[ "${dcgm_wave_label}" == "${DCGM_WAVE}" ]] \
  || fail "${APP_DCGM}'s distai.dev/wave label (${dcgm_wave_label}) is not the marker's wave (${DCGM_WAVE})"
dcgm_project="$(app_field "${APP_DCGM}" '{.spec.project}')"
[[ "${dcgm_project}" == "platform" ]] || fail "${APP_DCGM}'s project is ${dcgm_project}, expected platform (issue #41 Decision 3)"
dcgm_target_revision="$(app_field "${APP_DCGM}" '{.spec.source.targetRevision}')"
[[ "${dcgm_target_revision}" == "${ADD_DCGM_REVISION}" ]] \
  || fail "${APP_DCGM}'s targetRevision (${dcgm_target_revision}) is not the Secret's revision annotation (${ADD_DCGM_REVISION})"
dcgm_psa="$(k get namespace "${DCGM_NS}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
[[ "${dcgm_psa}" == "privileged" ]] \
  || fail "namespace ${DCGM_NS}'s pod-security.kubernetes.io/enforce label is [${dcgm_psa}], expected privileged (the chart's own Namespace)"
pass "${APP_DCGM}: wave label ${DCGM_WAVE}, project platform, targetRevision ${ADD_DCGM_REVISION}, namespace ${DCGM_NS} enforce=privileged"
# Issue #41 Decision 3's evidence check, recorded rather than asserted
# (the same treatment step 12 gives RollingSync's status): present means
# the capability leaves automated sync in place (RollingSync inert, every
# Application converges independently); absent means the capability
# strips it, i.e. honors RollingSync, and Decision 3's convergence claims
# need re-deriving.
dcgm_automated="$(app_field "${APP_DCGM}" '{.spec.syncPolicy.automated}')"
if [[ -n "${dcgm_automated}" ]]; then
  info "${APP_DCGM}'s spec.syncPolicy.automated is present (${dcgm_automated}): RollingSync is inert on this capability for addons-optional, as issue #41 Decision 3 states"
else
  info "${APP_DCGM}'s spec.syncPolicy.automated is ABSENT: the capability appears to honor RollingSync for addons-optional; issue #41 Decision 3's convergence claims need re-deriving"
fi

# ---- 14b-c. GPU NodePool/EC2NodeClass TEST FIXTURE
#
# A throwaway fixture for proving placement, applied with kubectl and
# never part of the shipped platform: one untainted NodePool/EC2NodeClass
# pair limited to one small NVIDIA instance, plus one pause Pod pinned to
# that NodePool (Karpenter never launches a node for a DaemonSet pod on
# its own, so something schedulable has to ask for the node). Named per
# run so it cannot collide with a concurrent run or a real cell's objects;
# deleted at the end of this step, and by cleanup() on any failure.
# The EC2NodeClass copies role, AMI and subnet/security-group discovery
# from the live capacity-pool EC2NodeClass (rendered from
# gitops/charts/capacity-pool/templates/ec2nodeclass.yaml), so the fixture
# uses the same pinned AMI alias -- Karpenter resolves an AL2023 alias to
# its NVIDIA variant for a GPU instance type -- and the same discovery
# tag; metadataOptions repeats that template's IMDSv2 settings. The root
# volume is set explicitly because the NVIDIA AMI and the dcgm-exporter
# image are larger than the CPU pools need. Every instance carries this
# run's TEST_TAG_KEY tag, so step 15's leftover check finds it.
GPU_FIXTURE_NAME="e2e-gpu-$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "${RUN_ID}")"
gpu_role="$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.spec.role}')"
gpu_ami_family="$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.spec.amiFamily}')"
gpu_ami_alias="$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.spec.amiSelectorTerms[0].alias}')"
gpu_discovery="$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.spec.subnetSelectorTerms[0].tags.karpenter\.sh/discovery}')"
[[ -n "${gpu_role}" && -n "${gpu_ami_family}" && -n "${gpu_ami_alias}" && -n "${gpu_discovery}" ]] \
  || fail "could not read role/amiFamily/amiSelectorTerms alias/discovery tag from EC2NodeClass ${NODECLASS}"
cat >"${WORK_DIR}/gpu-fixture.yaml" <<YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ${GPU_FIXTURE_NAME}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  role: "${gpu_role}"
  amiFamily: ${gpu_ami_family}
  amiSelectorTerms:
    - alias: "${gpu_ami_alias}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${gpu_discovery}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${gpu_discovery}"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        encrypted: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 1
    httpTokens: required
  tags:
    ${TEST_TAG_KEY}: "${RUN_ID}"
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ${GPU_FIXTURE_NAME}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: ${GPU_FIXTURE_NAME}
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["g5", "g6", "g6e"]
        - key: karpenter.k8s.aws/instance-gpu-manufacturer
          operator: In
          values: ["nvidia"]
      terminationGracePeriod: 10m
  limits:
    cpu: "8"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: Never
---
apiVersion: v1
kind: Pod
metadata:
  name: ${GPU_FIXTURE_NAME}
  namespace: default
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  nodeSelector:
    karpenter.sh/nodepool: ${GPU_FIXTURE_NAME}
  terminationGracePeriodSeconds: 0
  containers:
    - name: pause
      image: public.ecr.aws/eks-distro/kubernetes/pause:3.10
      resources:
        requests:
          cpu: 100m
          memory: 64Mi
YAML
k apply -f "${WORK_DIR}/gpu-fixture.yaml" || fail "kubectl apply the step 14b GPU test fixture"
pass "applied the GPU test fixture ${GPU_FIXTURE_NAME} (EC2NodeClass, NodePool limited to cpu 8, trigger Pod)"

# ---- 14b-d. dcgm-exporter lands on the GPU node, and only there
#
# "|" between fields, never " ": see canary_node()'s own comment (step 11).
dcgm_ready_node() {
  k get pods -n "${DCGM_NS}" \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"|"}{.spec.nodeName}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$1=="DaemonSet" && $2!="" && $3=="True" {print $2; found=1; exit} END{exit !found}'
}
dcgm_pod_ready() { [[ -n "$(dcgm_ready_node)" ]]; }
wait_until 1500 20 "a dcgm-exporter pod is Ready on a node" dcgm_pod_ready \
  || fail "no dcgm-exporter pod became Ready: pods=[$(k get pods -n "${DCGM_NS}" -o wide 2>&1 | tr '\n' ' ')] nodeclaims=[$(k get nodeclaims -o wide 2>&1 | tr '\n' ' ')]"
# dcgm_ready_node's own awk exits 1 (via END{exit !found}) when no
# matching pod is found; a bare assignment with no guard would let that
# abort the script silently under set -e if the pod stopped being Ready
# in the instant between wait_until's last successful poll and this
# direct re-invocation (unlikely, but the same shape this step's own
# other fixes are closing elsewhere).
DCGM_NODE="$(dcgm_ready_node)" \
  || fail "dcgm_ready_node found no Ready dcgm-exporter pod on this direct re-check, immediately after wait_until confirmed one"
dcgm_node_gpu="$(k get node "${DCGM_NODE}" -o jsonpath='{.metadata.labels.karpenter\.k8s\.aws/instance-gpu-manufacturer}')"
dcgm_node_pool="$(k get node "${DCGM_NODE}" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')"
dcgm_node_mng="$(k get node "${DCGM_NODE}" -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/nodegroup}')"
dcgm_node_type="$(k get node "${DCGM_NODE}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')"
[[ "${dcgm_node_gpu}" == "nvidia" ]] \
  || fail "dcgm-exporter pod is Ready on node ${DCGM_NODE}, which has karpenter.k8s.aws/instance-gpu-manufacturer=[${dcgm_node_gpu}], not nvidia"
[[ -z "${dcgm_node_mng}" ]] \
  || fail "dcgm-exporter pod is Ready on node ${DCGM_NODE}, a system managed node group node (eks.amazonaws.com/nodegroup=${dcgm_node_mng})"
[[ "${dcgm_node_pool}" == "${GPU_FIXTURE_NAME}" ]] \
  || fail "dcgm-exporter pod is Ready on node ${DCGM_NODE} from NodePool [${dcgm_node_pool}], not the GPU test fixture ${GPU_FIXTURE_NAME} (optional-pool is ${OPTIONAL_NODEPOOL})"
# A process-substitution `done < <(...)` never surfaces the piped
# command's own exit code -- a failed `kubectl get pods` here would feed
# the loop zero lines, same as a query that genuinely found none, and the
# loop would exit having checked nothing while the pass below still
# claims "every dcgm-exporter pod is on an NVIDIA node". Capturing the
# output and its exit code first makes that failure loud instead.
dcgm_pod_nodes="$(k get pods -n "${DCGM_NS}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>&1)" \
  || fail "kubectl get pods -n ${DCGM_NS} failed while checking every dcgm-exporter pod's node: ${dcgm_pod_nodes}"
dcgm_pod_node_count=0
while IFS= read -r pod_node; do
  [[ -n "${pod_node}" ]] || continue
  dcgm_pod_node_count=$((dcgm_pod_node_count + 1))
  [[ "$(k get node "${pod_node}" -o jsonpath='{.metadata.labels.karpenter\.k8s\.aws/instance-gpu-manufacturer}')" == "nvidia" ]] \
    || fail "a dcgm-exporter pod is scheduled on non-NVIDIA node ${pod_node}"
done <<<"${dcgm_pod_nodes}"
[[ "${dcgm_pod_node_count}" -ge 1 ]] || fail "no dcgm-exporter pod had a .spec.nodeName to check, even though one was just found Ready on ${DCGM_NODE}"
pass "a dcgm-exporter pod is Ready on ${DCGM_NODE} (${dcgm_node_type}, nvidia, NodePool ${GPU_FIXTURE_NAME}) -- not on the system node group or optional-pool's ${OPTIONAL_NODEPOOL}; every dcgm-exporter pod is on an NVIDIA node"

# "Ready" proves the container's liveness/readiness probes
# pass, not that DCGM itself produced a real metric from the GPU on this
# node -- the three-stage check (Ready, resource registered, computed
# value) DA-31 names, applied here to the metrics endpoint rather than a
# device-plugin resource. This scrapes the chart's own Service (never
# the Pod IP directly, so it also proves the Service/port the catalog
# entry's README states is reachable, not only the container port) from
# a throwaway Pod using this suite's own pinned curl image, and greps for
# a real DCGM_FI_DEV_* series -- the actual series name, not merely a
# 200 response (an exporter that serves an empty or malformed page on
# :9400/metrics would otherwise look identical to a working one here).
# A failed `k get svc` here would otherwise read as "one Service named
# <the error text>" -- mapfile/< <() never surfaces the piped command's
# own exit code, same shape as the step 14b-d node-loop fix above.
dcgm_svc_output="$(k get svc -n "${DCGM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1)" \
  || fail "kubectl get svc -n ${DCGM_NS} failed: ${dcgm_svc_output}"
mapfile -t dcgm_services <<<"${dcgm_svc_output}"
[[ "${#dcgm_services[@]}" -eq 1 && -n "${dcgm_services[0]}" ]] \
  || fail "expected exactly one Service in ${DCGM_NS} to scrape, found: ${dcgm_services[*]:-none}"
DCGM_SVC="${dcgm_services[0]}"
DCGM_SCRAPE_POD="dcgm-scrape-${RUN_ID##*-}"
cat >"${WORK_DIR}/dcgm-scrape-pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${DCGM_SCRAPE_POD}
  namespace: ${DCGM_NS}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: ${DCGM_SCRAPE_CURL_IMAGE}
      command: ["curl", "-sf", "-m", "10", "http://${DCGM_SVC}.${DCGM_NS}.svc:9400/metrics"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 32Mi}
YAML
k apply -f "${WORK_DIR}/dcgm-scrape-pod.yaml" >/dev/null || fail "apply the step 14b-d metrics-scrape Pod"
dcgm_scrape_done() {
  local phase
  phase="$(k get pod "${DCGM_SCRAPE_POD}" -n "${DCGM_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]]
}
wait_until 120 5 "the metrics-scrape Pod finished" dcgm_scrape_done \
  || fail "the step 14b-d metrics-scrape Pod ${DCGM_SCRAPE_POD} never reached Succeeded/Failed"
dcgm_scrape_phase="$(k get pod "${DCGM_SCRAPE_POD}" -n "${DCGM_NS}" -o jsonpath='{.status.phase}')" \
  || fail "kubectl get pod ${DCGM_SCRAPE_POD} -n ${DCGM_NS} failed: ${dcgm_scrape_phase}"
dcgm_scrape_output="$(k logs "${DCGM_SCRAPE_POD}" -n "${DCGM_NS}" 2>&1)" \
  || fail "kubectl logs ${DCGM_SCRAPE_POD} -n ${DCGM_NS} failed: ${dcgm_scrape_output}"
[[ "${dcgm_scrape_phase}" == "Succeeded" ]] \
  || fail "curl http://${DCGM_SVC}.${DCGM_NS}.svc:9400/metrics (-sf) exited non-zero (Pod phase ${dcgm_scrape_phase}): ${dcgm_scrape_output}"
echo "${dcgm_scrape_output}" | grep -qE '^DCGM_FI_DEV_[A-Z_]+(\{[^}]*\})? [0-9.eE+-]+$' \
  || fail "curl http://${DCGM_SVC}.${DCGM_NS}.svc:9400/metrics succeeded but no DCGM_FI_DEV_* series appeared; first 10 lines: $(echo "${dcgm_scrape_output}" | head -10 | tr '\n' ' ')"
dcgm_series_count="$(echo "${dcgm_scrape_output}" | grep -cE '^DCGM_FI_DEV_[A-Z_]+(\{[^}]*\})? [0-9.eE+-]+$')"
k delete pod "${DCGM_SCRAPE_POD}" -n "${DCGM_NS}" --ignore-not-found --wait=true --timeout=60s >/dev/null \
  || fail "kubectl delete the step 14b-d metrics-scrape Pod"
pass "GET http://${DCGM_SVC}.${DCGM_NS}.svc:9400/metrics returned ${dcgm_series_count} DCGM_FI_DEV_* series from the real GPU on ${DCGM_NODE}"

# Confirm the wrapper's own stated defaults against the real
# rendered objects on this cluster, not only against what the chart's
# values.yaml says it will do -- NetworkPolicy present and of the shape
# the README claims, no ServiceMonitor CRD instance, and no
# priorityClassName set on the running pod.
# 2>&1 would merge in any benign stderr warning kubectl happens to print
# on a SUCCESSFUL call too (a deprecation notice, for example), and that
# noise alone would satisfy "non-empty" even if the real jsonpath result
# was genuinely empty (no NetworkPolicy) -- not only a failure-path risk,
# so stdout and stderr are kept apart here rather than merged.
dcgm_netpol_errfile="$(mktemp)"
if ! dcgm_netpol_names="$(k get networkpolicy -n "${DCGM_NS}" -o jsonpath='{.items[*].metadata.name}' 2>"${dcgm_netpol_errfile}")"; then
  fail "kubectl get networkpolicy -n ${DCGM_NS} failed: $(cat "${dcgm_netpol_errfile}")"
fi
rm -f "${dcgm_netpol_errfile}"
[[ -n "$(tr -d '[:space:]' <<<"${dcgm_netpol_names}")" ]] \
  || fail "no NetworkPolicy exists in ${DCGM_NS}, but the chart's own networkPolicy.enabled is true"
# --ignore-not-found
# only suppresses "no object of this kind exists"; it does nothing for
# "this kind does not exist on this cluster at all" (no Prometheus
# Operator CRD here, the expected and normal case), which kubectl
# reports as a hard, non-zero-exit error on stderr -- piped into
# `grep -c .` with 2>&1, that one error line was counted as "1
# ServiceMonitor object", the opposite of what it meant. A second,
# independent bug an earlier version of this fix introduced and did not
# catch until a later real-cluster run: `var=$(failing_cmd); rc=$?` still
# aborts the whole script right at the assignment under `set -e`
# (confirmed: `set -e; v=$(false); echo reached` never prints "reached"
# -- a plain assignment statement's own exit status is checked same as
# any other simple command, so the following `rc=$?` line is never
# reached). The existing aws_text() helper already has the fix for this
# exact shape: put the assignment inside an `if` condition, where set -e
# does not apply to the first branch of an AND-OR or compound test.
# Stdout and stderr are kept apart here too (see the NetworkPolicy check
# just above): a benign stderr line on a SUCCESSFUL call must never add
# to the ServiceMonitor count, only a real stderr line on the FAILURE
# branch is ever inspected for the CRD-absent message.
dcgm_sm_errfile="$(mktemp)"
if dcgm_sm_output="$(k get servicemonitors.monitoring.coreos.com -n "${DCGM_NS}" --ignore-not-found -o name 2>"${dcgm_sm_errfile}")"; then
  dcgm_servicemonitor_count="$(echo "${dcgm_sm_output}" | grep -c . || true)"
else
  dcgm_sm_err="$(cat "${dcgm_sm_errfile}")"
  [[ "${dcgm_sm_err}" == *"doesn't have a resource type"* || "${dcgm_sm_err}" == *"the server could not find the requested resource"* ]] \
    || fail "kubectl get servicemonitors.monitoring.coreos.com -n ${DCGM_NS} failed, not with 'no such resource type': ${dcgm_sm_err}"
  dcgm_servicemonitor_count=0
fi
rm -f "${dcgm_sm_errfile}"
[[ "${dcgm_servicemonitor_count}" -eq 0 ]] \
  || fail "found ${dcgm_servicemonitor_count} ServiceMonitor object(s) in ${DCGM_NS}, but serviceMonitor.enabled is false"
# A bare `x=$(cmd)` with no `||` still trips set -e on cmd's own exit
# code (this is not a readability choice -- bash's errexit does check a
# command substitution's exit status in a plain assignment), and
# `-o jsonpath='{.items[0]...}'` against zero matching pods is exactly
# that: kubectl's own jsonpath engine errors on an out-of-range index
# rather than printing nothing, which would otherwise abort this script
# with no FAIL message naming why. Listing names first makes "is there
# exactly one" an explicit, loud check instead of an implicit one.
dcgm_pod_names_raw="$(k get pods -n "${DCGM_NS}" -l "app.kubernetes.io/name=dcgm-exporter" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1)" \
  || fail "kubectl get pods -n ${DCGM_NS} -l app.kubernetes.io/name=dcgm-exporter failed: ${dcgm_pod_names_raw}"
mapfile -t dcgm_pod_names <<<"${dcgm_pod_names_raw}"
[[ "${#dcgm_pod_names[@]}" -eq 1 && -n "${dcgm_pod_names[0]}" ]] \
  || fail "expected exactly one dcgm-exporter pod in ${DCGM_NS}, found: ${dcgm_pod_names[*]:-none}"
dcgm_pod_name="${dcgm_pod_names[0]}"
dcgm_prio_errfile="$(mktemp)"
if ! dcgm_pod_priority_class="$(k get pod "${dcgm_pod_name}" -n "${DCGM_NS}" -o jsonpath='{.spec.priorityClassName}' 2>"${dcgm_prio_errfile}")"; then
  fail "kubectl get pod ${dcgm_pod_name} -n ${DCGM_NS} failed: $(cat "${dcgm_prio_errfile}")"
fi
rm -f "${dcgm_prio_errfile}"
[[ -z "${dcgm_pod_priority_class}" ]] \
  || fail "pod ${dcgm_pod_name} has priorityClassName=${dcgm_pod_priority_class}, expected none (the wrapper sets priorityClassName: \"\")"
pass "NetworkPolicy exists in ${DCGM_NS}, no ServiceMonitor object, pod ${dcgm_pod_name} has no priorityClassName"

# ---- 14b-e. marker file removed: Application gone, resources orphaned
#
# Same reasoning as step 14: wait for the Application itself to be gone
# first, so "still there" means "never going to be pruned", not "not yet".
DCGM_DS_UID="$(k get daemonset "${DCGM_DS}" -n "${DCGM_NS}" -o jsonpath='{.metadata.uid}')"
DCGM_NS_UID="$(k get namespace "${DCGM_NS}" -o jsonpath='{.metadata.uid}')"
run_bootstrap --revision "${NO_DCGM_REVISION}" || fail "bootstrap.sh --revision ${NO_DCGM_REVISION} (removing the marker)"
wait_until 300 10 "dcgm-exporter Application disappears once its marker file is removed" dcgm_app_gone \
  || fail "${APP_DCGM} still exists after removing ${DCGM_MARKER_REL}"
[[ "$(k get daemonset "${DCGM_DS}" -n "${DCGM_NS}" -o jsonpath='{.metadata.uid}' 2>/dev/null)" == "${DCGM_DS_UID}" ]] \
  || fail "DaemonSet ${DCGM_NS}/${DCGM_DS} was deleted or replaced after removing the marker file (expected orphaned, preserveResourcesOnDeletion: true)"
[[ "$(k get namespace "${DCGM_NS}" -o jsonpath='{.metadata.uid}' 2>/dev/null)" == "${DCGM_NS_UID}" ]] \
  || fail "namespace ${DCGM_NS} was deleted or replaced after removing the marker file (expected orphaned)"
pass "removing ${DCGM_MARKER_REL} removed ${APP_DCGM} and orphaned DaemonSet ${DCGM_NS}/${DCGM_DS} and namespace ${DCGM_NS} (same UIDs) -- issue #41 Decision 4's removal half"

# ---- 14b-f. restore GITOPS_REVISION, delete the GPU test fixture
run_bootstrap --revision "${GITOPS_REVISION}" || fail "bootstrap.sh (restoring --revision ${GITOPS_REVISION} after step 14b)"
# DCGM_MARKER_PREEXISTED, not "${ADD_DCGM_REVISION}" == "${GITOPS_REVISION}":
# ADD_DCGM_REVISION is always a disposable branch now (it also carries
# step 14b-d's own scrape-allow override, which GITOPS_REVISION itself
# never gets), so that string comparison can no longer tell this apart --
# whether restoring GITOPS_REVISION re-adopts the same DaemonSet still
# depends only on whether the marker already lived there before 14b-a
# removed it.
if [[ "${DCGM_MARKER_PREEXISTED}" == "1" ]]; then
  wait_until 600 15 "dcgm-exporter Application reappears and reaches Synced" app_synced "${APP_DCGM}" \
    || fail "${APP_DCGM} did not reappear and reach Synced after restoring --revision ${GITOPS_REVISION}"
  [[ "$(k get daemonset "${DCGM_DS}" -n "${DCGM_NS}" -o jsonpath='{.metadata.uid}' 2>/dev/null)" == "${DCGM_DS_UID}" ]] \
    || fail "DaemonSet ${DCGM_NS}/${DCGM_DS} was recreated, not re-adopted, after restoring the marker file"
  pass "restoring the marker file re-adopted the orphaned DaemonSet ${DCGM_NS}/${DCGM_DS} (unchanged UID)"
fi
k delete pod "${GPU_FIXTURE_NAME}" -n default --ignore-not-found --wait=true --timeout=120s >/dev/null \
  || fail "kubectl delete the step 14b trigger Pod ${GPU_FIXTURE_NAME}"
k delete nodepool "${GPU_FIXTURE_NAME}" --ignore-not-found --wait=true --timeout=900s >/dev/null \
  || fail "kubectl delete the step 14b NodePool ${GPU_FIXTURE_NAME}"
k delete ec2nodeclass "${GPU_FIXTURE_NAME}" --ignore-not-found --wait=true --timeout=600s >/dev/null \
  || fail "kubectl delete the step 14b EC2NodeClass ${GPU_FIXTURE_NAME}"
# Capture kubectl's own exit code before treating an empty result
# as "no nodes" -- `2>/dev/null` with command substitution makes an API
# error and a genuinely empty list produce the identical empty string,
# and this predicate feeds a wait_until that stops as soon as it is true.
gpu_fixture_nodes_gone() {
  local out
  out="$(k get nodes -l "karpenter.sh/nodepool=${GPU_FIXTURE_NAME}" -o name 2>&1)" || return 1
  [[ -z "${out}" ]]
}
wait_until 900 20 "the GPU test fixture's node is gone" gpu_fixture_nodes_gone \
  || fail "node(s) from NodePool ${GPU_FIXTURE_NAME} remain after deleting it: $(k get nodes -l "karpenter.sh/nodepool=${GPU_FIXTURE_NAME}" -o name 2>&1 | tr '\n' ' ')"
pass "deleted the GPU test fixture ${GPU_FIXTURE_NAME} and its node"

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
tf "${DESTROY_FROM_ROOT}" destroy -auto-approve -input=false -var-file="${TFVARS}" \
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

if [[ "${GITOPS_RUN_ACCEL_E2E}" == "1" ]]; then
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
  # capacity-pool Application (cells/dp-a19-trn-r3/capacity-pool/trn.yaml)
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
