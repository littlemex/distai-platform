#!/usr/bin/env bash
# End-to-end test of the foundation layer on a real AWS account.
#
# It uses only the variables and outputs of infra/foundation:
#   1. init with the S3 backend, check the state has no resources yet, apply
#      with a generated tfvars file;
#   2. two Ready system nodes, four add-ons ACTIVE, outputs present;
#   3. a pod without host networking on a system node cannot obtain an
#      IMDSv2 token, and the system nodes require IMDSv2 with a hop limit
#      of 1;
#   4. the Karpenter node role and the system node role carry no
#      AmazonEKS_CNI_Policy, aws-node has a Pod Identity association, and a
#      pod without host networking still gets an IP address;
#   5. a deny-all NetworkPolicy blocks pod-to-pod traffic that worked before
#      the policy was applied;
#   6. Karpenter v1.15.x installed by Helm from the outputs only;
#   7. a spot CPU NodePool launches an instance for a pending pod;
#   8. a synthetic spot interruption sent to the queue is handled;
#   9. terraform destroy with the NodePool and Karpenter still in place;
#  10. nothing tagged for the cluster is left (instance, ENI, NAT, EBS).
#
# Every check prints PASS or FAIL. The script exits non-zero on the first
# failed step and always attempts to destroy what it created (EXIT trap).
#
# Required environment (export before running):
#   AWS_PROFILE, AWS_REGION, NAME, STATE_BUCKET, STATE_REGION,
#   ADMIN_PRINCIPAL_ARN, MY_CIDR
# Optional environment:
#   TERRAFORM (terraform), KARPENTER_VERSION (1.15.2),
#   E2E_INSTANCE_TYPES (m7i.large,m6i.large,m5.large),
#   E2E_AMI_ALIAS (al2023@v20261112), E2E_WORK_DIR (mktemp -d),
#   E2E_KEEP_ON_FAILURE (0), E2E_LEFTOVER_GRACE_SECONDS (600),
#   ARGOCD_IDC_INSTANCE_ARN, ARGOCD_IDC_REGION, ARGOCD_ADMIN_GROUP_IDS
#   (all three set: also create the Argo CD capability with one ADMIN role
#   mapping, and check it), ARGOCD_VIEWER_GROUP_IDS, ARGOCD_EDITOR_GROUP_IDS
#   (with the three above also set: add a VIEWER and/or an EDITOR role
#   mapping, each independently, and check every mapping that was added).
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
KARPENTER_VERSION="${KARPENTER_VERSION:-1.15.2}"
E2E_INSTANCE_TYPES="${E2E_INSTANCE_TYPES:-m7i.large,m6i.large,m5.large}"
E2E_AMI_ALIAS="${E2E_AMI_ALIAS:-al2023@v20261112}"
E2E_KEEP_ON_FAILURE="${E2E_KEEP_ON_FAILURE:-0}"
E2E_LEFTOVER_GRACE_SECONDS="${E2E_LEFTOVER_GRACE_SECONDS:-600}"
ARGOCD_IDC_INSTANCE_ARN="${ARGOCD_IDC_INSTANCE_ARN:-}"
ARGOCD_IDC_REGION="${ARGOCD_IDC_REGION:-}"
ARGOCD_ADMIN_GROUP_IDS="${ARGOCD_ADMIN_GROUP_IDS:-}"
ARGOCD_VIEWER_GROUP_IDS="${ARGOCD_VIEWER_GROUP_IDS:-}"
ARGOCD_EDITOR_GROUP_IDS="${ARGOCD_EDITOR_GROUP_IDS:-}"

# Images pinned by digest (see tests/README.md "Pinned images" for how these
# digests were resolved).
IMDS_CURL_IMAGE="docker.io/curlimages/curl@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69"
NETPOL_BUSYBOX_IMAGE="public.ecr.aws/docker/library/busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
TFVARS="${WORK_DIR}/e2e.tfvars.json"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1
# Isolate Helm's OCI registry credential store from the operator's own
# (global, machine-wide) one: public.ecr.aws needs no login for anonymous
# pulls, but if the operator previously ran `helm registry login` for it and
# that stored token later expired, Helm prefers the stale stored credential
# over an anonymous pull and every chart pull fails with "authorization
# token has expired", unrelated to anything this test does. Pointing
# HELM_REGISTRY_CONFIG at an empty file scoped to this run's WORK_DIR avoids
# depending on, or mutating, whatever is cached on the machine that runs
# this script.
export HELM_REGISTRY_CONFIG="${WORK_DIR}/helm-registry-config.json"
echo '{}' >"${HELM_REGISTRY_CONFIG}"

STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="e2e-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
NODEPOOL="e2e-spot"
NODECLASS="e2e-cpu"
APP="e2e-inflate"
IMDS_POD="e2e-imds-check"
NETPOL_NS="e2e-netpol-${RUN_ID#e2e-}"
ADDONS=(vpc-cni coredns kube-proxy eks-pod-identity-agent)

APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
VPC_ID=""
KARPENTER_INSTANCE_IDS=()

# ---------------------------------------------------------------- helpers

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
pass() { log "PASS $*"; }
fail() {
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

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
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

instance_of_node() {
  kubectl get node "$1" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}'
}

# -------------------------------------------------------- cleanup (trap)

cleanup() {
  local rc=$?
  set +e
  if [[ "${APPLY_ATTEMPTED}" -eq 1 && "${DESTROYED}" -eq 0 ]]; then
    if [[ "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving the cell in place; destroy it with:"
      info "TF_DATA_DIR=${TF_DATA_DIR} ${TERRAFORM} -chdir=${ROOT} destroy -var-file=${TFVARS}"
    else
      info "cleanup: the test did not reach a successful destroy; cleaning up"
      if kubectl get nodes >/dev/null 2>&1; then
        kubectl delete deployment "${APP}" --ignore-not-found --wait=false >/dev/null 2>&1
        kubectl delete nodepool "${NODEPOOL}" --ignore-not-found --timeout=300s >/dev/null 2>&1
        kubectl delete pod "${IMDS_POD}" --ignore-not-found --wait=false >/dev/null 2>&1
        kubectl delete namespace "${NETPOL_NS}" --ignore-not-found --wait=false >/dev/null 2>&1
      fi
      tf destroy -auto-approve -input=false -var-file="${TFVARS}"
      local destroy_rc=$?
      if [[ "${destroy_rc}" -ne 0 ]]; then
        log "FAIL cleanup: terraform destroy exited ${destroy_rc}; remove the cell by hand"
      else
        info "cleanup: terraform destroy completed"
      fi
      report_leftovers 60 || true
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
list_leftover() {
  local kind="$1" filter out all=""
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

# report_leftovers GRACE_SECONDS: PASS/FAIL per kind, returns 1 if any remains.
report_leftovers() {
  local grace="$1" kind ids bad=0
  for kind in instance eni nat volume launch-template; do
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

# ------------------------------------------------------------ preflight

for b in "${TERRAFORM}" aws kubectl helm; do require_bin "${b}"; done
[[ "${KARPENTER_VERSION}" =~ ^1\.15\.[0-9]+$ ]] \
  || fail "KARPENTER_VERSION must be a pinned 1.15.x version, got ${KARPENTER_VERSION}"
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
  || fail "MY_CIDR must be an IPv4 CIDR, got ${MY_CIDR}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || fail "aws sts get-caller-identity (check AWS_PROFILE and credentials)"
pass "preflight: tools present, credentials valid"
info "run ${RUN_ID}, work dir ${WORK_DIR}"

# ------------------------------------------------- 1. init and apply

csv_to_json_array() {
  printf '%s' "$1" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}}'
}

ARGOCD_JSON="null"
if [[ -n "${ARGOCD_IDC_INSTANCE_ARN}" && -n "${ARGOCD_IDC_REGION}" && -n "${ARGOCD_ADMIN_GROUP_IDS}" ]]; then
  admin_groups_json="$(csv_to_json_array "${ARGOCD_ADMIN_GROUP_IDS}")"
  role_mappings_json="{\"role\":\"ADMIN\",\"group_ids\":[${admin_groups_json}]}"
  if [[ -n "${ARGOCD_VIEWER_GROUP_IDS}" ]]; then
    viewer_groups_json="$(csv_to_json_array "${ARGOCD_VIEWER_GROUP_IDS}")"
    role_mappings_json="${role_mappings_json},{\"role\":\"VIEWER\",\"group_ids\":[${viewer_groups_json}]}"
  fi
  if [[ -n "${ARGOCD_EDITOR_GROUP_IDS}" ]]; then
    editor_groups_json="$(csv_to_json_array "${ARGOCD_EDITOR_GROUP_IDS}")"
    role_mappings_json="${role_mappings_json},{\"role\":\"EDITOR\",\"group_ids\":[${editor_groups_json}]}"
  fi
  ARGOCD_JSON="{\"idc_instance_arn\":\"${ARGOCD_IDC_INSTANCE_ARN}\",\"idc_region\":\"${ARGOCD_IDC_REGION}\",\"role_mappings\":[${role_mappings_json}]}"
  info "argocd is set: the Argo CD capability is created and checked"
fi

cat >"${TFVARS}" <<JSON
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "argocd": ${ARGOCD_JSON},
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

# ------------------------------------------- 1b. state empty before apply
#
# A state that already has resources means this run would apply new code
# over an old cell instead of building a fresh one (for example after a
# previous run left its cell in place with E2E_KEEP_ON_FAILURE=1, or NAME
# collides with another cell's state key). `terraform state list` exits 0
# with empty output for an empty state; for a backend that has no state
# object at all yet it prints "No state file was found!" to stderr and
# exits non-zero, which this test also treats as empty.
if ! existing_state="$(tf state list 2>&1)"; then
  [[ "${existing_state}" == *"No state file"* ]] \
    || fail "terraform state list (key ${STATE_KEY}): ${existing_state}"
  existing_state=""
fi
[[ -z "${existing_state}" ]] \
  || fail "state at key ${STATE_KEY} already has resources, refusing to apply over it: $(tr '\n' ' ' <<<"${existing_state}")"
pass "state at key ${STATE_KEY} has no resources before apply"

APPLY_ATTEMPTED=1
apply_start="$(date +%s)"
tf apply -auto-approve -input=false -var-file="${TFVARS}" || fail "terraform apply"
pass "terraform apply ($(($(date +%s) - apply_start))s)"

# ------------------------------------------------------- 2. outputs

for o in cluster_name cluster_endpoint cluster_certificate_authority_data region \
  vpc_id node_security_group_id karpenter_controller_role_arn \
  karpenter_node_role_name karpenter_interruption_queue_name; do
  v="$(tf_out "${o}" 2>/dev/null)" || fail "output ${o} is missing"
  [[ -n "${v}" ]] || fail "output ${o} is empty"
done
[[ "$(tf output -json private_subnet_ids)" == *subnet-* ]] || fail "output private_subnet_ids has no subnet"
# Terraform omits a root output from state entirely when its value is exactly
# null (confirmed on 1.17.2), so `terraform output -json <name>` then fails
# with "Output ... not found" instead of printing null. outputs.tf uses
# try(aws_eks_capability.argocd[0].arn, null), matching the README contract
# ("null when not created"), so that failure means the same thing as null here.
argocd_arn_json="$(tf output -json argocd_capability_arn 2>/dev/null)" || argocd_arn_json="null"
if [[ "${ARGOCD_JSON}" == "null" ]]; then
  [[ "${argocd_arn_json}" == "null" ]] || fail "argocd_capability_arn is not null while argocd is unset"
else
  [[ "${argocd_arn_json}" != "null" ]] || fail "argocd_capability_arn is missing while argocd is set"
fi
pass "all eleven outputs present"

CLUSTER="$(tf_out cluster_name)"
VPC_ID="$(tf_out vpc_id)"
NODE_ROLE="$(tf_out karpenter_node_role_name)"
QUEUE_NAME="$(tf_out karpenter_interruption_queue_name)"
[[ "${CLUSTER}" == "${NAME}" ]] || fail "cluster_name (${CLUSTER}) differs from var.name (${NAME})"
[[ "$(tf_out region)" == "${AWS_REGION}" ]] || fail "output region differs from var.region"
pass "cluster_name and region match the inputs"

# ------------------------------------------------- 3. cluster shape

read -r k8s_version auth_mode <<<"$(aws eks describe-cluster --name "${CLUSTER}" \
  --query '[cluster.version, cluster.accessConfig.authenticationMode]' --output text)"
[[ "${k8s_version}" == "1.37" ]] || fail "cluster version is ${k8s_version}, expected 1.37"
[[ "${auth_mode}" == "API" ]] || fail "authentication mode is ${auth_mode}, expected API"
public_cidrs="$(aws eks describe-cluster --name "${CLUSTER}" \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text)"
[[ "${public_cidrs}" == "${MY_CIDR}" ]] \
  || fail "public endpoint CIDRs are '${public_cidrs}', expected only ${MY_CIDR}"
pass "EKS 1.37, authentication mode API, public endpoint limited to MY_CIDR"

aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}" \
  --kubeconfig "${KUBECONFIG}" >/dev/null || fail "aws eks update-kubeconfig"
kubectl get --raw /readyz >/dev/null || fail "kubectl cannot reach the cluster as ADMIN_PRINCIPAL_ARN"
pass "kubectl reaches the cluster through the access entry"

ready_system_nodes() {
  kubectl get nodes -l eks.amazonaws.com/nodegroup \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2=="True"' | wc -l | tr -d ' '
}
two_ready_system_nodes() { [[ "$(ready_system_nodes)" -eq 2 ]]; }
wait_until 600 15 "two Ready system nodes" two_ready_system_nodes \
  || fail "expected 2 Ready system nodes, found $(ready_system_nodes)"
pass "kubectl get nodes: 2 Ready system nodes"

untainted="$(kubectl get nodes -l eks.amazonaws.com/nodegroup \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.taints[?(@.key=="CriticalAddonsOnly")].effect}{"\n"}{end}' \
  | awk '$2!="NoSchedule"{print $1}')"
[[ -z "${untainted}" ]] || fail "system nodes without CriticalAddonsOnly:NoSchedule: ${untainted}"
pass "system nodes carry the CriticalAddonsOnly=true:NoSchedule taint"

addon_active() {
  [[ "$(aws eks describe-addon --cluster-name "${CLUSTER}" --addon-name "$1" \
    --query addon.status --output text 2>/dev/null)" == "ACTIVE" ]]
}
for a in "${ADDONS[@]}"; do
  wait_until 600 15 "add-on ${a} ACTIVE" addon_active "${a}" \
    || fail "add-on ${a} is $(aws eks describe-addon --cluster-name "${CLUSTER}" --addon-name "${a}" --query addon.status --output text 2>&1)"
  pass "add-on ${a} ACTIVE ($(aws eks describe-addon --cluster-name "${CLUSTER}" --addon-name "${a}" --query addon.addonVersion --output text))"
done

if [[ "${ARGOCD_JSON}" != "null" ]]; then
  ARGOCD_ARN="$(tf_out argocd_capability_arn)"
  argocd_active() {
    [[ "$(aws eks list-capabilities --cluster-name "${CLUSTER}" \
      --query "capabilities[?arn=='${ARGOCD_ARN}'].status | [0]" --output text 2>/dev/null)" == "ACTIVE" ]]
  }
  wait_until 1200 30 "Argo CD capability ACTIVE" argocd_active || fail "Argo CD capability is not ACTIVE"
  pass "Argo CD capability ACTIVE"

  ARGOCD_CAPABILITY_NAME="$(aws eks list-capabilities --cluster-name "${CLUSTER}" \
    --query "capabilities[?arn=='${ARGOCD_ARN}'].capabilityName | [0]" --output text)" \
    || fail "aws eks list-capabilities --cluster-name ${CLUSTER}"
  [[ -n "${ARGOCD_CAPABILITY_NAME}" && "${ARGOCD_CAPABILITY_NAME}" != "None" ]] \
    || fail "no capability with arn ${ARGOCD_ARN} in list-capabilities"

  # var.argocd.role_mappings is {role, group_ids}; the Terraform resource has
  # no identity source other than IAM Identity Center groups, so each
  # group_id becomes one identity of type SSO_GROUP in the capability's
  # configuration (aws eks describe-capability). This checks role name plus
  # the set of SSO_GROUP identity IDs under it, not the group's type field
  # directly (kept out of this contract-only test).
  sorted_csv() {
    printf '%s' "$1" | tr ',' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//'
  }
  role_mapping_group_ids() {
    aws eks describe-capability --cluster-name "${CLUSTER}" --capability-name "${ARGOCD_CAPABILITY_NAME}" \
      --query "capability.configuration.argoCd.rbacRoleMappings[?role=='$1'].identities[].id" --output text 2>/dev/null \
      | tr '\t' '\n' | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ $//'
  }
  expect_role_mapping() {
    local role="$1" want_csv="$2" got want
    want="$(sorted_csv "${want_csv}")"
    got="$(role_mapping_group_ids "${role}")" \
      || fail "aws eks describe-capability ${ARGOCD_CAPABILITY_NAME} (role ${role})"
    [[ "${got}" == "${want}" ]] \
      || fail "Argo CD role mapping ${role}: capability has [${got}], expected [${want}]"
  }
  expect_role_mapping ADMIN "${ARGOCD_ADMIN_GROUP_IDS}"
  pass "Argo CD capability lists the ADMIN role mapping (${ARGOCD_ADMIN_GROUP_IDS})"
  if [[ -n "${ARGOCD_VIEWER_GROUP_IDS}" ]]; then
    expect_role_mapping VIEWER "${ARGOCD_VIEWER_GROUP_IDS}"
    pass "Argo CD capability lists the VIEWER role mapping (${ARGOCD_VIEWER_GROUP_IDS})"
  fi
  if [[ -n "${ARGOCD_EDITOR_GROUP_IDS}" ]]; then
    expect_role_mapping EDITOR "${ARGOCD_EDITOR_GROUP_IDS}"
    pass "Argo CD capability lists the EDITOR role mapping (${ARGOCD_EDITOR_GROUP_IDS})"
  fi
fi

# ------------------------------------------------------- 3b. IMDS hop limit

SYSTEM_NODE_NAMES=()
while IFS= read -r n; do SYSTEM_NODE_NAMES+=("${n}"); done \
  < <(kubectl get nodes -l eks.amazonaws.com/nodegroup -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ "${#SYSTEM_NODE_NAMES[@]}" -ge 1 ]] || fail "no system nodes found for the IMDS and CNI checks"
SYSTEM_NODEGROUP_LABEL="$(kubectl get node "${SYSTEM_NODE_NAMES[0]}" \
  -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/nodegroup}')"
[[ -n "${SYSTEM_NODEGROUP_LABEL}" ]] \
  || fail "system node ${SYSTEM_NODE_NAMES[0]} has no eks.amazonaws.com/nodegroup label"

cat >"${WORK_DIR}/imds-check.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${IMDS_POD}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  restartPolicy: Never
  hostNetwork: false
  nodeSelector:
    eks.amazonaws.com/nodegroup: ${SYSTEM_NODEGROUP_LABEL}
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  containers:
    - name: curl
      image: ${IMDS_CURL_IMAGE}
      command: ["sh", "-c"]
      args:
        - |
          set +e
          TOKEN="\$(curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token \
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
          printf 'IMDS_TOKEN_LEN=%s\n' "\${#TOKEN}"
          exit 0
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
YAML
kubectl apply -f "${WORK_DIR}/imds-check.yaml" || fail "kubectl apply the IMDS check pod"

imds_pod_done() {
  local p
  p="$(kubectl get pod "${IMDS_POD}" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "${p}" == "Succeeded" || "${p}" == "Failed" ]]
}
wait_until 180 10 "IMDS check pod finished" imds_pod_done \
  || fail "IMDS check pod ${IMDS_POD} did not finish: $(kubectl get pod "${IMDS_POD}" -o jsonpath='{.status}' 2>&1)"
IMDS_POD_IP="$(kubectl get pod "${IMDS_POD}" -o jsonpath='{.status.podIP}' 2>/dev/null)"
IMDS_LOG="$(kubectl logs "${IMDS_POD}" 2>/dev/null)"
kubectl delete pod "${IMDS_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
[[ "${IMDS_LOG}" == *"IMDS_TOKEN_LEN=0"* ]] \
  || fail "a pod without host networking obtained an IMDSv2 token: ${IMDS_LOG}"

# Control: the same pod on the host network (one hop) must get a token, which
# shows that the empty token above comes from the hop limit and not from a
# broken check (no curl, no route, wrong address).
IMDS_HOST_POD="${IMDS_POD}-host"
sed -e "s/name: ${IMDS_POD}\$/name: ${IMDS_HOST_POD}/" -e 's/hostNetwork: false/hostNetwork: true/' \
  "${WORK_DIR}/imds-check.yaml" > "${WORK_DIR}/imds-check-host.yaml"
kubectl apply -f "${WORK_DIR}/imds-check-host.yaml" || fail "kubectl apply the host-network IMDS control pod"
imds_host_pod_done() {
  local p
  p="$(kubectl get pod "${IMDS_HOST_POD}" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "${p}" == "Succeeded" || "${p}" == "Failed" ]]
}
wait_until 180 10 "host-network IMDS control pod finished" imds_host_pod_done \
  || fail "host-network IMDS control pod ${IMDS_HOST_POD} did not finish"
IMDS_HOST_LOG="$(kubectl logs "${IMDS_HOST_POD}" 2>/dev/null)"
kubectl delete pod "${IMDS_HOST_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
[[ "${IMDS_HOST_LOG}" == *"IMDS_TOKEN_LEN="* && "${IMDS_HOST_LOG}" != *"IMDS_TOKEN_LEN=0"* ]] \
  || fail "control failed: a host-network pod got no IMDSv2 token either (${IMDS_HOST_LOG}); the check cannot tell blocked from broken"
pass "a pod without host networking on a system node could not obtain an IMDSv2 token, while a host-network pod on the same node could"

SYSTEM_INSTANCE_IDS=()
for n in "${SYSTEM_NODE_NAMES[@]}"; do
  SYSTEM_INSTANCE_IDS+=("$(instance_of_node "${n}")")
done
bad_metadata_options="$(aws ec2 describe-instances --instance-ids "${SYSTEM_INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
  --output text | awk '$2!="required" || $3!="1" {print}')" \
  || fail "aws ec2 describe-instances --instance-ids ${SYSTEM_INSTANCE_IDS[*]}"
[[ -z "${bad_metadata_options}" ]] \
  || fail "system node instance metadata options are not locked down: ${bad_metadata_options}"
pass "system nodes require IMDSv2 (HttpTokens=required) with HttpPutResponseHopLimit=1"

# --------------------------------------------- 3c. no CNI permissions on
# --------------------------------------------- node roles, aws-node via Pod
# --------------------------------------------- Identity, pods still get IPs

SYSTEM_NODEGROUP_NAME="$(aws eks list-nodegroups --cluster-name "${CLUSTER}" --query 'nodegroups[0]' --output text)" \
  || fail "aws eks list-nodegroups --cluster-name ${CLUSTER}"
[[ -n "${SYSTEM_NODEGROUP_NAME}" && "${SYSTEM_NODEGROUP_NAME}" != "None" ]] \
  || fail "no managed node group found on cluster ${CLUSTER}"
SYSTEM_NODE_ROLE_ARN="$(aws eks describe-nodegroup --cluster-name "${CLUSTER}" \
  --nodegroup-name "${SYSTEM_NODEGROUP_NAME}" --query 'nodegroup.nodeRole' --output text)" \
  || fail "aws eks describe-nodegroup --cluster-name ${CLUSTER} --nodegroup-name ${SYSTEM_NODEGROUP_NAME}"
SYSTEM_NODE_ROLE="${SYSTEM_NODE_ROLE_ARN##*/}"

role_has_cni_policy() {
  aws iam list-attached-role-policies --role-name "$1" \
    --query "length(AttachedPolicies[?PolicyName=='AmazonEKS_CNI_Policy'])" --output text
}
for role in "${NODE_ROLE}" "${SYSTEM_NODE_ROLE}"; do
  n="$(role_has_cni_policy "${role}")" || fail "aws iam list-attached-role-policies --role-name ${role}"
  [[ "${n}" == "0" ]] || fail "role ${role} still has AmazonEKS_CNI_Policy attached"
done
pass "neither the Karpenter node role nor the system node role (${SYSTEM_NODE_ROLE}) has AmazonEKS_CNI_Policy"

aws_node_pia_count="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER}" \
  --namespace kube-system --service-account aws-node --query 'length(associations)' --output text)" \
  || fail "aws eks list-pod-identity-associations --cluster-name ${CLUSTER}"
[[ "${aws_node_pia_count}" == "1" ]] || fail "expected one EKS Pod Identity association for kube-system/aws-node, found ${aws_node_pia_count}"
aws_node_pia_id="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER}" \
  --namespace kube-system --service-account aws-node --query 'associations[0].associationId' --output text)" \
  || fail "aws eks list-pod-identity-associations (association id)"
aws_node_role_arn="$(aws eks describe-pod-identity-association --cluster-name "${CLUSTER}" \
  --association-id "${aws_node_pia_id}" --query 'association.roleArn' --output text)" \
  || fail "aws eks describe-pod-identity-association ${aws_node_pia_id}"
aws_node_role="${aws_node_role_arn##*/}"
aws_node_policies="$(aws iam list-attached-role-policies --role-name "${aws_node_role}" \
  --query 'AttachedPolicies[].PolicyName' --output text)" \
  || fail "aws iam list-attached-role-policies --role-name ${aws_node_role}"
aws_node_inline="$(aws iam list-role-policies --role-name "${aws_node_role}" --query 'length(PolicyNames)' --output text)" \
  || fail "aws iam list-role-policies --role-name ${aws_node_role}"
[[ "${aws_node_policies}" == "AmazonEKS_CNI_Policy" && "${aws_node_inline}" == "0" ]] \
  || fail "the aws-node role ${aws_node_role} should carry exactly AmazonEKS_CNI_Policy, has '${aws_node_policies}' and ${aws_node_inline} inline policies"
[[ "${aws_node_role}" != "${NODE_ROLE}" && "${aws_node_role}" != "${SYSTEM_NODE_ROLE}" ]] \
  || fail "kube-system/aws-node is associated with a node role (${aws_node_role})"
pass "kube-system/aws-node has one EKS Pod Identity association, to its own role that carries exactly AmazonEKS_CNI_Policy"

[[ -n "${IMDS_POD_IP}" ]] \
  || fail "pod ${IMDS_POD} (no host networking, no node role) never got a pod IP from the CNI"
pass "a pod without host networking still got a pod IP (${IMDS_POD_IP}) from the CNI"

# --------------------------------------------------------- 3d. NetworkPolicy

cat >"${WORK_DIR}/netpol-check.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NETPOL_NS}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
---
apiVersion: v1
kind: Pod
metadata:
  name: netpol-server
  namespace: ${NETPOL_NS}
  labels:
    role: netpol-server
spec:
  nodeSelector:
    eks.amazonaws.com/nodegroup: ${SYSTEM_NODEGROUP_LABEL}
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  containers:
    - name: httpd
      image: ${NETPOL_BUSYBOX_IMAGE}
      command: ["sh", "-c", "mkdir -p /www && echo ok >/www/index.html && httpd -f -p 8080 -h /www"]
      ports:
        - containerPort: 8080
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: netpol-client
  namespace: ${NETPOL_NS}
  labels:
    role: netpol-client
spec:
  nodeSelector:
    eks.amazonaws.com/nodegroup: ${SYSTEM_NODEGROUP_LABEL}
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  containers:
    - name: busybox
      image: ${NETPOL_BUSYBOX_IMAGE}
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
YAML
kubectl apply -f "${WORK_DIR}/netpol-check.yaml" || fail "kubectl apply the NetworkPolicy test namespace"
kubectl wait --for=condition=Ready pod/netpol-server pod/netpol-client \
  -n "${NETPOL_NS}" --timeout=120s \
  || fail "netpol-server or netpol-client did not become Ready in ${NETPOL_NS}"

NETPOL_SERVER_IP="$(kubectl get pod netpol-server -n "${NETPOL_NS}" -o jsonpath='{.status.podIP}')"
[[ -n "${NETPOL_SERVER_IP}" ]] || fail "netpol-server has no pod IP"

client_reaches_server() {
  kubectl exec -n "${NETPOL_NS}" netpol-client -- \
    wget -q -O /dev/null -T 3 "http://${NETPOL_SERVER_IP}:8080/" >/dev/null 2>&1
}
wait_until 60 5 "client reaches server before any NetworkPolicy" client_reaches_server \
  || fail "netpol-client cannot reach netpol-server before any NetworkPolicy is applied"
pass "client pod reaches the server pod before any NetworkPolicy is applied"

cat >"${WORK_DIR}/netpol-deny.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: ${NETPOL_NS}
spec:
  podSelector:
    matchLabels:
      role: netpol-server
  policyTypes:
    - Ingress
YAML
kubectl apply -f "${WORK_DIR}/netpol-deny.yaml" || fail "kubectl apply the deny-all ingress NetworkPolicy"

client_blocked() { ! client_reaches_server; }
wait_until 60 5 "deny-all NetworkPolicy blocks client-to-server traffic" client_blocked \
  || fail "netpol-client still reaches netpol-server after a deny-all ingress NetworkPolicy was applied"
pass "a deny-all ingress NetworkPolicy blocks traffic that worked before it was applied"

kubectl delete namespace "${NETPOL_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

# ------------------------------------- 4. Karpenter from the outputs only

# The Karpenter controller tolerates CriticalAddonsOnly and runs on a system
# node, which (3b above) now rejects a hop count beyond 1, so the controller
# can no longer reach IMDS to discover its own Region the way it does by
# default. The chart's "Additional environment variables for the controller
# pod" field is controller.env (values.yaml ships it commented out as
# `# - name: AWS_REGION` / `#   value: eu-west-1`); set it explicitly instead
# of relying on IMDS.
cat >"${WORK_DIR}/karpenter-values.yaml" <<YAML
serviceAccount:
  name: karpenter
settings:
  clusterName: ${CLUSTER}
  interruptionQueue: ${QUEUE_NAME}
controller:
  env:
    - name: AWS_REGION
      value: ${AWS_REGION}
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
YAML
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" --namespace kube-system \
  --values "${WORK_DIR}/karpenter-values.yaml" --wait --timeout 10m \
  || fail "helm install karpenter ${KARPENTER_VERSION}"
pass "Karpenter ${KARPENTER_VERSION} installed in kube-system with service account karpenter, controller.env AWS_REGION=${AWS_REGION}"

types_yaml="$(printf '%s' "${E2E_INSTANCE_TYPES}" | tr ',' '\n' | sed 's/^/            - /')"
cat >"${WORK_DIR}/karpenter-nodes.yaml" <<YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ${NODECLASS}
spec:
  role: ${NODE_ROLE}
  amiSelectorTerms:
    - alias: ${E2E_AMI_ALIAS}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER}
  tags:
    ${TEST_TAG_KEY}: ${RUN_ID}
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ${NODEPOOL}
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: ${NODECLASS}
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values:
${types_yaml}
      expireAfter: 720h
  limits:
    cpu: "16"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 1h
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        karpenter.sh/nodepool: ${NODEPOOL}
      containers:
        - name: pause
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.10
          resources:
            requests:
              cpu: 500m
              memory: 256Mi
YAML
kubectl apply -f "${WORK_DIR}/karpenter-nodes.yaml" || fail "kubectl apply EC2NodeClass, NodePool, Deployment"

nodeclass_ready() {
  [[ "$(kubectl get ec2nodeclass "${NODECLASS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}
wait_until 300 10 "EC2NodeClass Ready" nodeclass_ready \
  || fail "EC2NodeClass ${NODECLASS} not Ready: $(kubectl get ec2nodeclass "${NODECLASS}" -o jsonpath='{.status.conditions}')"
sg_count="$(kubectl get ec2nodeclass "${NODECLASS}" -o jsonpath='{.status.securityGroups[*].id}' | wc -w | tr -d ' ')"
subnet_count="$(kubectl get ec2nodeclass "${NODECLASS}" -o jsonpath='{.status.subnets[*].id}' | wc -w | tr -d ' ')"
[[ "${sg_count}" -ge 1 && "${subnet_count}" -ge 1 ]] \
  || fail "discovery tags matched ${subnet_count} subnet(s) and ${sg_count} security group(s)"
pass "EC2NodeClass Ready: discovery tags select ${subnet_count} subnet(s), ${sg_count} security group(s)"

# app_node: name of the node running the Ready app pod, empty if none.
app_node() {
  kubectl get pods -l "app=${APP}" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' \
    | awk '$2=="True" && $3=="" && !found {print $1; found=1}'
}
app_running() { [[ -n "$(app_node)" ]]; }
app_running_elsewhere() { local n; n="$(app_node)"; [[ -n "${n}" && "${n}" != "${NODE1}" ]]; }

# Checks that NODE comes from the test NodePool and is a spot instance; sets
# LAST_INSTANCE_ID and records it for the post-destroy check.
LAST_INSTANCE_ID=""
check_karpenter_spot_node() {
  local node="$1" iid lifecycle
  [[ "$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')" == "${NODEPOOL}" ]] \
    || fail "node ${node} is not from NodePool ${NODEPOOL}"
  iid="$(instance_of_node "${node}")"
  lifecycle="$(aws ec2 describe-instances --instance-ids "${iid}" \
    --query 'Reservations[0].Instances[0].InstanceLifecycle' --output text)"
  [[ "${lifecycle}" == "spot" ]] || fail "instance ${iid} lifecycle is ${lifecycle}, expected spot"
  KARPENTER_INSTANCE_IDS+=("${iid}")
  LAST_INSTANCE_ID="${iid}"
}

wait_until 900 15 "pending pod running on a Karpenter node" app_running \
  || fail "pod ${APP} did not run on a Karpenter node: $(kubectl get nodeclaims -o wide 2>&1)"
NODE1="$(app_node)"
check_karpenter_spot_node "${NODE1}"
INSTANCE1="${LAST_INSTANCE_ID}"
pass "pending pod runs on Karpenter spot node ${NODE1} ($(kubectl get node "${NODE1}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}'))"

# --------------------------------------- 5. synthetic spot interruption

QUEUE_URL="$(aws sqs get-queue-url --queue-name "${QUEUE_NAME}" --query QueueUrl --output text)" \
  || fail "aws sqs get-queue-url ${QUEUE_NAME}"
NODECLAIM1="$(kubectl get nodeclaims \
  -o jsonpath="{range .items[?(@.status.nodeName==\"${NODE1}\")]}{.metadata.name}{end}")"
[[ -n "${NODECLAIM1}" ]] || fail "no NodeClaim for node ${NODE1}"

# EventBridge envelope as Karpenter parses it: version "0", source aws.ec2,
# detail-type "EC2 Spot Instance Interruption Warning", detail.instance-id.
cat >"${WORK_DIR}/spot-interruption.json" <<JSON
{
  "version": "0",
  "id": "$(new_uuid)",
  "detail-type": "EC2 Spot Instance Interruption Warning",
  "source": "aws.ec2",
  "account": "${ACCOUNT_ID}",
  "time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "${AWS_REGION}",
  "resources": ["arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/${INSTANCE1}"],
  "detail": {
    "instance-id": "${INSTANCE1}",
    "instance-action": "terminate"
  }
}
JSON
aws sqs send-message --queue-url "${QUEUE_URL}" \
  --message-body "file://${WORK_DIR}/spot-interruption.json" >/dev/null \
  || fail "aws sqs send-message to the interruption queue"
info "sent a spot interruption warning for ${INSTANCE1} to ${QUEUE_NAME}"

INTERRUPTION_EVIDENCE=""
interruption_handled() {
  local dt logs
  if ! kubectl get nodeclaim "${NODECLAIM1}" >/dev/null 2>&1; then
    INTERRUPTION_EVIDENCE="NodeClaim ${NODECLAIM1} deleted"
    return 0
  fi
  dt="$(kubectl get nodeclaim "${NODECLAIM1}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)"
  if [[ -n "${dt}" ]]; then
    INTERRUPTION_EVIDENCE="NodeClaim ${NODECLAIM1} marked for deletion at ${dt}"
    return 0
  fi
  if kubectl get events -A --field-selector reason=SpotInterrupted -o name 2>/dev/null | grep -q .; then
    INTERRUPTION_EVIDENCE="event SpotInterrupted recorded"
    return 0
  fi
  logs="$(kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=-1 2>/dev/null)"
  if grep 'initiating delete from interruption message' <<<"${logs}" | grep -q spot_interrupted; then
    INTERRUPTION_EVIDENCE="Karpenter log: initiating delete from interruption message (spot_interrupted)"
    return 0
  fi
  return 1
}
wait_until 300 10 "Karpenter handles the interruption message" interruption_handled \
  || fail "Karpenter did not react to the interruption message within 300s"
pass "Karpenter received the interruption message: ${INTERRUPTION_EVIDENCE}"
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=-1 2>/dev/null \
  | grep -E 'interruption|SpotInterrupted' | tail -n 5 || true

# The Deployment brings the pod back on a replacement spot instance, so a
# Karpenter instance is running when terraform destroy starts.
wait_until 900 15 "pod running on a replacement Karpenter node" app_running_elsewhere \
  || fail "no replacement Karpenter node ran the pod after the interruption"
NODE2="$(app_node)"
check_karpenter_spot_node "${NODE2}"
INSTANCE2="${LAST_INSTANCE_ID}"
pass "replacement Karpenter spot node ${NODE2} runs the pod"

# ------------------------------- 6. destroy with Karpenter still running

running_karpenter="$(aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=${NODEPOOL}" \
  "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER}" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
[[ "${running_karpenter}" == *"${INSTANCE2}"* ]] \
  || fail "Karpenter instance ${INSTANCE2} is not running before destroy"
kubectl get nodepool "${NODEPOOL}" >/dev/null || fail "NodePool ${NODEPOOL} vanished before destroy"
helm status karpenter -n kube-system >/dev/null || fail "Karpenter release vanished before destroy"
pass "before destroy: NodePool, Karpenter release and instance(s) ${running_karpenter} in place"

destroy_start="$(date +%s)"
tf destroy -auto-approve -input=false -var-file="${TFVARS}" \
  || fail "terraform destroy with the NodePool and Karpenter still in place"
DESTROYED=1
pass "terraform destroy completed without manual steps ($(($(date +%s) - destroy_start))s)"

# ------------------------------------------------- 7. nothing left behind

# An ID this old can also fall out of EC2's own retention window and come
# back as InvalidInstanceID.NotFound; aws_text treats that the same as an
# empty result (the instance is gone), while any other failure (expired
# credentials, throttling) must not be read as "terminated".
instances_terminated() {
  local out states
  if ! out="$(aws_text aws ec2 describe-instances --instance-ids "${KARPENTER_INSTANCE_IDS[@]}" \
    --query 'Reservations[].Instances[].State.Name' --output text)"; then
    fail "checking Karpenter instance state: ${out}"
  fi
  states="$(printf '%s' "${out}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' | sort -u || true)"
  [[ -z "${states}" || "${states}" == "terminated" ]]
}
wait_until "${E2E_LEFTOVER_GRACE_SECONDS}" 20 "Karpenter instances terminated" instances_terminated \
  || fail "Karpenter instance(s) ${KARPENTER_INSTANCE_IDS[*]} not terminated after destroy"
pass "Karpenter instance(s) ${KARPENTER_INSTANCE_IDS[*]} terminated"

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" \
  || fail "resources tagged for the cluster remain after destroy"

# describe-vpcs on a gone VPC returns InvalidVpcID.NotFound (empty text,
# success); any other failure must not be read as "the VPC is gone".
if ! vpc_check_out="$(aws_text aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].VpcId' --output text)"; then
  fail "checking whether VPC ${VPC_ID} still exists: ${vpc_check_out}"
fi
if [[ -n "${vpc_check_out}" && "${vpc_check_out}" != "None" ]]; then
  fail "VPC ${VPC_ID} still exists after destroy"
fi
pass "VPC removed"
