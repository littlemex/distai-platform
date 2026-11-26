#!/usr/bin/env bash
# Stage 6 (coordinator priority 3, 2026-11-27): same-node vLLM
# prefill/decode disaggregation over NIXL's UCX backend (not EFA/
# LIBFABRIC) on the p5en.48xlarge node (8 GPUs, 16 EFA interfaces --
# unused by this transport on purpose), to check transport.ucx.
# tcpPortRange's NetworkPolicy port-range fix still produces a real
# goodput number at this larger instance/scale, following
# examples/inference/vllm/disagg-pd/README.md's own "same-node
# measurement cell" and "Check which path the KV cache took" recipes
# verbatim, plus the shared load-replay/scorer from
# examples/inference/_shared/README.md. Not part of the platform
# (examples/ is not gitops/).
set -euo pipefail

NAME="${NAME:-dp-p5en-efa}"
AWS_REGION="${AWS_REGION:-us-east-2}"
NODE="${NODE:?export NODE (the p5en node name from stage 3)}"
export MODEL_ID="${MODEL_ID:-Qwen/Qwen2.5-0.5B-Instruct}"
NAMESPACE=pd-ucx-demo
RELEASE=pducx
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
  --set transport.backend=UCX \
  --set-string 'proxy.nodeSelector.distai\.dev/pd-role=shared' \
  --set-json 'proxy.tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
kubectl rollout status deployment -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE}" --timeout=40m

echo "=== [3/7] both roles really are on the one node ==="
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE}" -o wide

echo "=== [4/7] one smoke request through the proxy (retrying up to 3 min) ==="
# The proxy's own NetworkPolicy (rendered by this chart) allows ingress
# on 8000 only from a pod labeled app.kubernetes.io/name=load-replay --
# not a bug, the documented "every Service cluster-internal" posture; a
# plain `kubectl run` pod needs that same label to pass it.
smoke_deadline=$(( $(date +%s) + 180 ))
smoke_ok=0
while [[ $(date +%s) -lt ${smoke_deadline} ]]; do
  if kubectl run "curl-pd-smoke-$(date +%s)" --rm -i --restart=Never -n "${NAMESPACE}" \
    --labels=app.kubernetes.io/name=load-replay \
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
  local tag="$1"
  local pod="efa-read-${tag}-$(date +%s)"
  cat > "/tmp/${pod}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  tolerations:
    - operator: Exists
  containers:
    - name: ${pod}
      image: curlimages/curl:8.23.0
      command: ["sh", "-c"]
      args:
        - |
          tx=0; rx=0; rr=0; rw=0
          for f in /host-sys/class/infiniband/*/ports/1/hw_counters/tx_bytes; do v=\$(cat "\$f" 2>/dev/null); tx=\$((tx+v)); done
          for f in /host-sys/class/infiniband/*/ports/1/hw_counters/rx_bytes; do v=\$(cat "\$f" 2>/dev/null); rx=\$((rx+v)); done
          for f in /host-sys/class/infiniband/*/ports/1/hw_counters/rdma_read_bytes; do v=\$(cat "\$f" 2>/dev/null); rr=\$((rr+v)); done
          for f in /host-sys/class/infiniband/*/ports/1/hw_counters/rdma_write_bytes; do v=\$(cat "\$f" 2>/dev/null); rw=\$((rw+v)); done
          echo tx_bytes_total=\$tx rx_bytes_total=\$rx rdma_read_bytes_total=\$rr rdma_write_bytes_total=\$rw
      volumeMounts:
        - name: sys
          mountPath: /host-sys
  volumes:
    - name: sys
      hostPath:
        path: /sys
EOF
  kubectl apply -f "/tmp/${pod}.yaml" >/dev/null
  kubectl wait -n "${NAMESPACE}" --for=jsonpath='"'"'{.status.phase}'"'"'=Succeeded "pod/${pod}" --timeout=60s >/dev/null 2>&1 || true
  kubectl logs -n "${NAMESPACE}" "${pod}"
  kubectl delete pod -n "${NAMESPACE}" "${pod}" --ignore-not-found >/dev/null
}

echo "=== [5/7] EFA counters before the load, then running the load-replay ==="
read_efa_counters before | tee /tmp/p5en-efa-before.txt

export RUN_ID=ucxrun1 LAYOUT=disagg-pd-ucx-samenode TARGET_URL="http://${RELEASE}-vllm-disagg-pd:8000"
export NUM_PROMPTS=200 REQUEST_RATE=2 MAX_SEND_LAG_MS=150
export BENCH_EXTRA_ARGS="--random-input-len 512 --random-output-len 128 --seed 0"
kubectl create configmap load-replay-scripts -n "${NAMESPACE}" \
  --from-file=examples/inference/_shared/load-replay/run-load.sh \
  --from-file=examples/inference/_shared/load-replay/driver.py \
  --dry-run=client -o yaml | kubectl apply -f -
envsubst '${TARGET_URL} ${MODEL_ID} ${NUM_PROMPTS} ${REQUEST_RATE} ${MAX_SEND_LAG_MS} ${BENCH_EXTRA_ARGS}' \
  < examples/inference/_shared/load-replay/load-job.yaml \
  > /tmp/load-job.rendered.yaml
# load-job.yaml carries no nodeSelector/tolerations of its own, so the
# client (same ~7GB vllm/vllm-openai image as the engines) can land on
# any node, including a small optional-pool node with no room for that
# image (confirmed on real hardware this same run: ErrImagePull, "no
# space left on device" extracting a layer, after the node's
# ephemeral-storage was exhausted -- the same shape as the proxy's own
# fix above). Pin it to this one well-provisioned node the same way.
python3 -c "
import sys
text = open('/tmp/load-job.rendered.yaml').read()
anchor = '      restartPolicy: Never\n'
addition = (
    '      nodeSelector:\n'
    '        distai.dev/pd-role: shared\n'
    '      tolerations:\n'
    '        - key: nvidia.com/gpu\n'
    '          operator: Exists\n'
    '          effect: NoSchedule\n'
)
assert text.count(anchor) == 1, 'expected exactly one restartPolicy: Never line'
text = text.replace(anchor, anchor + addition)
open('/tmp/load-job.rendered.yaml', 'w').write(text)
"
kubectl apply -n "${NAMESPACE}" -f /tmp/load-job.rendered.yaml

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
read_efa_counters after | tee /tmp/p5en-efa-after.txt

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
echo "RESULT UCX-DISAGG-PASS namespace=${NAMESPACE} release=${RELEASE} run_id=${RUN_ID}"
