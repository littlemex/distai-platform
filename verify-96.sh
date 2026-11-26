set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_REGION=us-east-1
NAME=dp-c96-gpu-r4
STATE_BUCKET="${STATE_BUCKET:?set to an S3 bucket for Terraform state}"
STATE_REGION="${STATE_REGION:-ap-northeast-1}"
ADMIN_PRINCIPAL_ARN="$(aws iam get-role --role-name "$(aws sts get-caller-identity --query Arn --output text | cut -d/ -f2)" --query Role.Arn --output text)"
INSTANCE_TYPE=g7.2xlarge
TEST_IMAGE=docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04

REPO_ROOT="$(pwd)"
EV="/tmp/96-verify-evidence"
mkdir -p "${EV}"
LOG="${EV}/run.log"
exec > >(tee -a "${LOG}") 2>&1

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

FOUNDATION_DIR="${REPO_ROOT}/infra/foundation"

cleanup() {
  log "=== cleanup: terraform destroy ==="
  cd "${FOUNDATION_DIR}" || return 0
  kubectl delete pod gpu-control gpu-positive gpu-negative --ignore-not-found --wait=false 2>/dev/null || true
  for nc in $(kubectl get nodeclaims -o name 2>/dev/null); do
    kubectl delete "${nc}" --wait=true --timeout=180s 2>/dev/null || true
  done
  for i in $(seq 1 18); do
    [ "$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)" -eq 0 ] && break
    sleep 10
  done
  terraform destroy -auto-approve -input=false 2>&1 | tee "${EV}/99-destroy.log"
  log "=== cleanup: leftover sweep (read-only) ==="
  aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text | tee "${EV}/99-leftover-instances.txt"
  aws ec2 describe-launch-templates --region "${AWS_REGION}" \
    --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" \
    --query 'LaunchTemplates[].LaunchTemplateId' --output text | tee "${EV}/99-leftover-launch-templates.txt"
  aws eks describe-cluster --name "${NAME}" --region "${AWS_REGION}" 2>&1 | tee "${EV}/99-leftover-cluster.txt" || true
}
trap cleanup EXIT

log "=== 1. terraform apply (infra/foundation, non-hub cell) ==="
cd "${FOUNDATION_DIR}"
MY_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
export TF_VAR_name="${NAME}"
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_endpoint_public_access_cidrs="[\"${MY_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_PRINCIPAL_ARN}\"]"
terraform init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true" | tee "${EV}/00-init.log"
terraform apply -auto-approve -input=false | tee "${EV}/01-apply.log"
APPLY_RC="${PIPESTATUS[0]}"
[ "${APPLY_RC}" -eq 0 ] || { log "FATAL: terraform apply failed (rc=${APPLY_RC})"; exit 1; }

NODE_ROLE="$(terraform output -raw karpenter_node_role_name)"
INTERRUPTION_QUEUE="$(terraform output -raw karpenter_interruption_queue_name)"
log "NODE_ROLE=${NODE_ROLE} INTERRUPTION_QUEUE=${INTERRUPTION_QUEUE}"

aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
kubectl get nodes -o wide | tee "${EV}/02-system-nodes.txt"
kubectl get daemonset -n kube-system -o json | tee "${EV}/02-system-daemonsets.json" > /dev/null
python3 -c "
import json
d = json.load(open('${EV}/02-system-daemonsets.json'))
for item in d.get('items', []):
    name = item['metadata']['name']
    tols = item['spec']['template']['spec'].get('tolerations')
    print(name, 'tolerations=', tols)
" | tee "${EV}/02-system-daemonsets-tolerations.txt"

log "=== 2. install karpenter-crd + karpenter ==="
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version 1.15.2 -n kube-system
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.2 -n kube-system \
  --skip-crds \
  --set serviceAccount.name=karpenter \
  --set "tolerations[0].key=CriticalAddonsOnly" --set "tolerations[0].operator=Exists" \
  --set settings.clusterName="${NAME}" \
  --set settings.interruptionQueue="${INTERRUPTION_QUEUE}" \
  --set "controller.env[0].name=AWS_REGION" \
  --set "controller.env[0].value=${AWS_REGION}"
kubectl rollout status -n kube-system deploy/karpenter --timeout=180s \
  || { log "FATAL: karpenter deployment never became Available"; exit 1; }

log "=== 3. install vigil-controller (#96) ==="
helm repo add vigil https://oss.nextdoor.com/vigil --force-update
helm repo update vigil
cat > "${EV}/vigil-values.yaml" <<'VALUES'
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
config:
  taintKey: "distai.dev/startup-not-ready"
  taintEffect: "NoSchedule"
  knownStartupTaintKeys:
    - "distai.dev/startup-not-ready"
    - "node.kubernetes.io/not-ready"
    - "node.kubernetes.io/unreachable"
  timeoutSeconds: 300
VALUES
helm upgrade --install vigil-controller vigil/vigil-controller --version 0.7.0 -n vigil-system --create-namespace \
  -f "${EV}/vigil-values.yaml"
VIGIL_DEPLOY=""
for i in $(seq 1 12); do
  VIGIL_DEPLOY="$(kubectl get deploy -n vigil-system -l app.kubernetes.io/name=vigil-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "${VIGIL_DEPLOY}" ] && break
  sleep 5
done
[ -n "${VIGIL_DEPLOY}" ] || { log "FATAL: vigil-controller Deployment object never appeared"; exit 1; }
kubectl rollout status -n vigil-system "deploy/${VIGIL_DEPLOY}" --timeout=180s \
  || { log "FATAL: vigil-controller deployment never became Available"; exit 1; }
kubectl logs -n vigil-system -l app.kubernetes.io/name=vigil-controller --tail=-1 --prefix > "${EV}/00-vigil-startup-logs.txt" 2>/dev/null || true

log "=== 4. install accel-nvidia-device-plugin (#96 toleration) ==="
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update
helm repo update nvdp
cat > "${EV}/nvdp-values.yaml" <<'VALUES'
nodeSelector:
  distai.dev/nvidia-gpu-method: device-plugin
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: distai.dev/startup-not-ready
    operator: Exists
    effect: NoSchedule
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: distai.dev/nvidia-gpu-method
              operator: In
              values: ["device-plugin"]
VALUES
helm upgrade --install accel-nvidia-device-plugin nvdp/nvidia-device-plugin --version 0.20.2 -n nvidia-device-plugin --create-namespace \
  -f "${EV}/nvdp-values.yaml"

render_pool() {
  local out="$1" startup="$2"
  cat > "${EV}/gpu-pool-values.yaml" <<VALUES
clusterName: "${NAME}"
nodeRole: "${NODE_ROLE}"
pool:
  name: gpu
  capacityType: on-demand
  requirements:
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64"]
    - key: node.kubernetes.io/instance-type
      operator: In
      values: ["${INSTANCE_TYPE}"]
${startup}
accelerator:
  resourceName: nvidia.com/gpu
  methodLabel:
    key: distai.dev/nvidia-gpu-method
    value: device-plugin
VALUES
  helm template gpu "${REPO_ROOT}/gitops/charts/capacity-pool" -n kube-system -f "${EV}/gpu-pool-values.yaml" > "${out}"
}

STARTUP_TAINTS_BLOCK="  startupTaints:
    - key: distai.dev/startup-not-ready
      effect: NoSchedule"

find_gpu_node() {
  local max_iters="$1" n=""
  for i in $(seq 1 "${max_iters}"); do
    n="$(kubectl get nodes -l distai.dev/nvidia-gpu-method=device-plugin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [ -n "${n}" ] && { echo "${n}"; return 0; }
    sleep 10
  done
  return 1
}

delete_gpu_node() {
  for nc in $(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu -o name 2>/dev/null); do
    kubectl delete "${nc}" --wait=true --timeout=180s 2>/dev/null || true
  done
  for i in $(seq 1 18); do
    kubectl get nodes -l distai.dev/nvidia-gpu-method=device-plugin --no-headers 2>/dev/null | grep -q . || break
    sleep 10
  done
}

dump_node_state() {
  local node="$1" prefix="$2"
  [ -z "${node}" ] && { log "${prefix}: no node to dump"; return 0; }
  kubectl get node "${node}" -o json > "${EV}/${prefix}-node.json" 2>/dev/null
  python3 -c "
import json
d = json.load(open('${EV}/${prefix}-node.json'))
taints = d.get('spec', {}).get('taints')
alloc = d.get('status', {}).get('allocatable', {}).get('nvidia.com/gpu')
ready = [c for c in d.get('status', {}).get('conditions', []) if c.get('type') == 'Ready']
print('node=${node}')
print('taints=', taints)
print('allocatable_nvidia_gpu=', alloc)
print('ready_condition=', ready[0] if ready else None)
" | tee "${EV}/${prefix}-node-summary.txt"
  kubectl get pods -A -o wide --field-selector "spec.nodeName=${node}" | tee "${EV}/${prefix}-pods-on-node.txt"
  kubectl get events -A --field-selector "involvedObject.fieldPath!=x" --sort-by=.lastTimestamp 2>/dev/null \
    | grep -E "${node}|gpu-control|gpu-positive|gpu-negative" > "${EV}/${prefix}-related-events.txt" || true
  kubectl logs -n vigil-system -l app.kubernetes.io/name=vigil-controller --tail=-1 --prefix > "${EV}/${prefix}-vigil-logs.txt" 2>/dev/null || true
}

watch_pod() {
  local pod="$1" prefix="$2" max_iters="$3"
  local node=""
  for i in $(seq 1 "${max_iters}"); do
    sleep 10
    node="$(kubectl get pod "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
    if [ -z "${node}" ]; then
      node="$(kubectl get nodes -l distai.dev/nvidia-gpu-method=device-plugin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    fi
    local phase sched_status sched_time dp_ready_status node_taints
    phase="$(kubectl get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null)"
    sched_status="$(kubectl get pod "${pod}" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null)"
    sched_time="$(kubectl get pod "${pod}" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].lastTransitionTime}' 2>/dev/null)"
    node_taints="<no-node>"
    dp_ready_status="no-node"
    if [ -n "${node}" ]; then
      node_taints="$(kubectl get node "${node}" -o jsonpath='{.spec.taints}' 2>/dev/null)"
      dp_ready_status="$(kubectl get pods -n nvidia-device-plugin --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    fi
    log "${prefix} t+$((i*10))s node=${node:-<none>} podScheduled=${sched_status:-<none>}@${sched_time:-?} nodeTaints=${node_taints} dpReady=${dp_ready_status:-<none>} phase=${phase:-<none>}"
    if [ "${phase}" = "Running" ]; then
      log "${prefix}: Running observed at t+$((i*10))s"
      break
    fi
  done
  dump_node_state "${node}" "${prefix}-final"
  kubectl get pod "${pod}" -o json > "${EV}/${prefix}-pod.json" 2>/dev/null
  python3 -c "
import json
d = json.load(open('${EV}/${prefix}-pod.json'))
for c in d.get('status', {}).get('conditions', []):
    print(c.get('type'), c.get('status'), c.get('lastTransitionTime'))
print('tolerations=', d.get('spec', {}).get('tolerations'))
print('phase=', d.get('status', {}).get('phase'))
" | tee "${EV}/${prefix}-pod-conditions.txt"
  kubectl describe pod "${pod}" > "${EV}/${prefix}-pod-describe.txt" 2>/dev/null || true
}

make_pod() {
  local name="$1" out="$2"
  cat > "${out}" <<PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: default
spec:
  restartPolicy: Never
  nodeSelector:
    distai.dev/nvidia-gpu-method: device-plugin
  containers:
    - name: smoke
      image: ${TEST_IMAGE}
      command: ["sh", "-c", "date -u; nvidia-smi -L || true; sleep 600"]
PODEOF
}

log "=== PHASE 0 (control): pool.startupTaints unset -- today's unsafe behavior ==="
render_pool "${EV}/03-gpu-pool-control.yaml" ""
cat "${EV}/03-gpu-pool-control.yaml"
kubectl apply -f "${EV}/03-gpu-pool-control.yaml" || log "(expected) the rendered ResourceFlavor errors -- Kueue is deliberately not installed for this test; NodePool/EC2NodeClass still apply"
make_pod gpu-control "${EV}/pod-control.yaml"
log "pod-control.yaml (no toleration, no resource request -- nothing but a taint could hold this Pending)"
cat "${EV}/pod-control.yaml"
kubectl apply -f "${EV}/pod-control.yaml"
watch_pod gpu-control control 30
kubectl delete pod gpu-control --ignore-not-found
delete_gpu_node

log "=== PHASE 1 (positive): same pool, pool.startupTaints set, device plugin healthy ==="
render_pool "${EV}/03-gpu-pool-positive.yaml" "${STARTUP_TAINTS_BLOCK}"
cat "${EV}/03-gpu-pool-positive.yaml"
kubectl apply -f "${EV}/03-gpu-pool-positive.yaml" || log "(expected) the rendered ResourceFlavor errors -- Kueue is deliberately not installed for this test; NodePool/EC2NodeClass still apply"
make_pod gpu-positive "${EV}/pod-positive.yaml"
kubectl apply -f "${EV}/pod-positive.yaml"
watch_pod gpu-positive positive 90
kubectl delete pod gpu-positive --ignore-not-found
delete_gpu_node

log "=== PHASE 2 (negative): same taint, device plugin broken, observed past timeoutSeconds=300 ==="
log "breaking accel-nvidia-device-plugin's image (ImagePullBackOff on purpose)"
helm upgrade accel-nvidia-device-plugin nvdp/nvidia-device-plugin --version 0.20.2 -n nvidia-device-plugin \
  -f "${EV}/nvdp-values.yaml" --set image.tag=does-not-exist-9.9.9
kubectl apply -f "${EV}/03-gpu-pool-positive.yaml" || true
make_pod gpu-negative "${EV}/pod-negative.yaml"
kubectl apply -f "${EV}/pod-negative.yaml"
GPU_NEG_NODE="$(find_gpu_node 12 || true)"
log "negative phase node: ${GPU_NEG_NODE:-<not found in 120s>}"
dump_node_state "${GPU_NEG_NODE}" "negative-early"
watch_pod gpu-negative negative 30
kubectl get pods -n nvidia-device-plugin -o wide > "${EV}/negative-device-plugin-pods.txt" 2>/dev/null || true

log "reverting accel-nvidia-device-plugin's image"
helm upgrade accel-nvidia-device-plugin nvdp/nvidia-device-plugin --version 0.20.2 -n nvidia-device-plugin \
  -f "${EV}/nvdp-values.yaml"

log "=== done; cleanup trap will destroy everything now ==="
