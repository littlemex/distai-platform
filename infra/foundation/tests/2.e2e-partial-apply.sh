#!/usr/bin/env bash
# End-to-end regression test for issue #26: terraform destroy after a
# terraform apply of the foundation layer that failed part-way must leave
# nothing behind, without manual steps.
#
#   1. init with the S3 backend, check the state has no resources yet;
#   2. apply with test_invalid_karpenter_node_principal_arn set to an IAM
#      role ARN that does not exist, and require the apply to fail;
#   3. require that it failed only after the EKS cluster and the system node
#      group exist (checked through the EKS API, not the exit code), that
#      aws_eks_access_entry.karpenter_node is the resource that failed, and
#      that terraform_data.teardown_guard (which depends_on that access
#      entry) is, as a result, absent from the partial state - the exact
#      state issue #26 is about, forced without depending on timing: the
#      access entry is teardown_guard's own dependency, not a sibling of it,
#      so terraform cannot create the guard no matter how the apply's
#      resources happen to be scheduled;
#   4. plant a detached network interface (description aws-K8S-*) in a
#      private subnet: whether the system node group's own deletion leaves
#      one behind is a race this test must not depend on (in this minimal
#      environment, with no pod load and no Karpenter running, it usually
#      does not), so the test creates the exact artifact issue #26 describes
#      directly, in the shape a Karpenter instance's own leftover interface
#      would take;
#   5. terraform destroy with the same inputs, which must succeed;
#   6. nothing is left: the leftover kinds of 1.e2e.sh (instance, ENI, NAT,
#      EBS, launch template), plus detached VPC CNI interfaces (aws-K8S-*,
#      including the planted one) in the cell's VPC and security groups
#      tagged aws:eks:cluster-name = NAME (the two leftovers of issue #26),
#      then the cluster, its security group and the VPC are gone.
#
# Every check prints PASS or FAIL. The script exits non-zero on the first
# failed step and always attempts to destroy what it created (EXIT trap).
#
# Required environment (export before running), the same as 1.e2e.sh:
#   AWS_PROFILE, AWS_REGION, NAME, STATE_BUCKET, STATE_REGION,
#   ADMIN_PRINCIPAL_ARN, MY_CIDR
# Optional environment:
#   TERRAFORM (terraform), E2E_WORK_DIR (mktemp -d),
#   E2E_KEEP_ON_FAILURE (0), E2E_LEFTOVER_GRACE_SECONDS (600),
#   E2E_INVALID_KARPENTER_NODE_PRINCIPAL_ARN (computed from the account ID
#   and NAME if unset)
set -euo pipefail

: "${AWS_PROFILE:?export AWS_PROFILE}"
: "${AWS_REGION:?export AWS_REGION}"
: "${NAME:?export NAME (cell and cluster name)}"
: "${STATE_BUCKET:?export STATE_BUCKET}"
: "${STATE_REGION:?export STATE_REGION}"
: "${ADMIN_PRINCIPAL_ARN:?export ADMIN_PRINCIPAL_ARN (the principal running this test)}"
: "${MY_CIDR:?export MY_CIDR (CIDR allowed to reach the API endpoint)}"
export AWS_PROFILE AWS_REGION

TERRAFORM="${TERRAFORM:-terraform}"
E2E_KEEP_ON_FAILURE="${E2E_KEEP_ON_FAILURE:-0}"
E2E_LEFTOVER_GRACE_SECONDS="${E2E_LEFTOVER_GRACE_SECONDS:-600}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
TFVARS="${WORK_DIR}/e2e-partial.tfvars.json"
APPLY_LOG="${WORK_DIR}/apply.log"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export TF_IN_AUTOMATION=1

STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="e2e-partial-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"

# Every leftover kind e2e-lib.sh knows: the five 1.e2e.sh checks plus the
# two of issue #26.
LEFTOVER_KINDS=(instance eni nat volume launch-template cni-eni security-group)

APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
VPC_ID=""
VPC_LOOKUP_ERROR=""
CLUSTER_SG_ID=""

# ---------------------------------------------------------------- helpers

# shellcheck source=e2e-lib.sh
source "${SCRIPT_DIR}/e2e-lib.sh"

# find_vpc_id: sets VPC_ID to the VPC that carries this run's tag (the
# provider's default_tags put var.tags on it); none leaves VPC_ID empty.
# Returns 1, with the reason in VPC_LOOKUP_ERROR, if the lookup fails or more
# than one VPC carries the tag. It never calls fail(), so the EXIT trap can
# use it.
find_vpc_id() {
  local out
  if ! out="$(aws_text aws ec2 describe-vpcs \
    --filters "Name=tag:${TEST_TAG_KEY},Values=${RUN_ID}" \
    --query 'Vpcs[].VpcId' --output text)"; then
    VPC_LOOKUP_ERROR="looking up the VPC tagged ${TEST_TAG_KEY}=${RUN_ID}: ${out}"
    return 1
  fi
  out="$(printf '%s' "${out}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' || true)"
  if [[ "$(grep -c . <<<"${out}" || true)" -gt 1 ]]; then
    VPC_LOOKUP_ERROR="more than one VPC is tagged ${TEST_TAG_KEY}=${RUN_ID}: $(tr '\n' ' ' <<<"${out}")"
    return 1
  fi
  VPC_ID="${out}"
}

# -------------------------------------------------------- cleanup (trap)

# Deletes, in the cell's VPC only, the two kinds of leftovers that make
# terraform destroy of a partial apply fail (issue #26), so that a failed run
# can still be torn down. Used only on the failure path, after the test has
# already failed; the test itself never removes anything by hand.
remove_issue26_leftovers() {
  local id
  [[ -n "${VPC_ID}" ]] || return 0
  for id in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
    "Name=description,Values=aws-K8S-*" "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
    [[ "${id}" == "None" ]] && continue
    info "cleanup: deleting detached network interface ${id}"
    aws ec2 delete-network-interface --network-interface-id "${id}"
  done
  for id in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:aws:eks:cluster-name,Values=${NAME}" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
    [[ "${id}" == "None" ]] && continue
    info "cleanup: deleting EKS cluster security group ${id}"
    aws ec2 delete-security-group --group-id "${id}"
  done
}

cleanup() {
  local rc=$?
  set +e
  if [[ "${APPLY_ATTEMPTED}" -eq 1 && "${DESTROYED}" -eq 0 ]]; then
    if [[ "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving the cell in place; destroy it with:"
      info "TF_DATA_DIR=${TF_DATA_DIR} ${TERRAFORM} -chdir=${ROOT} destroy -var-file=${TFVARS}"
    else
      info "cleanup: the test did not reach a successful destroy; cleaning up"
      if [[ -z "${VPC_ID}" ]] && ! find_vpc_id; then
        log "cleanup: ${VPC_LOOKUP_ERROR}"
      fi
      tf destroy -auto-approve -input=false -var-file="${TFVARS}"
      local destroy_rc=$?
      if [[ "${destroy_rc}" -ne 0 ]]; then
        info "cleanup: terraform destroy exited ${destroy_rc}; removing detached aws-K8S-* interfaces and the EKS cluster security group in ${VPC_ID:-the cell VPC, not found}, then retrying"
        remove_issue26_leftovers
        tf destroy -auto-approve -input=false -var-file="${TFVARS}"
        destroy_rc=$?
      fi
      if [[ "${destroy_rc}" -ne 0 ]]; then
        log "FAIL cleanup: terraform destroy exited ${destroy_rc}; remove the cell by hand"
      else
        info "cleanup: terraform destroy completed"
      fi
      if [[ -n "${VPC_ID}" ]]; then
        report_leftovers 60 "${LEFTOVER_KINDS[@]}" || true
      else
        report_leftovers 60 instance eni nat volume launch-template security-group || true
      fi
    fi
  fi
  echo
  if [[ "${rc}" -eq 0 ]]; then
    log "RESULT PASS: all checks passed (run ${RUN_ID}, work dir ${WORK_DIR})"
  else
    log "RESULT FAIL: ${FAILED_STEP:-exit ${rc}} (run ${RUN_ID}, work dir ${WORK_DIR})"
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------ preflight

for b in "${TERRAFORM}" aws; do require_bin "${b}"; done
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
  || fail "MY_CIDR must be an IPv4 CIDR, got ${MY_CIDR}"
if ! ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"; then
  fail "aws sts get-caller-identity (check AWS_PROFILE and credentials)"
fi
# The real principal of aws_eks_access_entry.karpenter_node once the cell is
# up (karpenter.tf: aws_iam_role.karpenter_node.name = "${var.name}-karpenter-node");
# the invalid ARN below must look like a role ARN but name a role that is
# never created, so EKS rejects the access entry with that principal.
KARPENTER_NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${NAME}-karpenter-node"
E2E_INVALID_KARPENTER_NODE_PRINCIPAL_ARN="${E2E_INVALID_KARPENTER_NODE_PRINCIPAL_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/${NAME}-test-only-does-not-exist}"
pass "preflight: tools present, credentials valid"
info "run ${RUN_ID}, work dir ${WORK_DIR}"

# ------------------------------------------------- 1. init, empty state

cat >"${TFVARS}" <<JSON
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "argocd": null,
  "test_invalid_karpenter_node_principal_arn": "${E2E_INVALID_KARPENTER_NODE_PRINCIPAL_ARN}",
  "tags": {"${TEST_TAG_KEY}": "${RUN_ID}"}
}
JSON

tf init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true" \
  || fail "terraform init with the S3 backend (key ${STATE_KEY})"
pass "terraform init with the S3 backend, key ${STATE_KEY}"

# See 1.e2e.sh step 1b: an empty state, or no state object at all, is
# required, so that the partial state below is this run's own.
if ! existing_state="$(tf state list 2>&1)"; then
  [[ "${existing_state}" == *"No state file"* ]] \
    || fail "terraform state list (key ${STATE_KEY}): ${existing_state}"
  existing_state=""
fi
[[ -z "${existing_state}" ]] \
  || fail "state at key ${STATE_KEY} already has resources, refusing to apply over it: $(tr '\n' ' ' <<<"${existing_state}")"
pass "state at key ${STATE_KEY} has no resources before apply"

# ------------------------------------------- 2. apply that fails part-way

APPLY_ATTEMPTED=1
apply_start="$(date +%s)"
if tf apply -auto-approve -input=false -var-file="${TFVARS}" 2>&1 | tee "${APPLY_LOG}"; then
  fail "terraform apply succeeded with test_invalid_karpenter_node_principal_arn=${E2E_INVALID_KARPENTER_NODE_PRINCIPAL_ARN}; the test-only trigger did not make it fail"
fi
pass "terraform apply failed as intended ($(($(date +%s) - apply_start))s)"

# ------------------------------- 3. it failed after the cluster existed

# The exit code alone does not say where the apply stopped. An apply that
# failed before the cluster and the system node group existed (a typo in the
# inputs, a quota, a transient API error) leaves nothing for EKS or the VPC
# CNI to have created, so it would not test issue #26 at all.
grep -q 'aws_eks_access_entry.karpenter_node' "${APPLY_LOG}" \
  || fail "terraform apply failed, but its output never mentions aws_eks_access_entry.karpenter_node: it failed somewhere other than the injected principal ARN (see ${APPLY_LOG})"

if ! cluster_status="$(aws_text aws eks describe-cluster --name "${NAME}" \
  --query 'cluster.status' --output text)"; then
  fail "aws eks describe-cluster --name ${NAME}: ${cluster_status}"
fi
[[ "${cluster_status}" == "ACTIVE" ]] \
  || fail "after the failed apply the cluster ${NAME} is '${cluster_status:-not found}', expected ACTIVE: the apply failed too early to test issue #26"
pass "after the failed apply the EKS cluster exists and is ACTIVE"

if ! nodegroup="$(aws_text aws eks list-nodegroups --cluster-name "${NAME}" \
  --query 'nodegroups[0]' --output text)"; then
  fail "aws eks list-nodegroups --cluster-name ${NAME}: ${nodegroup}"
fi
[[ -n "${nodegroup}" && "${nodegroup}" != "None" ]] \
  || fail "after the failed apply the cluster has no managed node group: the apply failed too early to test issue #26"
if ! nodegroup_status="$(aws_text aws eks describe-nodegroup --cluster-name "${NAME}" \
  --nodegroup-name "${nodegroup}" --query 'nodegroup.status' --output text)"; then
  fail "aws eks describe-nodegroup --nodegroup-name ${nodegroup}: ${nodegroup_status}"
fi
[[ "${nodegroup_status}" == "ACTIVE" ]] \
  || fail "after the failed apply node group ${nodegroup} is '${nodegroup_status}', expected ACTIVE"
pass "after the failed apply the system node group ${nodegroup} exists and is ACTIVE"

# The access entry named by the trigger must be the one that is missing: EKS
# never created one for the real Karpenter node role, because the apply gave
# it the invalid ARN instead.
if describe_out="$(aws eks describe-access-entry --cluster-name "${NAME}" \
  --principal-arn "${KARPENTER_NODE_ROLE_ARN}" --query 'accessEntry.principalArn' --output text 2>&1)"; then
  fail "access entry for ${KARPENTER_NODE_ROLE_ARN} exists (${describe_out}) although test_invalid_karpenter_node_principal_arn was set"
fi
case "${describe_out}" in
  *ResourceNotFoundException*) ;;
  *) fail "aws eks describe-access-entry --principal-arn ${KARPENTER_NODE_ROLE_ARN}: ${describe_out}" ;;
esac
pass "no access entry for the real Karpenter node role exists"

# terraform_data.teardown_guard depends_on aws_eks_access_entry.karpenter_node
# (teardown.tf), so it cannot be in the partial state: this is the exact
# condition issue #26 is about, and here it holds by construction, not by
# how the apply's resources happened to be scheduled. Asserting this is not
# coupling to the fix: teardown_guard and its depends_on list predate it
# (PR #21) and are unchanged by it.
partial_state="$(tf state list 2>/dev/null || true)"
if grep -qx 'terraform_data.teardown_guard' <<<"${partial_state}"; then
  fail "terraform_data.teardown_guard is in the partial state; the injected failure did not block it as expected, so this run does not test issue #26"
fi
pass "terraform_data.teardown_guard is absent from the partial state, as issue #26 requires"

find_vpc_id || fail "${VPC_LOOKUP_ERROR}"
[[ -n "${VPC_ID}" ]] || fail "no VPC is tagged ${TEST_TAG_KEY}=${RUN_ID} after the failed apply"
if ! cluster_vpc="$(aws_text aws eks describe-cluster --name "${NAME}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"; then
  fail "aws eks describe-cluster (VPC): ${cluster_vpc}"
fi
[[ "${cluster_vpc}" == "${VPC_ID}" ]] \
  || fail "cluster ${NAME} is in VPC ${cluster_vpc}, not in the VPC tagged for this run (${VPC_ID})"
if ! CLUSTER_SG_ID="$(aws_text aws eks describe-cluster --name "${NAME}" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"; then
  fail "aws eks describe-cluster (cluster security group): ${CLUSTER_SG_ID}"
fi
[[ "${CLUSTER_SG_ID}" == sg-* ]] || fail "cluster ${NAME} reports no cluster security group (${CLUSTER_SG_ID})"
pass "the cluster runs in this run's VPC, with the EKS-created cluster security group"

# Informational: the rest of what the partial state holds (asserted above
# only for teardown_guard), and how many VPC CNI interfaces exist before
# destroy.
info "partial state holds $(grep -c . <<<"${partial_state}" || true) resources; terraform_data in it: $(grep '^terraform_data\.' <<<"${partial_state}" | tr '\n' ' ')"
cni_enis="$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
  "Name=description,Values=aws-K8S-*" --query 'length(NetworkInterfaces)' --output text 2>/dev/null || true)"
info "VPC CNI (aws-K8S-*) network interfaces in the VPC before destroy: ${cni_enis:-unknown}"

# Whether the system node group's own deletion happens to leave a detached
# VPC CNI interface behind is a race this test must not depend on (with no
# real pod load and no Karpenter running, it usually does not). So the test
# plants the exact artifact issue #26 describes directly: a detached network
# interface in a private subnet of this cell's VPC, with the description
# both guards filter on (Name=description,Values=aws-K8S-*). This is the
# same shape of leftover a Karpenter-launched instance's secondary interface
# becomes once that instance is terminated outside the normal node group
# lifecycle; planting it this way removes the need to run Karpenter here,
# and makes the cause-and-effect of this test deterministic: present at this
# point whichever guard is or is not later in a position to remove it.
if ! private_subnet="$(aws_text aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:karpenter.sh/discovery,Values=${NAME}" \
  --query 'Subnets[0].SubnetId' --output text)"; then
  fail "aws ec2 describe-subnets (private, tag karpenter.sh/discovery=${NAME}): ${private_subnet}"
fi
[[ -n "${private_subnet}" && "${private_subnet}" != "None" ]] \
  || fail "no private subnet (tag karpenter.sh/discovery=${NAME}) found in ${VPC_ID} to plant the test interface in"
if ! planted_eni="$(aws_text aws ec2 create-network-interface \
  --subnet-id "${private_subnet}" --description "aws-K8S-i-issue26testonly" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)"; then
  fail "aws ec2 create-network-interface (planting the issue #26 test artifact in ${private_subnet}): ${planted_eni}"
fi
pass "planted a detached network interface (${planted_eni}, aws-K8S-* description) in ${private_subnet}"

# ------------------------------------ 4. destroy the partial state

destroy_start="$(date +%s)"
tf destroy -auto-approve -input=false -var-file="${TFVARS}" \
  || fail "terraform destroy after a partial apply"
DESTROYED=1
pass "terraform destroy after a partial apply completed without manual steps ($(($(date +%s) - destroy_start))s)"

# ------------------------------------------------- 5. nothing left behind

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" "${LEFTOVER_KINDS[@]}" \
  || fail "resources of the cell remain after destroy of a partial apply"

if ! sg_out="$(aws_text aws ec2 describe-security-groups --group-ids "${CLUSTER_SG_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text)"; then
  fail "checking whether security group ${CLUSTER_SG_ID} still exists: ${sg_out}"
fi
[[ -z "${sg_out}" || "${sg_out}" == "None" ]] \
  || fail "EKS cluster security group ${CLUSTER_SG_ID} still exists after destroy"
pass "EKS cluster security group removed"

if ! cluster_out="$(aws_text aws eks describe-cluster --name "${NAME}" \
  --query 'cluster.status' --output text)"; then
  fail "checking whether cluster ${NAME} still exists: ${cluster_out}"
fi
[[ -z "${cluster_out}" ]] || fail "EKS cluster ${NAME} still exists after destroy (${cluster_out})"
pass "EKS cluster removed"

assert_vpc_gone
