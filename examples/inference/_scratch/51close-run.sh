#!/usr/bin/env bash
# Real-hardware investigation closing PR #51's 3 open MPS/KV-cache items.
# Runs INSIDE the EC2 runner, in a fresh clone of littlemex/distai-platform
# at verify/51-mps-kvcache-close (based on fix/51-rebase-onto-39-efa, PR #51's
# own head). Single cell, sequential phases, max 2 g7.8xlarge-class nodes at
# once, always destroys at the end (trap).
set -uo pipefail
export AWS_PROFILE=default
export AWS_REGION=us-east-1
export NAME=dp-51c-r1
export STATE_BUCKET=distai-eks-tfstate-776010787911
export STATE_REGION=ap-northeast-1
export KUBECONFIG=/tmp/${NAME}-kubeconfig
MODEL_ID="Qwen/Qwen2.5-0.5B-Instruct"

log() { echo "[$(date -u +%T)] === $* ==="; }
mark() { echo "MARK:$1"; }

cleanup() {
  log "TEARDOWN (trap)"
  cd /tmp/work/repo/infra/foundation 2>/dev/null || cd /tmp/work/repo/infra/foundation 2>/dev/null || { echo "cannot find infra/foundation to destroy"; mark TEARDOWN_PATH_MISSING; return 0; }
  terraform destroy -auto-approve 2>&1 | tail -100
  mark TEARDOWN_DONE
}
trap cleanup EXIT

mkdir -p /tmp/work && cd /tmp/work
ADMIN_ROLE_NAME="$(aws sts get-caller-identity --query Arn --output text | cut -d/ -f2)"
ADMIN_PRINCIPAL_ARN="$(aws iam get-role --role-name "$ADMIN_ROLE_NAME" --query Role.Arn --output text)"
MY_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
export TF_VAR_name="$NAME" TF_VAR_region="$AWS_REGION"
export TF_VAR_endpoint_public_access_cidrs="[\"${MY_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_PRINCIPAL_ARN}\"]"

log "PHASE0: foundation apply"
cd repo/infra/foundation
terraform init -backend-config="bucket=${STATE_BUCKET}" -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" -backend-config="region=${STATE_REGION}" -backend-config="use_lockfile=true" || { echo FATAL_TF_INIT; exit 1; }
terraform apply -auto-approve || { echo FATAL_TF_APPLY; exit 1; }
cd /tmp/work/repo
aws eks update-kubeconfig --name "$NAME" --region "$AWS_REGION" || { echo FATAL_KUBECONFIG; exit 1; }
kubectl config current-context
mark PHASE0_DONE

log "PHASE0b: addons (karpenter, nvidia-device-plugin w/ MPS config, EFA plugin, kueue)"
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version 1.15.2 -n kube-system --wait --timeout 5m
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.2 -n kube-system --skip-crds --wait --timeout 10m \
  --set serviceAccount.name=karpenter \
  --set "controller.env[0].name=AWS_REGION" --set "controller.env[0].value=${AWS_REGION}" \
  --set settings.clusterName="$NAME" --set settings.interruptionQueue="$NAME" \
  --set "tolerations[0].key=CriticalAddonsOnly" --set "tolerations[0].operator=Exists"

cat > /tmp/nvdp-mps-values.yaml <<'YAML'
config:
  default: whole
  map:
    whole: |-
      version: v1
      flags:
        migStrategy: none
    mps-2: |-
      version: v1
      sharing:
        mps:
          resources:
          - name: nvidia.com/gpu
            replicas: 2
YAML
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install nvdp nvdp/nvidia-device-plugin --version 0.20.2 -n nvidia-device-plugin --create-namespace -f /tmp/nvdp-mps-values.yaml --wait --timeout 5m
helm upgrade --install aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin --version v0.5.35 -n kube-system --wait --timeout 5m
helm upgrade --install kueue oci://registry.k8s.io/kueue/charts/kueue --version 0.20.6 -n kueue-system --create-namespace --wait --timeout 5m \
  --set "controllerManager.tolerations[0].key=CriticalAddonsOnly" --set "controllerManager.tolerations[0].operator=Exists"
mark PHASE0B_DONE

NODE_ROLE="${NAME}-karpenter-node"
log "PHASE0c: gpu-shared pool (g7.8xlarge, mps-2, pd-role=shared, no EFA)"
cat > /tmp/gpu-shared-values.yaml <<EOF
clusterName: ${NAME}
nodeRole: ${NODE_ROLE}
pool:
  name: gpu-shared
  capacityType: flex
  requirements:
    - {key: kubernetes.io/arch, operator: In, values: ["amd64"]}
    - {key: node.kubernetes.io/instance-type, operator: In, values: ["g7.8xlarge"]}
    - {key: distai.dev/pd-role, operator: In, values: ["shared"]}
  limits: {cpu: "32"}
  disruption: {consolidationPolicy: WhenEmptyOrUnderutilized, consolidateAfter: "30m"}
  rootVolumeSizeGi: "150Gi"
accelerator:
  sharingLabel: {key: "nvidia.com/device-plugin.config", value: "mps-2"}
  mpsLabel: {key: "nvidia.com/mps.capable", value: "true"}
EOF
helm upgrade --install gpu-shared-pool gitops/charts/capacity-pool -n kube-system -f /tmp/gpu-shared-values.yaml
mark PHASE0C_DONE

###############################################################################
log "PHASE1a: agg-baseline, replicas=2, mps.enabled=false (reproduce the original success; capture FULL startup logs)"
kubectl create namespace vllm-mps1 --dry-run=client -o yaml | kubectl apply -f -
cat > /tmp/agg-shared.yaml <<'EOF'
engine:
  replicas: 2
  nodeSelector:
    distai.dev/pd-role: shared
EOF
helm install t1a examples/inference/vllm/agg-baseline -n vllm-mps1 --set model.name="$MODEL_ID" -f /tmp/agg-shared.yaml --timeout 15m 2>&1 | tail -20
kubectl rollout status deployment -n vllm-mps1 -l app.kubernetes.io/instance=t1a --timeout=12m
echo "PHASE1A_PODS:"; kubectl get pods -n vllm-mps1 -o wide
for p in $(kubectl get pods -n vllm-mps1 -o jsonpath='{.items[*].metadata.name}'); do
  echo "---LOG $p (grep gpu_memory_utilization / EngineArgs / GiB)---"
  kubectl logs -n vllm-mps1 "$p" 2>&1 | grep -iE "gpu_memory_utilization|gpu memory utilization|EngineArgs|free memory on device|GPU KV cache|maximum concurrency" | head -20
done
mark PHASE1A_DONE
helm uninstall t1a -n vllm-mps1 --wait --timeout 5m 2>&1 | tail -5

log "PHASE1b: disagg-pd same-node colocate, mps.enabled=false, UCX/no-EFA (confirm ORIGINAL failure still reproduces unchanged, before the fix is used)"
cat > /tmp/disagg-samenode-nofix.yaml <<'EOF'
placement:
  sameNodeMeasurement: true
  sharedPoolValue: shared
  enforceAntiAffinity: false
transport:
  backend: UCX
prefill:
  efaDevices: 0
decode:
  efaDevices: 0
EOF
helm install t1b examples/inference/vllm/disagg-pd -n vllm-mps1 --set model.name="$MODEL_ID" -f /tmp/disagg-samenode-nofix.yaml --timeout 15m 2>&1 | tail -20
sleep 120
echo "PHASE1B_PODS (expect CrashLoopBackOff, no fix applied yet):"; kubectl get pods -n vllm-mps1 -o wide
for p in $(kubectl get pods -n vllm-mps1 -o jsonpath='{.items[*].metadata.name}'); do
  echo "---LOG $p---"
  kubectl logs -n vllm-mps1 "$p" --tail=20 2>&1 | grep -iE "gpu_memory_utilization|free memory on device|ValueError|Error"
done
mark PHASE1B_DONE
helm uninstall t1b -n vllm-mps1 --wait --timeout 5m 2>&1 | tail -5

log "PHASE1c: disagg-pd same-node colocate, prefill/decode.mps.enabled=true, replicas=2 (THE FIX), UCX/no-EFA"
cat > /tmp/disagg-samenode-fix.yaml <<'EOF'
placement:
  sameNodeMeasurement: true
  sharedPoolValue: shared
  enforceAntiAffinity: false
transport:
  backend: UCX
prefill:
  efaDevices: 0
  mps: {enabled: true, replicas: 2}
decode:
  efaDevices: 0
  mps: {enabled: true, replicas: 2}
EOF
helm install t1c examples/inference/vllm/disagg-pd -n vllm-mps1 --set model.name="$MODEL_ID" -f /tmp/disagg-samenode-fix.yaml --timeout 15m 2>&1 | tail -20
kubectl rollout status deployment -n vllm-mps1 -l app.kubernetes.io/instance=t1c --timeout=12m
echo "PHASE1C_PODS (expect Running/Ready now):"; kubectl get pods -n vllm-mps1 -o wide
for p in $(kubectl get pods -n vllm-mps1 -o jsonpath='{.items[*].metadata.name}'); do
  echo "---LOG $p---"
  kubectl logs -n vllm-mps1 "$p" 2>&1 | grep -iE "gpu_memory_utilization|free memory on device|Starting vLLM|Uvicorn running" | head -10
done
kubectl run curl-1c --rm -i --restart=Never -n vllm-mps1 --image=curlimages/curl:8.23.0 --timeout=60s -- \
  curl -sS "http://t1c-vllm-disagg-pd-decode:8000/v1/completions" -H 'Content-Type: application/json' \
  -d "{\"model\": \"${MODEL_ID}\", \"prompt\": \"The capital of France is\", \"max_tokens\": 16}" 2>&1 | tail -5
mark PHASE1C_DONE
helm uninstall t1c -n vllm-mps1 --wait --timeout 5m 2>&1 | tail -5
kubectl delete namespace vllm-mps1 --wait=true --timeout=3m 2>&1 | tail -5

###############################################################################
log "PHASE2: 2-node MPS disagg (form c) -- GPU UUID + EFA byte-counter evidence, vLLM with the fix and SGLang"
cat > /tmp/gpu-mps-efa-prefill-values.yaml <<EOF
clusterName: ${NAME}
nodeRole: ${NODE_ROLE}
pool:
  name: gpu-mps-efa-prefill
  capacityType: flex
  requirements:
    - {key: kubernetes.io/arch, operator: In, values: ["amd64"]}
    - {key: node.kubernetes.io/instance-type, operator: In, values: ["g7.48xlarge"]}
    - {key: distai.dev/pd-role, operator: In, values: ["prefill"]}
  limits: {cpu: "200"}
  disruption: {consolidationPolicy: WhenEmptyOrUnderutilized, consolidateAfter: "10m"}
  rootVolumeSizeGi: "150Gi"
  networkInterfaces:
    - {networkCardIndex: 0, deviceIndex: 0, interfaceType: interface}
    - {networkCardIndex: 0, deviceIndex: 1, interfaceType: efa-only}
    - {networkCardIndex: 1, deviceIndex: 0, interfaceType: efa-only}
accelerator:
  sharingLabel: {key: "nvidia.com/device-plugin.config", value: "mps-2"}
  mpsLabel: {key: "nvidia.com/mps.capable", value: "true"}
EOF
helm upgrade --install gpu-mps-efa-prefill-pool gitops/charts/capacity-pool -n kube-system -f /tmp/gpu-mps-efa-prefill-values.yaml

cat > /tmp/gpu-efa-decode-values.yaml <<EOF
clusterName: ${NAME}
nodeRole: ${NODE_ROLE}
pool:
  name: gpu-efa-decode
  capacityType: flex
  requirements:
    - {key: kubernetes.io/arch, operator: In, values: ["amd64"]}
    - {key: node.kubernetes.io/instance-type, operator: In, values: ["g7.8xlarge"]}
    - {key: distai.dev/pd-role, operator: In, values: ["decode"]}
  limits: {cpu: "32"}
  disruption: {consolidationPolicy: WhenEmptyOrUnderutilized, consolidateAfter: "10m"}
  rootVolumeSizeGi: "150Gi"
  networkInterfaces:
    - {networkCardIndex: 0, deviceIndex: 0, interfaceType: interface}
    - {networkCardIndex: 0, deviceIndex: 1, interfaceType: efa-only}
EOF
helm upgrade --install gpu-efa-decode-pool gitops/charts/capacity-pool -n kube-system -f /tmp/gpu-efa-decode-values.yaml
mark PHASE2_POOLS_DONE

kubectl create namespace vllm-mps2 --dry-run=client -o yaml | kubectl apply -f -
cat > /tmp/disagg-2node-fix.yaml <<'EOF'
prefill:
  replicas: 2
  mps: {enabled: true, replicas: 2}
decode:
  replicas: 1
EOF
helm install t2v examples/inference/vllm/disagg-pd -n vllm-mps2 --set model.name="$MODEL_ID" -f /tmp/disagg-2node-fix.yaml --timeout 20m 2>&1 | tail -20
kubectl rollout status deployment -n vllm-mps2 -l app.kubernetes.io/instance=t2v --timeout=18m
echo "PHASE2_VLLM_PODS:"
kubectl get pods -n vllm-mps2 -o wide
kubectl get pods -n vllm-mps2 -o jsonpath='{range .items[*]}{.metadata.name}{" node="}{.spec.nodeName}{"\n"}{end}'
echo "---GPU UUID per prefill replica (known issue #5)---"
for p in $(kubectl get pods -n vllm-mps2 -l app.kubernetes.io/component=prefill -o jsonpath='{.items[*].metadata.name}'); do
  echo "pod=$p uuid=$(kubectl exec -n vllm-mps2 "$p" -- nvidia-smi --query-gpu=uuid,index --format=csv,noheader 2>&1)"
done
PREFILL_NODE=$(kubectl get pod -n vllm-mps2 -l app.kubernetes.io/component=prefill -o jsonpath='{.items[0].spec.nodeName}')
DECODE_NODE=$(kubectl get pod -n vllm-mps2 -l app.kubernetes.io/component=decode -o jsonpath='{.items[0].spec.nodeName}')
echo "prefill_node=$PREFILL_NODE decode_node=$DECODE_NODE"
hw_debug() {
  kubectl debug "node/$1" -n vllm-mps2 --profile=general --image=curlimages/curl:8.23.0 -i -- \
    sh -c 'for f in /host/sys/class/infiniband/*/ports/1/hw_counters/tx_bytes /host/sys/class/infiniband/*/ports/1/hw_counters/rx_bytes /host/sys/class/infiniband/*/ports/1/hw_counters/rdma_read_bytes /host/sys/class/infiniband/*/ports/1/hw_counters/rdma_write_bytes; do echo "$f = $(cat "$f" 2>&1)"; done' 2>&1
}
echo "---EFA hw_counters BEFORE load---"
echo "[prefill:$PREFILL_NODE]"; hw_debug "$PREFILL_NODE"
echo "[decode:$DECODE_NODE]"; hw_debug "$DECODE_NODE"
kubectl get pods -n vllm-mps2 -o name | grep node-debugger | xargs -r kubectl delete -n vllm-mps2
for i in $(seq 1 10); do
  kubectl run curl-2v-$i --rm -i --restart=Never -n vllm-mps2 --image=curlimages/curl:8.23.0 --timeout=60s -- \
    curl -sS "http://t2v-vllm-disagg-pd-decode:8000/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\": \"${MODEL_ID}\", \"prompt\": \"The capital of France is\", \"max_tokens\": 32}" >/dev/null 2>&1
done
echo "---EFA hw_counters AFTER load---"
echo "[prefill:$PREFILL_NODE]"; hw_debug "$PREFILL_NODE"
echo "[decode:$DECODE_NODE]"; hw_debug "$DECODE_NODE"
kubectl get pods -n vllm-mps2 -o name | grep node-debugger | xargs -r kubectl delete -n vllm-mps2
mark PHASE2_VLLM_DONE
helm uninstall t2v -n vllm-mps2 --wait --timeout 5m 2>&1 | tail -5

cat > /tmp/sglang-2node.yaml <<'EOF'
prefill:
  replicas: 2
EOF
helm install t2s examples/inference/sglang/disagg-pd -n vllm-mps2 --set model.name="$MODEL_ID" -f /tmp/sglang-2node.yaml --timeout 20m 2>&1 | tail -30
kubectl rollout status deployment -n vllm-mps2 -l app.kubernetes.io/instance=t2s --timeout=18m
echo "PHASE2_SGLANG_PODS:"
kubectl get pods -n vllm-mps2 -o wide
kubectl get pods -n vllm-mps2 -o jsonpath='{range .items[*]}{.metadata.name}{" node="}{.spec.nodeName}{"\n"}{end}'
echo "---GPU UUID per SGLang prefill replica---"
for p in $(kubectl get pods -n vllm-mps2 -l app.kubernetes.io/component=prefill -o jsonpath='{.items[*].metadata.name}'); do
  echo "pod=$p uuid=$(kubectl exec -n vllm-mps2 "$p" -- nvidia-smi --query-gpu=uuid,index --format=csv,noheader 2>&1)"
done
mark PHASE2_SGLANG_DONE
helm uninstall t2s -n vllm-mps2 --wait --timeout 5m 2>&1 | tail -5
kubectl delete namespace vllm-mps2 --wait=true --timeout=3m 2>&1 | tail -5

###############################################################################
log "PHASE3: SGLang HiCache cold/warm, in isolation (dedicated namespace, decode pool node, no concurrent test)"
kubectl create namespace sglang-hc --dry-run=client -o yaml | kubectl apply -f -
cat > /tmp/sglang-hicache.yaml <<'EOF'
engine:
  nodeSelector:
    distai.dev/pd-role: decode
  resources:
    requests:
      cpu: "4"
      memory: 48Gi
kvCacheTier:
  mode: local
  hicache:
    sizeGb: 4
EOF
helm install h1 examples/inference/sglang/agg-baseline -n sglang-hc --set model.name="$MODEL_ID" -f /tmp/sglang-hicache.yaml --timeout 15m 2>&1 | tail -40
kubectl rollout status deployment -n sglang-hc -l app.kubernetes.io/instance=h1 --timeout=12m
kubectl get pods -n sglang-hc -o wide
mark PHASE3_INSTALLED
SVC=$(kubectl get svc -n sglang-hc -o jsonpath='{.items[0].metadata.name}')
PROMPT_FILE=/tmp/hc-prompt.json
python3 - "$MODEL_ID" > "$PROMPT_FILE" <<'PY'
import json, sys
model = sys.argv[1]
prompt = "You are a careful assistant. Repeat the following long passage verbatim then answer: " + ("context token filler sentence. " * 200)
print(json.dumps({"model": model, "prompt": prompt, "max_tokens": 8}))
PY
req() {
  kubectl run hc-req-$RANDOM --rm -i --restart=Never -n sglang-hc --image=curlimages/curl:8.23.0 --timeout=60s -- \
    curl -sS -w "\nTTFT_PROXY_TOTAL_TIME=%{time_starttransfer}\n" "http://$SVC:8000/v1/completions" \
    -H 'Content-Type: application/json' --data-binary @- 2>&1
}
echo "--- COLD pass ---"; cat "$PROMPT_FILE" | req
sleep 2
echo "--- WARM pass (same prefix) ---"; cat "$PROMPT_FILE" | req
mark PHASE3_DONE
helm uninstall h1 -n sglang-hc --wait --timeout 5m 2>&1 | tail -5
kubectl delete namespace sglang-hc --wait=true --timeout=3m 2>&1 | tail -5

log "ALL PHASES DONE"
mark ALL_DONE
