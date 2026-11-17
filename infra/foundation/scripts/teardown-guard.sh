#!/usr/bin/env bash
# Destroy-time guard of infra/foundation (called from teardown.tf).
#
# Terminates every EC2 instance that Karpenter launched for one cluster, waits
# until they are terminated, then deletes what they leave behind: detached VPC
# CNI network interfaces in the cell's VPC, Karpenter launch templates and the
# instance profiles that hold the Karpenter node role.
#
# Required environment: CLUSTER_NAME, AWS_REGION, VPC_ID, NODE_ROLE_NAME.
# Requires the AWS CLI v2 and the credentials that run terraform destroy.
set -euo pipefail

: "${CLUSTER_NAME:?}" "${AWS_REGION:?}" "${VPC_ID:?}" "${NODE_ROLE_NAME:?}"
export AWS_REGION AWS_PAGER=""

MAX_ROUNDS=5

log() { echo "[teardown-guard] $*"; }

list_instances() {
  aws ec2 describe-instances \
    --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" \
    "Name=tag-key,Values=karpenter.sh/nodepool" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text | xargs
}

# 1. Instances. Repeat until none is left, in case one was launched while the
#    previous round was waiting.
round=0
while :; do
  ids="$(list_instances)"
  if [ -z "$ids" ]; then
    log "no Karpenter instances left for cluster ${CLUSTER_NAME}"
    break
  fi
  round=$((round + 1))
  if [ "$round" -gt "$MAX_ROUNDS" ]; then
    log "instances still present after ${MAX_ROUNDS} rounds: ${ids}" >&2
    exit 1
  fi
  log "round ${round}: terminating ${ids}"
  # shellcheck disable=SC2086 # instance IDs contain no whitespace
  aws ec2 terminate-instances --instance-ids ${ids} >/dev/null
  # shellcheck disable=SC2086
  if ! aws ec2 wait instance-terminated --instance-ids ${ids}; then
    log "waiter timed out; checking again"
  fi
done

# 2. Network interfaces that the VPC CNI attached and that were not deleted
#    with their instance. Any detached interface the VPC CNI created in this
#    cell's VPC belongs to this cluster.
enis="$(aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
  "Name=description,Values=aws-K8S-*" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
for eni in $enis; do
  log "deleting detached network interface ${eni}"
  aws ec2 delete-network-interface --network-interface-id "$eni"
done

# 3. Launch templates Karpenter created for this cluster.
lts="$(aws ec2 describe-launch-templates \
  --filters "Name=tag:karpenter.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
  --query 'LaunchTemplates[].LaunchTemplateId' --output text)"
for lt in $lts; do
  log "deleting launch template ${lt}"
  aws ec2 delete-launch-template --launch-template-id "$lt" >/dev/null
done

# 4. Instance profiles Karpenter created around the node role. Terraform
#    creates none for this role, so every profile that holds it is Karpenter's.
profiles="$(aws iam list-instance-profiles-for-role \
  --role-name "$NODE_ROLE_NAME" \
  --query 'InstanceProfiles[].InstanceProfileName' --output text)"
for p in $profiles; do
  log "deleting instance profile ${p}"
  aws iam remove-role-from-instance-profile --instance-profile-name "$p" --role-name "$NODE_ROLE_NAME"
  aws iam delete-instance-profile --instance-profile-name "$p"
done

log "done"
