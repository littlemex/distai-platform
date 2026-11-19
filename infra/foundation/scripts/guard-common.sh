# shellcheck shell=bash
# Shared by the destroy-time guards of infra/foundation (teardown-guard.sh,
# network-guard.sh). Sourced, not executed. The caller sets LOG_PREFIX,
# ACCOUNT_ID and AWS_REGION before sourcing this file, and VPC_ID before
# calling delete_detached_cni_interfaces.

export AWS_REGION AWS_PAGER=""

log() { echo "[${LOG_PREFIX}] $*"; }

# The AWS CLI must act on the account Terraform manages. If the CLI resolves
# other credentials (for example when the provider assumes a role), every
# lookup would come back empty and the guard would pass without removing
# anything.
require_cell_account() {
  local caller_account
  caller_account="$(aws sts get-caller-identity --query Account --output text)"
  if [ "$caller_account" != "$ACCOUNT_ID" ]; then
    log "the AWS CLI uses account ${caller_account}, but the cell is in account ${ACCOUNT_ID}; set AWS_PROFILE or credentials for the cell's account" >&2
    exit 1
  fi
}

# Delete calls tolerate resources that disappeared since they were listed
# (the VPC CNI, Karpenter or EKS may remove them at the same time).
tolerate_not_found() {
  local out
  if ! out="$("$@" 2>&1)"; then
    case "$out" in
      *NotFound* | *NoSuchEntity*) log "already gone: $*" ;;
      *) echo "$out" >&2; return 1 ;;
    esac
  fi
}

# Deletes the network interfaces that the VPC CNI created in VPC_ID and that
# are detached (status "available"). Any such interface in this cell's VPC
# belongs to this cell's cluster: the VPC holds one cluster only. Interfaces
# that are still attached are left alone (network-guard.sh lists those
# itself, while waiting for them to settle; teardown-guard.sh does not,
# since it runs while the cluster is still up and attached interfaces there
# are still in normal use).
delete_detached_cni_interfaces() {
  local enis eni
  enis="$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
    "Name=description,Values=aws-K8S-*" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
  for eni in $enis; do
    log "deleting detached network interface ${eni}"
    tolerate_not_found aws ec2 delete-network-interface --network-interface-id "$eni"
  done
}
