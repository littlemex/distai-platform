#!/usr/bin/env bash
set -euo pipefail
export AWS_PROFILE=default
AWS_REGION=ap-northeast-1
NAME=dp-p4defa-v1
STATE_BUCKET=distai-eks-tfstate-776010787911
STATE_REGION=ap-northeast-1
STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"

cd infra/foundation
terraform init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"
CLUSTER_NAME=$(terraform output -raw cluster_name)
NODE_ROLE=$(terraform output -raw karpenter_node_role_name)
INTQ=$(terraform output -raw karpenter_interruption_queue_name)
echo "CLUSTER_NAME=${CLUSTER_NAME} NODE_ROLE=${NODE_ROLE} INTQ=${INTQ}"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null
kubectl get nodes -o wide
cd ../..

V=_verify/p4d-efa
sed -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" -e "s/__NODE_ROLE__/${NODE_ROLE}/g" "$V/capacity-pool-p4d.values.yaml" > /tmp/capacity-pool-p4d.values.yaml
sed -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" -e "s/__REGION__/${AWS_REGION}/g" -e "s/__INTERRUPTION_QUEUE__/${INTQ}/g" "$V/karpenter.values.yaml" > /tmp/karpenter.values.yaml
sed -e "s/__REGION__/${AWS_REGION}/g" "$V/efa-device-plugin.yaml" > /tmp/efa-device-plugin.yaml

echo "=== karpenter-crd ==="
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version 1.15.2 -n kube-system --wait --timeout 3m
echo "=== karpenter ==="
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.2 -n kube-system \
  --skip-crds -f /tmp/karpenter.values.yaml --wait --timeout 5m

echo "=== accel-nvidia-device-plugin ==="
helm upgrade --install accel-nvidia-device-plugin nvidia-device-plugin --repo https://nvidia.github.io/k8s-device-plugin \
  --version 0.20.2 -n nvidia-device-plugin --create-namespace \
  -f "$V/accel-nvidia-device-plugin.values.yaml" --wait --timeout 3m

echo "=== efa device plugin (raw manifest) ==="
kubectl apply -f /tmp/efa-device-plugin.yaml

echo "=== capacity-pool p4d NodePool/EC2NodeClass ==="
helm upgrade --install capacity-pool-p4d "$V/../../gitops/charts/capacity-pool" -n kube-system \
  -f /tmp/capacity-pool-p4d.values.yaml

echo "=== dcgm-exporter ==="
helm dependency build "$V/../../gitops/charts/dcgm-exporter"
helm upgrade --install dcgm-exporter "$V/../../gitops/charts/dcgm-exporter" -n dcgm-exporter --create-namespace

echo "=== ssh keypair + test workload ==="
ssh-keygen -t rsa -b 2048 -N '' -f /tmp/ncclkey -q
PRIV_B64=$(base64 -w0 /tmp/ncclkey 2>/dev/null || base64 /tmp/ncclkey | tr -d '\n')
PUB_B64=$(base64 -w0 /tmp/ncclkey.pub 2>/dev/null || base64 /tmp/ncclkey.pub | tr -d '\n')
python3 - "$V/nccl-test-pods.yaml" /tmp/ncclkey /tmp/ncclkey.pub /tmp/nccl-test-pods.rendered.yaml <<'PY'
import sys
tmpl_path, priv_path, pub_path, out_path = sys.argv[1:]
with open(tmpl_path) as f:
    content = f.read()
with open(priv_path) as f:
    priv = f.read()
with open(pub_path) as f:
    pub = f.read()
import json
content = content.replace('"__ID_RSA__"', json.dumps(priv))
content = content.replace('"__ID_RSA_PUB__"', json.dumps(pub))
with open(out_path, "w") as f:
    f.write(content)
PY
kubectl apply -f /tmp/nccl-test-pods.rendered.yaml

echo "=== DONE: stack applied, watch NodeClaims ==="
kubectl get nodeclaims -o wide
