#!/usr/bin/env bash
# End-to-end test of issue #34 on a real EKS cell with real GPUs: the
# JobSet add-on delivered by Argo CD, a disposable team onboarded with
# gitops/bootstrap/team-onboard.sh submitting the
# examples/training/pytorch-ddp JobSet under its own identity, Kueue gang
# admission, and checkpoint/resume to Amazon S3 after a worker is killed.
#
# Steps, each mapped to the issue's acceptance criteria (tests/README.md
# has the full table):
#   1. the cell's ${CELL}-jobset-crd and ${CELL}-jobset Applications are
#      Synced (and Healthy where Argo CD reports health), the
#      jobsets.jobset.x-k8s.io CRD is Established, the JobSet controller
#      Deployment is Available, and Kueue's live manager configuration
#      lists jobset.x-k8s.io/jobset;
#   2. team-onboard.sh onboards a disposable team; the real
#      team-rbac-guard admits a Role granting jobsets CRUD and denies one
#      granting jobsets/status; the team's own <team>-deployer identity
#      (kubectl --as, never the admin) can create jobsets but not Kueue
#      LocalQueues, and applies the chart's rendered objects itself;
#   3. gang admission (criterion 3): with the team's ClusterQueue
#      deliberately sized for one Pod fewer than the JobSet needs, the
#      Workload stays without quota and ZERO Pods are created (not a
#      partial set) for UNDERPROVISION_WINDOW_SECONDS; once the quota is
#      raised to exactly what the JobSet needs, the Workload is admitted
#      for every replica at once and every worker Pod reaches Running; the
#      nodes they run on are a light-tier family on the expected capacity
#      type (criterion 4);
#   4. a steady state that writes at least one checkpoint to S3
#      (criterion 1), then one worker Pod is deleted: the JobSet's
#      failurePolicy recreates the WHOLE group (every Pod of the first
#      attempt is gone, not only the deleted one, and status.restarts
#      moves), the restarted Pods log that they resumed from a step at
#      least as new as the latest checkpoint seen before the kill, and a
#      newer checkpoint lands afterwards (criterion 2).
#
# Cleanup (EXIT trap, success or failure): the JobSet and the team
# namespace, the team's AppProject, the test ClusterQueue, the Pod
# Identity association, and every S3 object under this run's own
# sub-prefix. The cluster-wide guards team-onboard.sh applies are removed
# only if they did not exist before this run and no other team namespace
# exists.
#
# Preconditions (this script never pushes to Git and never changes the
# platform's own add-ons):
#   - the cell already opts into the jobset catalog entry
#     (gitops/cells/${CELL}/addons/jobset.yaml at the revision its root
#     Application tracks);
#   - a Kueue ResourceFlavor for a light-tier GPU capacity pool exists
#     (GPU_RESOURCE_FLAVOR), and that pool can launch enough GPUs for
#     E2E_REPLICAS x GPUS_PER_POD;
#   - CHECKPOINT_ROLE_ARN is an IAM role trusted by pods.eks.amazonaws.com
#     that may read and write s3://${CHECKPOINT_BUCKET}/${CHECKPOINT_PREFIX}/*
#     and nothing more (AGENTS.md section 6, least privilege);
#   - the caller's own credentials may list and delete objects under that
#     prefix and create/delete EKS Pod Identity associations.
#
# Required environment (export before running):
#   AWS_PROFILE, AWS_REGION,
#   NAME                 the EKS cluster name (the current kubeconfig
#                        context must point at its endpoint; checked
#                        before any write),
#   CHECKPOINT_BUCKET, CHECKPOINT_PREFIX, CHECKPOINT_ROLE_ARN,
#   GPU_RESOURCE_FLAVOR.
# Optional environment:
#   CELL (NAME; the Argo CD cluster name in Application names),
#   ARGOCD_NAMESPACE (argocd), KUBECTL (kubectl), HELM (helm),
#   PYTHON (python3), E2E_TEAM (t34-<run id>), E2E_REPLICAS (2),
#   GPUS_PER_POD (2), CHECKPOINT_EVERY (20), TOTAL_STEPS (1000000),
#   TRAINING_VALUES_FILE (extra -f values, for example the image),
#   SOURCE_REPO (https://github.com/littlemex/distai-platform.git),
#   UNDERPROVISION_WINDOW_SECONDS (180), READY_TIMEOUT_SECONDS (2400),
#   CHECKPOINT_TIMEOUT_SECONDS (1800), RESTART_TIMEOUT_SECONDS (1800),
#   LIGHT_TIER_FAMILIES ("g5 g6e g7"), EXPECT_CAPACITY_TYPE (spot),
#   E2E_KEEP_ON_FAILURE (0), E2E_WORK_DIR (mktemp -d).
set -euo pipefail

: "${AWS_PROFILE:?export AWS_PROFILE}"
: "${AWS_REGION:?export AWS_REGION}"
: "${NAME:?export NAME (EKS cluster name of the test cell)}"
: "${CHECKPOINT_BUCKET:?export CHECKPOINT_BUCKET (the S3 bucket checkpoints are written to)}"
: "${CHECKPOINT_PREFIX:?export CHECKPOINT_PREFIX (a key prefix in that bucket; this run writes only below <prefix>/<run id>/)}"
: "${CHECKPOINT_ROLE_ARN:?export CHECKPOINT_ROLE_ARN (the IAM role the Pod Identity association grants)}"
: "${GPU_RESOURCE_FLAVOR:?export GPU_RESOURCE_FLAVOR (an existing Kueue ResourceFlavor of a light-tier GPU pool)}"
export AWS_PROFILE AWS_REGION

CELL="${CELL:-${NAME}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
PYTHON="${PYTHON:-python3}"
E2E_REPLICAS="${E2E_REPLICAS:-2}"
GPUS_PER_POD="${GPUS_PER_POD:-2}"
CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-20}"
TOTAL_STEPS="${TOTAL_STEPS:-1000000}"
TRAINING_VALUES_FILE="${TRAINING_VALUES_FILE:-}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/littlemex/distai-platform.git}"
UNDERPROVISION_WINDOW_SECONDS="${UNDERPROVISION_WINDOW_SECONDS:-180}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-2400}"
CHECKPOINT_TIMEOUT_SECONDS="${CHECKPOINT_TIMEOUT_SECONDS:-1800}"
RESTART_TIMEOUT_SECONDS="${RESTART_TIMEOUT_SECONDS:-1800}"
LIGHT_TIER_FAMILIES="${LIGHT_TIER_FAMILIES:-g5 g6e g7}"
EXPECT_CAPACITY_TYPE="${EXPECT_CAPACITY_TYPE:-spot}"
E2E_KEEP_ON_FAILURE="${E2E_KEEP_ON_FAILURE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRAINING_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TRAINING_ROOT}/../.." && pwd)"
CHART="${TRAINING_ROOT}/pytorch-ddp"
TEAM_ONBOARD="${REPO_ROOT}/gitops/bootstrap/team-onboard.sh"
WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"

# shellcheck source=chart-contract.sh
. "${SCRIPT_DIR}/chart-contract.sh"

SHORT_ID="$(date -u +%m%d%H%M%S)"
RUN_ID="t34-e2e-${SHORT_ID}"
TEAM="${E2E_TEAM:-t34-${SHORT_ID}}"
DEPLOYER="system:serviceaccount:${TEAM}:${TEAM}-deployer"
TRAINER_SA="${TEAM}-trainer"
CLUSTER_QUEUE="${TEAM}-cq"
LOCAL_QUEUE="${TEAM}-lq"
RUN_PREFIX="${CHECKPOINT_PREFIX%/}/${RUN_ID}"
RENDERED="${WORK_DIR}/rendered.yaml"
APP_CRD="${CELL}-jobset-crd"
APP_JOBSET="${CELL}-jobset"

CREATED_ANYTHING=0
POD_IDENTITY_ASSOCIATION_ID=""
GUARDS_PREEXISTED=1
FAILED_STEP=""
TORN_DOWN=0

# ---------------------------------------------------------------- helpers

# Logs go to stderr, so a helper's own log lines never end up in a
# caller's $(...) capture.
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
pass() { log "PASS $*"; }
info() { log "INFO $*"; }
fail() {
  FAILED_STEP="$*"
  log "FAIL $*"
  exit 1
}
require_bin() { command -v "$1" >/dev/null 2>&1 || fail "prerequisite: $1 not found"; }
k() { "${KUBECTL}" "$@"; }
kn() { "${KUBECTL}" -n "${TEAM}" "$@"; }
# as_deployer: the team's own identity, never the admin running this script.
as_deployer() { "${KUBECTL}" -n "${TEAM}" --as="${DEPLOYER}" "$@"; }
py() { "${PYTHON}" -c "$@"; }

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

app_field() { k get application "$1" -n "${ARGOCD_NAMESPACE}" -o jsonpath="$2" 2>/dev/null; }
# A CRD-only Application may report no health of its own (gitops/README.md
# says the same of karpenter-crd); Synced is required, and Healthy is
# required whenever Argo CD reports a health status at all.
app_synced_healthy_or_unreported() {
  local h
  [[ "$(app_field "$1" '{.status.sync.status}')" == "Synced" ]] || return 1
  h="$(app_field "$1" '{.status.health.status}')"
  [[ -z "${h}" || "${h}" == "Healthy" ]]
}
app_synced_healthy() {
  [[ "$(app_field "$1" '{.status.sync.status}')" == "Synced" && "$(app_field "$1" '{.status.health.status}')" == "Healthy" ]]
}

# The rendered JobSet's own facts, read from the render (never from the
# chart's values.yaml): name, worker container name, per-Pod requests.
jobset_fact() {
  py '
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if isinstance(d, dict)]
js = [d for d in docs if d.get("kind") == "JobSet"][0]
rj = js["spec"]["replicatedJobs"][0]
pod = rj["template"]["spec"]["template"]["spec"]
acc = ("nvidia.com/gpu", "aws.amazon.com/neuron")
what = sys.argv[2]
if what == "name":
    print(js["metadata"]["name"])
elif what == "container":
    print(next(c["name"] for c in pod["containers"] if any(a in (c.get("resources") or {}).get("limits", {}) for a in acc)))
elif what == "replicas":
    print(rj.get("replicas", 1) * (rj["template"]["spec"].get("parallelism") or 1))
' "${RENDERED}" "$1"
}

# ClusterQueue resource quotas for the rendered JobSet: every resource any
# container requests (requests, else limits) is covered; the accelerator
# gets exactly MODE pods worth ("all" = every replica, "short" = one Pod
# fewer), every other resource twice the full total, so only the
# accelerator can ever be the reason for (non-)admission.
quota_json() {
  py '
import json, math, re, sys, yaml
def qty(v):
    s = str(v); m = re.fullmatch(r"([0-9.]+)([A-Za-z]*)", s)
    num, unit = float(m.group(1)), m.group(2)
    mult = {"": 1, "m": 1e-3, "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "K": 1e3, "M": 1e6, "G": 1e9}[unit]
    return num * mult
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if isinstance(d, dict)]
js = [d for d in docs if d.get("kind") == "JobSet"][0]
rj = js["spec"]["replicatedJobs"][0]
pods = rj.get("replicas", 1) * (rj["template"]["spec"].get("parallelism") or 1)
spec = rj["template"]["spec"]["template"]["spec"]
per = {}
for c in spec["containers"]:
    r = c.get("resources") or {}
    for name, v in {**(r.get("limits") or {}), **(r.get("requests") or {})}.items():
        per[name] = per.get(name, 0) + qty(v)
acc = [a for a in ("nvidia.com/gpu", "aws.amazon.com/neuron") if a in per]
mode = sys.argv[2]
out = []
for name, v in sorted(per.items()):
    if name in acc:
        n = v * (pods if mode == "all" else pods - 1)
    else:
        n = v * pods * 2
    # cpu in millicores, everything else (memory bytes, device counts) as
    # a whole number, rounded up.
    q = f"{math.ceil(n * 1000)}m" if name == "cpu" else str(math.ceil(n))
    out.append({"name": name, "nominalQuota": q})
print(json.dumps({"covered": sorted(per), "resources": out}))
' "${RENDERED}" "$1"
}

apply_cluster_queue() {
  local q
  q="$(quota_json "$1")" || return 1
  py '
import json, sys
q = json.loads(sys.argv[1])
print(json.dumps({
  "apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "ClusterQueue",
  "metadata": {"name": sys.argv[2], "labels": {"distai-platform-e2e": sys.argv[5]}},
  "spec": {
    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": sys.argv[3]}},
    "resourceGroups": [{"coveredResources": q["covered"], "flavors": [{"name": sys.argv[4], "resources": q["resources"]}]}],
  },
}))' "${q}" "${CLUSTER_QUEUE}" "${TEAM}" "${GPU_RESOURCE_FLAVOR}" "${RUN_ID}" | k apply -f - >/dev/null
}

JOBSET_NAME=""
WORKER_CONTAINER=""
JOBSET_PODS_SELECTOR() { printf 'jobset.sigs.k8s.io/jobset-name=%s' "${JOBSET_NAME}"; }
pod_count() { kn get pods -l "$(JOBSET_PODS_SELECTOR)" -o name 2>/dev/null | wc -l | tr -d ' '; }
# workload_json: the Kueue Workload owned by this run's JobSet, or "".
workload_json() {
  kn get workloads.kueue.x-k8s.io -o json 2>/dev/null | py '
import json, sys
name = sys.argv[1]
for w in json.load(sys.stdin).get("items", []):
    if any(o.get("kind") == "JobSet" and o.get("name") == name for o in w["metadata"].get("ownerReferences") or []):
        print(json.dumps(w)); break
' "${JOBSET_NAME}"
}
workload_condition() {
  workload_json | py '
import json, sys
t = sys.argv[1]
raw = sys.stdin.read().strip()
w = json.loads(raw) if raw else {}
print(next((c["status"] for c in (w.get("status") or {}).get("conditions") or [] if c["type"] == t), ""))' "$1"
}
workload_exists() { [[ -n "$(workload_json)" ]]; }
workload_admitted() { [[ "$(workload_condition Admitted)" == "True" ]]; }
# running_pods: names of non-terminating Running Pods of this JobSet,
# whatever attempt they belong to. There is no per-attempt label to
# filter by for the restartStrategy this chart uses (BlockingRecreate):
# JobSet's own well-known labels/annotations
# (kubernetes-sigs/jobset v0.13.1, api/jobset/v1alpha2/jobset_types.go)
# define jobset.sigs.k8s.io/in-place-restart-attempt only for the
# InPlaceRestart strategy, nothing equivalent for Recreate/
# BlockingRecreate -- there, a restart deletes and recreates the Job (and
# therefore the Pod) objects themselves, so the Pod's own UID is the
# per-attempt signal, not a label. Callers that need "this attempt only"
# compare metadata.uid against a snapshot taken before the restart
# (uids_before/first_attempt_gone below), not this function.
running_pods() {
  kn get pods -l "$(JOBSET_PODS_SELECTOR)" -o json | py '
import json, sys
for p in json.load(sys.stdin)["items"]:
    if not p["metadata"].get("deletionTimestamp") and (p.get("status") or {}).get("phase") == "Running":
        print(p["metadata"]["name"])'
}
all_running() { [[ "$(running_pods | wc -l | tr -d ' ')" -eq "${E2E_REPLICAS}" ]]; }

# checkpoint_steps: one step number per checkpoint object under this
# run's own prefix (chart-contract.sh: the last run of digits in the key,
# relative to the prefix), sorted ascending; empty if none.
checkpoint_steps() {
  aws s3api list-objects-v2 --bucket "${CHECKPOINT_BUCKET}" --prefix "${RUN_PREFIX}/" \
    --query 'Contents[].Key' --output json 2>/dev/null | py '
import json, re, sys
raw = sys.stdin.read().strip()
keys = json.loads(raw) if raw and raw != "null" else []
pre = sys.argv[1]
steps = sorted({int(re.findall(r"[0-9]+", k[len(pre):])[-1]) for k in keys if re.findall(r"[0-9]+", k[len(pre):])})
print("\n".join(map(str, steps)))' "${RUN_PREFIX}/"
}
latest_checkpoint() { checkpoint_steps | tail -n1; }
have_checkpoint() { [[ -n "$(latest_checkpoint)" ]]; }

# --------------------------------------------------------------- cleanup

teardown() {
  local bad=0 others
  [[ "${CREATED_ANYTHING}" -eq 1 ]] || return 0
  info "teardown: deleting JobSet, namespace ${TEAM}, AppProject ${TEAM}, ClusterQueue ${CLUSTER_QUEUE}"
  [[ -n "${JOBSET_NAME}" ]] && kn delete jobsets.jobset.x-k8s.io "${JOBSET_NAME}" --ignore-not-found --wait=true --timeout=10m >/dev/null 2>&1
  k delete namespace "${TEAM}" --ignore-not-found --wait=true --timeout=15m >/dev/null 2>&1 \
    || { log "FAIL teardown: namespace ${TEAM} not deleted"; bad=1; }
  k delete appproject "${TEAM}" -n "${ARGOCD_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 \
    || { log "FAIL teardown: AppProject ${TEAM} not deleted"; bad=1; }
  k delete clusterqueues.kueue.x-k8s.io "${CLUSTER_QUEUE}" --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 \
    || { log "FAIL teardown: ClusterQueue ${CLUSTER_QUEUE} not deleted"; bad=1; }
  if [[ -n "${POD_IDENTITY_ASSOCIATION_ID}" ]]; then
    aws eks delete-pod-identity-association --cluster-name "${NAME}" --association-id "${POD_IDENTITY_ASSOCIATION_ID}" >/dev/null \
      || { log "FAIL teardown: Pod Identity association ${POD_IDENTITY_ASSOCIATION_ID} not deleted"; bad=1; }
  fi
  # Only this run's own sub-prefix, never the caller's CHECKPOINT_PREFIX itself.
  aws s3 rm "s3://${CHECKPOINT_BUCKET}/${RUN_PREFIX}/" --recursive >/dev/null \
    || { log "FAIL teardown: objects under s3://${CHECKPOINT_BUCKET}/${RUN_PREFIX}/ not deleted"; bad=1; }
  if [[ -n "$(aws s3api list-objects-v2 --bucket "${CHECKPOINT_BUCKET}" --prefix "${RUN_PREFIX}/" --query 'Contents[].Key' --output text 2>/dev/null | grep -v '^None$' || true)" ]]; then
    log "FAIL teardown: objects remain under s3://${CHECKPOINT_BUCKET}/${RUN_PREFIX}/"
    bad=1
  else
    pass "no checkpoint object of this run remains in S3"
  fi
  if [[ "${GUARDS_PREEXISTED}" -eq 0 ]]; then
    others="$(k get namespaces -l distai.dev/team -o name 2>/dev/null | grep -v "^namespace/${TEAM}$" || true)"
    if [[ -z "${others}" ]]; then
      info "teardown: removing the team guards this run's onboarding created (no other team namespace exists)"
      k delete -f "${REPO_ROOT}/gitops/bootstrap/team-rbac-guard.yaml" --ignore-not-found >/dev/null 2>&1 || bad=1
      k delete -f "${REPO_ROOT}/gitops/bootstrap/team-namespace-guard.yaml" --ignore-not-found >/dev/null 2>&1 || bad=1
    else
      info "teardown: leaving the team guards in place (other team namespaces exist: $(tr '\n' ' ' <<<"${others}"))"
    fi
  fi
  TORN_DOWN=1
  return "${bad}"
}

cleanup() {
  local rc=$?
  set +e
  if [[ "${TORN_DOWN}" -eq 0 && "${CREATED_ANYTHING}" -eq 1 ]]; then
    if [[ "${rc}" -ne 0 && "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving namespace ${TEAM}, AppProject ${TEAM}, ClusterQueue ${CLUSTER_QUEUE}, Pod Identity association ${POD_IDENTITY_ASSOCIATION_ID:-none} and s3://${CHECKPOINT_BUCKET}/${RUN_PREFIX}/ in place"
    else
      teardown || { [[ "${rc}" -eq 0 ]] && rc=1; FAILED_STEP="${FAILED_STEP:-teardown left resources behind}"; }
    fi
  fi
  echo >&2
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

for b in aws jq "${KUBECTL}" "${HELM}" "${PYTHON}"; do require_bin "${b}"; done
"${PYTHON}" -c 'import yaml' 2>/dev/null || fail "preflight: ${PYTHON} has no PyYAML (pip install pyyaml==6.0.2)"
[[ "${E2E_REPLICAS}" =~ ^[0-9]+$ && "${E2E_REPLICAS}" -ge 2 ]] \
  || fail "preflight: E2E_REPLICAS must be >= 2 -- with one Pod, 'all workers or none' cannot be told apart from 'partial' (acceptance criterion 3)"
aws sts get-caller-identity --query Arn --output text >/dev/null \
  || fail "preflight: AWS credentials for profile ${AWS_PROFILE} are not valid"
for f in "${CHART}/Chart.yaml" "${TEAM_ONBOARD}"; do [[ -f "${f}" ]] || fail "preflight: ${f} is missing"; done
[[ -z "${TRAINING_VALUES_FILE}" || -f "${TRAINING_VALUES_FILE}" ]] || fail "preflight: TRAINING_VALUES_FILE ${TRAINING_VALUES_FILE} does not exist"

# Wrong-cluster guard, before any write.
CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${NAME}" --query cluster.endpoint --output text)" \
  || fail "preflight: aws eks describe-cluster --name ${NAME} failed"
got_endpoint="$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "${got_endpoint%/}" == "${CLUSTER_ENDPOINT%/}" ]] \
  || fail "preflight: the current kubeconfig context points at ${got_endpoint}, not cluster ${NAME}"
k get namespace "${TEAM}" >/dev/null 2>&1 && fail "preflight: namespace ${TEAM} already exists; refusing to reuse it"
k get resourceflavors.kueue.x-k8s.io "${GPU_RESOURCE_FLAVOR}" >/dev/null 2>&1 \
  || fail "preflight: Kueue ResourceFlavor ${GPU_RESOURCE_FLAVOR} does not exist"
aws s3api head-bucket --bucket "${CHECKPOINT_BUCKET}" >/dev/null 2>&1 \
  || fail "preflight: bucket ${CHECKPOINT_BUCKET} is not reachable with the caller's credentials"
[[ -z "$(checkpoint_steps)" ]] || fail "preflight: s3://${CHECKPOINT_BUCKET}/${RUN_PREFIX}/ is not empty"
if k get validatingadmissionpolicy team-rbac-guard >/dev/null 2>&1; then GUARDS_PREEXISTED=1; else GUARDS_PREEXISTED=0; fi

# The chart, rendered once with this run's values (key names: chart-contract.sh).
helm_args=(template ddp "${CHART}" --namespace "${TEAM}")
[[ -n "${TRAINING_VALUES_FILE}" ]] && helm_args+=(-f "${TRAINING_VALUES_FILE}")
helm_args+=(
  --set-string "${TRAINING_KEY_QUEUE_NAME}=${LOCAL_QUEUE}"
  --set-string "${TRAINING_KEY_SERVICE_ACCOUNT}=${TRAINER_SA}"
  --set-string "${TRAINING_KEY_CHECKPOINT_BUCKET}=${CHECKPOINT_BUCKET}"
  --set-string "${TRAINING_KEY_CHECKPOINT_PREFIX}=${RUN_PREFIX}"
  --set-string "${TRAINING_KEY_CHECKPOINT_REGION}=${AWS_REGION}"
  --set "${TRAINING_KEY_REPLICAS}=${E2E_REPLICAS}"
  --set "${TRAINING_KEY_GPUS_PER_POD}=${GPUS_PER_POD}"
  --set "${TRAINING_KEY_CHECKPOINT_EVERY}=${CHECKPOINT_EVERY}"
  --set "${TRAINING_KEY_TOTAL_STEPS}=${TOTAL_STEPS}"
)
[[ -f "${CHART}/Chart.lock" ]] && { "${HELM}" dependency build "${CHART}" >/dev/null || fail "preflight: helm dependency build ${CHART}"; }
"${HELM}" "${helm_args[@]}" >"${RENDERED}" || fail "preflight: helm template ${CHART} with this run's values"
"${PYTHON}" "${SCRIPT_DIR}/check_training_render.py" "${RENDERED}" --queue "${LOCAL_QUEUE}" \
  --service-account "${TRAINER_SA}" --bucket "${CHECKPOINT_BUCKET}" --prefix "${RUN_PREFIX}" \
  --replicas "${E2E_REPLICAS}" --team-onboard "${TEAM_ONBOARD}" >"${WORK_DIR}/render-check.log" 2>&1 \
  || fail "preflight: the rendered chart fails check_training_render.py ($(grep '^FAIL' "${WORK_DIR}/render-check.log" | tr '\n' ';'))"
JOBSET_NAME="$(jobset_fact name)"
WORKER_CONTAINER="$(jobset_fact container)"
[[ "$(jobset_fact replicas)" -eq "${E2E_REPLICAS}" ]] || fail "preflight: the render has $(jobset_fact replicas) worker Pods, not E2E_REPLICAS=${E2E_REPLICAS} (check ${TRAINING_KEY_REPLICAS} in chart-contract.sh)"
pass "preflight: tools, credentials, cluster ${NAME} (endpoint matches), flavor ${GPU_RESOURCE_FLAVOR}, empty run prefix, chart renders JobSet ${JOBSET_NAME} (${E2E_REPLICAS} workers, container ${WORKER_CONTAINER})"

# ------------------------- 1. the add-on pair is delivered and running
# (acceptance criterion 1's precondition: a cell that opted in)

k get application "${APP_JOBSET}" -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 \
  || fail "step 1: no Application ${APP_JOBSET} -- the cell has not opted into the jobset catalog entry (gitops/cells/${CELL}/addons/jobset.yaml)"
wait_until 900 15 "${APP_CRD} Synced (Healthy if reported)" app_synced_healthy_or_unreported "${APP_CRD}" \
  || fail "step 1: ${APP_CRD} is not Synced (sync=$(app_field "${APP_CRD}" '{.status.sync.status}'), health=$(app_field "${APP_CRD}" '{.status.health.status}'))"
wait_until 900 15 "${APP_JOBSET} Synced and Healthy" app_synced_healthy "${APP_JOBSET}" \
  || fail "step 1: ${APP_JOBSET} is not Synced+Healthy (sync=$(app_field "${APP_JOBSET}" '{.status.sync.status}'), health=$(app_field "${APP_JOBSET}" '{.status.health.status}'))"
[[ "$(k get crd jobsets.jobset.x-k8s.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}')" == "True" ]] \
  || fail "step 1: CRD jobsets.jobset.x-k8s.io is not Established"
JOBSET_NS="$(app_field "${APP_JOBSET}" '{.spec.destination.namespace}')"
deploys="$(k get deployments -n "${JOBSET_NS}" -o json | py '
import json, sys
ds = json.load(sys.stdin)["items"]
bad = [d["metadata"]["name"] for d in ds if (d.get("status") or {}).get("availableReplicas", 0) < (d["spec"].get("replicas") or 1)]
print(len(ds), " ".join(bad))')"
[[ "${deploys%% *}" -ge 1 && -z "${deploys#* }" ]] || fail "step 1: JobSet controller Deployment(s) in ${JOBSET_NS} not Available (count and unavailable: ${deploys})"
k get configmaps -n kueue-system -o json | grep -q 'jobset.x-k8s.io/jobset' \
  || fail "step 1: no ConfigMap in kueue-system names jobset.x-k8s.io/jobset (Kueue's live integrations list)"
pass "step 1: ${APP_CRD} and ${APP_JOBSET} Synced/Healthy, CRD Established, controller in ${JOBSET_NS} Available, Kueue integrates jobset.x-k8s.io/jobset"

# ------------------------- 2. onboard a team; its own identity submits

CREATED_ANYTHING=1
# team-onboard.sh learns the cell only from `terraform output -json`; this
# run builds the three outputs it reads from read-only facts instead.
TF_OUTPUTS="${WORK_DIR}/tf-outputs.json"
jq -n --arg n "${NAME}" --arg e "${CLUSTER_ENDPOINT}" --arg a "${ARGOCD_NAMESPACE}" \
  '{cluster_name: {value: $n}, cluster_endpoint: {value: $e}, argocd_namespace: {value: $a}}' >"${TF_OUTPUTS}"
bash "${TEAM_ONBOARD}" --team "${TEAM}" --tf-outputs "${TF_OUTPUTS}" --source-repo "${SOURCE_REPO}" >"${WORK_DIR}/onboard.log" 2>&1 \
  || fail "step 2: team-onboard.sh --team ${TEAM} failed: $(tail -n 5 "${WORK_DIR}/onboard.log" | tr '\n' ';')"
k label namespace "${TEAM}" "distai-platform-e2e=${RUN_ID}" >/dev/null
pass "step 2: team-onboard.sh onboarded ${TEAM} (namespace, ${TEAM}-deployer, its Role, AppProject)"

# The real API server's team-rbac-guard, both directions, for the widening
# (gitops/tests/check_team_rbac_guard.py is the offline version).
kn apply -f - >/dev/null <<YAML || fail "step 2: team-rbac-guard denied a Role granting jobsets CRUD in ${TEAM}"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: e2e-jobset-crud}
rules:
  - apiGroups: ["jobset.x-k8s.io"]
    resources: ["jobsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
YAML
kn delete role e2e-jobset-crud >/dev/null
if err="$(kn apply -f - 2>&1 <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: e2e-jobset-status}
rules:
  - apiGroups: ["jobset.x-k8s.io"]
    resources: ["jobsets/status"]
    verbs: ["get", "update", "patch"]
YAML
)"; then
  fail "step 2: team-rbac-guard ADMITTED a Role granting jobsets/status in ${TEAM}"
fi
[[ "${err}" == *"may grant only"* ]] || fail "step 2: the jobsets/status Role was refused, but not by team-rbac-guard's own rule: ${err}"
kn get role e2e-jobset-status >/dev/null 2>&1 && fail "step 2: Role e2e-jobset-status exists despite the refusal"
pass "step 2: the live team-rbac-guard admits jobsets CRUD and denies jobsets/status in ${TEAM}"

[[ "$(as_deployer auth can-i create jobsets.jobset.x-k8s.io)" == "yes" ]] \
  || fail "step 2: ${DEPLOYER} cannot create jobsets in ${TEAM} (team-onboard.sh step 3's Role)"
[[ "$(as_deployer auth can-i create localqueues.kueue.x-k8s.io 2>/dev/null || true)" == "no" ]] \
  || fail "step 2: ${DEPLOYER} can create Kueue LocalQueues -- a team must not size its own queue"
pass "step 2: ${DEPLOYER} can create jobsets, and cannot create LocalQueues"

# Admin-owned envelope (team-onboard.sh deliberately creates no queue):
# the ClusterQueue starts one Pod short of what the JobSet needs.
apply_cluster_queue short || fail "step 2: creating ClusterQueue ${CLUSTER_QUEUE} (one Pod short)"
kn apply -f - >/dev/null <<YAML || fail "step 2: creating LocalQueue ${LOCAL_QUEUE}"
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata: {name: ${LOCAL_QUEUE}}
spec: {clusterQueue: ${CLUSTER_QUEUE}}
YAML

POD_IDENTITY_ASSOCIATION_ID="$(aws eks create-pod-identity-association --cluster-name "${NAME}" \
  --namespace "${TEAM}" --service-account "${TRAINER_SA}" --role-arn "${CHECKPOINT_ROLE_ARN}" \
  --query association.associationId --output text)" \
  || fail "step 2: creating the Pod Identity association for ${TEAM}/${TRAINER_SA}"

# The whole rendered chart, applied by the team's own identity.
as_deployer apply -f "${RENDERED}" >"${WORK_DIR}/deployer-apply.log" 2>&1 \
  || fail "step 2: ${DEPLOYER} could not apply the rendered chart: $(tr '\n' ';' <"${WORK_DIR}/deployer-apply.log")"
kn get jobsets.jobset.x-k8s.io "${JOBSET_NAME}" >/dev/null || fail "step 2: JobSet ${JOBSET_NAME} does not exist after the apply"
pass "step 2: ${DEPLOYER} itself (kubectl --as, not the admin) applied the rendered chart; JobSet ${JOBSET_NAME} exists"

# ---------------- 3. gang admission: zero Pods short of quota, then all

wait_until 300 5 "a Kueue Workload owned by JobSet ${JOBSET_NAME}" workload_exists \
  || fail "step 3: Kueue created no Workload for JobSet ${JOBSET_NAME} (is the kueue.x-k8s.io/queue-name label on it, and jobset.x-k8s.io/jobset integrated?)"
# Under-provisioned: quota for E2E_REPLICAS-1 Pods. Without gang admission,
# that is enough to start a partial set; with it, nothing starts.
window_end=$(( $(date +%s) + UNDERPROVISION_WINDOW_SECONDS ))
while (( $(date +%s) < window_end )); do
  n="$(pod_count)"
  [[ "${n}" -eq 0 ]] || fail "step 3: ${n} Pod(s) of JobSet ${JOBSET_NAME} exist with quota for only $((E2E_REPLICAS - 1)) of ${E2E_REPLICAS} -- a partial set started (criterion 3)"
  [[ "$(workload_condition QuotaReserved)" != "True" ]] || fail "step 3: the Workload reserved quota the ClusterQueue does not have"
  [[ "$(kn get jobsets.jobset.x-k8s.io "${JOBSET_NAME}" -o jsonpath='{.spec.suspend}')" == "true" ]] \
    || fail "step 3: JobSet ${JOBSET_NAME} is not suspended while its Workload has no quota"
  sleep 10
done
pass "step 3: one Pod short of quota for ${UNDERPROVISION_WINDOW_SECONDS}s: zero Pods created, Workload QuotaReserved=$(workload_condition QuotaReserved), JobSet suspended (criterion 3: all or none)"

apply_cluster_queue all || fail "step 3: raising ClusterQueue ${CLUSTER_QUEUE} to the JobSet's full size"
wait_until 600 5 "the Workload Admitted" workload_admitted || fail "step 3: the Workload was not admitted once the quota fits"
admitted_count="$(workload_json | py '
import json, sys
w = json.load(sys.stdin)
print(sum(a.get("count", 0) for a in ((w.get("status") or {}).get("admission") or {}).get("podSetAssignments") or []))')"
[[ "${admitted_count}" -eq "${E2E_REPLICAS}" ]] \
  || fail "step 3: the Workload was admitted for ${admitted_count} Pod(s), not all ${E2E_REPLICAS}"
wait_until "${READY_TIMEOUT_SECONDS}" 15 "all ${E2E_REPLICAS} worker Pods Running" all_running \
  || fail "step 3: not every worker Pod reached Running ($(kn get pods -l "$(JOBSET_PODS_SELECTOR)" -o wide 2>&1 | tr '\n' ';'))"
pass "step 3: with the quota sized to fit, the Workload was admitted for all ${E2E_REPLICAS} Pods at once and every worker Pod is Running"

# Criterion 4: a light-tier GPU pool on the expected capacity type.
for pod in $(running_pods); do
  node="$(kn get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
  itype="$(k get node "${node}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')"
  ctype="$(k get node "${node}" -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}')"
  family="${itype%%.*}"
  [[ " ${LIGHT_TIER_FAMILIES} " == *" ${family} "* ]] || fail "step 3: Pod ${pod} runs on ${itype}, not a light-tier family (${LIGHT_TIER_FAMILIES})"
  [[ "${ctype}" == "${EXPECT_CAPACITY_TYPE}" ]] || fail "step 3: Pod ${pod}'s node is ${ctype}, not ${EXPECT_CAPACITY_TYPE}"
  info "worker ${pod} on ${itype} (${ctype})"
done
pass "step 3: every worker runs on a light-tier family (${LIGHT_TIER_FAMILIES}) on ${EXPECT_CAPACITY_TYPE} capacity (criterion 4)"

# ------------- 4. checkpoint to S3; kill one worker; whole-group resume

wait_until "${CHECKPOINT_TIMEOUT_SECONDS}" 20 "a checkpoint under s3://${CHECKPOINT_BUCKET}/${RUN_PREFIX}/" have_checkpoint \
  || fail "step 4: no checkpoint object landed under s3://${CHECKPOINT_BUCKET}/${RUN_PREFIX}/ (criterion 1)"
all_running || fail "step 4: not every worker is still Running when the first checkpoint landed"
pass "step 4: steady state, all ${E2E_REPLICAS} workers Running and checkpoint step $(latest_checkpoint) in S3 (criterion 1)"

restarts_before="$(kn get jobsets.jobset.x-k8s.io "${JOBSET_NAME}" -o jsonpath='{.status.restarts}')"
restarts_before="${restarts_before:-0}"
mapfile -t uids_before < <(kn get pods -l "$(JOBSET_PODS_SELECTOR)" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}')
step_before_kill="$(latest_checkpoint)"
victim="$(running_pods | sort | tail -n1)"
kn delete pod "${victim}" --wait=false >/dev/null || fail "step 4: deleting worker Pod ${victim}"
info "deleted worker ${victim}; latest checkpoint before the kill: step ${step_before_kill}"

restarted() {
  local r
  r="$(kn get jobsets.jobset.x-k8s.io "${JOBSET_NAME}" -o jsonpath='{.status.restarts}')"
  [[ "${r:-0}" -gt "${restarts_before}" ]]
}
wait_until "${RESTART_TIMEOUT_SECONDS}" 10 "JobSet status.restarts above ${restarts_before}" restarted \
  || fail "step 4: JobSet ${JOBSET_NAME}'s failurePolicy did not restart the group after ${victim} was deleted (criterion 2)"
ATTEMPT="$(kn get jobsets.jobset.x-k8s.io "${JOBSET_NAME}" -o jsonpath='{.status.restarts}')"
first_attempt_gone() {
  local live u
  live="$(kn get pods -l "$(JOBSET_PODS_SELECTOR)" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}')"
  for u in "${uids_before[@]}"; do grep -qx "${u}" <<<"${live}" && return 1; done
  return 0
}
wait_until "${RESTART_TIMEOUT_SECONDS}" 10 "every Pod of the first attempt gone" first_attempt_gone \
  || fail "step 4: a Pod of the first attempt survived -- only the deleted Pod was replaced, not the whole group (criterion 2)"
wait_until "${READY_TIMEOUT_SECONDS}" 15 "all ${E2E_REPLICAS} Pods of restart attempt ${ATTEMPT} Running (status.restarts=${ATTEMPT})" all_running \
  || fail "step 4: the restarted group did not reach Running ($(kn get pods -l "$(JOBSET_PODS_SELECTOR)" -o wide 2>&1 | tr '\n' ';'))"
pass "step 4: deleting ${victim} restarted the whole group: every first-attempt Pod replaced, ${E2E_REPLICAS} Pods of attempt ${ATTEMPT} Running (criterion 2)"

# NOTE (chart-contract.sh): the training script must print a line matching
# TRAINING_RESUME_LOG_REGEX with the step it loaded. A step at least as new
# as the last checkpoint seen before the kill -- and above zero -- is a
# resume; a cold start prints no such line, or step 0.
resumed_step() {
  local pod
  for pod in $(running_pods); do  # first_attempt_gone already passed: every current Pod is this attempt
    kn logs "${pod}" -c "${WORKER_CONTAINER}" 2>/dev/null
  done | py '
import re, sys
steps = [int(m.group(1)) for line in sys.stdin for m in [re.search(sys.argv[1], line)] if m]
print(max(steps) if steps else "")' "${TRAINING_RESUME_LOG_REGEX}"
}
has_resumed() { [[ -n "$(resumed_step)" ]]; }
wait_until 900 15 "a '${TRAINING_RESUME_LOG_REGEX}' line in the restarted workers' logs" has_resumed \
  || fail "step 4: no restarted worker logged '${TRAINING_RESUME_LOG_REGEX}' -- the job started over instead of resuming (criterion 2)"
RESUMED="$(resumed_step)"
[[ "${RESUMED}" -gt 0 && "${RESUMED}" -ge "${step_before_kill}" ]] \
  || fail "step 4: the restarted job resumed from step ${RESUMED}, older than the checkpoint at step ${step_before_kill} seen before the kill (criterion 2)"
progressed() { [[ "$(latest_checkpoint)" -gt "${RESUMED}" ]]; }
wait_until "${CHECKPOINT_TIMEOUT_SECONDS}" 20 "a checkpoint newer than step ${RESUMED}" progressed \
  || fail "step 4: no checkpoint newer than the resumed step ${RESUMED} landed -- the restarted job is not making progress"
pass "step 4: the restarted job resumed from step ${RESUMED} (checkpoint before the kill: ${step_before_kill}) and wrote checkpoint step $(latest_checkpoint) after it (criterion 2)"

# --------------------------------------------------------- 5. teardown

teardown || fail "teardown left resources behind"
