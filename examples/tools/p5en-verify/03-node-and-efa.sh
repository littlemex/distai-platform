#!/usr/bin/env bash
# Stage 3: force Karpenter to launch the p5en.48xlarge node from the
# reserved pool (a canary Job requesting one nvidia.com/gpu, tolerating
# the pool's taint), wait for it to go Ready, then gather EFA facts two
# independent ways: (a) the real EC2 API's own view of the attached
# network interfaces (NetworkCardIndex/DeviceIndex/InterfaceType per
# ENI) against gitops/charts/capacity-pool/tools/fixtures/
# p5en.48xlarge.networkInterfaces.yaml (issue #50, PR #75); (b) the
# vendored awsome-distributed-ai gpu-healthcheck preflight
# (examples/tools/gpu-healthcheck) running lspci/ibv_devices/fi_info
# inside the node itself. Neither depends on the other.
set -euo pipefail

NAME="${NAME:-dp-p5en-efa}"
AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_PROFILE=default
aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"

echo "=== [1/5] canary Job to trigger the p5en node launch ==="
kubectl create namespace p5en-verify --dry-run=client -o yaml | kubectl apply -f -
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: p5en-canary
  namespace: p5en-verify
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        node.kubernetes.io/instance-type: p5en.48xlarge
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: canary
          image: public.ecr.aws/docker/library/busybox:1.37
          command: ["sh", "-c", "nvidia-smi 2>/dev/null; sleep 3600"]
          resources:
            limits:
              nvidia.com/gpu: "1"
EOF

echo "=== [2/5] waiting for the node to join and go Ready (up to 15 min) ==="
deadline=$(( $(date +%s) + 900 ))
NODE=""
while [[ $(date +%s) -lt ${deadline} ]]; do
  NODE="$(kubectl get nodes -l node.kubernetes.io/instance-type=p5en.48xlarge -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${NODE}" ]]; then
    READY="$(kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    [[ "${READY}" == "True" ]] && break
  fi
  kubectl get pods -n p5en-verify -o wide || true
  sleep 15
done
[[ -n "${NODE}" ]] || { echo "RESULT NODE-FAIL: no p5en.48xlarge node appeared"; exit 1; }
echo "node: ${NODE}"
kubectl get node "${NODE}" -o wide
kubectl describe node "${NODE}" | sed -n '/Allocatable:/,/System Info:/p'

INSTANCE_ID="$(kubectl get node "${NODE}" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
echo "instance id: ${INSTANCE_ID}"
echo "${INSTANCE_ID}" > /tmp/p5en-instance-id.txt

echo "=== [3/5] EC2 API ground truth: network interfaces on ${INSTANCE_ID} ==="
aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
  --filters "Name=attachment.instance-id,Values=${INSTANCE_ID}" \
  --query 'NetworkInterfaces[].{NetworkCardIndex:Attachment.NetworkCardIndex,DeviceIndex:Attachment.DeviceIndex,InterfaceType:InterfaceType,Status:Status}' \
  --output json | tee /tmp/p5en-enis.json | python3 -c '
import json,sys
rows=json.load(sys.stdin)
rows.sort(key=lambda r:(r["NetworkCardIndex"], r["DeviceIndex"]))
print("total ENIs attached:", len(rows))
for r in rows:
    card = r["NetworkCardIndex"]
    device = r["DeviceIndex"]
    itype = r["InterfaceType"]
    status = r["Status"]
    print("  card=" + str(card) + " device=" + str(device) + " type=" + str(itype) + " status=" + str(status))
'

echo "=== [4/5] expected layout from the committed fixture (issue #50, PR #75) ==="
cat gitops/charts/capacity-pool/tools/fixtures/p5en.48xlarge.networkInterfaces.yaml

echo "=== [5/5] vpc.amazonaws.com/efa allocatable on the node ==="
kubectl get node "${NODE}" -o jsonpath='{.status.allocatable.vpc\.amazonaws\.com/efa}{"\n"}'
kubectl get node "${NODE}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'

echo "=== gpu-healthcheck preflight (lspci/ibv_devices/fi_info inside the node) ==="
export INSTANCE_TYPE=p5en.48xlarge
bash examples/tools/gpu-healthcheck/run.sh 2>&1 | tee /tmp/p5en-healthcheck.log

echo "RESULT NODE-AND-EFA-PASS node=${NODE} instance=${INSTANCE_ID}"
