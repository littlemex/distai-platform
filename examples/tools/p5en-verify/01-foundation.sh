#!/usr/bin/env bash
# One-off real-hardware verification run, not part of the platform (see
# ../../../AGENTS.md section 3). Tags the owner's own Capacity Reservation
# by the tag gitops/charts/capacity-pool's "reserved" capacityType selects
# on (never by ID, #17), then applies infra/foundation for a new cell in
# us-east-2 bound to it. Run on the EC2 runner only.
set -euo pipefail

: "${CR_ID:?export CR_ID}"
NAME="${NAME:-dp-p5en-efa}"
AWS_REGION="${AWS_REGION:-us-east-2}"
STATE_BUCKET="${STATE_BUCKET:-distai-eks-tfstate-776010787911}"
STATE_REGION="${STATE_REGION:-ap-northeast-1}"
RES_TAG_KEY="${RES_TAG_KEY:-distai-platform/reserved-pool}"
RES_TAG_VAL="${RES_TAG_VAL:-dp-p5en-efa-rsv}"
export AWS_PROFILE=default

echo "=== [1/4] tagging capacity reservation ${CR_ID} in ${AWS_REGION} ==="
aws ec2 describe-capacity-reservations --region "${AWS_REGION}" \
  --capacity-reservation-ids "${CR_ID}" \
  --query 'CapacityReservations[0].[State,AvailableInstanceCount,InstanceType,EndDate]' --output text
aws ec2 create-tags --region "${AWS_REGION}" --resources "${CR_ID}" \
  --tags "Key=${RES_TAG_KEY},Value=${RES_TAG_VAL}"
aws ec2 describe-capacity-reservations --region "${AWS_REGION}" \
  --capacity-reservation-ids "${CR_ID}" \
  --query 'CapacityReservations[0].Tags' --output json

echo "=== [2/4] terraform init (state key distai-platform/${AWS_REGION}/${NAME}/foundation) ==="
MY_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
ADMIN_ROLE_NAME="$(aws sts get-caller-identity --query Arn --output text | cut -d/ -f2)"
ADMIN_PRINCIPAL_ARN="$(aws iam get-role --role-name "${ADMIN_ROLE_NAME}" --query Role.Arn --output text)"
echo "MY_CIDR=${MY_CIDR} ADMIN_PRINCIPAL_ARN=${ADMIN_PRINCIPAL_ARN}"

export TF_VAR_name="${NAME}"
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_endpoint_public_access_cidrs="[\"${MY_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_PRINCIPAL_ARN}\"]"
export TF_VAR_argocd="{idc_instance_arn=\"arn:aws:sso:::instance/ssoins-7223037211dc5301\",idc_region=\"us-east-1\",role_mappings=[{role=\"ADMIN\",group_ids=[\"f46844c8-1001-7075-33e6-4829e64a7500\"]}]}"
export TF_VAR_tags="{\"distai-platform/cell\"=\"${NAME}\"}"

cd infra/foundation
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"

echo "=== [3/4] terraform apply ==="
terraform apply -auto-approve

echo "=== [4/4] cluster check ==="
aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
kubectl get nodes -o wide
for addon in vpc-cni kube-proxy eks-pod-identity-agent coredns; do
  aws eks describe-addon --cluster-name "${NAME}" --region "${AWS_REGION}" \
    --addon-name "${addon}" --query 'addon.[addonName,status]' --output text
done
echo "RESULT FOUNDATION-PASS name=${NAME} region=${AWS_REGION}"
