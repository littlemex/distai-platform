#!/usr/bin/env bash
# Destroy-time guard of infra/foundation (called from teardown.tf,
# terraform_data.teardown_guard).
#
# Terminates every EC2 instance that Karpenter launched for one cluster, waits
# until they are terminated, then deletes what they leave behind: detached VPC
# CNI network interfaces in the cell's VPC, Karpenter launch templates and the
# instance profiles that hold the Karpenter node role. network-guard.sh runs
# later in the same destroy, after the cluster is gone, and removes what is
# left in the VPC after that (see teardown.tf).
#
# Required environment: CLUSTER_NAME, ACCOUNT_ID, AWS_REGION, VPC_ID, NODE_ROLE_NAME.
# Requires the AWS CLI v2 and the credentials that run terraform destroy.
set -euo pipefail

: "${CLUSTER_NAME:?}" "${ACCOUNT_ID:?}" "${AWS_REGION:?}" "${VPC_ID:?}" "${NODE_ROLE_NAME:?}"

LOG_PREFIX="teardown-guard"
# shellcheck source=SCRIPTDIR/guard-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard-common.sh"

MAX_ROUNDS=5

require_cell_account

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
#    previous round was waiting. "None left" must be seen twice, 15 seconds
#    apart, because a launch that started just before the controller lost its
#    permissions can take a moment to appear.
round=0
while :; do
  ids="$(list_instances)"
  if [ -z "$ids" ]; then
    sleep 15
    ids="$(list_instances)"
  fi
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

# 2. Network interfaces that the VPC CNI attached to those instances and that
#    were not deleted with them. Removing them now lets EKS delete its cluster
#    security group itself when the cluster is destroyed.
delete_detached_cni_interfaces

# 3. Launch templates Karpenter created for this cluster. Karpenter v1 tags
#    them with eks:eks-cluster-name (v1.EKSClusterNameTagKey, which its own
#    launch template provider filters on) and karpenter.k8s.aws/ec2nodeclass;
#    requiring both leaves templates of other tools alone.
lts="$(aws ec2 describe-launch-templates \
  --filters "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" \
  "Name=tag-key,Values=karpenter.k8s.aws/ec2nodeclass" \
  --query 'LaunchTemplates[].LaunchTemplateId' --output text)"
for lt in $lts; do
  log "deleting launch template ${lt}"
  tolerate_not_found aws ec2 delete-launch-template --launch-template-id "$lt"
done

# 4. Instance profiles Karpenter created around the node role. Only profiles
#    with the tag Karpenter puts on its own (kubernetes.io/cluster/<name> =
#    owned, the same tag its IAM policy requires) are removed; any other
#    profile that holds the role is left alone and reported.
profiles="$(aws iam list-instance-profiles-for-role \
  --role-name "$NODE_ROLE_NAME" \
  --query 'InstanceProfiles[].InstanceProfileName' --output text)"
for p in $profiles; do
  owner="$(aws iam list-instance-profile-tags --instance-profile-name "$p" \
    --query "Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}'].Value" --output text)"
  if [ "$owner" != "owned" ]; then
    log "keeping instance profile ${p}: not tagged as owned by cluster ${CLUSTER_NAME}" >&2
    continue
  fi
  log "deleting instance profile ${p}"
  tolerate_not_found aws iam remove-role-from-instance-profile --instance-profile-name "$p" --role-name "$NODE_ROLE_NAME"
  tolerate_not_found aws iam delete-instance-profile --instance-profile-name "$p"
done

log "done"
