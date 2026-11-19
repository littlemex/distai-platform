# shellcheck shell=bash
# Helpers shared by the end-to-end tests of the foundation layer
# (1.e2e.sh, 2.e2e-partial-apply.sh). Sourced, not executed.
#
# This file is the one place that defines what "nothing is left of the cell"
# means: which AWS resources are listed, by which tags and in which VPC.
#
# The functions read these globals of the calling script at call time:
#   TERRAFORM, ROOT        terraform binary and the infra/foundation directory
#   NAME                   cell and cluster name
#   TEST_TAG_KEY, RUN_ID   the run tag the test passes through var.tags
#   VPC_ID                 the cell's VPC, empty while unknown
#   FAILED_STEP            set by fail()

# ---------------------------------------------------------------- logging

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
pass() { log "PASS $*"; }
fail() {
  # Read by the calling script's EXIT trap.
  # shellcheck disable=SC2034
  FAILED_STEP="$*"
  log "FAIL $*"
  exit 1
}
info() { log "INFO $*"; }

# wait_until TIMEOUT_SECONDS INTERVAL_SECONDS DESCRIPTION COMMAND...
# Runs COMMAND until it succeeds or the timeout expires.
wait_until() {
  local timeout="$1" interval="$2" desc="$3"
  shift 3
  local start now
  start="$(date +%s)"
  while true; do
    if "$@"; then
      return 0
    fi
    now="$(date +%s)"
    if ((now - start >= timeout)); then
      log "timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep "${interval}"
  done
}

tf() { "${TERRAFORM}" -chdir="${ROOT}" "$@"; }
tf_out() { tf output -raw "$1"; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "prerequisite: $1 not found"
}

# aws_text CMD ARGS...: runs an AWS CLI read call and prints its stdout.
# A "*.NotFound*"-shaped error (for example InvalidVpcID.NotFound or
# InvalidInstanceID.NotFound, returned when the call names an ID that no
# longer exists) means "the thing is gone": prints nothing and returns 0, the
# same as a successful call that matched nothing. Any other non-zero exit
# (expired credentials, throttling, a typo in the call) is a hard failure:
# prints the command and the AWS CLI's error text and returns 1, so a caller
# capturing this with `out="$(aws_text ...)"; rc=$?` gets the error text in
# `out` and a non-zero `rc`, and must fail() rather than treat it as "found
# nothing".
aws_text() {
  local out err errfile ok=1
  errfile="$(mktemp)"
  if ! out="$("$@" 2>"${errfile}")"; then
    ok=0
  fi
  err="$(cat "${errfile}")"
  rm -f "${errfile}"
  if [[ "${ok}" -eq 1 ]]; then
    printf '%s' "${out}"
    return 0
  fi
  if [[ "${err}" == *".NotFound"* || "${err}" == *"NotFoundException"* ]]; then
    return 0
  fi
  printf '%s: %s' "$*" "${err}"
  return 1
}

# ---------------------------------------------------- leftover detection

# Tag filters that identify resources belonging to this cell: the tag the
# test passes through var.tags and the EC2NodeClass, the Karpenter discovery
# tag, and the tags that EKS, managed node groups, Karpenter and the VPC CNI
# put on what they create.
tag_filters() {
  printf '%s\n' \
    "Name=tag:${TEST_TAG_KEY},Values=${RUN_ID}" \
    "Name=tag:karpenter.sh/discovery,Values=${NAME}" \
    "Name=tag-key,Values=kubernetes.io/cluster/${NAME}" \
    "Name=tag:eks:cluster-name,Values=${NAME}" \
    "Name=tag:eks:eks-cluster-name,Values=${NAME}" \
    "Name=tag:cluster.k8s.amazonaws.com/name,Values=${NAME}"
}

# Prints the IDs of one resource kind that still exist for the cell.
# Each underlying AWS call goes through aws_text (see above), so a hard
# failure of any single call (not a "not found") stops this function
# immediately: it prints the error text instead of an ID list and returns 1.
#
# Kinds: instance, eni, nat, volume, launch-template (searched by
# tag_filters and, where the API supports it, by the cell's VPC), and
# cni-eni, security-group (see list_leftover_network below).
list_leftover() {
  local kind="$1" filter out all=""
  case "${kind}" in
    cni-eni | security-group)
      list_leftover_network "${kind}"
      return
      ;;
  esac
  while IFS= read -r filter; do
    if ! case "${kind}" in
      instance)
        out="$(aws_text aws ec2 describe-instances --filters "${filter}" \
          "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text)" ;;
      eni)
        out="$(aws_text aws ec2 describe-network-interfaces --filters "${filter}" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ;;
      nat)
        out="$(aws_text aws ec2 describe-nat-gateways --filter "${filter}" \
          "Name=state,Values=pending,available,deleting" \
          --query 'NatGateways[].NatGatewayId' --output text)" ;;
      volume)
        out="$(aws_text aws ec2 describe-volumes --filters "${filter}" \
          --query 'Volumes[].VolumeId' --output text)" ;;
      launch-template)
        out="$(aws_text aws ec2 describe-launch-templates --filters "${filter}" \
          --query 'LaunchTemplates[].LaunchTemplateId' --output text)" ;;
    esac; then
      printf '%s' "${out}"
      return 1
    fi
    all+="${out}"$'\n'
  done < <(tag_filters)
  if [[ -n "${VPC_ID}" ]]; then
    if ! case "${kind}" in
      instance)
        out="$(aws_text aws ec2 describe-instances --filters "Name=vpc-id,Values=${VPC_ID}" \
          "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text)" ;;
      eni)
        out="$(aws_text aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ;;
      nat)
        out="$(aws_text aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" \
          "Name=state,Values=pending,available,deleting" \
          --query 'NatGateways[].NatGatewayId' --output text)" ;;
      volume | launch-template) out="" ;;
    esac; then
      printf '%s' "${out}"
      return 1
    fi
    all+="${out}"$'\n'
  fi
  printf '%s' "${all}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' | sort -u || true
}

# The two kinds that a terraform destroy of a partial apply left behind
# (issue #26), each looked up the way the issue names it:
#   cni-eni         detached VPC CNI network interfaces in the cell's VPC
#                   (description aws-K8S-*, status available). Needs VPC_ID;
#                   without it the check could only pass vacuously, so it is
#                   a hard failure instead.
#   security-group  security groups that EKS created for the cluster (tag
#                   aws:eks:cluster-name = NAME), anything else tagged for
#                   the cell, and every non-default security group still in
#                   the cell's VPC.
list_leftover_network() {
  local kind="$1" filter out all=""
  case "${kind}" in
    cni-eni)
      if [[ -z "${VPC_ID}" ]]; then
        printf 'cni-eni: VPC_ID is not known, cannot look for detached VPC CNI interfaces'
        return 1
      fi
      out="$(aws_text aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
        "Name=description,Values=aws-K8S-*" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" \
        || { printf '%s' "${out}"; return 1; }
      all+="${out}"$'\n'
      ;;
    security-group)
      while IFS= read -r filter; do
        out="$(aws_text aws ec2 describe-security-groups --filters "${filter}" \
          --query 'SecurityGroups[].GroupId' --output text)" \
          || { printf '%s' "${out}"; return 1; }
        all+="${out}"$'\n'
      done < <(printf '%s\n' "Name=tag:aws:eks:cluster-name,Values=${NAME}"; tag_filters)
      if [[ -n "${VPC_ID}" ]]; then
        out="$(aws_text aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" \
          --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)" \
          || { printf '%s' "${out}"; return 1; }
        all+="${out}"$'\n'
      fi
      ;;
    *)
      printf 'list_leftover_network: unknown kind %s' "${kind}"
      return 1
      ;;
  esac
  printf '%s' "${all}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' | sort -u || true
}

# no_leftover KIND: true if nothing of KIND remains. A hard AWS failure
# inside list_leftover is not "nothing remains": it calls fail() with the
# error text and stops the whole script, the same as any other check here.
no_leftover() {
  local out
  if ! out="$(list_leftover "$1")"; then
    fail "checking for leftover $1: ${out}"
  fi
  [[ -z "${out}" ]]
}

# report_leftovers GRACE_SECONDS [KIND...]: PASS/FAIL per kind, returns 1 if
# any remains. Without KIND arguments it checks instance, eni, nat, volume
# and launch-template.
report_leftovers() {
  local grace="$1" kind ids bad=0
  shift
  local kinds=("$@")
  if [[ "${#kinds[@]}" -eq 0 ]]; then
    kinds=(instance eni nat volume launch-template)
  fi
  for kind in "${kinds[@]}"; do
    if wait_until "${grace}" 20 "no ${kind} left" no_leftover "${kind}"; then
      pass "no ${kind} tagged for the cluster remains"
    else
      if ! ids="$(list_leftover "${kind}")"; then
        fail "checking for leftover ${kind}: ${ids}"
      fi
      log "FAIL ${kind} left after destroy: $(tr '\n' ' ' <<<"${ids}")"
      bad=1
    fi
  done
  return "${bad}"
}

# assert_vpc_gone: fails unless the cell's VPC (VPC_ID) no longer exists.
# describe-vpcs on a gone VPC returns InvalidVpcID.NotFound (empty text,
# success); any other failure must not be read as "the VPC is gone".
assert_vpc_gone() {
  local vpc_check_out
  if ! vpc_check_out="$(aws_text aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].VpcId' --output text)"; then
    fail "checking whether VPC ${VPC_ID} still exists: ${vpc_check_out}"
  fi
  if [[ -n "${vpc_check_out}" && "${vpc_check_out}" != "None" ]]; then
    fail "VPC ${VPC_ID} still exists after destroy"
  fi
  pass "VPC removed"
}
