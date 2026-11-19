#!/usr/bin/env bash
# End-to-end test of the foundation layer on a real AWS account.
#
# It uses only the variables and outputs of infra/foundation:
#   1. init with the S3 backend, check the state has no resources yet, apply
#      with a generated tfvars file;
#   2. two Ready system nodes, four add-ons ACTIVE, outputs present
#      (including cluster_arn/argocd_namespace, issue #25 decision 1); with
#      argocd set, the capability's own IAM role has an AmazonEKSClusterAdminPolicy
#      access-policy association (issue #25 decision 1);
#   3. a pod without host networking on a system node cannot obtain an
#      IMDSv2 token, and the system nodes require IMDSv2 with a hop limit
#      of 1;
#   4. the Karpenter node role and the system node role carry no
#      AmazonEKS_CNI_Policy, aws-node has a Pod Identity association, and a
#      pod without host networking still gets an IP address;
#   5. a deny-all NetworkPolicy blocks pod-to-pod traffic that worked before
#      the policy was applied;
#   6. terraform destroy;
#   7. nothing tagged for the cluster is left (instance, ENI, NAT, EBS).
#
# Every check prints PASS or FAIL. The script exits non-zero on the first
# failed step and always attempts to destroy what it created (EXIT trap).
#
# Karpenter itself is not installed by this test. Issue #25 (the delivery
# layer) moved "Karpenter healthy, a NodePool launches a node" to
# gitops/tests/1.e2e.sh, which installs Karpenter through the managed Argo
# CD capability instead of a stand-in `helm install` here (Decision 9: "the
# foundation e2e's stand-in Karpenter install is removed"). This script still
# proves the foundation layer's own contract: the outputs Karpenter will
# need (karpenter_node_role_name, karpenter_interruption_queue_name) exist
# and are well-formed, and the node role carries no CNI permissions,
# independent of anything that later runs on top of it.
#
# Required environment (export before running):
#   AWS_PROFILE, AWS_REGION, NAME, STATE_BUCKET, STATE_REGION,
#   ADMIN_PRINCIPAL_ARN, MY_CIDR
# Optional environment:
#   TERRAFORM (terraform), E2E_WORK_DIR (mktemp -d),
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

STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="e2e-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
IMDS_POD="e2e-imds-check"
NETPOL_NS="e2e-netpol-${RUN_ID#e2e-}"
ADDONS=(vpc-cni coredns kube-proxy eks-pod-identity-agent)

APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
VPC_ID=""

# ---------------------------------------------------------------- helpers

# shellcheck source=e2e-lib.sh
source "${SCRIPT_DIR}/e2e-lib.sh"

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
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

# ------------------------------------------------------------ preflight

for b in "${TERRAFORM}" aws kubectl; do require_bin "${b}"; done
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
  || fail "MY_CIDR must be an IPv4 CIDR, got ${MY_CIDR}"
aws sts get-caller-identity --query Account --output text >/dev/null \
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
  karpenter_node_role_name karpenter_interruption_queue_name cluster_arn; do
  v="$(tf_out "${o}" 2>/dev/null)" || fail "output ${o} is missing"
  [[ -n "${v}" ]] || fail "output ${o} is empty"
done
[[ "$(tf output -json private_subnet_ids)" == *subnet-* ]] || fail "output private_subnet_ids has no subnet"
# Terraform omits a root output from state entirely when its value is exactly
# null (confirmed on 1.17.2), so `terraform output -json <name>` then fails
# with "Output ... not found" instead of printing null. outputs.tf uses
# try(aws_eks_capability.argocd[0].arn, null) for argocd_capability_arn and
# try(aws_eks_capability.argocd[0]...namespace, null) for argocd_namespace
# (issue #25 decision 1), matching the README contract ("null when not
# created") for both -- so that failure means the same thing as null here.
# Neither can go in the blanket "must be non-empty" loop above: both are
# genuinely null in the common, lighter default run (ARGOCD_* unset, no
# capability created), which the loop would otherwise always fail.
argocd_arn_json="$(tf output -json argocd_capability_arn 2>/dev/null)" || argocd_arn_json="null"
argocd_namespace_json="$(tf output -json argocd_namespace 2>/dev/null)" || argocd_namespace_json="null"
if [[ "${ARGOCD_JSON}" == "null" ]]; then
  [[ "${argocd_arn_json}" == "null" ]] || fail "argocd_capability_arn is not null while argocd is unset"
  [[ "${argocd_namespace_json}" == "null" ]] || fail "argocd_namespace is not null while argocd is unset"
else
  [[ "${argocd_arn_json}" != "null" ]] || fail "argocd_capability_arn is missing while argocd is set"
  [[ "${argocd_namespace_json}" != "null" ]] || fail "argocd_namespace is missing while argocd is set"
fi
pass "all thirteen outputs present"

# cluster_arn (issue #25 decision 1) is the value the delivery layer's
# bootstrap script writes verbatim into the registration Secret's `server`
# field: it must be the cluster's own ARN, never an API server URL.
CLUSTER_ARN="$(tf_out cluster_arn)"
[[ "${CLUSTER_ARN}" =~ ^arn:[^:]+:eks:${AWS_REGION}:[0-9]{12}:cluster/${NAME}$ ]] \
  || fail "output cluster_arn (${CLUSTER_ARN}) is not an EKS cluster ARN for ${AWS_REGION}/${NAME}"
pass "output cluster_arn is a well-formed EKS cluster ARN for ${AWS_REGION}/${NAME}"

CLUSTER="$(tf_out cluster_name)"
VPC_ID="$(tf_out vpc_id)"
NODE_ROLE="$(tf_out karpenter_node_role_name)"
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

  # Issue #25 decision 1: this layer's argocd.tf also creates one
  # aws_eks_access_policy_association binding the capability's own IAM role
  # to AmazonEKSClusterAdminPolicy at type=cluster, since the capability's
  # access entry carries only the two built-in Argo-CD-capability-
  # management policies by default (AmazonEKSArgoCDClusterPolicy,
  # AmazonEKSArgoCDPolicy -- confirmed on a real cluster), never
  # AmazonEKSClusterAdminPolicy. No Terraform *output*
  # exposes the capability role's ARN (the association is a direct Terraform
  # resource reference the RFC says nothing else needs to read) -- but
  # DescribeCapability's own response carries the capability's roleArn
  # directly, so find it there rather than by elimination over
  # list-access-entries: argocd.tf names the role
  # "${var.name}-argocd-capability", which embeds NAME, the same substring
  # an elimination-by-NAME approach would use to skip node/Karpenter roles,
  # so it would skip the very entry this check needs (this is exactly the
  # bug gitops/tests/1.e2e.sh's own identical check hit and fixed first;
  # ported here).
  capability_role_arn="$(aws eks describe-capability --cluster-name "${CLUSTER}" \
    --capability-name "${ARGOCD_CAPABILITY_NAME}" --query 'capability.roleArn' --output text)" \
    || fail "aws eks describe-capability --cluster-name ${CLUSTER} --capability-name ${ARGOCD_CAPABILITY_NAME}"
  [[ -n "${capability_role_arn}" && "${capability_role_arn}" != "None" ]] \
    || fail "capability ${ARGOCD_CAPABILITY_NAME} has no roleArn"
  capability_policies="$(aws eks list-associated-access-policies --cluster-name "${CLUSTER}" \
    --principal-arn "${capability_role_arn}" --query 'associatedAccessPolicies[].policyArn' --output text)" \
    || fail "aws eks list-associated-access-policies --principal-arn ${capability_role_arn}"
  [[ "${capability_policies}" == *"AmazonEKSClusterAdminPolicy"* ]] \
    || fail "capability role ${capability_role_arn} has no AmazonEKSClusterAdminPolicy association: [${capability_policies}]"
  pass "Argo CD capability role has an AmazonEKSClusterAdminPolicy access-policy association"
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

# ------------------------------------------------------- 4. terraform destroy
#
# No Karpenter-launched node exists in this test (Issue #25 moved that
# coverage to gitops/tests/1.e2e.sh), so destroy only has to remove the
# foundation's own resources: the system node group, add-ons, VPC, IAM
# roles and the interruption queue/EventBridge rules.

destroy_start="$(date +%s)"
tf destroy -auto-approve -input=false -var-file="${TFVARS}" \
  || fail "terraform destroy"
DESTROYED=1
pass "terraform destroy completed without manual steps ($(($(date +%s) - destroy_start))s)"

# ------------------------------------------------- 5. nothing left behind

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" \
  || fail "resources tagged for the cluster remain after destroy"

assert_vpc_gone
