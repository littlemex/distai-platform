#!/usr/bin/env bash
# Ad hoc real-hardware verification for issue #96 (not part of the PR,
# lives only on a scratch branch). Builds one disposable, non-hub EKS
# cell with infra/foundation, installs Karpenter, vigil-controller and
# accel-nvidia-device-plugin directly with helm (no GitOps/Argo CD layer
# -- that delivery mechanism is proven separately by PR #21/#25; this
# script only exercises the #96 mechanism itself: capacity-pool's
# pool.startupTaints + vigil-controller + the device-plugin toleration).
#
# All three test Pods below request NO extended resource
# (nvidia.com/gpu) on purpose: kube-scheduler's own resource-fit check
# would otherwise hold a GPU-requesting Pod Pending on its own, with no
# taint involved at all, confounding every result below. Each Pod only
# carries a nodeSelector matching the pool's method label, so the ONLY
# thing that can hold it Pending is the startup taint itself.
#
#   phase 0 (control): pool.startupTaints unset (today's behavior). The
#     Pod must schedule as soon as the node is Ready, with no wait for
#     the device plugin -- this is the unsafe race #96 describes.
#   phase 1 (positive): the same pool, now with pool.startupTaints set.
#     The Pod must stay unschedulable until the real nvidia-device-plugin
#     Pod is Ready and vigil-controller removes the taint.
#   phase 2 (negative): same pool/taint, but the device plugin is made
#     unable to become Ready (bad image tag) on a freshly launched node;
#     the Pod must stay Pending the whole observation window.
#
# Always destroys everything at the end via a trap, whether or not the
# scenarios pass, and writes one evidence file per step under
# /tmp/96-verify-evidence.
set -uo pipefail
# Deliberately not set -e: this script runs many minutes of polling
# against a live cluster where a single transient kubectl error must not
# abort the whole run before the cleanup trap gets a chance to destroy
# everything. The handful of genuinely fatal steps check their own exit
# code explicitly below instead.

export AWS_PROFILE=default
export AWS_REGION=us-east-1
NAME=dp-c96-gpu-r2
STATE_BUCKET=distai-eks-tfstate-776010787911
STATE_REGION=ap-northeast-1
ADMIN_PRINCIPAL_ARN=arn:aws:iam::776010787911:role/distai-platform-runner
# g6e.2xlarge (attempt 1): real g6e.2xlarge spot capacity was unavailable
# in every us-east-1 AZ at the time ("InsufficientInstanceCapacity" from
# the karpenter controller logs, aws-request-id 8edc57de-ce0d-4d53-
# a4f8-21d5babce557/b4634fc3-971e-4093-90ae-fa32c081e7c2), which also hit
# this chart's own README-documented "flex sticks to spot" Karpenter bug
# (the on-demand fallback never engaged within the observation window).
# Switching to g7.2xlarge on-demand (both this account's own 2026-11-17
# capacity survey and this real attempt point the same way) and to
# on-demand (not flex) removes both failure modes for this short-lived
# test node.
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

NODE_ROLE="$(terraform output -raw karpenter_node_role_name)"
INTERRUPTION_QUEUE="$(terraform output -raw karpenter_interruption_queue_name)"
log "NODE_ROLE=${NODE_ROLE} INTERRUPTION_QUEUE=${INTERRUPTION_QUEUE}"

aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
kubectl get nodes -o wide | tee "${EV}/02-system-nodes.txt"
kubectl get daemonset -A -o wide | tee "${EV}/02-system-daemonsets.txt"

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

render_pool() {
  # render_pool OUT_FILE STARTUP_TAINTS_YAML_OR_EMPTY
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

delete_gpu_node() {
  local nc
  for i in $(seq 1 30); do
    nc="$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [ -z "${nc}" ] && break
    kubectl delete nodeclaim "${nc}" --wait=true --timeout=120s 2>/dev/null || true
    sleep 5
  done
  for i in $(seq 1 12); do
    kubectl get nodes -l distai.dev/nvidia-gpu-method=device-plugin --no-headers 2>/dev/null | grep -q . || break
    sleep 10
  done
}

# watch_pod POD_NAME EVIDENCE_PREFIX MAX_ITERS -> writes summary, returns via files
watch_pod() {
  local pod="$1" prefix="$2" max_iters="$3"
  local node="" scheduled_at="" running_at="" taint_gone_at="" dp_ready_at=""
  ( kubectl get events -A --watch -o wide > "${EV}/${prefix}-events.log" 2>&1 & echo $! > "${EV}/${prefix}-events.pid" )
  for i in $(seq 1 "${max_iters}"); do
    sleep 10
    node="$(kubectl get pod "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
    local phase scheduled_cond taints dp_pod dp_ready
    phase="$(kubectl get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null)"
    scheduled_cond="$(kubectl get pod "${pod}" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null)"
    if [ "${scheduled_cond}" = "True" ] && [ -z "${scheduled_at}" ]; then
      scheduled_at="$(date -u +%H:%M:%S)"; log "${prefix}: Scheduled (onto ${node}) at ${scheduled_at}"
    fi
    taints="<no-node>"
    if [ -n "${node}" ]; then
      taints="$(kubectl get node "${node}" -o jsonpath='{.spec.taints}' 2>/dev/null)"
      if [ -z "${taint_gone_at}" ] && ! echo "${taints}" | grep -q "startup-not-ready"; then
        taint_gone_at="$(date -u +%H:%M:%S)"; log "${prefix}: startup taint gone from ${node} at ${taint_gone_at}"
      fi
      dp_pod="$(kubectl get pods -n nvidia-device-plugin --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
      if [ -n "${dp_pod}" ] && [ -z "${dp_ready_at}" ]; then
        dp_ready="$(kubectl get pod "${dp_pod}" -n nvidia-device-plugin -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
        [ "${dp_ready}" = "True" ] && { dp_ready_at="$(date -u +%H:%M:%S)"; log "${prefix}: device-plugin pod ${dp_pod} Ready at ${dp_ready_at}"; }
      fi
    fi
    log "${prefix} t+$((i*10))s node=${node:-<none>} scheduled=${scheduled_at:-no} taints=${taints} dp_ready=${dp_ready_at:-no} phase=${phase:-<none>}"
    if [ "${phase}" = "Running" ] && [ -z "${running_at}" ]; then
      running_at="$(date -u +%H:%M:%S)"; log "${prefix}: Running at ${running_at}"
      break
    fi
  done
  kill "$(cat "${EV}/${prefix}-events.pid" 2>/dev/null)" 2>/dev/null || true
  [ -n "${node}" ] && kubectl get node "${node}" -o yaml > "${EV}/${prefix}-final-node.yaml" 2>/dev/null
  kubectl describe pod "${pod}" > "${EV}/${prefix}-final-pod-describe.txt" 2>/dev/null || true
  kubectl get events -A --sort-by=.lastTimestamp > "${EV}/${prefix}-events-final.txt" 2>/dev/null || true
  {
    echo "node=${node}"
    echo "scheduled_at=${scheduled_at}"
    echo "device_plugin_ready_at=${dp_ready_at}"
    echo "taint_removed_at=${taint_gone_at}"
    echo "running_at=${running_at}"
  } > "${EV}/${prefix}-summary.txt"
  cat "${EV}/${prefix}-summary.txt"
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

#############################################################################
log "=== PHASE 0 (control): pool.startupTaints unset -- today's unsafe behavior ==="
#############################################################################
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

#############################################################################
log "=== PHASE 1 (positive): same pool, pool.startupTaints set, device plugin healthy ==="
#############################################################################
render_pool "${EV}/03-gpu-pool-positive.yaml" "${STARTUP_TAINTS_BLOCK}"
cat "${EV}/03-gpu-pool-positive.yaml"
kubectl apply -f "${EV}/03-gpu-pool-positive.yaml" || log "(expected) the rendered ResourceFlavor errors -- Kueue is deliberately not installed for this test; NodePool/EC2NodeClass still apply"
make_pod gpu-positive "${EV}/pod-positive.yaml"
kubectl apply -f "${EV}/pod-positive.yaml"
watch_pod gpu-positive positive 90
kubectl logs -n vigil-system -l app.kubernetes.io/name=vigil-controller --since=30m > "${EV}/positive-vigil-logs.txt" 2>/dev/null || true
kubectl delete pod gpu-positive --ignore-not-found
delete_gpu_node

#############################################################################
log "=== PHASE 2 (negative): same taint, device plugin broken ==="
#############################################################################
log "breaking accel-nvidia-device-plugin's image (ImagePullBackOff on purpose)"
helm upgrade accel-nvidia-device-plugin nvdp/nvidia-device-plugin --version 0.20.2 -n nvidia-device-plugin \
  -f "${EV}/nvdp-values.yaml" --set image.tag=does-not-exist-9.9.9
kubectl apply -f "${EV}/03-gpu-pool-positive.yaml" || true
make_pod gpu-negative "${EV}/pod-negative.yaml"
kubectl apply -f "${EV}/pod-negative.yaml"
watch_pod gpu-negative negative 18
kubectl get pods -n nvidia-device-plugin -o wide > "${EV}/negative-device-plugin-pods.txt" 2>/dev/null || true

log "reverting accel-nvidia-device-plugin's image"
helm upgrade accel-nvidia-device-plugin nvdp/nvidia-device-plugin --version 0.20.2 -n nvidia-device-plugin \
  -f "${EV}/nvdp-values.yaml"

log "=== done; cleanup trap will destroy everything now ==="
