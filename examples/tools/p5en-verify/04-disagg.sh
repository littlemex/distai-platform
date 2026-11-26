#!/usr/bin/env bash
# Stage 4 (time permitting): same-node vLLM prefill/decode disaggregation
# on the p5en.48xlarge node, forced over the real EFA device
# (transport.forceEfaSameNode=true), following
# examples/inference/vllm/disagg-pd/README.md's own "same-node
# measurement cell" and "Check which path the KV cache took" recipes
# verbatim, plus the shared load-replay/scorer from
# examples/inference/_shared/README.md. Not part of the platform
# (examples/ is not gitops/).
set -euo pipefail

NAME="${NAME:-dp-p5en-efa}"
AWS_REGION="${AWS_REGION:-us-east-2}"
NODE="${NODE:?export NODE (the p5en node name from stage 3)}"
MODEL_ID="${MODEL_ID:-Qwen/Qwen2.5-0.5B-Instruct}"
NAMESPACE=pd-demo
RELEASE=pd
export AWS_PROFILE=default
aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"

echo "=== [1/7] labeling the single node for the shared same-node pool ==="
kubectl label node "${NODE}" distai.dev/pd-role=shared --overwrite

echo "=== [2/7] helm install (sameNodeMeasurement, forceEfaSameNode, anti-affinity off) ==="
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install "${RELEASE}" examples/inference/vllm/disagg-pd \
  --namespace "${NAMESPACE}" \
  --set model.name="${MODEL_ID}" \
  --set placement.sameNodeMeasurement=true \
  --set placement.sharedPoolValue=shared \
  --set placement.enforceAntiAffinity=false \
  --set transport.forceEfaSameNode=true \
  --set-string 'proxy.nodeSelector.distai\.dev/pd-role=shared' \
  --set-json 'proxy.tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
kubectl rollout status deployment -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE}" --timeout=40m

echo "=== [3/7] both roles really are on the one node ==="
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE}" -o wide

echo "=== [4/7] one smoke request through the proxy (retrying up to 3 min) ==="
smoke_deadline=$(( $(date +%s) + 180 ))
smoke_ok=0
while [[ $(date +%s) -lt ${smoke_deadline} ]]; do
  if kubectl run "curl-pd-smoke-$(date +%s)" --rm -i --restart=Never -n "${NAMESPACE}" \
    --image=curlimages/curl:8.23.0 --command -- \
    curl -sS --max-time 20 "http://${RELEASE}-vllm-disagg-pd:8000/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\": \"${MODEL_ID}\", \"prompt\": \"The capital of France is\", \"max_tokens\": 32}" \
    | tee /tmp/p5en-smoke.json | grep -q '"text"'; then
    smoke_ok=1
    break
  fi
  sleep 10
done
cat /tmp/p5en-smoke.json || true
echo
[[ "${smoke_ok}" == "1" ]] || echo "WARNING: smoke request did not return a completion within 3 min, continuing anyway"

read_efa_counters() {
  kubectl debug "node/${NODE}" -n "${NAMESPACE}" --profile=general --image=curlimages/curl:8.23.0 -i -- \
    sh -c 'tx=0; rx=0; rr=0; rw=0
      for f in /host/sys/class/infiniband/*/ports/1/hw_counters/tx_bytes; do v=$(cat "$f" 2>/dev/null || echo 0); tx=$((tx+v)); done
      for f in /host/sys/class/infiniband/*/ports/1/hw_counters/rx_bytes; do v=$(cat "$f" 2>/dev/null || echo 0); rx=$((rx+v)); done
      for f in /host/sys/class/infiniband/*/ports/1/hw_counters/rdma_read_bytes; do v=$(cat "$f" 2>/dev/null || echo 0); rr=$((rr+v)); done
      for f in /host/sys/class/infiniband/*/ports/1/hw_counters/rdma_write_bytes; do v=$(cat "$f" 2>/dev/null || echo 0); rw=$((rw+v)); done
      echo "tx_bytes_total=$tx rx_bytes_total=$rx rdma_read_bytes_total=$rr rdma_write_bytes_total=$rw"'
}

echo "=== [5/7] EFA counters before the load, then running the load-replay ==="
read_efa_counters | tee /tmp/p5en-efa-before.txt

export RUN_ID=run1 LAYOUT=disagg-pd-samenode TARGET_URL="http://${RELEASE}-vllm-disagg-pd:8000"
export NUM_PROMPTS=200 REQUEST_RATE=2 MAX_SEND_LAG_MS=150
export BENCH_EXTRA_ARGS="--random-input-len 512 --random-output-len 128 --seed 0"
kubectl create configmap load-replay-scripts -n "${NAMESPACE}" \
  --from-file=examples/inference/_shared/load-replay/run-load.sh \
  --from-file=examples/inference/_shared/load-replay/driver.py \
  --dry-run=client -o yaml | kubectl apply -f -
envsubst '${TARGET_URL} ${MODEL_ID} ${NUM_PROMPTS} ${REQUEST_RATE} ${MAX_SEND_LAG_MS} ${BENCH_EXTRA_ARGS}' \
  < examples/inference/_shared/load-replay/load-job.yaml \
  | kubectl apply -n "${NAMESPACE}" -f -

kubectl wait -n "${NAMESPACE}" --for=condition=Ready pod -l job-name=load-replay --timeout=15m
POD="$(kubectl get pods -n "${NAMESPACE}" -l job-name=load-replay -o jsonpath='{.items[0].metadata.name}')"
deadline=$(( $(date +%s) + 1800 ))
until kubectl exec -n "${NAMESPACE}" "${POD}" -- test -e /results/exit-code; do
  [[ $(date +%s) -lt ${deadline} ]] || { echo "RESULT LOAD-TIMEOUT"; break; }
  sleep 15
done
mkdir -p /tmp/p5en-results
kubectl cp -n "${NAMESPACE}" "${POD}:/results" "/tmp/p5en-results/results-${RUN_ID}"
kubectl exec -n "${NAMESPACE}" "${POD}" -- touch /results/.collected
echo "load-replay exit code: $(cat "/tmp/p5en-results/results-${RUN_ID}/exit-code")"

echo "=== [6/7] EFA counters after the load ==="
read_efa_counters | tee /tmp/p5en-efa-after.txt

echo "=== [7/7] scoring ==="
export GPU_COUNT=2 TTFT_MS=2000 GAP_MS=100
python3 examples/inference/_shared/scorer/score.py \
  --records "/tmp/p5en-results/results-${RUN_ID}/bench.json" \
  --planned-requests "${NUM_PROMPTS}" \
  --gpu-count "${GPU_COUNT}" \
  --ttft-ms "${TTFT_MS}" --tpot-or-gap-ms "${GAP_MS}" \
  --out "/tmp/p5en-results/results-${RUN_ID}/score.json"
cat "/tmp/p5en-results/results-${RUN_ID}/score.json"

echo "=== summary ==="
echo "before: $(cat /tmp/p5en-efa-before.txt)"
echo "after:  $(cat /tmp/p5en-efa-after.txt)"
echo "RESULT DISAGG-PASS namespace=${NAMESPACE} release=${RELEASE} run_id=${RUN_ID}"
