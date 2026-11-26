#!/usr/bin/env bash
# Stage 2: bootstrap the Argo CD capability on the cell 01-foundation.sh
# just created, pointed at this same branch (so the cell's own
# gitops/cells/dp-p5en-efa/capacity-pool/gpu-rsv.yaml is read without
# touching main), then wait for every core add-on and this cell's own
# gpu-rsv capacity-pool Application to reach Synced/Healthy.
set -euo pipefail

NAME="${NAME:-dp-p5en-efa}"
AWS_REGION="${AWS_REGION:-us-east-2}"
STATE_BUCKET="${STATE_BUCKET:-distai-eks-tfstate-776010787911}"
STATE_REGION="${STATE_REGION:-ap-northeast-1}"
REVISION="${REVISION:?export REVISION (this branch name)}"
export AWS_PROFILE=default

aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
kubectl get nodes

# Each runner invocation is a fresh clone with no local Terraform state:
# re-init against the same S3 backend 01-foundation.sh used, so
# `terraform output` reads the real state instead of an empty one.
cd infra/foundation
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"
../../gitops/bootstrap/bootstrap.sh --tf-outputs <(terraform output -json) --revision "${REVISION}"
cd ../..

echo "=== waiting for argocd apps to settle (up to 15 min) ==="
ARGOCD_NS="$(kubectl get secret -A -l argocd.argoproj.io/secret-type=cluster -o jsonpath='{.items[0].metadata.namespace}')"
echo "argocd namespace: ${ARGOCD_NS}"

deadline=$(( $(date +%s) + 900 ))
while [[ $(date +%s) -lt ${deadline} ]]; do
  kubectl -n "${ARGOCD_NS}" get applications.argoproj.io -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>&1 || true
  not_ready=$(kubectl -n "${ARGOCD_NS}" get applications.argoproj.io -o json 2>/dev/null \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
n=0
for it in d.get("items",[]):
    s=it.get("status",{})
    sync=s.get("sync",{}).get("status")
    health=s.get("health",{}).get("status")
    if sync!="Synced" or health not in ("Healthy","Progressing"):
        n+=1
print(n)
' || echo 999)
  if [[ "${not_ready}" == "0" ]]; then
    echo "all applications Synced/Healthy-or-Progressing"
    break
  fi
  sleep 20
done

echo "=== final application status ==="
kubectl -n "${ARGOCD_NS}" get applications.argoproj.io -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

echo "=== NodePool / EC2NodeClass for gpu-rsv ==="
kubectl get nodepool gpu-rsv -o yaml || true
kubectl get ec2nodeclass gpu-rsv -o yaml || true
echo "RESULT GITOPS-PASS"
