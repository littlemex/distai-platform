#!/usr/bin/env bash
# Throwaway real-hardware verification for #111 (vllm/neuron disagg-pd's own
# round trip: EFA device-plugin toleration retest, a correctly-configured
# trn-prefill pool, and a landing node for the proxy), run directly against
# terraform/helm, outside Argo CD/gitops bootstrap on purpose
# (examples/inference/README.md's own statement that these charts are
# self-contained). Not part of the PR diff, not merged anywhere -- same
# convention the prior attempts on #80/#111 used (see verify80.sh, #80).
#
# Three fixes versus verify80.sh, all tracked in #111:
#   1. trn-prefill now sets pool.networkInterfaces (one EFA interface), the
#      same as trn-decode -- the chart's own README Prerequisites require an
#      EFA interface on BOTH pools; the #80 attempt only set it on trn-decode.
#   2. agg-baseline is not installed in this script at all, so there is no
#      stale release left holding trn-prefill's one Neuron device before
#      disagg-pd is installed (the #80 attempt's own second bug). agg-baseline
#      already has two independent, confirmed real-hardware passes (#80); this
#      script's only job is disagg-pd's own round trip.
#   3. A third, untainted, generic CPU capacity pool is created (chart
#      defaults: no accelerator.*, no taint -- the same shape as this
#      platform's own gitops/cells/example-cell/capacity-pool/cpu.yaml) for
#      disagg-pd's proxy to land on with the chart's own default
#      proxy.nodeSelector/proxy.tolerations ({}/[]), unchanged. This is #111's
#      own Option B: the chart's values are not touched, a cell that serves
#      this chart gets one more ordinary, untainted pool, exactly like a
#      real deployment would already need for any non-accelerator workload.
#
# Required env: AWS_PROFILE, AWS_REGION, NAME, STATE_BUCKET, STATE_REGION,
#   ADMIN_PRINCIPAL_ARN, MY_CIDR
# Optional: STOP_BEFORE_WORKLOAD=1 to tear down right after the capacity
#   pools reach Ready, before any workload (and before any Trainium
#   NodeClaim) -- the dry-run mode.
set -euo pipefail

: "${AWS_PROFILE:?}"; : "${AWS_REGION:?}"; : "${NAME:?}"
: "${STATE_BUCKET:?}"; : "${STATE_REGION:?}"
: "${ADMIN_PRINCIPAL_ARN:?}"; : "${MY_CIDR:?}"
export AWS_PROFILE AWS_REGION

TERRAFORM=terraform
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/infra/foundation"
WORK_DIR="$(mktemp -d)"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1
STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="verify80-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
TFVARS="${WORK_DIR}/v80.tfvars.json"

# shellcheck source=infra/foundation/tests/e2e-lib.sh
source "${SCRIPT_DIR}/infra/foundation/tests/e2e-lib.sh"

APPLY_ATTEMPTED=0
DESTROYED=0
VPC_ID=""
HELM_RELEASES=()   # "name|namespace", uninstalled in reverse on cleanup
KUEUE_MANIFEST=""  # set once helm template'd; deleted with kubectl delete -f on cleanup

helm_release() { HELM_RELEASES+=("$1|$2"); }

# require TIMEOUT INTERVAL DESCRIPTION COMMAND...: wait_until, but a timeout
# is treated as a named failure (fail(), with a pod/describe dump the caller
# supplies via on_timeout), never a bare `set -e` abort with no diagnosis.
# This is the fix for the harness bug found earlier this issue: a wait whose
# timeout was not guarded aborted the whole run (teardown included) before
# the step after it -- sending a real request -- ever ran.
require() {
  local timeout="$1" interval="$2" desc="$3"
  shift 3
  if ! wait_until "${timeout}" "${interval}" "${desc}" "$@"; then
    fail "timed out after ${timeout}s waiting for: ${desc}"
  fi
}

DIAG_DUMPED=0
# dump_diagnostics: pods/events/describe/logs across our own namespaces,
# plus NodeClaims/Nodes. Always called from cleanup() BEFORE any teardown
# step, on any non-zero exit -- not only the specific waits that already
# call it, so a failure anywhere still leaves a full picture.
dump_diagnostics() {
  [[ "${DIAG_DUMPED}" -eq 1 ]] && return 0
  DIAG_DUMPED=1
  echo "===== DIAGNOSTICS (before any teardown) ====="
  echo "--- kubectl get nodeclaims,nodes -o wide ---"
  kubectl get nodeclaims,nodes -o wide 2>&1
  for ns in pd-neuron-disagg; do
    echo "--- kubectl get pods -n ${ns} -o wide ---"
    kubectl -n "${ns}" get pods -o wide 2>&1
    echo "--- kubectl get events -n ${ns} --sort-by=.lastTimestamp ---"
    kubectl -n "${ns}" get events --sort-by=.lastTimestamp 2>&1 | tail -n 100
    for pod in $(kubectl -n "${ns}" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      echo "--- kubectl -n ${ns} describe pod ${pod} ---"
      kubectl -n "${ns}" describe pod "${pod}" 2>&1
      echo "--- kubectl -n ${ns} logs ${pod} --all-containers --previous ---"
      kubectl -n "${ns}" logs "${pod}" --all-containers --previous 2>&1
      echo "--- kubectl -n ${ns} logs ${pod} --all-containers (tail 200) ---"
      kubectl -n "${ns}" logs "${pod}" --all-containers 2>&1 | tail -n 200
    done
  done
  echo "===== END DIAGNOSTICS ====="
}

cleanup() {
  local rc=$?
  set +e
  if [[ "${APPLY_ATTEMPTED}" -eq 1 && "${DESTROYED}" -eq 0 ]]; then
    [[ "${rc}" -ne 0 ]] && dump_diagnostics
    info "cleanup: uninstalling helm releases (reverse order)"
    for ((i = ${#HELM_RELEASES[@]} - 1; i >= 0; i--)); do
      IFS='|' read -r rn rns <<<"${HELM_RELEASES[$i]}"
      helm uninstall "$rn" -n "$rns" --wait --timeout 5m >/dev/null 2>&1 || true
    done
    [[ -n "${KUEUE_MANIFEST}" && -f "${KUEUE_MANIFEST}" ]] && kubectl delete -f "${KUEUE_MANIFEST}" --ignore-not-found --timeout=60s >/dev/null 2>&1
    kubectl delete namespace pd-neuron-disagg kueue-system neuron-device-plugin --ignore-not-found --timeout=60s >/dev/null 2>&1
    info "cleanup: terraform destroy"
    tf destroy -auto-approve -input=false -var-file="${TFVARS}"
    local drc=$?
    if [[ "${drc}" -eq 0 ]]; then
      DESTROYED=1
      info "cleanup: terraform destroy completed"
    else
      log "FAIL cleanup: terraform destroy exited ${drc}; remove by hand (NAME=${NAME}, region=${AWS_REGION})"
    fi
    report_leftovers 120 || true
  fi
  echo
  if [[ "${rc}" -eq 0 ]]; then
    log "RESULT PASS (run ${RUN_ID}, work dir ${WORK_DIR})"
  else
    log "RESULT FAIL exit=${rc} (run ${RUN_ID}, work dir ${WORK_DIR})"
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

tf() { "${TERRAFORM}" -chdir="${ROOT}" "$@"; }
tf_out() { tf output -raw "$1"; }

# wait_pod_ready NAMESPACE LABEL_SELECTOR LOGFILE DEADLINE_SECONDS DESC
# -> prints the pod name on success, returns 1 (no fail()) on timeout so the
# caller decides what extra diagnosis to dump before calling fail() itself.
# Captures `kubectl logs --previous` on every restart (the gap the original
# attempt on real hardware had).
wait_pod_ready() {
  local ns="$1" selector="$2" logfile="$3" deadline_s="$4" desc="$5"
  local last_restarts=-1 deadline
  : >"${logfile}"
  deadline=$(( $(date +%s) + deadline_s ))
  while (( $(date +%s) < deadline )); do
    local pod restarts ready
    pod="$(kubectl -n "${ns}" get pods -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${pod}" ]]; then
      restarts="$(kubectl -n "${ns}" get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
      ready="$(kubectl -n "${ns}" get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
      if [[ "${restarts}" != "${last_restarts}" ]]; then
        {
          echo "=== $(date -u +%FT%TZ) pod=${pod} restarts=${restarts} ready=${ready} ==="
          echo "--- kubectl logs --previous (the just-crashed container, if any) ---"
          kubectl -n "${ns}" logs "${pod}" --previous 2>&1 || true
          echo "--- kubectl logs (current/live container) ---"
          kubectl -n "${ns}" logs "${pod}" 2>&1 | tail -n 100 || true
          echo "--- kubectl describe pod (events tail) ---"
          kubectl -n "${ns}" describe pod "${pod}" 2>&1 | tail -n 40 || true
        } >>"${logfile}"
        last_restarts="${restarts}"
      fi
      if [[ "${ready}" == "true" ]]; then
        printf '%s' "${pod}"
        return 0
      fi
    fi
    sleep 15
  done
  log "FAIL ${desc}: never became Ready within ${deadline_s}s (see ${logfile})"
  return 1
}

# service_host NAMESPACE RELEASE COMPONENT -> prints the Service name, read
# from the live cluster (never assumed/hardcoded): the chart's own rendered
# Service carries app.kubernetes.io/instance=RELEASE and
# app.kubernetes.io/component=COMPONENT, so this is the exact selector a
# client would use, not a guess at the chart's own fullname template. Fails
# loudly (via fail(), not a silent empty string) if no such Service exists.
service_host() {
  local ns="$1" release="$2" component="$3" name
  name="$(kubectl -n "${ns}" get svc \
    -l "app.kubernetes.io/instance=${release},app.kubernetes.io/component=${component}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${name}" ]] || fail "service_host: no Service with instance=${release},component=${component} in ${ns} (kubectl get svc -n ${ns} --show-labels)"
  printf '%s' "${name}"
}

# svc_name_from_template CHART_DIR RELEASE COMPONENT [SET...] -> the Service
# name `helm template` would render for that component, with no cluster
# needed at all. Used in the dry run (before any Trainium capacity, before
# even `helm install`) to confirm service_host()'s label-based lookup will
# find the right object once installed -- the two must agree.
SVC_NAME_PY="${WORK_DIR:-/tmp}/svc_name_from_template.py"
cat >"${SVC_NAME_PY}" <<'PY'
import sys
component = sys.argv[1]
docs = sys.stdin.read().split("\n---\n")
want = f"app.kubernetes.io/component: {component}"
for doc in docs:
    if "kind: Service" not in doc or want not in doc:
        continue
    for line in doc.splitlines():
        if line.startswith("  name:"):
            print(line.split(":", 1)[1].strip())
            sys.exit(0)
sys.exit(1)
PY
svc_name_from_template() {
  local chart_dir="$1" release="$2" component="$3"
  shift 3
  # The python SCRIPT is a file (python3 -I path/to.py), never fed via "-"
  # on stdin: "python3 - <<HEREDOC" reads the heredoc as the PROGRAM, not
  # as data, which silently discards the piped `helm template` output --
  # the exact bug the dry run caught before any real-hardware attempt.
  helm template "${release}" "${chart_dir}" "$@" 2>/dev/null | python3 -I "${SVC_NAME_PY}" "${component}"
}

# send_completion_exec NAMESPACE EXEC_POD EXEC_CONTAINER HOST PORT MODEL LOGFILE LABEL
# Sends the completion request by exec'ing into a Pod that is ALREADY
# Ready (the engine itself, or one of the disaggregated roles), never a new
# throwaway client Pod -- no image pull, no scheduling wait, so no new
# "Pod never reached Running" failure mode to guard. Prefers curl, falls
# back to python3's own urllib (both already in the pinned image).
send_completion_exec() {
  local ns="$1" pod="$2" container="$3" host="$4" port="$5" model="$6" logfile="$7" label="$8"
  local url="http://${host}:${port}/v1/completions"
  local payload="{\"model\":\"${model}\",\"prompt\":\"The capital of France is\",\"max_tokens\":8}"
  local resp has_curl
  has_curl="$(kubectl -n "${ns}" exec "${pod}" -c "${container}" -- sh -c 'command -v curl' 2>/dev/null || true)"
  if [[ -n "${has_curl}" ]]; then
    resp="$(kubectl -n "${ns}" exec "${pod}" -c "${container}" -- \
      curl -sS -m 90 -X POST "${url}" -H 'Content-Type: application/json' -d "${payload}" 2>&1)" || true
  else
    resp="$(kubectl -n "${ns}" exec "${pod}" -c "${container}" -- python3 -c "
import json, urllib.request
req = urllib.request.Request('${url}', data=json.dumps(${payload}).encode(), headers={'Content-Type': 'application/json'})
print(urllib.request.urlopen(req, timeout=90).read().decode())
" 2>&1)" || true
  fi
  {
    echo "=== $(date -u +%FT%TZ) ${label} completion request to ${url} (exec in ${ns}/${pod}, curl=${has_curl:+yes}${has_curl:-no}) ==="
    echo "REQUEST RESPONSE: ${resp}"
  } | tee -a "${logfile}"
  if echo "${resp}" | grep -q '"choices"'; then
    pass "${label}: a real completion request returned a choices[] response"
    return 0
  fi
  log "FAIL ${label}: the completion request did not return a choices[] response: ${resp}"
  return 1
}

for b in terraform aws kubectl helm; do require_bin "$b"; done
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || fail "MY_CIDR must be a CIDR"
aws sts get-caller-identity >/dev/null || fail "aws sts get-caller-identity"
pass "preflight ok, run ${RUN_ID}, work dir ${WORK_DIR}"

# --------------------------------------------------------- 1. foundation

cat >"${TFVARS}" <<JSON
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "argocd": null,
  "tags": {"${TEST_TAG_KEY}": "${RUN_ID}"}
}
JSON

tf init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true" || fail "terraform init"
pass "terraform init (key ${STATE_KEY})"

if ! existing="$(tf state list 2>&1)"; then
  [[ "${existing}" == *"No state file"* ]] || fail "terraform state list: ${existing}"
  existing=""
fi
[[ -z "${existing}" ]] || fail "state ${STATE_KEY} already has resources: $(tr '\n' ' ' <<<"${existing}")"
pass "state empty before apply"

APPLY_ATTEMPTED=1
apply_start="$(date +%s)"
tf apply -auto-approve -input=false -var-file="${TFVARS}" || fail "terraform apply"
pass "terraform apply ($(($(date +%s) - apply_start))s)"

CLUSTER="$(tf_out cluster_name)"
VPC_ID="$(tf_out vpc_id)"
NODE_ROLE="$(tf_out karpenter_node_role_name)"
QUEUE="$(tf_out karpenter_interruption_queue_name)"
pass "cluster=${CLUSTER} vpc=${VPC_ID} node_role=${NODE_ROLE}"

aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}" --kubeconfig "${KUBECONFIG}" >/dev/null \
  || fail "aws eks update-kubeconfig"
require 120 5 "kubectl can reach the API" kubectl get nodes >/dev/null 2>&1
pass "kubeconfig works"

# --------------------------------------------------------- 2. karpenter

helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
  --version 1.15.2 -n kube-system --wait --timeout 5m || fail "karpenter-crd install"
helm_release karpenter-crd kube-system
pass "karpenter-crd installed"

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.15.2 -n kube-system --skip-crds --wait --timeout 5m \
  --set serviceAccount.name=karpenter \
  --set settings.clusterName="${CLUSTER}" \
  --set settings.interruptionQueue="${QUEUE}" \
  --set controller.env[0].name=AWS_REGION \
  --set controller.env[0].value="${AWS_REGION}" \
  --set "tolerations[0].key=CriticalAddonsOnly" \
  --set "tolerations[0].operator=Exists" \
  || fail "karpenter install"
helm_release karpenter kube-system
require 180 10 "karpenter Deployment available" \
  kubectl -n kube-system wait deploy/karpenter --for=condition=Available --timeout=5s
pass "karpenter installed and Available"

# ------------------------------------------------------------- 3. kueue

helm template kueue oci://registry.k8s.io/kueue/charts/kueue --version 0.20.6 -n kueue-system \
  --set controllerManager.tolerations[0].key=CriticalAddonsOnly \
  --set controllerManager.tolerations[0].operator=Exists \
  --set-json 'controllerManager.affinity={"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"karpenter.sh/nodepool","operator":"DoesNotExist"}]}]}}}' \
  >"${WORK_DIR}/kueue.yaml" || fail "helm template kueue"
kubectl create namespace kueue-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply --server-side --force-conflicts -f "${WORK_DIR}/kueue.yaml" || fail "kubectl apply kueue (server-side)"
KUEUE_MANIFEST="${WORK_DIR}/kueue.yaml"  # not a helm release; torn down with kubectl delete -f in cleanup()
require 180 10 "kueue controller-manager available" \
  kubectl -n kueue-system wait deploy/kueue-controller-manager --for=condition=Available --timeout=5s
pass "kueue installed and Available"

# -------------------------------------------- 4. Neuron/EFA device plugins

kubectl create namespace neuron-device-plugin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install accel-neuron-device-plugin oci://public.ecr.aws/neuron/neuron-helm-chart \
  --version 1.11.2 -n neuron-device-plugin --wait --timeout 5m \
  --set devicePlugin.nodeSelector."distai\.dev/neuron-method"=device-plugin \
  --set draDriver.enabled=false \
  --set npd.namespaceOverride=neuron-device-plugin \
  || fail "accel-neuron-device-plugin install"
helm_release accel-neuron-device-plugin neuron-device-plugin
pass "accel-neuron-device-plugin installed"

helm repo add eks-charts https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks-charts >/dev/null 2>&1 || true
helm upgrade --install accel-efa-device-plugin-neuron eks-charts/aws-efa-k8s-device-plugin \
  --version v0.5.35 -n kube-system --wait --timeout 5m \
  --set image.tag="v0.5.22-eksbuild.9@sha256:a392d84ff82b23580fd92d0a6c770136c56d4a6ee979a47d1bf4e379a7171647" \
  --set-string nodeSelector."distai\.dev/neuron-method"=device-plugin \
  --set-string nodeSelector."distai\.dev/efa-attached"=true \
  --set securityContext.privileged=false \
  --set securityContext.allowPrivilegeEscalation=false \
  --set securityContext.runAsNonRoot=false \
  --set securityContext.runAsUser=0 \
  --set-json 'securityContext.capabilities={"drop":["ALL"]}' \
  || fail "accel-efa-device-plugin-neuron install"
helm_release accel-efa-device-plugin-neuron kube-system
pass "accel-efa-device-plugin-neuron installed"

# -------------------------------------------------------- 5. capacity pools

# Fix 1 (#111): trn-prefill now sets pool.networkInterfaces, the same single
# EFA interface layout as trn-decode. The chart's own README Prerequisites
# (examples/inference/vllm/neuron/disagg-pd/README.md) require an EFA
# interface on BOTH pools; the earlier #80 attempt's own trn-prefill release
# never set this at all, so prefill's default efaDevices:1 request could
# never be satisfied on that pool regardless of the device-plugin toleration
# fix (#104).
helm upgrade --install trn-prefill "${SCRIPT_DIR}/gitops/charts/capacity-pool" \
  -n kube-system --wait --timeout 3m \
  --set clusterName="${CLUSTER}" --set nodeRole="${NODE_ROLE}" \
  --set pool.name=trn-prefill --set pool.capacityType=flex \
  --set-json 'pool.requirements=[{"key":"kubernetes.io/arch","operator":"In","values":["amd64"]},{"key":"node.kubernetes.io/instance-type","operator":"In","values":["trn2.3xlarge"]}]' \
  --set pool.disruption.consolidationPolicy=WhenEmptyOrUnderutilized \
  --set pool.disruption.consolidateAfter=15m \
  --set pool.rootVolumeSizeGi=100Gi \
  --set-json 'pool.networkInterfaces=[{"networkCardIndex":0,"deviceIndex":0,"interfaceType":"interface"},{"networkCardIndex":0,"deviceIndex":1,"interfaceType":"efa-only"}]' \
  --set accelerator.resourceName=aws.amazon.com/neuron \
  --set accelerator.taint.key=aws.amazon.com/neuron \
  --set-string accelerator.taint.value=true --set accelerator.taint.effect=NoSchedule \
  --set accelerator.methodLabel.key="distai.dev/neuron-method" \
  --set accelerator.methodLabel.value=device-plugin \
  || fail "capacity-pool trn-prefill install"
helm_release trn-prefill kube-system
pass "trn-prefill NodePool/EC2NodeClass/ResourceFlavor installed (with an EFA interface)"

helm upgrade --install trn-decode "${SCRIPT_DIR}/gitops/charts/capacity-pool" \
  -n kube-system --wait --timeout 3m \
  --set clusterName="${CLUSTER}" --set nodeRole="${NODE_ROLE}" \
  --set pool.name=trn-decode --set pool.capacityType=flex \
  --set-json 'pool.requirements=[{"key":"kubernetes.io/arch","operator":"In","values":["amd64"]},{"key":"node.kubernetes.io/instance-type","operator":"In","values":["trn2.3xlarge"]}]' \
  --set pool.disruption.consolidationPolicy=WhenEmptyOrUnderutilized \
  --set pool.disruption.consolidateAfter=15m \
  --set pool.rootVolumeSizeGi=100Gi \
  --set-json 'pool.networkInterfaces=[{"networkCardIndex":0,"deviceIndex":0,"interfaceType":"interface"},{"networkCardIndex":0,"deviceIndex":1,"interfaceType":"efa-only"}]' \
  --set accelerator.resourceName=aws.amazon.com/neuron \
  --set accelerator.taint.key=aws.amazon.com/neuron \
  --set-string accelerator.taint.value=true --set accelerator.taint.effect=NoSchedule \
  --set accelerator.methodLabel.key="distai.dev/neuron-method" \
  --set accelerator.methodLabel.value=device-plugin \
  || fail "capacity-pool trn-decode install"
helm_release trn-decode kube-system
pass "trn-decode NodePool/EC2NodeClass/ResourceFlavor installed"

# Fix 3 (#111), Option B: a third, ordinary, untainted capacity pool for the
# proxy to land on. No accelerator.* and no taint are set, the same chart
# defaults as this platform's own gitops/cells/example-cell/capacity-pool/
# cpu.yaml -- this is not a new mechanism, it is the shape every other cell
# in this repository already uses for a plain CPU workload. disagg-pd's own
# chart is untouched: proxy.nodeSelector/proxy.tolerations stay at the
# chart's default ({}/[]), because this pool's nodes carry no taint for
# them to need to tolerate in the first place.
helm upgrade --install generic "${SCRIPT_DIR}/gitops/charts/capacity-pool" \
  -n kube-system --wait --timeout 3m \
  --set clusterName="${CLUSTER}" --set nodeRole="${NODE_ROLE}" \
  --set pool.name=generic --set pool.capacityType=flex \
  --set pool.disruption.consolidationPolicy=WhenEmptyOrUnderutilized \
  --set pool.disruption.consolidateAfter=15m \
  --set pool.rootVolumeSizeGi=100Gi \
  || fail "capacity-pool generic install"
helm_release generic kube-system
pass "generic NodePool/EC2NodeClass/ResourceFlavor installed (no accelerator, no taint)"

require 60 5 "trn-prefill NodePool Ready" \
  bash -c 'kubectl get nodepool trn-prefill -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -q True'
pass "trn-prefill NodePool Ready"

require 60 5 "trn-decode NodePool Ready" \
  bash -c 'kubectl get nodepool trn-decode -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -q True'
pass "trn-decode NodePool Ready"

require 60 5 "generic NodePool Ready" \
  bash -c 'kubectl get nodepool generic -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -q True'
pass "generic NodePool Ready"

# Confirm, with no cluster and no Trainium needed, that service_host()'s
# live label-based lookup (instance=RELEASE,component=COMPONENT) agrees
# with what `helm template` actually renders, for the Service a completion
# request will target. This is the fix for an earlier round's bug (a
# Service hostname assumed instead of read): from here on, nothing in this
# script names a Service directly.
MODEL_ID_CHECK="unsloth/Llama-3.2-1B-Instruct"
disagg_tmpl_svc="$(svc_name_from_template "${SCRIPT_DIR}/examples/inference/vllm/neuron/disagg-pd" disaggn proxy \
  --set model.name="${MODEL_ID_CHECK}" --set prefill.neuronCoresPerEngine=1 --set decode.neuronCoresPerEngine=1)" \
  || fail "helm template: vllm/neuron/disagg-pd rendered no Service with component=proxy"
pass "disagg-pd template proxy Service name: ${disagg_tmpl_svc}"

if [[ "${STOP_BEFORE_WORKLOAD:-0}" == "1" ]]; then
  info "STOP_BEFORE_WORKLOAD=1: stopping before any workload is installed (no Trainium NodeClaim triggered yet); tearing down now"
  exit 0
fi

# ------------------------------------------- 6. vllm/neuron/disagg-pd
# Fix 2 (#111): agg-baseline is deliberately NOT installed anywhere in this
# script, so there is no stale release that could still be holding
# trn-prefill's one Neuron device when disagg-pd's own prefill pod asks for
# it (the earlier #80 attempt's own second bug: agg-baseline was installed
# first on the same pool and never uninstalled before disagg-pd). agg-
# baseline already has two independent, confirmed real-hardware passes
# (#80); this script's only job is disagg-pd's own round trip.

MODEL_ID="unsloth/Llama-3.2-1B-Instruct"
kubectl create namespace pd-neuron-disagg --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install disaggn "${SCRIPT_DIR}/examples/inference/vllm/neuron/disagg-pd" \
  -n pd-neuron-disagg \
  --set model.name="${MODEL_ID}" \
  --set prefill.neuronCoresPerEngine=1 --set decode.neuronCoresPerEngine=1 \
  --set-json 'placement.tolerations=[{"key":"aws.amazon.com/neuron","operator":"Equal","value":"true","effect":"NoSchedule"}]' \
  --set placement.nodeSelectorKey="karpenter.sh/nodepool" \
  --set prefill.nodeSelectorValue="trn-prefill" \
  --set decode.nodeSelectorValue="trn-decode" \
  --set prefill.extraArgs[0]="--max-model-len" --set prefill.extraArgs[1]="4096" \
  --set prefill.extraArgs[2]="--max-num-seqs" --set prefill.extraArgs[3]="4" \
  --set decode.extraArgs[0]="--max-model-len" --set decode.extraArgs[1]="4096" \
  --set decode.extraArgs[2]="--max-num-seqs" --set decode.extraArgs[3]="4" \
  || fail "disagg-pd helm install"
helm_release disaggn pd-neuron-disagg
pass "disagg-pd chart installed (model=${MODEL_ID})"

PREFILL_LOG="${WORK_DIR}/disagg-prefill.log"
DECODE_LOG="${WORK_DIR}/disagg-decode.log"
PROXY_LOG="${WORK_DIR}/disagg-proxy.log"

PREFILL_POD="$(wait_pod_ready pd-neuron-disagg "app.kubernetes.io/instance=disaggn,app.kubernetes.io/component=prefill" \
  "${PREFILL_LOG}" 1800 "disagg-pd prefill pod")"
PREFILL_RC=$?
if [[ "${PREFILL_RC}" -ne 0 ]]; then
  cat "${PREFILL_LOG}"
  dump_diagnostics
  fail "disagg-pd prefill pod did not reach Ready"
fi
pass "disagg-pd prefill pod Ready: ${PREFILL_POD} (see ${PREFILL_LOG})"

DECODE_POD="$(wait_pod_ready pd-neuron-disagg "app.kubernetes.io/instance=disaggn,app.kubernetes.io/component=decode" \
  "${DECODE_LOG}" 1800 "disagg-pd decode pod")"
DECODE_RC=$?
if [[ "${DECODE_RC}" -ne 0 ]]; then
  cat "${DECODE_LOG}"
  dump_diagnostics
  fail "disagg-pd decode pod did not reach Ready"
fi
pass "disagg-pd decode pod Ready: ${DECODE_POD} (see ${DECODE_LOG})"

# The proxy itself: the cause this issue was actually opened for. It has no
# device/EFA request, so a timeout here means the generic pool fix (above)
# did not land it anywhere, not a device-plugin or EFA problem.
PROXY_POD="$(wait_pod_ready pd-neuron-disagg "app.kubernetes.io/instance=disaggn,app.kubernetes.io/component=proxy" \
  "${PROXY_LOG}" 900 "disagg-pd proxy pod")"
PROXY_RC=$?
if [[ "${PROXY_RC}" -ne 0 ]]; then
  cat "${PROXY_LOG}"
  dump_diagnostics
  fail "disagg-pd proxy pod did not reach Ready"
fi
pass "disagg-pd proxy pod Ready: ${PROXY_POD} (see ${PROXY_LOG}), landed on the generic pool"

# The disaggregated chart's proxy, not the engines directly, is the
# client-facing endpoint. Exec into the proxy pod itself (already Ready, no
# new Pod needed) and send the request to the proxy's own Service, read
# live from the cluster (service_host(), never assumed).
DISAGG_SVC="$(service_host pd-neuron-disagg disaggn proxy)"
send_completion_exec pd-neuron-disagg "${PROXY_POD}" proxy "${DISAGG_SVC}" 8000 "${MODEL_ID}" "${WORK_DIR}/disagg-request.log" disagg \
  || { dump_diagnostics; fail "disagg-pd: completion request through the proxy did not succeed"; }

# Evidence that the KV cache actually moved from prefill to decode over
# NIXL, not just that a response came back: both engines log the plugin's
# own connector rewrite (NeuronNixlConnector) and NIXL's own handshake/
# transfer lines. Collected into one dedicated file regardless of whether
# dump_diagnostics() also ran, so the PR's own Test Results has a precise
# grep target instead of a full log dump.
KV_EVIDENCE="${WORK_DIR}/kv-transfer-evidence.log"
{
  echo "=== prefill ($(date -u +%FT%TZ)) ==="
  kubectl -n pd-neuron-disagg logs "${PREFILL_POD}" --all-containers 2>&1 \
    | grep -iE 'nixl|connector|handshake|libfabric|efa' || true
  echo "=== decode ($(date -u +%FT%TZ)) ==="
  kubectl -n pd-neuron-disagg logs "${DECODE_POD}" --all-containers 2>&1 \
    | grep -iE 'nixl|connector|handshake|libfabric|efa' || true
} >"${KV_EVIDENCE}" 2>&1
if grep -qi 'NeuronNixlConnector' "${KV_EVIDENCE}" && grep -qi 'nixl' "${KV_EVIDENCE}"; then
  pass "disagg-pd: NIXL/NeuronNixlConnector evidence captured (see ${KV_EVIDENCE})"
else
  dump_diagnostics
  fail "disagg-pd: no NIXL/NeuronNixlConnector evidence in prefill/decode logs (see ${KV_EVIDENCE})"
fi

info "verification steps complete; proceeding to teardown"
