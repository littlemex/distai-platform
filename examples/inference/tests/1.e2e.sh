#!/usr/bin/env bash
# End-to-end test of examples/inference/vllm/{disagg-pd,agg-baseline} and
# the shared scorer on a real EKS cell with real GPUs and real traffic.
# It runs against an existing cell (built by infra/foundation, with
# Karpenter, the NVIDIA device plugin and the EFA device plugin running);
# it creates only its own GPU NodePools, one EC2NodeClass and one
# namespace, and removes all of them again, success or failure.
#
# Maps to the interface contract's acceptance criteria:
#   1. (static, covered by tests/0.static.sh -- re-run here as a preflight);
#   2. with default values, the prefill and decode Deployments reach Ready
#      on two different nodes, each on a node labeled with its own
#      distai.dev/pd-role value, and a request through the proxy returns a
#      generated completion that the prefill pod prefilled and the decode
#      pod decoded (both pods' own vLLM counters move);
#   3. both roles forced onto one node (placement.sameNodeMeasurement=true, placement.enforceAntiAffinity=false):
#      with transport.forceEfaSameNode=true the node's EFA hardware
#      counters increase during requests; with it false they do not
#      move at all;
#   4. score.py on a real `vllm bench serve --save-detailed` result from
#      disagg-pd writes a summary with non-null joint_attainment_share and
#      goodput_per_gpu;
#   5. the same for agg-baseline on the same nodes, with the same load and
#      SLO, so the two summaries compare like for like;
#   6. teardown leaves no node, instance, launch template or EBS volume
#      created for this run (tag-based sweep, the same approach as
#      gitops/tests/1.e2e.sh and infra/foundation/tests/1.e2e.sh).
#
# Required environment (export before running):
#   AWS_PROFILE, AWS_REGION,
#   NAME            the EKS cluster name of the test cell (the current
#                   kubeconfig context must point at this cluster's
#                   endpoint; checked before any write),
#   BASE_NODECLASS  an existing EC2NodeClass in the cell to copy subnets,
#                   security groups, role and AMI selection from (the copy
#                   gets this run's own name and tags),
#   GPU_INSTANCE_TYPE  an EFA-capable GPU instance type with enough GPUs on
#                   one node for one prefill and one decode engine together
#                   (criterion 3 puts both on one node),
#   MODEL_ID        the model the charts serve (the "model" field of every
#                   request and the bench tool's tokenizer; the bench Job
#                   downloads that tokenizer itself, so pick a model that
#                   needs no access token, or bake it into VLLM_BENCH_IMAGE).
# Optional environment:
#   KUBECTL (kubectl), HELM (helm), PYTHON (python3),
#   DISAGG_VALUES_FILE, AGG_VALUES_FILE (extra -f values for each chart,
#     for example the model and image; none by default),
#   PROXY_SERVICE (the disagg-pd proxy Service; discovered by default as the
#     one Service whose selector matches neither role's pods),
#   CAPACITY_TYPE (on-demand), E2E_NAMESPACE (pd-e2e-<run id>),
#   VLLM_BENCH_IMAGE (vllm/vllm-openai:v0.34.0),
#   CURL_IMAGE (curlimages/curl:8.11.1),
#   PROBE_IMAGE (public.ecr.aws/docker/library/busybox:1.37.0),
#   BENCH_NUM_PROMPTS (200), BENCH_REQUEST_RATE (4), BENCH_INPUT_LEN (1024),
#   BENCH_OUTPUT_LEN (128), SLO_TTFT_MS (2000), SLO_GAP_MS (100),
#   TRANSFER_REQUESTS (8), IDLE_WINDOW_SECONDS (30),
#   READY_TIMEOUT_SECONDS (2400), BENCH_TIMEOUT_SECONDS (3600),
#   E2E_LEFTOVER_GRACE_SECONDS (900), E2E_KEEP_ON_FAILURE (0),
#   E2E_WORK_DIR (mktemp -d).
set -euo pipefail

: "${AWS_PROFILE:?export AWS_PROFILE}"
: "${AWS_REGION:?export AWS_REGION}"
: "${NAME:?export NAME (EKS cluster name of the test cell)}"
: "${BASE_NODECLASS:?export BASE_NODECLASS (an existing EC2NodeClass to copy)}"
: "${GPU_INSTANCE_TYPE:?export GPU_INSTANCE_TYPE (EFA-capable, room for both roles on one node)}"
: "${MODEL_ID:?export MODEL_ID (the model the charts serve)}"
export AWS_PROFILE AWS_REGION

KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
PYTHON="${PYTHON:-python3}"
DISAGG_VALUES_FILE="${DISAGG_VALUES_FILE:-}"
AGG_VALUES_FILE="${AGG_VALUES_FILE:-}"
PROXY_SERVICE="${PROXY_SERVICE:-}"
CAPACITY_TYPE="${CAPACITY_TYPE:-on-demand}"
VLLM_BENCH_IMAGE="${VLLM_BENCH_IMAGE:-vllm/vllm-openai:v0.34.0}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/busybox:1.37.0}"
BENCH_NUM_PROMPTS="${BENCH_NUM_PROMPTS:-200}"
BENCH_REQUEST_RATE="${BENCH_REQUEST_RATE:-4}"
BENCH_INPUT_LEN="${BENCH_INPUT_LEN:-1024}"
BENCH_OUTPUT_LEN="${BENCH_OUTPUT_LEN:-128}"
SLO_TTFT_MS="${SLO_TTFT_MS:-2000}"
SLO_GAP_MS="${SLO_GAP_MS:-100}"
TRANSFER_REQUESTS="${TRANSFER_REQUESTS:-8}"
IDLE_WINDOW_SECONDS="${IDLE_WINDOW_SECONDS:-30}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-2400}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-3600}"
E2E_LEFTOVER_GRACE_SECONDS="${E2E_LEFTOVER_GRACE_SECONDS:-900}"
E2E_KEEP_ON_FAILURE="${E2E_KEEP_ON_FAILURE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFERENCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISAGG_CHART="${INFERENCE_ROOT}/vllm/disagg-pd"
AGG_CHART="${INFERENCE_ROOT}/vllm/agg-baseline"
SCORE_PY="${INFERENCE_ROOT}/_shared/scorer/score.py"

WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"

RUN_ID="pd-e2e-$(date -u +%Y%m%d%H%M%S)"
SHORT_ID="$(date -u +%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
NS="${E2E_NAMESPACE:-pd-e2e-${SHORT_ID}}"
NODECLASS="pd-e2e-${SHORT_ID}"
POOL_PREFILL="pd-e2e-${SHORT_ID}-prefill"
POOL_DECODE="pd-e2e-${SHORT_ID}-decode"
ROLE_KEY="distai.dev/pd-role"
RELEASE_DISAGG="disagg"
RELEASE_AGG="agg"

CREATED_ANYTHING=0
TORN_DOWN=0
FAILED_STEP=""

# ---------------------------------------------------------------- helpers

# Logs go to stderr, so a helper's own log lines never end up in a caller's
# $(...) capture, and a fail() inside one is still visible.
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
kn() { "${KUBECTL}" -n "${NS}" "$@"; }

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

# aws_text CMD...: prints CMD's stdout; a NotFound error is "nothing";
# any other error prints the error text and returns 1.
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

# py SCRIPT ARGS...: runs an inline Python snippet (stdlib only) on stdin JSON.
py() { "${PYTHON}" -c "$@"; }

values_args() {
  # values_args FILE: prints "-f FILE" only when FILE is set.
  [[ -n "$1" ]] && printf '%s\n' "-f" "$1"
  return 0
}

# ---------------------------------------------- role discovery (black box)
#
# A role Deployment is identified only by what the contract fixes: its pod
# template's nodeSelector has ROLE_KEY=prefill|decode. Live objects are
# read, never the chart's own names.

# release_objects [RELEASE]: a release's (default: disagg-pd's) chart-rendered objects as one
# JSON List. Read from the release manifest rather than from live objects,
# because criterion 3 replaces the live nodeSelector with a hostname pin.
release_objects() {
  "${HELM}" get manifest "${1:-${RELEASE_DISAGG}}" -n "${NS}" \
    | k create --dry-run=client -o json -f - 2>/dev/null \
    | py '
import json, sys
o = json.load(sys.stdin)
print(json.dumps(o.get("items", [o]) if o.get("kind") == "List" else [o]))'
}

# role_deployments ROLE: names of the release's Deployments whose pod
# template's nodeSelector has ROLE_KEY=ROLE.
role_deployments() {
  release_objects | py '
import json, sys
role, key = sys.argv[1], sys.argv[2]
for o in json.load(sys.stdin):
    if o.get("kind") != "Deployment":
        continue
    ns = o["spec"]["template"]["spec"].get("nodeSelector") or {}
    if ns.get(key) == role:
        print(o["metadata"]["name"])
' "$1" "${ROLE_KEY}"
}

# role_pod_labels ROLE: JSON list of the pod-template labels of ROLE's Deployments.
role_pod_labels() {
  release_objects | py '
import json, sys
role, key = sys.argv[1], sys.argv[2]
out = []
for o in json.load(sys.stdin):
    if o.get("kind") == "Deployment" and (o["spec"]["template"]["spec"].get("nodeSelector") or {}).get(key) == role:
        out.append(o["spec"]["template"]["metadata"].get("labels") or {})
print(json.dumps(out))
' "$1" "${ROLE_KEY}"
}

# pods_of_deployment DEPLOY: "pod node" for each Ready, non-terminating pod
# selected by DEPLOY's own selector.
pods_of_deployment() {
  local sel
  sel="$(kn get deployment "$1" -o json | py '
import json, sys
m = json.load(sys.stdin)["spec"]["selector"].get("matchLabels") or {}
print(",".join(f"{k}={v}" for k, v in sorted(m.items())))')"
  kn get pods -l "${sel}" -o json | py '
import json, sys
for p in json.load(sys.stdin)["items"]:
    if p["metadata"].get("deletionTimestamp"):
        continue
    conds = {c["type"]: c["status"] for c in (p.get("status") or {}).get("conditions") or []}
    if conds.get("Ready") == "True":
        print(p["metadata"]["name"], p["spec"].get("nodeName", ""))'
}

# role_pods ROLE: "pod node" lines for every Ready pod of ROLE.
role_pods() {
  local d
  for d in $(role_deployments "$1"); do pods_of_deployment "${d}"; done
}

# wait_rollouts: every Deployment in NS (both roles and the proxy) has
# rolled out and all its pods are Ready.
wait_rollouts() {
  local d
  for d in $(kn get deployments -o jsonpath='{.items[*].metadata.name}'); do
    kn rollout status "deployment/${d}" --timeout="${READY_TIMEOUT_SECONDS}s" \
      || fail "deployment ${d} did not become Ready within ${READY_TIMEOUT_SECONDS}s ($(kn get pods -o wide 2>&1 | tr '\n' ';'))"
  done
}

# pod_metrics_url POD: http://<podIP>:<port>/metrics of the pod's GPU
# container (its first containerPort).
pod_metrics_url() {
  kn get pod "$1" -o json | py '
import json, sys
p = json.load(sys.stdin)
cs = p["spec"]["containers"]
gpu = [c for c in cs if "nvidia.com/gpu" in ((c.get("resources") or {}).get("limits") or {})] or cs
ports = [pt["containerPort"] for c in gpu for pt in c.get("ports") or []]
if not ports:
    sys.exit("no containerPort on the vLLM container of " + p["metadata"]["name"])
ip = p["status"]["podIP"]
print(f"http://{ip}:{ports[0]}/metrics")'
}

# in_cluster CMD...: runs CMD inside the in-cluster client pod (never a
# port-forward: every request originates inside the cluster).
in_cluster() { kn exec client -- "$@"; }

# metric_sum POD NAME: sum of every sample of the Prometheus counter NAME
# exported by POD's vLLM server.
metric_sum() {
  local url
  url="$(pod_metrics_url "$1")" || fail "cannot find the metrics port of pod $1"
  in_cluster curl -fsS --max-time 20 "${url}" | py '
import sys
name = sys.argv[1]
total, seen = 0.0, False
for line in sys.stdin:
    if line.startswith("#"):
        continue
    metric = line.split("{", 1)[0].split(" ", 1)[0]
    if metric == name:
        total += float(line.rsplit(" ", 1)[-1])
        seen = True
if not seen:
    sys.exit(f"metric {name} not exported")
print(repr(total))' "$2"
}

# role_metric ROLE NAME: metric_sum summed over every pod of ROLE.
role_metric() {
  local total=0 pod node v
  while read -r pod node; do
    [[ -n "${pod}" ]] || continue
    v="$(metric_sum "${pod}" "$2")" || fail "reading $2 from ${pod}"
    total="$(py 'import sys; print(repr(float(sys.argv[1]) + float(sys.argv[2])))' "${total}" "${v}")"
  done < <(role_pods "$1")
  printf '%s' "${total}"
}

float_gt() { py 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)' "$1" "$2"; }

# proxy_url: http://<service>.<ns>.svc:<port> of the disagg-pd proxy:
# PROXY_SERVICE if set, otherwise the one Service of the release whose
# selector matches neither role's pods.
proxy_url() {
  local svc="${PROXY_SERVICE}"
  if [[ -z "${svc}" ]]; then
    svc="$(release_objects | py '
import json, sys
roles = json.loads(sys.argv[1]) + json.loads(sys.argv[2])
cands = []
for s in json.load(sys.stdin):
    if s.get("kind") != "Service":
        continue
    sel = s["spec"].get("selector") or {}
    if not sel or any(all(l.get(k) == v for k, v in sel.items()) for l in roles):
        continue
    cands.append(s["metadata"]["name"])
if len(cands) != 1:
    sys.exit(f"expected exactly one Service selecting neither role (the proxy), found {cands}; set PROXY_SERVICE")
print(cands[0])' "$(role_pod_labels prefill)" "$(role_pod_labels decode)")" || return 1
  fi
  service_url "${svc}"
}

service_url() {
  local port
  port="$(kn get service "$1" -o jsonpath='{.spec.ports[0].port}')" || return 1
  [[ -n "${port}" ]] || return 1
  printf 'http://%s.%s.svc:%s' "$1" "${NS}" "${port}"
}

# completion URL PROMPT MAX_TOKENS: one /v1/completions call from inside the
# cluster; prints the response body; fails unless it carries generated text.
completion() {
  local body resp
  body="$(py 'import json, sys; print(json.dumps({"model": sys.argv[1], "prompt": sys.argv[2], "max_tokens": int(sys.argv[3]), "temperature": 0}))' "${MODEL_ID}" "$2" "$3")"
  resp="$(in_cluster curl -fsS --max-time 600 -H 'Content-Type: application/json' -d "${body}" "$1/v1/completions")" \
    || { log "request to $1/v1/completions failed"; return 1; }
  printf '%s' "${resp}" | py '
import json, sys
r = json.load(sys.stdin)
ch = r.get("choices") or []
if not ch or not (ch[0].get("text") or "").strip():
    sys.exit("response has no generated text: " + json.dumps(r)[:500])
u = r.get("usage") or {}
if "completion_tokens" in u and u["completion_tokens"] < 1:
    sys.exit("usage.completion_tokens < 1: " + json.dumps(u))
' || return 1
  printf '%s' "${resp}"
}

long_prompt() {
  # A prompt long enough that its KV cache spans many blocks.
  py 'print(" ".join(f"Item {i} is described in plain words for the transfer check." for i in range(int(__import__("sys").argv[1]))))' "${1:-200}"
}

# ------------------------------------------------- EFA hardware counters
#
# The node's EFA hardware counters, read from the same sysfs hw_counters
# files that awsome's efa-node-exporter turns into node_amazonefa_*
# metrics (rdma_write_bytes -> node_amazonefa_rdma_write_bytes_total,
# rdma_write_recv_bytes -> ..._rdma_write_recv_bytes_total, tx_bytes ->
# ..._tx_bytes_total, plus rdma_read_bytes and rx_bytes, since a KV pull
# can be an RDMA read). Read through a read-only hostPath mount, so the
# result does not depend on the probe pod's network namespace.
EFA_COUNTERS="rdma_read_bytes rdma_write_bytes rdma_write_recv_bytes tx_bytes rx_bytes"

start_efa_probe() {
  local node="$1"
  kn delete pod efa-probe --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kn apply -f - >/dev/null <<YAML || return 1
apiVersion: v1
kind: Pod
metadata:
  name: efa-probe
  labels: {app.kubernetes.io/name: pd-e2e-efa-probe}
spec:
  nodeName: ${node}
  restartPolicy: Never
  tolerations: [{operator: Exists}]
  securityContext: {runAsUser: 65534, runAsGroup: 65534, runAsNonRoot: true}
  containers:
    - name: probe
      image: ${PROBE_IMAGE}
      command: ["sleep", "86400"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
      volumeMounts: [{name: ib, mountPath: /host/infiniband, readOnly: true}]
  volumes:
    - name: ib
      hostPath: {path: /sys/class/infiniband, type: Directory}
YAML
  kn wait --for=condition=Ready pod/efa-probe --timeout=300s >/dev/null
}

# efa_counter_total: the sum over every EFA device on the probe's node of
# EFA_COUNTERS; fails if the node has no EFA device or no such counter.
efa_counter_total() {
  # shellcheck disable=SC2016 # expanded by the probe pod's own shell
  kn exec efa-probe -- sh -c '
    set -e
    n=0; total=0
    for dev in /host/infiniband/*; do
      [ -d "$dev" ] || continue
      for dir in "$dev"/ports/*/hw_counters "$dev"/hw_counters; do
        [ -d "$dir" ] || continue
        for c in '"${EFA_COUNTERS}"'; do
          if [ -r "$dir/$c" ]; then total=$((total + $(cat "$dir/$c"))); n=$((n + 1)); fi
        done
      done
    done
    [ "$n" -gt 0 ] || { echo "no EFA hw_counters under /sys/class/infiniband" >&2; exit 1; }
    echo "$total"'
}

# ----------------------------------------------------- teardown and sweep

tag_filters() {
  printf '%s\n' \
    "Name=tag:${TEST_TAG_KEY},Values=${RUN_ID}" \
    "Name=tag:karpenter.k8s.aws/ec2nodeclass,Values=${NODECLASS}" \
    "Name=tag:karpenter.sh/nodepool,Values=${POOL_PREFILL}" \
    "Name=tag:karpenter.sh/nodepool,Values=${POOL_DECODE}"
}

list_leftover() {
  local kind="$1" filter out all=""
  while IFS= read -r filter; do
    if ! case "${kind}" in
      instance)
        out="$(aws_text aws ec2 describe-instances --filters "${filter}" \
          "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text)" ;;
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
  printf '%s' "${all}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' | sort -u || true
}

no_leftover() {
  local out
  if ! out="$(list_leftover "$1")"; then
    log "FAIL checking for leftover $1: ${out}"
    return 2
  fi
  [[ -z "${out}" ]]
}

leftover_nodes() {
  k get nodes -l "karpenter.sh/nodepool in (${POOL_PREFILL},${POOL_DECODE})" -o name 2>/dev/null || true
}
no_leftover_nodes() { [[ -z "$(leftover_nodes)" ]]; }
nodeclaims_gone() {
  [[ -z "$(k get nodeclaims -l "karpenter.sh/nodepool in (${POOL_PREFILL},${POOL_DECODE})" -o name 2>/dev/null || true)" ]]
}
no_leftover_karpenter() { no_leftover_nodes && nodeclaims_gone; }

# teardown: removes everything this run created, then sweeps for what it
# left behind. Returns 1 if anything remains. Safe to call more than once.
teardown() {
  local bad=0 kind ids
  [[ "${CREATED_ANYTHING}" -eq 1 ]] || return 0
  info "teardown: uninstalling releases and deleting namespace ${NS}"
  "${HELM}" uninstall "${RELEASE_DISAGG}" -n "${NS}" --wait --timeout 10m >/dev/null 2>&1 || true
  "${HELM}" uninstall "${RELEASE_AGG}" -n "${NS}" --wait --timeout 10m >/dev/null 2>&1 || true
  k delete namespace "${NS}" --ignore-not-found --wait=true --timeout=15m >/dev/null 2>&1 \
    || { log "FAIL teardown: namespace ${NS} not deleted"; bad=1; }
  info "teardown: deleting NodePools ${POOL_PREFILL}, ${POOL_DECODE} (Karpenter drains and terminates their nodes)"
  k delete nodepool "${POOL_PREFILL}" "${POOL_DECODE}" --ignore-not-found --wait=true --timeout=20m >/dev/null 2>&1 \
    || { log "FAIL teardown: NodePools not deleted"; bad=1; }
  if wait_until "${E2E_LEFTOVER_GRACE_SECONDS}" 20 "no node or NodeClaim of this run" no_leftover_karpenter; then
    pass "no Kubernetes node or NodeClaim of this run remains"
  else
    log "FAIL nodes left after teardown: $(leftover_nodes | tr '\n' ' ')"
    bad=1
  fi
  # The EC2NodeClass goes last: Karpenter deletes its launch templates when
  # the EC2NodeClass itself is deleted.
  k delete ec2nodeclass "${NODECLASS}" --ignore-not-found --wait=true --timeout=15m >/dev/null 2>&1 \
    || { log "FAIL teardown: EC2NodeClass ${NODECLASS} not deleted"; bad=1; }
  for kind in instance volume launch-template; do
    if wait_until "${E2E_LEFTOVER_GRACE_SECONDS}" 20 "no ${kind} of this run left" no_leftover "${kind}"; then
      pass "no ${kind} tagged for this run remains"
    else
      ids="$(list_leftover "${kind}" || true)"
      log "FAIL ${kind} left after teardown: $(tr '\n' ' ' <<<"${ids}")"
      bad=1
    fi
  done
  TORN_DOWN=1
  return "${bad}"
}

cleanup() {
  local rc=$?
  set +e
  if [[ "${TORN_DOWN}" -eq 0 && "${CREATED_ANYTHING}" -eq 1 ]]; then
    if [[ "${rc}" -ne 0 && "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving namespace ${NS}, NodePools ${POOL_PREFILL}/${POOL_DECODE} and EC2NodeClass ${NODECLASS} in place"
      info "remove them with: ${KUBECTL} delete namespace ${NS}; ${KUBECTL} delete nodepool ${POOL_PREFILL} ${POOL_DECODE}; ${KUBECTL} delete ec2nodeclass ${NODECLASS}"
    else
      teardown || { [[ "${rc}" -eq 0 ]] && rc=1; FAILED_STEP="${FAILED_STEP:-teardown left resources behind (acceptance criterion 6)}"; }
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

for b in aws "${KUBECTL}" "${HELM}" "${PYTHON}"; do require_bin "${b}"; done
aws sts get-caller-identity --query Arn --output text >/dev/null \
  || fail "preflight: AWS credentials for profile ${AWS_PROFILE} are not valid"
for f in "${DISAGG_CHART}/Chart.yaml" "${AGG_CHART}/Chart.yaml" "${SCORE_PY}"; do
  [[ -f "${f}" ]] || fail "preflight: ${f} is missing"
done
for f in "${DISAGG_VALUES_FILE}" "${AGG_VALUES_FILE}"; do
  [[ -z "${f}" || -f "${f}" ]] || fail "preflight: values file ${f} does not exist"
done

# Wrong-cluster guard: the current kubeconfig context must be NAME's own
# endpoint, checked before this script writes anything to a cluster.
want_endpoint="$(aws eks describe-cluster --name "${NAME}" --query cluster.endpoint --output text)" \
  || fail "preflight: aws eks describe-cluster --name ${NAME} failed"
got_endpoint="$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "${got_endpoint%/}" == "${want_endpoint%/}" ]] \
  || fail "preflight: the current kubeconfig context points at ${got_endpoint}, not cluster ${NAME} (${want_endpoint})"
k get ec2nodeclass "${BASE_NODECLASS}" >/dev/null 2>&1 \
  || fail "preflight: EC2NodeClass ${BASE_NODECLASS} does not exist in cluster ${NAME}"
if k get namespace "${NS}" >/dev/null 2>&1; then
  fail "preflight: namespace ${NS} already exists; refusing to reuse it"
fi
for nodepool in "${POOL_PREFILL}" "${POOL_DECODE}"; do
  if k get nodepool "${nodepool}" >/dev/null 2>&1; then fail "preflight: NodePool ${nodepool} already exists"; fi
done
# shellcheck disable=SC2046 # values_args prints zero or two words
"${HELM}" lint "${DISAGG_CHART}" $(values_args "${DISAGG_VALUES_FILE}") >/dev/null \
  || fail "preflight: helm lint ${DISAGG_CHART} (acceptance criterion 1)"
# shellcheck disable=SC2046 # values_args prints zero or two words
"${HELM}" lint "${AGG_CHART}" $(values_args "${AGG_VALUES_FILE}") >/dev/null \
  || fail "preflight: helm lint ${AGG_CHART} (acceptance criterion 1)"
pass "preflight: tools, credentials, cluster ${NAME} (endpoint matches), base EC2NodeClass, charts lint clean"

# ------------------------------------- 1. namespace, node class, pools

CREATED_ANYTHING=1
k create namespace "${NS}" >/dev/null || fail "creating namespace ${NS}"
k label namespace "${NS}" "${TEST_TAG_KEY}=${RUN_ID}" >/dev/null

# The run's own EC2NodeClass: BASE_NODECLASS's spec unchanged, plus this
# run's tag (Karpenter puts spec.tags on the instances, volumes and launch
# templates it creates, which is what the teardown sweep looks for).
k get ec2nodeclass "${BASE_NODECLASS}" -o json | py '
import json, sys
src = json.load(sys.stdin)
name, tag_key, run_id = sys.argv[1], sys.argv[2], sys.argv[3]
spec = src["spec"]
spec["tags"] = dict(spec.get("tags") or {}, **{tag_key: run_id})
print(json.dumps({"apiVersion": src["apiVersion"], "kind": "EC2NodeClass",
                  "metadata": {"name": name, "labels": {tag_key: run_id}}, "spec": spec}))
' "${NODECLASS}" "${TEST_TAG_KEY}" "${RUN_ID}" | k apply -f - >/dev/null \
  || fail "creating EC2NodeClass ${NODECLASS} from ${BASE_NODECLASS}"
nodeclass_ready() {
  [[ "$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]
}
wait_until 600 10 "EC2NodeClass ${NODECLASS} Ready" nodeclass_ready \
  || fail "EC2NodeClass ${NODECLASS} did not become Ready"

nodeclass_group="$(k get ec2nodeclass "${NODECLASS}" -o jsonpath='{.apiVersion}' | cut -d/ -f1)"
for role in prefill decode; do
  pool="${POOL_PREFILL}"
  [[ "${role}" == decode ]] && pool="${POOL_DECODE}"
  k apply -f - >/dev/null <<YAML || fail "creating NodePool ${pool}"
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ${pool}
  labels: {${TEST_TAG_KEY}: ${RUN_ID}}
spec:
  template:
    metadata:
      labels:
        ${ROLE_KEY}: ${role}
        ${TEST_TAG_KEY}: ${RUN_ID}
    spec:
      nodeClassRef: {group: ${nodeclass_group}, kind: EC2NodeClass, name: ${NODECLASS}}
      expireAfter: Never
      requirements:
        - {key: node.kubernetes.io/instance-type, operator: In, values: ["${GPU_INSTANCE_TYPE}"]}
        - {key: karpenter.sh/capacity-type, operator: In, values: ["${CAPACITY_TYPE}"]}
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: Never
YAML
done
pass "created EC2NodeClass ${NODECLASS} and NodePools ${POOL_PREFILL} (${ROLE_KEY}=prefill), ${POOL_DECODE} (${ROLE_KEY}=decode), ${GPU_INSTANCE_TYPE} only"

# The in-cluster client every request goes through (no port-forward).
kn apply -f - >/dev/null <<YAML || fail "creating the client pod"
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels: {app.kubernetes.io/name: pd-e2e-client}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 100, runAsGroup: 101}
  containers:
    - name: curl
      image: ${CURL_IMAGE}
      command: ["sleep", "86400"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {cpu: 500m, memory: 128Mi}}
YAML
kn wait --for=condition=Ready pod/client --timeout=300s >/dev/null || fail "client pod not Ready"

# ----------------------- 2. criterion 2: default placement, real completion

disagg_install() {
  # disagg_install EXTRA_HELM_ARGS...: install or upgrade the disagg-pd release.
  # shellcheck disable=SC2046 # values_args prints zero or two words
  "${HELM}" upgrade --install "${RELEASE_DISAGG}" "${DISAGG_CHART}" -n "${NS}" \
    $(values_args "${DISAGG_VALUES_FILE}") "$@" --wait=false >/dev/null
}

disagg_install || fail "helm install ${RELEASE_DISAGG} with default values"
[[ -n "$(role_deployments prefill)" ]] || fail "the rendered release has no Deployment with nodeSelector ${ROLE_KEY}=prefill"
[[ -n "$(role_deployments decode)" ]] || fail "the rendered release has no Deployment with nodeSelector ${ROLE_KEY}=decode"
wait_rollouts
pass "criterion 2: every Deployment of ${RELEASE_DISAGG} is Ready (prefill: $(role_deployments prefill | tr '\n' ' '), decode: $(role_deployments decode | tr '\n' ' '))"

# assert_cross_node: both roles Ready, no node shared, each pod on a node
# labeled with its own role.
assert_cross_node() {
  local label="$1" pre dec role pod node got shared
  pre="$(role_pods prefill)"
  dec="$(role_pods decode)"
  [[ -n "${pre}" && -n "${dec}" ]] || fail "${label}: no Ready prefill or decode pod"
  for role in prefill decode; do
    while read -r pod node; do
      got="$(k get node "${node}" -o jsonpath="{.metadata.labels.${ROLE_KEY//./\\.}}")"
      [[ "${got}" == "${role}" ]] || fail "${label}: ${role} pod ${pod} is on node ${node} labeled ${ROLE_KEY}=${got:-<none>}"
    done <<<"$( [[ "${role}" == prefill ]] && echo "${pre}" || echo "${dec}")"
  done
  shared="$(comm -12 <(awk '{print $2}' <<<"${pre}" | sort -u) <(awk '{print $2}' <<<"${dec}" | sort -u))"
  [[ -z "${shared}" ]] || fail "${label}: prefill and decode pods share node(s): ${shared}"
  kn get pods -o wide >"${WORK_DIR}/pods-wide-$(tr -c 'a-zA-Z0-9\n' '-' <<<"${label}").txt"
  pass "${label}: prefill on [$(awk '{print $2}' <<<"${pre}" | sort -u | tr '\n' ' ')], decode on [$(awk '{print $2}' <<<"${dec}" | sort -u | tr '\n' ' ')] -- no node shared (kubectl get pods -o wide saved)"
}
assert_cross_node "criterion 2"

PROXY_URL="$(proxy_url)" || fail "could not determine the proxy Service"
info "proxy: ${PROXY_URL}"

pre_prompt0="$(role_metric prefill vllm:prompt_tokens_total)"
dec_gen0="$(role_metric decode vllm:generation_tokens_total)"
resp="$(completion "${PROXY_URL}" "The capital of France is" 32)" \
  || fail "criterion 2: a request through the proxy did not return a generated completion"
printf '%s\n' "${resp}" >"${WORK_DIR}/criterion2-response.json"
pre_prompt1="$(role_metric prefill vllm:prompt_tokens_total)"
dec_gen1="$(role_metric decode vllm:generation_tokens_total)"
float_gt "${pre_prompt1}" "${pre_prompt0}" \
  || fail "criterion 2: the prefill pods' vllm:prompt_tokens_total did not move (${pre_prompt0} -> ${pre_prompt1}); the request was not prefilled by the prefill role"
float_gt "${dec_gen1}" "${dec_gen0}" \
  || fail "criterion 2: the decode pods' vllm:generation_tokens_total did not move (${dec_gen0} -> ${dec_gen1}); the completion was not decoded by the decode role"
pass "criterion 2: the proxy returned a generated completion; prefill prompt tokens ${pre_prompt0} -> ${pre_prompt1}, decode generated tokens ${dec_gen0} -> ${dec_gen1}"

# ------------- 3. criterion 3: same node, EFA forced vs library default

SAME_NODE="$(role_pods prefill | awk 'NR==1{print $2}')"
[[ -n "${SAME_NODE}" ]] || fail "criterion 3: no prefill node to co-locate on"
start_efa_probe "${SAME_NODE}" || fail "criterion 3: EFA probe pod on ${SAME_NODE} not Ready"
efa_counter_total >/dev/null || fail "criterion 3: node ${SAME_NODE} exposes no EFA hw_counters (is ${GPU_INSTANCE_TYPE} EFA-capable and is the EFA device plugin running?)"
NONCE="$(date +%s%N)"

# same_node_cell FORCE: both roles on SAME_NODE with
# transport.forceEfaSameNode=FORCE. The chart gets
# placement.sameNodeMeasurement=true and placement.enforceAntiAffinity=false (so the anti-affinity is gone and the two
# roles *can* share a node); the role Deployments' nodeSelector is then
# replaced by a hostname pin, the one thing a values file cannot express
# without knowing the chart's own value names. The chart itself renders
# strategy.type=Recreate whenever placement.sameNodeMeasurement=true (see
# templates/engines.yaml), so the old pods already release their GPUs
# before the new ones need them on the same node; this patch only pins the
# hostname, it no longer needs to also set strategy.
same_node_cell() {
  local force="$1" d patch pod node env_val
  disagg_install --set placement.sameNodeMeasurement=true --set placement.enforceAntiAffinity=false --set "transport.forceEfaSameNode=${force}" \
    || fail "criterion 3: helm upgrade with placement.sameNodeMeasurement=true, placement.enforceAntiAffinity=false, transport.forceEfaSameNode=${force}"
  patch="$(py 'import json, sys; print(json.dumps([
    {"op": "replace", "path": "/spec/template/spec/nodeSelector", "value": {"kubernetes.io/hostname": sys.argv[1]}}]))' "${SAME_NODE}")"
  for d in $(role_deployments prefill) $(role_deployments decode); do
    kn patch deployment "${d}" --type=json -p "${patch}" >/dev/null || fail "criterion 3: pinning ${d} to ${SAME_NODE}"
  done
  wait_rollouts
  while read -r pod node; do
    [[ -z "${pod}" ]] && continue
    [[ "${node}" == "${SAME_NODE}" ]] || fail "criterion 3 (force=${force}): pod ${pod} is on ${node}, not ${SAME_NODE}"
    env_val="$(kn get pod "${pod}" -o json | py '
import json, sys
p = json.load(sys.stdin)
cs = p["spec"]["containers"]
gpu = [c for c in cs if "nvidia.com/gpu" in ((c.get("resources") or {}).get("limits") or {})] or cs
vals = {e.get("value", "<valueFrom>") for c in gpu for e in c.get("env") or [] if e["name"] == "FI_EFA_ENABLE_SHM_TRANSFER"}
print(",".join(sorted(vals)) or "<unset>")')"
    if [[ "${force}" == true ]]; then
      [[ "${env_val}" == "0" ]] || fail "criterion 3: forceEfaSameNode=true but pod ${pod} has FI_EFA_ENABLE_SHM_TRANSFER=${env_val}"
    else
      [[ ",${env_val}," != *",0,"* ]] || fail "criterion 3: forceEfaSameNode=false but pod ${pod} has FI_EFA_ENABLE_SHM_TRANSFER=${env_val}"
    fi
  done < <(role_pods prefill; role_pods decode)
  kn get pods -o wide >"${WORK_DIR}/pods-wide-same-node-force-${force}.txt"
  pass "criterion 3 (force=${force}): every prefill and decode pod is Ready on ${SAME_NODE}, FI_EFA_ENABLE_SHM_TRANSFER as expected"
}

# transfer_delta LABEL: EFA counter delta on SAME_NODE across
# TRANSFER_REQUESTS unique long-prompt requests (unique, so no prefix-cache
# hit can skip a KV transfer). Fails if the node was not idle beforehand
# or if the requests did not reach the prefill role.
transfer_delta() {
  local label="$1" url c0 c1 c2 p0 p1 i
  url="$(proxy_url)" || fail "${label}: could not determine the proxy Service"
  c0="$(efa_counter_total)" || fail "${label}: reading EFA counters"
  sleep "${IDLE_WINDOW_SECONDS}"
  c1="$(efa_counter_total)" || fail "${label}: reading EFA counters"
  [[ "${c1}" -eq "${c0}" ]] \
    || fail "${label}: EFA counters on ${SAME_NODE} moved by $((c1 - c0)) bytes in ${IDLE_WINDOW_SECONDS}s with no request in flight -- something else uses EFA on this node; the comparison is not valid"
  p0="$(role_metric prefill vllm:prompt_tokens_total)"
  for i in $(seq 1 "${TRANSFER_REQUESTS}"); do
    completion "${url}" "Request ${NONCE}-${label}-${i}. $(long_prompt 200)" 16 >/dev/null \
      || fail "${label}: request ${i} through the proxy failed"
  done
  c2="$(efa_counter_total)" || fail "${label}: reading EFA counters"
  p1="$(role_metric prefill vllm:prompt_tokens_total)"
  float_gt "${p1}" "${p0}" || fail "${label}: the prefill role's prompt token counter did not move; the requests never reached it"
  info "${label}: EFA counters ${c1} -> ${c2} (delta $((c2 - c1)) bytes), prefill prompt tokens ${p0} -> ${p1}"
  printf '%s' "$((c2 - c1))"
}

same_node_cell true
delta_forced="$(transfer_delta forced)"
[[ "${delta_forced}" -gt 0 ]] \
  || fail "criterion 3: with transport.forceEfaSameNode=true the EFA counters on ${SAME_NODE} did not increase during ${TRANSFER_REQUESTS} requests"
pass "criterion 3: transport.forceEfaSameNode=true, same node -- EFA counters increased by ${delta_forced} bytes during the requests"

# NOT a flat-vs-rising contrast: confirmed on real hardware (g7.48xlarge,
# 2026-11-20) that forceEfaSameNode=false ALSO moves real EFA bytes here,
# the same magnitude as =true, because each role's Pod already owns its
# own distinct physical EFA interface under this chart's two-Pod model --
# libfabric's same-host shm bypass is keyed to both endpoints resolving to
# the SAME device, which never happens across two separate Pods, so there
# is nothing for forceEfaSameNode to force either way (see disagg-pd's own
# README, "Known issues"). This asserts both cases move real traffic, not
# that they differ.
same_node_cell false
delta_default="$(transfer_delta default)"
[[ "${delta_default}" -gt 0 ]] \
  || fail "criterion 3: with transport.forceEfaSameNode=false the EFA counters on ${SAME_NODE} did not increase during ${TRANSFER_REQUESTS} requests"
pass "criterion 3: transport.forceEfaSameNode=false, same node -- EFA counters also increased by ${delta_default} bytes (forced was +${delta_forced} bytes); no flat-vs-rising contrast under this chart's two-Pod model, both move real EFA traffic"
kn delete pod efa-probe --ignore-not-found --wait=true >/dev/null

# ------------------------------------- bench + score (criteria 4 and 5)

# run_bench LABEL BASE_URL: runs `vllm bench serve --save-result
# --save-detailed` in-cluster as a Job (open-loop, Poisson arrivals at
# BENCH_REQUEST_RATE, BENCH_NUM_PROMPTS requests) against BASE_URL and
# saves its raw result JSON to WORK_DIR/LABEL-records.json. The result is
# carried out through the Job's log between two markers, so nothing is
# copied from a pod after it exits.
run_bench() {
  local label="$1" url="$2" job="bench-$1" logs
  kn delete job "${job}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kn apply -f - >/dev/null <<YAML || fail "${label}: creating Job ${job}"
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${BENCH_TIMEOUT_SECONDS}
  template:
    metadata:
      labels: {app.kubernetes.io/name: pd-e2e-bench}
    spec:
      restartPolicy: Never
      containers:
        - name: bench
          image: ${VLLM_BENCH_IMAGE}
          command: ["bash", "-c"]
          args:
            - |
              set -euo pipefail
              mkdir -p /results
              vllm bench serve --backend vllm --base-url "${url}" --endpoint /v1/completions \\
                --model "${MODEL_ID}" --dataset-name random \\
                --random-input-len ${BENCH_INPUT_LEN} --random-output-len ${BENCH_OUTPUT_LEN} \\
                --num-prompts ${BENCH_NUM_PROMPTS} --request-rate ${BENCH_REQUEST_RATE} --seed 0 \\
                --save-result --save-detailed --result-dir /results --result-filename result.json >&2
              echo "=====BEGIN-RESULT====="
              gzip -c /results/result.json | base64 -w0
              echo
              echo "=====END-RESULT====="
          resources: {requests: {cpu: "2", memory: 4Gi}, limits: {cpu: "4", memory: 8Gi}}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
  job_done() {
    local c f
    c="$(kn get job "${job}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')"
    f="$(kn get job "${job}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')"
    [[ "${f}" == "True" ]] && return 0
    [[ "${c}" == "True" ]]
  }
  wait_until "$((BENCH_TIMEOUT_SECONDS + 300))" 15 "Job ${job} finished" job_done || fail "${label}: Job ${job} did not finish"
  logs="$(kn logs "job/${job}" -c bench)" || fail "${label}: reading Job ${job} logs"
  [[ "$(kn get job "${job}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" == "True" ]] \
    || fail "${label}: vllm bench serve Job ${job} failed: $(tail -n 20 <<<"${logs}" | tr '\n' ';')"
  sed -n '/=====BEGIN-RESULT=====/,/=====END-RESULT=====/p' <<<"${logs}" | sed '1d;$d' | tr -d '\n' \
    | base64 -d | gunzip >"${WORK_DIR}/${label}-records.json" \
    || fail "${label}: could not decode the bench result from the Job log"
  [[ -s "${WORK_DIR}/${label}-records.json" ]] || fail "${label}: empty bench result"
  pass "${label}: vllm bench serve --save-detailed finished (${BENCH_NUM_PROMPTS} requests at ${BENCH_REQUEST_RATE}/s), raw result saved"
}

# ns_gpus: total nvidia.com/gpu limit of every live pod in NS (the GPUs
# the serving layout under test holds).
ns_gpus() {
  kn get pods -o json | py '
import json, sys
total = 0
for p in json.load(sys.stdin)["items"]:
    if p["metadata"].get("deletionTimestamp") or p["status"].get("phase") != "Running":
        continue
    total += sum(int(((c.get("resources") or {}).get("limits") or {}).get("nvidia.com/gpu", 0)) for c in p["spec"]["containers"])
print(total)'
}

# score LABEL GPUS: score.py on LABEL's raw result; asserts a well-formed
# summary with non-null joint_attainment_share and goodput_per_gpu.
score() {
  local label="$1" gpus="$2" out="${WORK_DIR}/$1-summary.json"
  [[ "${gpus}" -ge 1 ]] || fail "${label}: no GPU held by the pods under test"
  "${PYTHON}" "${SCORE_PY}" --records "${WORK_DIR}/${label}-records.json" \
    --planned-requests "${BENCH_NUM_PROMPTS}" --gpu-count "${gpus}" \
    --ttft-ms "${SLO_TTFT_MS}" --tpot-or-gap-ms "${SLO_GAP_MS}" --out "${out}" \
    || fail "${label}: score.py exited non-zero on a real vllm bench serve --save-detailed result"
  py '
import json, math, sys
path, planned = sys.argv[1], int(sys.argv[2])
s = json.load(open(path))
need = ["planned_requests", "successful_requests", "failed_requests", "no_tokens_generated",
        "joint_attainment_share", "goodput_per_gpu", "ttft_ms", "longest_gap_ms"]
missing = [k for k in need if k not in s]
if missing:
    sys.exit(f"summary is missing {missing}")
def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
errs = []
if s["planned_requests"] != planned:
    errs.append("planned_requests={!r}, passed {}".format(s["planned_requests"], planned))
for k in ("successful_requests", "failed_requests", "no_tokens_generated"):
    if not isinstance(s[k], int) or s[k] < 0:
        errs.append(f"{k}={s[k]!r} is not a non-negative integer")
if not num(s["joint_attainment_share"]) or not 0 <= s["joint_attainment_share"] <= 1:
    errs.append("joint_attainment_share={!r} is not a number in [0, 1]".format(s["joint_attainment_share"]))
if not num(s["goodput_per_gpu"]) or s["goodput_per_gpu"] < 0:
    errs.append("goodput_per_gpu={!r} is not a non-negative number".format(s["goodput_per_gpu"]))
if isinstance(s["successful_requests"], int) and s["successful_requests"] < 1:
    errs.append("no successful request in a real run")
if isinstance(s["successful_requests"], int) and isinstance(s["failed_requests"], int) \
        and s["successful_requests"] + s["failed_requests"] > planned:
    errs.append("successful + failed exceeds planned_requests")
for d in ("ttft_ms", "longest_gap_ms"):
    v = s[d]
    if not isinstance(v, dict) or not all(num(v.get(q)) for q in ("p50", "p90", "p99")):
        errs.append(f"{d}={v!r} lacks numeric p50/p90/p99")
    elif not v["p50"] <= v["p90"] <= v["p99"]:
        errs.append(f"{d} percentiles are not ordered: {v}")
if errs:
    sys.exit("; ".join(errs))
' "${out}" "${BENCH_NUM_PROMPTS}" || fail "${label}: score.py summary is not well-formed"
  pass "${label}: score.py summary well-formed ($(py 'import json,sys; s=json.load(open(sys.argv[1])); print("joint_attainment_share={}, goodput_per_gpu={}, gpus={}".format(s["joint_attainment_share"], s["goodput_per_gpu"], sys.argv[2]))' "${out}" "${gpus}"))"
}

uninstall_and_wait() {
  "${HELM}" uninstall "$1" -n "${NS}" --wait --timeout 15m >/dev/null || fail "helm uninstall $1"
  gpu_pods_gone() { [[ "$(ns_gpus)" -eq 0 ]]; }
  wait_until 900 10 "GPU pods of $1 gone" gpu_pods_gone || fail "GPU pods of $1 still present after uninstall"
}

# ------------------- 4. criterion 4: disagg-pd scored, default placement

# A clean reinstall: helm upgrade would keep criterion 3's hostname pin
# (a field the chart does not manage), so the default placement is
# restored by uninstalling, not by upgrading.
uninstall_and_wait "${RELEASE_DISAGG}"
disagg_install || fail "criterion 4: helm install ${RELEASE_DISAGG} with default values"
wait_rollouts
assert_cross_node "criterion 4 (default placement restored)"
PROXY_URL="$(proxy_url)" || fail "criterion 4: could not determine the proxy Service"
DISAGG_GPUS="$(ns_gpus)"
run_bench disagg "${PROXY_URL}"
score disagg "${DISAGG_GPUS}"
kn get pods -o json >"${WORK_DIR}/disagg-pods-after.json"

# ---------------- 5. criterion 5: agg-baseline scored, same nodes and load

uninstall_and_wait "${RELEASE_DISAGG}"
# shellcheck disable=SC2046 # values_args prints zero or two words
"${HELM}" upgrade --install "${RELEASE_AGG}" "${AGG_CHART}" -n "${NS}" $(values_args "${AGG_VALUES_FILE}") >/dev/null \
  || fail "criterion 5: helm install ${RELEASE_AGG}"
wait_rollouts
agg_node="$(kn get pods -o json | py '
import json, sys
for p in json.load(sys.stdin)["items"]:
    if any("nvidia.com/gpu" in ((c.get("resources") or {}).get("limits") or {}) for c in p["spec"]["containers"]):
        print(p["spec"].get("nodeName", ""))')"
for n in ${agg_node}; do
  pool="$(k get node "${n}" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')"
  [[ "${pool}" == "${POOL_PREFILL}" || "${pool}" == "${POOL_DECODE}" ]] \
    || fail "criterion 5: agg-baseline pod is on node ${n} (NodePool ${pool:-<none>}), not on this run's ${GPU_INSTANCE_TYPE} nodes -- not the same hardware"
done
AGG_SERVICE="$(release_objects "${RELEASE_AGG}" | py '
import json, sys
svcs = [o["metadata"]["name"] for o in json.load(sys.stdin) if o.get("kind") == "Service" and (o["spec"].get("selector") or {})]
if len(svcs) != 1:
    sys.exit(f"expected exactly one Service in the agg-baseline release, found {svcs}")
print(svcs[0])')" || fail "criterion 5: could not determine the agg-baseline Service"
AGG_URL="$(service_url "${AGG_SERVICE}")" || fail "criterion 5: agg-baseline Service has no port"
completion "${AGG_URL}" "The capital of France is" 16 >/dev/null || fail "criterion 5: agg-baseline did not return a completion"
AGG_GPUS="$(ns_gpus)"
run_bench agg "${AGG_URL}"
score agg "${AGG_GPUS}"

py '
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
print("layout        gpus  joint_attainment_share  goodput_per_gpu  ttft_ms.p99  longest_gap_ms.p99  failed")
for name, s, g in (("disagg-pd", a, sys.argv[3]), ("agg-baseline", b, sys.argv[4])):
    print("{:<13} {:>4}  {:>22.4f}  {:>15.4f}  {:>11.1f}  {:>18.1f}  {:>6}".format(
        name, g, s["joint_attainment_share"], s["goodput_per_gpu"],
        s["ttft_ms"]["p99"], s["longest_gap_ms"]["p99"], s["failed_requests"]))
' "${WORK_DIR}/disagg-summary.json" "${WORK_DIR}/agg-summary.json" "${DISAGG_GPUS}" "${AGG_GPUS}" >&2
pass "criterion 5: both layouts scored with the same load (${BENCH_NUM_PROMPTS} requests at ${BENCH_REQUEST_RATE}/s) and the same SLO (TTFT <= ${SLO_TTFT_MS} ms, longest gap <= ${SLO_GAP_MS} ms)"

# ------------------------------------------- 6. criterion 6: teardown

teardown || fail "criterion 6: teardown left a node, instance, launch template or EBS volume of this run behind"
pass "criterion 6: teardown removed every node, instance, launch template and EBS volume of this run"
