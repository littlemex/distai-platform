#!/usr/bin/env bash
# Disposable experiment script for the "miles on Trainium" investigation.
# NOT part of distai-platform's own test suite; lives only on branch
# exp/miles-trainium (never merged). Runs on the distai-platform EC2 runner
# via runner/run.sh, never on a developer Mac.
#
# What it proves: a real trn2.3xlarge spot node, provisioned through this
# repo's own foundation (Terraform) + capacity-pool chart + Neuron device
# plugin addon (the same artifacts gitops/ delivers through Argo CD -- this
# script installs the identical OCI charts with the identical values
# directly via `helm`, skipping only the Argo CD/GitOps wrapper, which this
# one-off probe does not need), can run a from-scratch generate -> reward ->
# train -> weight-update loop for a small model (scripts/rl_probe.py).
#
# Required environment: AWS_PROFILE, AWS_REGION (ap-southeast-4), NAME
# (cell name, e.g. dp-miles-trn-r1), STATE_BUCKET, STATE_REGION,
# ADMIN_PRINCIPAL_ARN, MY_CIDR (same meaning as infra/foundation/tests/1.e2e.sh).
# Optional: TRN_BUDGET_SECONDS (10800 = 3h, leaves headroom inside the
# 4-hour/4-attempt trn2.3xlarge budget), TERRAFORM (terraform).
set -euo pipefail

: "${AWS_PROFILE:?export AWS_PROFILE}"
: "${AWS_REGION:?export AWS_REGION}"
: "${NAME:?export NAME}"
: "${STATE_BUCKET:?export STATE_BUCKET}"
: "${STATE_REGION:?export STATE_REGION}"
: "${ADMIN_PRINCIPAL_ARN:?export ADMIN_PRINCIPAL_ARN}"
: "${MY_CIDR:?export MY_CIDR}"
export AWS_PROFILE AWS_REGION

TERRAFORM="${TERRAFORM:-terraform}"
TRN_BUDGET_SECONDS="${TRN_BUDGET_SECONDS:-10800}"
KARPENTER_VERSION="1.15.2"
NEURON_CHART_VERSION="1.11.2"
RUN_START="$(date +%s)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FOUNDATION_ROOT="${ROOT}/infra/foundation"
WORK_DIR="$(mktemp -d)"
TFVARS="${WORK_DIR}/trn.tfvars.json"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1
STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
pass() { log "PASS $*"; }
info() { log "INFO $*"; }
fail() { log "FAIL $*"; exit 1; }
tf() { "${TERRAFORM}" -chdir="${FOUNDATION_ROOT}" "$@"; }
k() { kubectl "$@"; }
aws_text() { "$@" 2>&1; }

elapsed() { echo $(( $(date +%s) - RUN_START )); }
check_budget() {
  local e
  e="$(elapsed)"
  if (( e > TRN_BUDGET_SECONDS )); then
    fail "Trainium time budget (${TRN_BUDGET_SECONDS}s) exceeded at ${e}s -- tearing down regardless of where this run is"
  fi
  info "elapsed ${e}s of budget ${TRN_BUDGET_SECONDS}s"
}

wait_until() {
  local timeout="$1" interval="$2" desc="$3"; shift 3
  local start now
  start="$(date +%s)"
  while true; do
    if "$@"; then return 0; fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      log "timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    check_budget
    sleep "${interval}"
  done
}

# ------------------------------------------------------------- state captured for cleanup
APPLIED=0
KARPENTER_INSTALLED=0
DESTROYED=0
JOB_APPLIED=0
CLUSTER_NAME=""
VPC_ID=""

cleanup() {
  local rc=$?
  info "cleanup: rc=${rc} elapsed=$(elapsed)s"
  if [[ "${JOB_APPLIED}" == "1" ]]; then
    k delete job rl-probe -n default --ignore-not-found --wait=false >/dev/null 2>&1 || true
    k delete configmap rl-probe-script -n default --ignore-not-found >/dev/null 2>&1 || true
  fi
  if [[ "${KARPENTER_INSTALLED}" == "1" ]]; then
    helm uninstall accel-neuron-device-plugin -n neuron-device-plugin --wait --timeout 5m >/dev/null 2>&1 || true
    helm uninstall capacity-pool -n kube-system --wait --timeout 8m >/dev/null 2>&1 || true
    # give Karpenter time to actually terminate the node it owns before
    # tearing down the controller that would otherwise do it
    sleep 30
    helm uninstall karpenter -n kube-system --wait --timeout 5m >/dev/null 2>&1 || true
    helm uninstall karpenter-crd -n kube-system --wait --timeout 3m >/dev/null 2>&1 || true
  fi
  if [[ "${APPLIED}" == "1" && "${DESTROYED}" == "0" ]]; then
    info "terraform destroy"
    tf destroy -auto-approve -input=false -var-file="${TFVARS}" || log "FAIL terraform destroy did not succeed cleanly; re-check by hand"
    DESTROYED=1
  fi
  if [[ -n "${CLUSTER_NAME}" ]]; then
    info "independent leftover sweep for ${CLUSTER_NAME}"
    for kind_query in \
      "instance:ec2 describe-instances --query 'Reservations[].Instances[?State.Name!=\`terminated\`].InstanceId'" \
      "nat:ec2 describe-nat-gateways --query 'NatGateways[?State!=\`deleted\`].NatGatewayId'" \
      "launch-template:ec2 describe-launch-templates --query 'LaunchTemplates[].LaunchTemplateId'"; do
      kind="${kind_query%%:*}"; q="${kind_query#*:}"
      out="$(aws ${q} --filters "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" "Name=tag:karpenter.k8s.aws/ec2nodeclass,Values=trn" --output text 2>&1 || true)"
      out2="$(aws ${q} --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER_NAME}" --output text 2>&1 || true)"
      info "leftover sweep ${kind}: tag-set-1=[${out}] tag-set-2=[${out2}]"
    done
    if [[ -n "${VPC_ID}" ]]; then
      vpc_check="$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].VpcId' --output text 2>&1 || true)"
      info "VPC ${VPC_ID} after destroy: ${vpc_check}"
    fi
  fi
  rm -rf "${WORK_DIR}"
  exit "${rc}"
}
trap cleanup EXIT

# ------------------------------------------------------------- 1. terraform apply (foundation)
cat > "${TFVARS}" <<EOF
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "tags": {"distai-platform-experiment": "miles-trainium"}
}
EOF
info "tfvars: $(cat "${TFVARS}")"

tf init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true" \
  || fail "terraform init"

existing="$(tf state list 2>/dev/null | wc -l | tr -d ' ')"
[[ "${existing}" == "0" ]] || fail "state at ${STATE_KEY} is not empty (${existing} resources) -- refusing to apply on top of someone else's state"
pass "state at ${STATE_KEY} is empty before apply"

apply_start="$(date +%s)"
tf apply -auto-approve -input=false -var-file="${TFVARS}" || fail "terraform apply"
APPLIED=1
pass "terraform apply completed ($(($(date +%s) - apply_start))s)"

CLUSTER_NAME="$(tf output -raw cluster_name)"
VPC_ID="$(tf output -raw vpc_id)"
NODE_ROLE_NAME="$(tf output -raw karpenter_node_role_name)"
INTERRUPT_QUEUE="$(tf output -raw karpenter_interruption_queue_name)"
[[ "${CLUSTER_NAME}" == "${NAME}" ]] || fail "cluster_name (${CLUSTER_NAME}) != NAME (${NAME})"
pass "foundation outputs: cluster=${CLUSTER_NAME} vpc=${VPC_ID} node_role=${NODE_ROLE_NAME} interrupt_queue=${INTERRUPT_QUEUE}"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --kubeconfig "${KUBECONFIG}" >/dev/null \
  || fail "update-kubeconfig"
wait_until 300 10 "kubectl can list nodes" bash -c "k get nodes >/dev/null 2>&1" || fail "kubectl never became reachable"
pass "kubeconfig works"

# ------------------------------------------------------------- 2. karpenter (direct helm, same OCI charts gitops/addons/karpenter* delivers)
helm install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version "${KARPENTER_VERSION}" \
  -n kube-system --wait --timeout 5m \
  || fail "helm install karpenter-crd"
pass "karpenter-crd installed"

KARPENTER_VALUES="${WORK_DIR}/karpenter-values.yaml"
cat > "${KARPENTER_VALUES}" <<EOF
serviceAccount:
  name: karpenter
settings:
  clusterName: "${CLUSTER_NAME}"
  interruptionQueue: "${INTERRUPT_QUEUE}"
controller:
  env:
    - name: AWS_REGION
      value: "${AWS_REGION}"
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
EOF
helm install karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" \
  -n kube-system --skip-crds --wait --timeout 5m -f "${KARPENTER_VALUES}" \
  || fail "helm install karpenter"
KARPENTER_INSTALLED=1
pass "karpenter controller installed"

wait_until 180 10 "karpenter deployment Available" bash -c \
  "k get deployment -n kube-system karpenter -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -q True" \
  || fail "karpenter deployment never became Available"
pass "karpenter deployment Available"

# ------------------------------------------------------------- 3. capacity-pool chart (local chart, trn2.3xlarge, spot, same values as gitops/cells/dp-a19-trn-r3)
CP_VALUES="${WORK_DIR}/capacity-pool-trn-values.yaml"
cat > "${CP_VALUES}" <<EOF
clusterName: "${CLUSTER_NAME}"
nodeRole: "${NODE_ROLE_NAME}"
pool:
  name: trn
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
    consolidateAfter: 15m
  rootVolumeSizeGi: "100Gi"
accelerator:
  resourceName: aws.amazon.com/neuron
  taint:
    key: aws.amazon.com/neuron
    value: "true"
    effect: NoSchedule
  methodLabel:
    key: distai.dev/neuron-method
    value: device-plugin
EOF
info "capacity-pool values: $(cat "${CP_VALUES}")"

helm install capacity-pool "${ROOT}/gitops/charts/capacity-pool" -n kube-system -f "${CP_VALUES}" --wait --timeout 3m \
  || fail "helm install capacity-pool"
pass "capacity-pool chart installed (NodePool/EC2NodeClass for trn2.3xlarge spot)"

# ------------------------------------------------------------- 4. Neuron device plugin addon (same OCI chart/values as gitops/addons/accel-neuron-device-plugin)
NEURON_VALUES="${WORK_DIR}/neuron-device-plugin-values.yaml"
cat > "${NEURON_VALUES}" <<EOF
devicePlugin:
  nodeSelector:
    distai.dev/neuron-method: device-plugin
draDriver:
  enabled: false
npd:
  namespaceOverride: neuron-device-plugin
EOF
helm install accel-neuron-device-plugin oci://public.ecr.aws/neuron/neuron-helm-chart --version "${NEURON_CHART_VERSION}" \
  -n neuron-device-plugin --create-namespace --wait --timeout 5m -f "${NEURON_VALUES}" \
  || fail "helm install accel-neuron-device-plugin"
pass "accel-neuron-device-plugin installed"

# ------------------------------------------------------------- 5. wait for a real trn2.3xlarge spot node (Karpenter) and confirm exactly 1 neuron device
node_ready_with_neuron() {
  local n
  n="$(k get nodes -l distai.dev/neuron-method=device-plugin -o jsonpath='{.items[?(@.status.allocatable.aws\.amazon\.com/neuron=="1")].metadata.name}' 2>/dev/null)"
  [[ -n "${n}" ]]
}
info "waiting for Karpenter to launch a real trn2.3xlarge spot node (this also proves/records capacity availability)"
if ! wait_until 900 15 "a node with allocatable aws.amazon.com/neuron=1" node_ready_with_neuron; then
  info "CAPACITY: no trn2.3xlarge spot node came up in region ${AWS_REGION} within 900s at $(date -u +%FT%TZ) -- recording and stopping per instructions"
  k get nodeclaims -o wide || true
  k describe nodepool trn || true
  fail "no trn2.3xlarge spot capacity obtained in ${AWS_REGION} (see CAPACITY line above for AZ/time); stopping, not retrying instance types outside the authorized trn2.3xlarge/spot/ap-southeast-4 scope"
fi
ACCEL_NODE="$(k get nodes -l distai.dev/neuron-method=device-plugin -o jsonpath='{.items[0].metadata.name}')"
INSTANCE_TYPE="$(k get node "${ACCEL_NODE}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')"
CAP_TYPE="$(k get node "${ACCEL_NODE}" -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}')"
[[ "${INSTANCE_TYPE}" == "trn2.3xlarge" ]] || fail "node ${ACCEL_NODE} is ${INSTANCE_TYPE}, not trn2.3xlarge -- refusing to continue (instance-type budget is trn2.3xlarge only)"
[[ "${CAP_TYPE}" == "spot" ]] || fail "node ${ACCEL_NODE} is capacity-type ${CAP_TYPE}, not spot -- refusing to continue (on-demand Trainium is not authorized)"
pass "node ${ACCEL_NODE} is trn2.3xlarge spot"

k wait --for=condition=Ready node/"${ACCEL_NODE}" --timeout=120s || fail "node ${ACCEL_NODE} never became Ready"
pass "node ${ACCEL_NODE} Ready"

# ------------------------------------------------------------- 6. the RL-primitives probe Job
k create configmap rl-probe-script -n default --from-file=rl_probe.py="${SCRIPT_DIR}/rl_probe.py" \
  || fail "create configmap rl-probe-script"
JOB_APPLIED=1

JOB_MANIFEST="${WORK_DIR}/job.yaml"
cat > "${JOB_MANIFEST}" <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: rl-probe
  namespace: default
  labels:
    app: miles-trainium-rl-probe
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3300
  template:
    metadata:
      labels:
        app: miles-trainium-rl-probe
    spec:
      restartPolicy: Never
      nodeSelector:
        distai.dev/neuron-method: device-plugin
      tolerations:
        - key: aws.amazon.com/neuron
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: rl-probe
          image: public.ecr.aws/neuron/pytorch-training-neuronx:2.9.0-neuronx-py312-sdk2.30.0-ubuntu24.04
          command: ["/bin/bash", "-lc"]
          args:
            - |
              set -euo pipefail
              echo "[job] pip install transformers"
              pip install --no-cache-dir --quiet "transformers==4.57.1"
              echo "[job] neuron-ls:"
              neuron-ls || true
              echo "[job] running rl_probe.py"
              python3 /work/rl_probe.py
              echo "[job] rl_probe.py exit code $?"
          env:
            - name: RL_PROBE_MODEL
              value: "Qwen/Qwen2.5-0.5B-Instruct"
            - name: RL_PROBE_SEQ_LEN
              value: "48"
            - name: RL_PROBE_PROMPT_LEN
              value: "32"
            - name: RL_PROBE_SAMPLES
              value: "4"
            - name: RL_PROBE_STEPS
              value: "2"
            - name: HF_HOME
              value: "/tmp/hf"
          resources:
            requests:
              aws.amazon.com/neuron: "1"
              cpu: "2"
              memory: "8Gi"
            limits:
              aws.amazon.com/neuron: "1"
              cpu: "4"
              memory: "16Gi"
          volumeMounts:
            - name: script
              mountPath: /work
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: script
          configMap:
            name: rl-probe-script
        - name: tmp
          emptyDir:
            sizeLimit: 20Gi
EOF

k apply -f "${JOB_MANIFEST}" || fail "kubectl apply job rl-probe"
pass "rl-probe Job submitted"

job_done() {
  local succ fail_c
  succ="$(k get job rl-probe -n default -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  fail_c="$(k get job rl-probe -n default -o jsonpath='{.status.failed}' 2>/dev/null)"
  [[ "${succ}" == "1" || "${fail_c}" -ge "1" ]] 2>/dev/null
}
info "waiting for rl-probe Job to finish (image pull + first-compile may take a while)"
wait_until 3000 20 "rl-probe Job finished" job_done || info "rl-probe Job did not reach a terminal state within 3000s; dumping what we have"

info "---- kubectl describe job/rl-probe ----"
k describe job rl-probe -n default || true
info "---- kubectl logs job/rl-probe ----"
k logs job/rl-probe -n default --all-containers --tail=-1 || true

succeeded="$(k get job rl-probe -n default -o jsonpath='{.status.succeeded}' 2>/dev/null)"
if [[ "${succeeded}" == "1" ]]; then
  pass "rl-probe Job succeeded"
else
  log "FAIL rl-probe Job did not succeed (status.succeeded=${succeeded:-<empty>}); logs above are the evidence"
fi

info "run finished at elapsed=$(elapsed)s; cleanup() runs next via EXIT trap"
