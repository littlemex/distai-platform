#!/usr/bin/env bash
# Real-hardware verification of examples/inference/vllm/neuron/{agg-baseline,disagg-pd}
# (Issue #80) on trn2.3xlarge spot, ap-southeast-4. Bypasses Argo CD/gitops
# bootstrap on purpose (examples/inference's own README: these charts are
# self-contained and do not depend on this repo's GitOps delivery; the
# capacity-pool chart's own README already has a precedent for a direct
# `helm upgrade --install` real-hardware check, 2026-11-22, p4d.24xlarge x2).
# PASS/FAIL per step; always tears down (EXIT trap), always does an
# independent read-only leftover sweep.
set -euo pipefail

NAME="dp-80-trn"
AWS_REGION="ap-southeast-4"
STATE_BUCKET="distai-eks-tfstate-776010787911"
STATE_REGION="ap-northeast-1"
AWS_PROFILE="default"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}" && git rev-parse --show-toplevel)"
ROOT="${REPO_ROOT}/infra/foundation"
TERRAFORM="terraform"
WORK_DIR="$(mktemp -d)"
TFVARS="${WORK_DIR}/dp80.tfvars.json"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1
STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="dp80-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
VPC_ID=""
APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
RESULTS_DIR="${WORK_DIR}/results"
mkdir -p "${RESULTS_DIR}"

# shellcheck source=e2e-lib.sh
source "${ROOT}/tests/e2e-lib.sh"

K() { kubectl --kubeconfig "${KUBECONFIG}" "$@"; }
HM() { helm --kubeconfig "${KUBECONFIG}" "$@"; }

cleanup() {
  local rc=$?
  set +e
  info "cleanup: starting (rc so far ${rc})"
  if kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1; then
    for rel in dp80-disagg dp80-agg; do
      HM uninstall "${rel}" -n default --wait --timeout 5m >/dev/null 2>&1
    done
    K delete nodeclaims --all --wait=true --timeout=10m >/dev/null 2>&1
    wait_until 300 10 "no NodeClaims left" bash -c "[ -z \"\$(kubectl --kubeconfig '${KUBECONFIG}' get nodeclaims -o name 2>/dev/null)\" ]"
    for rel in trn-prefill trn-decode; do
      HM uninstall "capacity-pool-${rel}" -n kube-system >/dev/null 2>&1
    done
    HM uninstall accel-efa-device-plugin-neuron -n kube-system >/dev/null 2>&1
    HM uninstall accel-neuron-device-plugin -n neuron-device-plugin >/dev/null 2>&1
    HM uninstall karpenter -n kube-system >/dev/null 2>&1
    HM uninstall karpenter-crd -n kube-system >/dev/null 2>&1
    # kueue was applied with kubectl (helm template | kubectl apply
    # --server-side), not `helm install` -- no Helm release to uninstall;
    # it is purely in-cluster (no EC2/external resource of its own), so
    # the terraform destroy below removing the whole EKS cluster is enough.
  fi
  if [[ "${APPLY_ATTEMPTED}" -eq 1 && "${DESTROYED}" -eq 0 ]]; then
    tf() { "${TERRAFORM}" -chdir="${ROOT}" "$@"; }
    tf destroy -auto-approve -input=false -var-file="${TFVARS}"
    local destroy_rc=$?
    if [[ "${destroy_rc}" -ne 0 ]]; then
      log "FAIL cleanup: terraform destroy exited ${destroy_rc}; cell ${NAME} may need manual removal"
    else
      info "cleanup: terraform destroy completed"
      DESTROYED=1
    fi
  fi
  report_leftovers 90 || true
  echo "===RESULTS_DIR==${RESULTS_DIR}==="
  tar -C "${WORK_DIR}" -czf /tmp/dp80-results.tgz results 2>/dev/null || true
  if command -v aws >/dev/null 2>&1; then
    aws s3 cp /tmp/dp80-results.tgz "s3://${STATE_BUCKET}/distai-platform/${NAME}/results.tgz" --region "${STATE_REGION}" --only-show-errors 2>&1 || true
  fi
  echo
  if [[ "${rc}" -eq 0 ]]; then
    log "RESULT PASS: real-hardware verification complete (run ${RUN_ID})"
  else
    log "RESULT FAIL: ${FAILED_STEP:-exit ${rc}} (run ${RUN_ID})"
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

tf() { "${TERRAFORM}" -chdir="${ROOT}" "$@"; }
tf_out() { tf output -raw "$1"; }

# --------------------------------------------------------------- 1. apply

# admin_principal_arns must be a plain IAM role/user ARN, not an STS
# assumed-role ARN (infra/foundation/variables.tf's own validation rule) --
# the runner's own identity is always an assumed-role session, so convert
# arn:aws:sts::ACCOUNT:assumed-role/ROLE/SESSION to arn:aws:iam::ACCOUNT:role/ROLE.
ASSUMED_ARN="$(aws sts get-caller-identity --query Arn --output text)"
ADMIN_PRINCIPAL_ARN="$(printf '%s' "${ASSUMED_ARN}" | sed -E 's#^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.*#arn:aws:iam::\1:role/\2#')"
[[ "${ADMIN_PRINCIPAL_ARN}" == arn:aws:iam::* ]] || fail "could not derive an IAM role ARN from ${ASSUMED_ARN}"
MY_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
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

existing_state="$(tf state list 2>&1)" || true
[[ -z "${existing_state}" || "${existing_state}" == *"No state file"* ]] \
  || fail "state at key ${STATE_KEY} already has resources: $(tr '\n' ' ' <<<"${existing_state}")"
pass "state empty before apply"

APPLY_ATTEMPTED=1
apply_start="$(date +%s)"
tf apply -auto-approve -input=false -var-file="${TFVARS}" || fail "terraform apply"
pass "terraform apply ($(($(date +%s) - apply_start))s)"

CLUSTER_NAME="$(tf_out cluster_name)"
NODE_ROLE="$(tf_out karpenter_node_role_name)"
INTERRUPT_QUEUE="$(tf_out karpenter_interruption_queue_name)"
VPC_ID="$(tf_out vpc_id)"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --kubeconfig "${KUBECONFIG}" >/dev/null \
  || fail "update-kubeconfig"
wait_until 180 10 "nodes command works" bash -c "kubectl --kubeconfig '${KUBECONFIG}' get nodes >/dev/null 2>&1" \
  || fail "kubectl get nodes never worked"
pass "kubeconfig and API access ($(K get nodes --no-headers | wc -l | tr -d ' ') system node(s))"

# --------------------------------------------------------- 2. Karpenter

HM upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version 1.15.2 \
  -n kube-system --wait --timeout 5m || fail "karpenter-crd install"
pass "karpenter-crd installed"

cat >"${WORK_DIR}/karpenter-values.yaml" <<YAML
serviceAccount:
  name: karpenter
controller:
  env:
    - name: AWS_REGION
      value: "${AWS_REGION}"
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
settings:
  clusterName: "${CLUSTER_NAME}"
  interruptionQueue: "${INTERRUPT_QUEUE}"
YAML
HM upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.2 \
  -n kube-system --skip-crds -f "${WORK_DIR}/karpenter-values.yaml" --wait --timeout 5m \
  || fail "karpenter install"
pass "karpenter installed"
wait_until 180 10 "karpenter pod Ready" bash -c "K() { kubectl --kubeconfig '${KUBECONFIG}' \"\$@\"; }; [ \"\$(K get pods -n kube-system -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)\" = true ]" \
  || fail "karpenter pod never became Ready"
pass "karpenter pod Ready"

# capacity-pool's chart renders a Kueue ResourceFlavor; Kueue's own CRDs
# must exist before that chart can render at all (found by attempt 2 of
# this verification: "no matches for kind ResourceFlavor"). Same chart,
# version and placement as gitops/addons/kueue/addon.yaml, installed
# directly instead of through Argo CD.
cat >"${WORK_DIR}/kueue-values.yaml" <<'YAML'
controllerManager:
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: karpenter.sh/nodepool
                operator: DoesNotExist
YAML
K create namespace kueue-system --dry-run=client -o yaml | K apply -f - || fail "kueue-system namespace"
# Helm 3.22 has no --server-side flag (confirmed: `helm upgrade --help` on
# this exact runner, 2026-11-26 -- unknown flag). gitops/addons/kueue's own
# ServerSideApply=true is an Argo CD sync option, which switches Argo CD's
# own apply from client-side to server-side for the generated manifests;
# the direct-helm equivalent is `helm template` piped into
# `kubectl apply --server-side`, not a Helm CLI flag that does not exist.
HM template kueue oci://registry.k8s.io/kueue/charts/kueue --version 0.20.6 \
  -n kueue-system -f "${WORK_DIR}/kueue-values.yaml" > "${WORK_DIR}/kueue-rendered.yaml" \
  || fail "kueue helm template"
K apply --server-side --force-conflicts -f "${WORK_DIR}/kueue-rendered.yaml" || fail "kueue apply --server-side"
wait_until 240 10 "kueue CRDs established" bash -c \
  "kubectl --kubeconfig '${KUBECONFIG}' get crd resourceflavors.kueue.x-k8s.io >/dev/null 2>&1" \
  || fail "kueue ResourceFlavor CRD never appeared"
if wait_until 180 10 "kueue controller pod Ready" bash -c \
  "kubectl --kubeconfig '${KUBECONFIG}' get pods -n kueue-system -l app.kubernetes.io/name=kueue -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true"; then
  pass "kueue controller pod Ready"
else
  K get pods -n kueue-system -o wide
  log "INFO kueue controller pod not confirmed Ready within 3m (non-fatal here; the next step, capacity-pool install, fails clearly if the CRD/webhook is not actually usable)"
fi
# Give a freshly-Ready controller's webhook (TLS cert + service endpoints)
# a short margin to finish registering before anything calls it.
sleep 15
pass "kueue installed (ResourceFlavor CRD now exists)"

# --------------------------------------------------- 3. Neuron + EFA device plugins

HM upgrade --install accel-neuron-device-plugin oci://public.ecr.aws/neuron/neuron-helm-chart --version 1.11.2 \
  -n neuron-device-plugin --create-namespace \
  --set devicePlugin.nodeSelector."distai\.dev/neuron-method"=device-plugin \
  --set draDriver.enabled=false \
  --set npd.namespaceOverride=neuron-device-plugin \
  --wait --timeout 5m || fail "accel-neuron-device-plugin install"
pass "accel-neuron-device-plugin installed"

HM repo add eks-charts https://aws.github.io/eks-charts >/dev/null
HM repo update eks-charts >/dev/null
HM upgrade --install accel-efa-device-plugin-neuron eks-charts/aws-efa-k8s-device-plugin --version v0.5.35 \
  -n kube-system \
  --set image.tag="v0.5.22-eksbuild.9@sha256:a392d84ff82b23580fd92d0a6c770136c56d4a6ee979a47d1bf4e379a7171647" \
  --set-string nodeSelector."distai\.dev/neuron-method"=device-plugin \
  --set-string nodeSelector."distai\.dev/efa-attached"="true" \
  --set securityContext.privileged=false \
  --set securityContext.allowPrivilegeEscalation=false \
  --set securityContext.runAsNonRoot=false \
  --set securityContext.runAsUser=0 \
  --set-json securityContext.capabilities='{"drop":["ALL"]}' \
  || fail "accel-efa-device-plugin-neuron install"
pass "accel-efa-device-plugin-neuron installed (DaemonSet; no node matches it yet)"

# --------------------------------------------------------- 4. capacity pools

render_pool() {
  local pool_name="$1" out="$2"
  cat >"${out}" <<YAML
clusterName: "${CLUSTER_NAME}"
nodeRole: "${NODE_ROLE}"
pool:
  name: ${pool_name}
  capacityType: flex
  requirements:
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64"]
    - key: karpenter.k8s.aws/instance-family
      operator: In
      values: ["trn2"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    # 15m, not the chart default 60s: #28's own real-hardware finding on this
    # exact pool shape (gitops/cells/dp-a19-trn-r3/capacity-pool/trn.yaml) --
    # 60s is shorter than a multi-gigabyte image can pull on a freshly
    # launched node, so WhenEmptyOrUnderutilized consolidation can reclaim a
    # node that is still pulling the (large) vLLM Neuron image, reading a
    # still-Pending pod as "empty". Using the known-good value here rather
    # than re-discovering the same failure.
    consolidateAfter: 15m
  rootVolumeSizeGi: "100Gi"
  networkInterfaces:
    - networkCardIndex: 0
      deviceIndex: 0
      interfaceType: interface
    - networkCardIndex: 0
      deviceIndex: 1
      interfaceType: efa-only
accelerator:
  resourceName: aws.amazon.com/neuron
  taint:
    key: aws.amazon.com/neuron
    value: "true"
    effect: NoSchedule
  methodLabel:
    key: distai.dev/neuron-method
    value: device-plugin
YAML
}

for pool in trn-prefill trn-decode; do
  render_pool "${pool}" "${WORK_DIR}/pool-${pool}.yaml"
  HM upgrade --install "capacity-pool-${pool}" "${REPO_ROOT}/gitops/charts/capacity-pool" \
    -n kube-system -f "${WORK_DIR}/pool-${pool}.yaml" --wait --timeout 3m \
    || fail "capacity-pool-${pool} install"
  pass "capacity-pool-${pool} installed (NodePool/EC2NodeClass/ResourceFlavor)"
done
for pool in trn-prefill trn-decode; do
  if K wait nodepool "${pool}" --for=condition=Ready --timeout=120s; then
    pass "NodePool ${pool} Ready"
  else
    log "INFO NodePool ${pool} did not report condition=Ready within 2m (non-fatal here; the real proof is a workload actually scheduling a node below)"
  fi
done

TOL_JSON='[{"key":"aws.amazon.com/neuron","value":"true","effect":"NoSchedule"}]'

echo "===CONFIG_DONE==="

# ------------------------------------------------------- 5. aggregated smoke

MODEL="unsloth/Llama-3.2-1B-Instruct"
HM upgrade --install dp80-agg "${REPO_ROOT}/examples/inference/vllm/neuron/agg-baseline" \
  -n default \
  --set model.name="${MODEL}" \
  --set engine.neuronCoresPerEngine=1 \
  --set-json engine.nodeSelector='{"karpenter.sh/nodepool":"trn-prefill"}' \
  --set-json engine.tolerations="${TOL_JSON}" \
  || fail "dp80-agg install"
pass "dp80-agg (aggregated baseline) release installed"

wait_until 900 15 "dp80-agg pod Ready" bash -c \
  "kubectl --kubeconfig '${KUBECONFIG}' get pods -n default -l app.kubernetes.io/instance=dp80-agg -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true" \
  || { K get pods -n default -o wide; K describe pods -n default -l app.kubernetes.io/instance=dp80-agg | tail -60; fail "dp80-agg engine never became Ready within 15m"; }
pass "dp80-agg engine Ready"

AGG_NODE="$(K get pods -n default -l app.kubernetes.io/instance=dp80-agg -o jsonpath='{.items[0].spec.nodeName}')"
AGG_INSTANCE="$(K get node "${AGG_NODE}" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
pass "dp80-agg engine on node ${AGG_NODE} (instance ${AGG_INSTANCE})"
K get node "${AGG_NODE}" -o jsonpath='{.status.allocatable}' | tee "${RESULTS_DIR}/agg-node-allocatable.json"
echo
AGG_SVC="$(K get svc -n default -l app.kubernetes.io/instance=dp80-agg -o jsonpath='{.items[0].metadata.name}')"
K port-forward -n default "svc/${AGG_SVC}" 18000:8000 >"${WORK_DIR}/agg-pf.log" 2>&1 &
PF_PID=$!
sleep 5
curl -sS --max-time 60 http://127.0.0.1:18000/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"${MODEL}\", \"prompt\": \"The capital of France is\", \"max_tokens\": 16}" \
  | tee "${RESULTS_DIR}/agg-response.json"
echo
AGG_OK=$(python3 -c "import json;d=json.load(open('${RESULTS_DIR}/agg-response.json'));print(1 if d.get('choices') else 0)" 2>/dev/null || echo 0)
kill "${PF_PID}" 2>/dev/null || true
[[ "${AGG_OK}" == "1" ]] || fail "aggregated baseline: no real completion returned"
pass "aggregated baseline: real completion returned on real trn2.3xlarge hardware"

HM uninstall dp80-agg -n default --wait --timeout 3m || true
pass "dp80-agg uninstalled (node released back to the pool)"

# -------------------------------------------------------- 6. disaggregated

HM upgrade --install dp80-disagg "${REPO_ROOT}/examples/inference/vllm/neuron/disagg-pd" \
  -n default \
  --set model.name="${MODEL}" \
  --set prefill.neuronCoresPerEngine=1 --set decode.neuronCoresPerEngine=1 \
  --set placement.nodeSelectorKey=karpenter.sh/nodepool \
  --set prefill.nodeSelectorValue=trn-prefill --set decode.nodeSelectorValue=trn-decode \
  --set-json placement.tolerations="${TOL_JSON}" \
  || fail "dp80-disagg install"
pass "dp80-disagg release installed"

wait_until 300 10 "dp80-disagg prefill and decode Pods exist" bash -c \
  "[ \"\$(kubectl --kubeconfig '${KUBECONFIG}' get pods -n default -l app.kubernetes.io/instance=dp80-disagg --no-headers 2>/dev/null | wc -l)\" -ge 2 ]" \
  || { K get pods -n default -o wide; fail "dp80-disagg never created 2 pods"; }
for role in prefill decode; do
  wait_until 900 15 "dp80-disagg ${role} Ready" bash -c \
    "kubectl --kubeconfig '${KUBECONFIG}' get pods -n default -l app.kubernetes.io/instance=dp80-disagg,app.kubernetes.io/component=${role} -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true" \
    || { K get pods -n default -o wide; K describe pods -n default -l app.kubernetes.io/instance=dp80-disagg,app.kubernetes.io/component=${role} | tail -60; fail "dp80-disagg ${role} never became Ready within 15m"; }
  pass "dp80-disagg ${role} Ready"
done

PREFILL_POD="$(K get pods -n default -l app.kubernetes.io/instance=dp80-disagg,app.kubernetes.io/component=prefill -o jsonpath='{.items[0].metadata.name}')"
DECODE_POD="$(K get pods -n default -l app.kubernetes.io/instance=dp80-disagg,app.kubernetes.io/component=decode -o jsonpath='{.items[0].metadata.name}')"
PREFILL_NODE="$(K get pod "${PREFILL_POD}" -n default -o jsonpath='{.spec.nodeName}')"
DECODE_NODE="$(K get pod "${DECODE_POD}" -n default -o jsonpath='{.spec.nodeName}')"
[[ "${PREFILL_NODE}" != "${DECODE_NODE}" ]] || fail "prefill and decode landed on the SAME node (${PREFILL_NODE}): placement contract violated"
pass "prefill on ${PREFILL_NODE}, decode on ${DECODE_NODE} -- different real trn2.3xlarge nodes"

# EFA counter check: a privileged pod per node reads
# /sys/class/infiniband/*/ports/1/hw_counters before and after a real request.
for role in prefill decode; do
  node_var="${role^^}_NODE"
  node="${!node_var}"
  cat >"${WORK_DIR}/efa-debug-${role}.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: efa-debug-${role}
  namespace: default
spec:
  nodeName: ${node}
  tolerations:
    - key: aws.amazon.com/neuron
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: debug
      image: public.ecr.aws/docker/library/busybox:1.37
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: sys
          mountPath: /sys
  volumes:
    - name: sys
      hostPath:
        path: /sys
  restartPolicy: Never
YAML
  K apply -f "${WORK_DIR}/efa-debug-${role}.yaml" || log "INFO efa-debug-${role} apply failed (non-fatal: EFA counter evidence is secondary to the completion already confirmed above)"
done
EFA_DEBUG_OK=1
for role in prefill decode; do
  K wait pod "efa-debug-${role}" -n default --for=condition=Ready --timeout=120s || { EFA_DEBUG_OK=0; log "INFO efa-debug-${role} never Ready (non-fatal)"; }
done
if [[ "${EFA_DEBUG_OK}" == "1" ]]; then
  pass "EFA debug pods Ready on both nodes"
fi

snapshot_efa() {
  local role="$1" when="$2"
  K exec -n default "efa-debug-${role}" -- sh -c \
    'for d in /sys/class/infiniband/*/ports/1/hw_counters; do echo "== $d =="; cat "$d"/rdma_write_bytes "$d"/tx_bytes 2>/dev/null; done' \
    > "${RESULTS_DIR}/efa-${role}-${when}.txt" 2>&1 || true
}
snapshot_efa prefill before
snapshot_efa decode before

DISAGG_SVC="$(K get svc -n default -l app.kubernetes.io/instance=dp80-disagg -o jsonpath='{.items[0].metadata.name}')"
K port-forward -n default "svc/${DISAGG_SVC}" 18001:8000 >"${WORK_DIR}/disagg-pf.log" 2>&1 &
PF_PID=$!
sleep 5
curl -sS --max-time 60 http://127.0.0.1:18001/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"${MODEL}\", \"prompt\": \"The capital of Japan is\", \"max_tokens\": 16}" \
  | tee "${RESULTS_DIR}/disagg-response.json"
echo
DISAGG_OK=$(python3 -c "import json;d=json.load(open('${RESULTS_DIR}/disagg-response.json'));print(1 if d.get('choices') else 0)" 2>/dev/null || echo 0)
kill "${PF_PID}" 2>/dev/null || true
[[ "${DISAGG_OK}" == "1" ]] || fail "disaggregated: no real completion returned"
pass "disaggregated: real completion returned, prefill+decode on separate real trn2.3xlarge nodes"

snapshot_efa prefill after
snapshot_efa decode after
diff -u "${RESULTS_DIR}/efa-prefill-before.txt" "${RESULTS_DIR}/efa-prefill-after.txt" | tee "${RESULTS_DIR}/efa-prefill-diff.txt" || true
diff -u "${RESULTS_DIR}/efa-decode-before.txt" "${RESULTS_DIR}/efa-decode-after.txt" | tee "${RESULTS_DIR}/efa-decode-diff.txt" || true
K delete pod efa-debug-prefill efa-debug-decode -n default --wait=false || true

# ---------------------------------------------- 7. load-replay + score.py
#
# Supplementary to the two completions already confirmed above: run in a
# subshell with its own trap disabled, so any failure here is logged and
# skipped rather than aborting the script (and skipping the teardown this
# script's own EXIT trap would otherwise still run anyway, but there is no
# reason to rely on that twice).
(
set +e

export NAMESPACE=default
export RUN_ID_LR="dp80-$(date +%s)"
export TARGET_URL="http://${DISAGG_SVC}:8000"
export MODEL_ID="${MODEL}"
export NUM_PROMPTS=20
export REQUEST_RATE=1
export MAX_SEND_LAG_MS=2000
export BENCH_EXTRA_ARGS="--random-input-len 64 --random-output-len 32 --seed 0"
K create configmap load-replay-scripts -n "${NAMESPACE}" \
  --from-file="${REPO_ROOT}/examples/inference/_shared/load-replay/run-load.sh" \
  --from-file="${REPO_ROOT}/examples/inference/_shared/load-replay/driver.py" || fail "load-replay configmap"
# Substitute only the named variables (not envsubst, to avoid depending on
# gettext being installed on the runner): read the template, replace
# ${VAR} for exactly the six names load-job.yaml uses, leave anything else
# (e.g. a literal $ in BENCH_EXTRA_ARGS, which has none here) untouched.
python3 - "${REPO_ROOT}/examples/inference/_shared/load-replay/load-job.yaml" \
  TARGET_URL MODEL_ID NUM_PROMPTS REQUEST_RATE MAX_SEND_LAG_MS BENCH_EXTRA_ARGS <<'PYEOF' | K apply -n "${NAMESPACE}" -f - || fail "load-replay job apply"
import os, sys
path, names = sys.argv[1], sys.argv[2:]
text = open(path).read()
for n in names:
    text = text.replace("${" + n + "}", os.environ.get(n, ""))
sys.stdout.write(text)
PYEOF

wait_until 300 10 "load-replay pod Ready" bash -c \
  "kubectl --kubeconfig '${KUBECONFIG}' get pods -n ${NAMESPACE} -l job-name=load-replay -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -qE 'Running|Succeeded'" \
  || fail "load-replay pod never started"
LR_POD="$(K get pods -n "${NAMESPACE}" -l job-name=load-replay -o jsonpath='{.items[0].metadata.name}')"
wait_until 600 15 "load-replay exit-code file" bash -c \
  "kubectl --kubeconfig '${KUBECONFIG}' exec -n ${NAMESPACE} '${LR_POD}' -- test -e /results/exit-code 2>/dev/null" \
  || fail "load-replay never produced /results/exit-code"
K cp -n "${NAMESPACE}" "${LR_POD}:/results" "${RESULTS_DIR}/load-replay"
K exec -n "${NAMESPACE}" "${LR_POD}" -- touch /results/.collected || true
cat "${RESULTS_DIR}/load-replay/exit-code"
LR_RC="$(cat "${RESULTS_DIR}/load-replay/exit-code")"
K delete job load-replay -n "${NAMESPACE}" --wait=false || true
if [[ "${LR_RC}" == "0" ]]; then
  pass "load-replay run valid (client did not fall behind)"
  export GPU_COUNT=2
  export TTFT_MS=5000
  export GAP_MS=2000
  python3 "${REPO_ROOT}/examples/inference/_shared/scorer/score.py" \
    --records "${RESULTS_DIR}/load-replay/bench.json" \
    --planned-requests "${NUM_PROMPTS}" \
    --gpu-count "${GPU_COUNT}" \
    --ttft-ms "${TTFT_MS}" --tpot-or-gap-ms "${GAP_MS}" \
    --out "${RESULTS_DIR}/score.json" || fail "score.py"
  cat "${RESULTS_DIR}/score.json"
  pass "score.py produced a goodput number from a real disaggregated run"
else
  log "INFO load-replay exit code ${LR_RC} (client send-lag or run invalid) -- see ${RESULTS_DIR}/load-replay for detail; not scored"
fi
) || log "INFO load-replay/score.py step did not complete cleanly (non-fatal; see output above). The two real completions (aggregated and disaggregated) already confirmed above stand regardless."

HM uninstall dp80-disagg -n default --wait --timeout 3m || true
K delete nodeclaims --all --wait=true --timeout=10m || true
pass "dp80-disagg uninstalled"

echo "===VERIFICATION_DONE==="
