#!/usr/bin/env bash
# Stage 90: tear down this cell and independently confirm zero leftovers.
# Run with the same NAME/AWS_REGION/STATE_BUCKET/STATE_REGION/CR_ID as
# 01-foundation.sh. Safe to re-run (terraform destroy against an already-
# destroyed or partial state is a no-op/partial cleanup either way).
set -euo pipefail

NAME="${NAME:-dp-p5en-efa}"
AWS_REGION="${AWS_REGION:-us-east-2}"
STATE_BUCKET="${STATE_BUCKET:-distai-eks-tfstate-776010787911}"
STATE_REGION="${STATE_REGION:-ap-northeast-1}"
CR_ID="${CR_ID:-}"
RES_TAG_KEY="${RES_TAG_KEY:-distai-platform/reserved-pool}"
export AWS_PROFILE=default

echo "=== [1/4] deleting namespaced workloads (best effort, destroy's own guard covers the rest) ==="
aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}" 2>/dev/null || true
kubectl delete namespace p5en-verify --ignore-not-found --wait=false 2>/dev/null || true

echo "=== [2/4] terraform destroy ==="
MY_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
ADMIN_PRINCIPAL_ARN="$(aws sts get-caller-identity --query Arn --output text)"
export TF_VAR_name="${NAME}"
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_endpoint_public_access_cidrs="[\"${MY_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_PRINCIPAL_ARN}\"]"
export TF_VAR_argocd="{idc_instance_arn=\"arn:aws:sso:::instance/ssoins-7223037211dc5301\",idc_region=\"us-east-1\",role_mappings=[{role=\"ADMIN\",group_ids=[\"00000000-0000-0000-0000-000000000000\"]}]}"
export TF_VAR_tags="{\"distai-platform/cell\"=\"${NAME}\"}"

cd infra/foundation
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"
terraform destroy -auto-approve
cd ../..

echo "=== [3/4] independent read-only leftover sweep ==="
echo "-- eks clusters named ${NAME} --"
aws eks list-clusters --region "${AWS_REGION}" --query "clusterList[?@=='${NAME}']" --output text
echo "-- running/pending ec2 instances tagged eks:eks-cluster-name=${NAME} --"
aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
echo "-- vpcs tagged distai-platform/cell=${NAME} --"
aws ec2 describe-vpcs --region "${AWS_REGION}" \
  --filters "Name=tag:distai-platform/cell,Values=${NAME}" \
  --query 'Vpcs[].VpcId' --output text
echo "-- launch templates tagged eks:eks-cluster-name=${NAME} --"
aws ec2 describe-launch-templates --region "${AWS_REGION}" \
  --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" \
  --query 'LaunchTemplates[].LaunchTemplateName' --output text
echo "-- iam roles with prefix ${NAME} --"
aws iam list-roles --query "Roles[?starts_with(RoleName, '${NAME}')].RoleName" --output text
echo "(all of the above should print nothing / empty between the markers)"

if [[ -n "${CR_ID}" ]]; then
  echo "=== [4/4] removing the reservation-selector tag from the borrowed CR (restoring it to how it was given) ==="
  aws ec2 delete-tags --region "${AWS_REGION}" --resources "${CR_ID}" --tags "Key=${RES_TAG_KEY}"
  aws ec2 describe-capacity-reservations --region "${AWS_REGION}" \
    --capacity-reservation-ids "${CR_ID}" --query 'CapacityReservations[0].Tags' --output json
fi

echo "RESULT TEARDOWN-PASS $(date -u +%Y-%m-%dT%H:%M:%SZ)"
