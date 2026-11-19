#!/usr/bin/env bash
# Destroy-time network guard of infra/foundation (called from teardown.tf,
# terraform_data.network_guard).
#
# Runs after the EKS cluster and the system node group have been destroyed and
# before the subnets and the VPC are. Deletes what the VPC CNI and EKS created
# in the cell's VPC outside Terraform and left behind: detached VPC CNI network
# interfaces (description aws-K8S-*), and then the cluster security group that
# EKS created for this cluster (tag aws:eks:cluster-name = <name>). It
# terminates no instance.
#
# Required environment: CLUSTER_NAME, ACCOUNT_ID, AWS_REGION, VPC_ID.
# Requires the AWS CLI v2 and the credentials that run terraform destroy.
set -euo pipefail

: "${CLUSTER_NAME:?}" "${ACCOUNT_ID:?}" "${AWS_REGION:?}" "${VPC_ID:?}"

LOG_PREFIX="network-guard"
# shellcheck source=SCRIPTDIR/guard-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard-common.sh"

# Interfaces of terminated nodes and the control plane interfaces EKS removes
# can take a few minutes to reach their final state; poll for up to 10 minutes.
POLL_SECONDS=15
MAX_POLLS=40

require_cell_account

# 0. The cluster must be gone. Terraform destroys it before this guard; if it
#    still exists (for example it was created outside this state), its
#    security group and interfaces are in use and are not this guard's to
#    remove.
if out="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.status' --output text 2>&1)"; then
  log "cluster ${CLUSTER_NAME} still exists (status ${out}); refusing to remove its network resources" >&2
  exit 1
fi
case "$out" in
  *ResourceNotFoundException*) ;;
  *) echo "$out" >&2; exit 1 ;;
esac

# 1. VPC CNI network interfaces. Delete the detached ones, and wait for any
#    that is still attached or changing state: with the cluster and its nodes
#    gone, nothing in the VPC creates or attaches new ones, so the count only
#    goes down.
polls=0
while :; do
  delete_detached_cni_interfaces
  remaining="$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=description,Values=aws-K8S-*" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]' --output text | xargs)"
  if [ -z "$remaining" ]; then
    log "no VPC CNI network interfaces left in ${VPC_ID}"
    break
  fi
  polls=$((polls + 1))
  if [ "$polls" -gt "$MAX_POLLS" ]; then
    log "VPC CNI network interfaces still present (id status): ${remaining}" >&2
    exit 1
  fi
  log "waiting for VPC CNI network interfaces (id status): ${remaining}"
  sleep "$POLL_SECONDS"
done

# 2. The cluster security group. EKS deletes it with the cluster when nothing
#    uses it; it stays when an interface still referenced it at that time.
#    DependencyViolation means an interface (for example a control plane
#    interface EKS is still removing) still uses it: wait and retry.
sgs="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:aws:eks:cluster-name,Values=${CLUSTER_NAME}" \
  --query 'SecurityGroups[].GroupId' --output text)"
for sg in $sgs; do
  polls=0
  while :; do
    log "deleting cluster security group ${sg}"
    if out="$(aws ec2 delete-security-group --group-id "$sg" 2>&1)"; then
      break
    fi
    case "$out" in
      *NotFound*) log "already gone: ${sg}"; break ;;
      *DependencyViolation*) ;;
      *) echo "$out" >&2; exit 1 ;;
    esac
    polls=$((polls + 1))
    if [ "$polls" -gt "$MAX_POLLS" ]; then
      users="$(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=${sg}" \
        --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]' --output text | xargs)"
      log "security group ${sg} is still in use by: ${users}" >&2
      exit 1
    fi
    log "security group ${sg} is still in use; retrying"
    sleep "$POLL_SECONDS"
  done
done

log "done"
