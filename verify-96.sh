#!/usr/bin/env bash
# Ad hoc real-hardware verification for issue #96 (not part of the PR,
# lives only on a scratch branch). Builds one disposable, non-hub EKS
# cell with infra/foundation, installs Karpenter, vigil-controller and
# accel-nvidia-device-plugin directly with helm (no GitOps/Argo CD layer
# -- that delivery mechanism is proven separately by PR #21/#25; this
# script only exercises the #96 mechanism itself: capacity-pool's
# pool.startupTaints + vigil-controller + the device-plugin toleration),
# then:
#   scenario 1 (positive): a real g6e.2xlarge on-demand node launches
#     with the startup taint; a GPU-requesting Pod with NO toleration for
#     it must stay unschedulable until the real nvidia-device-plugin Pod
#     is Ready and vigil-controller removes the taint.
#   scenario 2 (negative): the device plugin is made unable to become
#     Ready (bad image tag) on a second, freshly launched node; the same
#     kind of Pod must stay Pending the whole observation window.
# Always destroys everything at the end via a trap, whether or not the
# scenarios pass, and writes one evidence file per step under
# /tmp/96-verify-evidence.
set -uo pipefail
# Deliberately not set -e: this script runs ~20 minutes of polling against a
# live cluster where a single transient kubectl error must not abort the
# whole run before the cleanup trap gets a chance to destroy everything. A
# handful of genuinely fatal steps (terraform apply, the controller rollouts)
# check their own exit code explicitly below instead.

export AWS_PROFILE=default
export AWS_REGION=us-east-1
NAME=dp-c96-gpu-r1
STATE_BUCKET=distai-eks-tfstate-776010787911
STATE_REGION=ap-northeast-1
ADMIN_PRINCIPAL_ARN=arn:aws:iam::776010787911:role/distai-platform-runner
INSTANCE_TYPE=g6e.2xlarge
TEST_IMAGE=docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04

REPO_ROOT="$(pwd)"
EV="/tmp/96-verify-evidence"
mkdir -p "${EV}"
LOG="${EV}/run.log"
exec > >(tee -a "${LOG}") 2>&1

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

APPLY_OK=0
FOUNDATION_DIR="${REPO_ROOT}/infra/foundation"

cleanup() {
  log "=== cleanup: terraform destroy ==="
  cd "${FOUNDATION_DIR}" || return 0
  kubectl delete pod gpu-smoke-1 gpu-smoke-2 --ignore-not-found --wait=false 2>/dev/null || true
  kubectl get nodeclaims -o name 2>/dev/null | xargs -r kubectl delete --wait=false 2>/dev/null || true
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
APPLY_OK=1

NODE_ROLE="$(terraform output -raw karpenter_node_role_name)"
INTERRUPTION_QUEUE="$(terraform output -raw karpenter_interruption_queue_name)"
log "NODE_ROLE=${NODE_ROLE} INTERRUPTION_QUEUE=${INTERRUPTION_QUEUE}"

aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
kubectl get nodes -o wide | tee "${EV}/02-system-nodes.txt"

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

log "=== 5. render capacity-pool 'gpu' NodePool (pool.startupTaints set) ==="
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
  startupTaints:
    - key: distai.dev/startup-not-ready
      effect: NoSchedule
accelerator:
  resourceName: nvidia.com/gpu
  methodLabel:
    key: distai.dev/nvidia-gpu-method
    value: device-plugin
VALUES
helm template gpu "${REPO_ROOT}/gitops/charts/capacity-pool" -n kube-system -f "${EV}/gpu-pool-values.yaml" \
  > "${EV}/03-gpu-pool-rendered.yaml"
cat "${EV}/03-gpu-pool-rendered.yaml"
kubectl apply -f "${EV}/03-gpu-pool-rendered.yaml"

#############################################################################
log "=== SCENARIO 1 (positive): device plugin healthy, Pod must wait for it ==="
#############################################################################
cat > "${EV}/pod1.yaml" <<PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke-1
  namespace: default
  labels: { scenario: positive-96 }
spec:
  restartPolicy: Never
  nodeSelector:
    distai.dev/nvidia-gpu-method: device-plugin
  containers:
    - name: smoke
      image: ${TEST_IMAGE}
      command: ["sh", "-c", "date -u; nvidia-smi -L; sleep 600"]
      resources:
        limits:
          nvidia.com/gpu: 1
PODEOF
log "pod1.yaml (note: NO toleration for distai.dev/startup-not-ready -- this is the point)"
cat "${EV}/pod1.yaml"
( kubectl get events -A --watch -o wide > "${EV}/s1-events.log" 2>&1 & echo $! > "${EV}/s1-events.pid" )
kubectl apply -f "${EV}/pod1.yaml"

S1_NODE_READY=""
S1_TAINT_GONE=""
S1_DP_READY=""
S1_POD_RUNNING=""
for i in $(seq 1 90); do
  sleep 10
  NODE1="$(kubectl get nodes -l distai.dev/nvidia-gpu-method=device-plugin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -n "${NODE1}" ]; then
    if [ -z "${S1_NODE_READY}" ] && kubectl get node "${NODE1}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
      S1_NODE_READY="$(date -u +%H:%M:%S)"; log "node ${NODE1} Ready at ${S1_NODE_READY}"
    fi
    TAINTS="$(kubectl get node "${NODE1}" -o jsonpath='{.spec.taints}' 2>/dev/null)"
    if [ -z "${S1_TAINT_GONE}" ] && ! echo "${TAINTS}" | grep -q "startup-not-ready"; then
      S1_TAINT_GONE="$(date -u +%H:%M:%S)"; log "startup taint gone from ${NODE1} at ${S1_TAINT_GONE} (taints now: ${TAINTS})"
    fi
    DP_POD="$(kubectl get pods -n nvidia-device-plugin --field-selector spec.nodeName="${NODE1}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [ -n "${DP_POD}" ] && [ -z "${S1_DP_READY}" ]; then
      READY="$(kubectl get pod "${DP_POD}" -n nvidia-device-plugin -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
      if [ "${READY}" = "True" ]; then
        S1_DP_READY="$(date -u +%H:%M:%S)"; log "device-plugin pod ${DP_POD} Ready at ${S1_DP_READY}"
      fi
    fi
  fi
  PHASE="$(kubectl get pod gpu-smoke-1 -o jsonpath='{.status.phase}' 2>/dev/null)"
  TAINT_PRESENT=no
  echo "${TAINTS:-}" | grep -q "startup-not-ready" && TAINT_PRESENT=yes
  log "t+$((i*10))s node=${NODE1:-<none>} taint_present=${TAINT_PRESENT} dp_ready=${S1_DP_READY:-no} pod_phase=${PHASE:-<none>}"
  if [ "${PHASE}" = "Running" ] && [ -z "${S1_POD_RUNNING}" ]; then
    S1_POD_RUNNING="$(date -u +%H:%M:%S)"; log "gpu-smoke-1 Running at ${S1_POD_RUNNING}"
    break
  fi
done
kill "$(cat "${EV}/s1-events.pid")" 2>/dev/null || true
kubectl get node "${NODE1}" -o yaml > "${EV}/s1-final-node.yaml" 2>/dev/null || true
kubectl describe pod gpu-smoke-1 > "${EV}/s1-final-pod-describe.txt" 2>/dev/null || true
kubectl logs -n vigil-system -l app.kubernetes.io/name=vigil-controller --since=30m > "${EV}/s1-vigil-logs.txt" 2>/dev/null || true
kubectl get events -A --sort-by=.lastTimestamp > "${EV}/s1-events-final.txt" 2>/dev/null || true
{
  echo "node_ready=${S1_NODE_READY}"
  echo "device_plugin_ready=${S1_DP_READY}"
  echo "taint_removed=${S1_TAINT_GONE}"
  echo "pod_running=${S1_POD_RUNNING}"
} > "${EV}/s1-summary.txt"
cat "${EV}/s1-summary.txt"

#############################################################################
log "=== SCENARIO 2 (negative): device plugin broken, Pod must stay Pending ==="
#############################################################################
log "deleting scenario 1's node to force a fresh one for scenario 2"
kubectl delete pod gpu-smoke-1 --ignore-not-found
NODECLAIM1="$(kubectl get nodeclaims -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "${NODECLAIM1}" ]; then
  kubectl delete nodeclaim "${NODECLAIM1}" --wait=true --timeout=120s || true
fi
for i in $(seq 1 12); do kubectl get nodes -l distai.dev/nvidia-gpu-method=device-plugin --no-headers 2>/dev/null | grep -q . || break; sleep 10; done

log "breaking accel-nvidia-device-plugin's image (ImagePullBackOff on purpose)"
helm upgrade accel-nvidia-device-plugin nvdp/nvidia-device-plugin --version 0.20.2 -n nvidia-device-plugin \
  -f "${EV}/nvdp-values.yaml" --set image.tag=does-not-exist-9.9.9

cat > "${EV}/pod2.yaml" <<PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke-2
  namespace: default
  labels: { scenario: negative-96 }
spec:
  restartPolicy: Never
  nodeSelector:
    distai.dev/nvidia-gpu-method: device-plugin
  containers:
    - name: smoke
      image: ${TEST_IMAGE}
      command: ["sh", "-c", "sleep 600"]
      resources:
        limits:
          nvidia.com/gpu: 1
PODEOF
kubectl apply -f "${EV}/pod2.yaml"

S2_STAYED_PENDING=1
for i in $(seq 1 18); do
  sleep 10
  NODE2="$(kubectl get nodes -l distai.dev/nvidia-gpu-method=device-plugin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  PHASE2="$(kubectl get pod gpu-smoke-2 -o jsonpath='{.status.phase}' 2>/dev/null)"
  TAINTS2="$(kubectl get node "${NODE2}" -o jsonpath='{.spec.taints}' 2>/dev/null)"
  log "t+$((i*10))s node=${NODE2:-<none>} taints=${TAINTS2:-<none>} pod_phase=${PHASE2:-<none>}"
  if [ "${PHASE2}" = "Running" ]; then
    log "UNEXPECTED: gpu-smoke-2 reached Running at t+$((i*10))s -- see evidence"
    S2_STAYED_PENDING=0
    break
  fi
done
kubectl describe pod gpu-smoke-2 > "${EV}/s2-final-pod-describe.txt" 2>/dev/null || true
kubectl get events -A --sort-by=.lastTimestamp > "${EV}/s2-events-final.txt" 2>/dev/null || true
kubectl get node "${NODE2}" -o yaml > "${EV}/s2-final-node.yaml" 2>/dev/null || true
kubectl get pods -n nvidia-device-plugin -o wide > "${EV}/s2-device-plugin-pods.txt" 2>/dev/null || true
echo "stayed_pending=${S2_STAYED_PENDING}" > "${EV}/s2-summary.txt"
cat "${EV}/s2-summary.txt"

log "reverting accel-nvidia-device-plugin's image"
helm upgrade accel-nvidia-device-plugin nvdp/nvidia-device-plugin --version 0.20.2 -n nvidia-device-plugin \
  -f "${EV}/nvdp-values.yaml"

log "=== done; cleanup trap will destroy everything now ==="
