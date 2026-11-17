#!/usr/bin/env bash
# End-to-end test of the foundation layer on a real AWS account.
#
# It uses only the variables and outputs of infra/foundation:
#   1. init with the S3 backend, apply with a generated tfvars file;
#   2. two Ready system nodes, four add-ons ACTIVE, outputs present;
#   3. Karpenter v1.15.x installed by Helm from the outputs only;
#   4. a spot CPU NodePool launches an instance for a pending pod;
#   5. a synthetic spot interruption sent to the queue is handled;
#   6. terraform destroy with the NodePool and Karpenter still in place;
#   7. nothing tagged for the cluster is left (instance, ENI, NAT, EBS).
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
#   (all three set: also create and check the Argo CD capability).
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
TFVARS="${WORK_DIR}/e2e.tfvars.json"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1

STATE_KEY="distai-platform/${NAME}/foundation"
RUN_ID="e2e-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
NODEPOOL="e2e-spot"
NODECLASS="e2e-cpu"
APP="e2e-inflate"
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
list_leftover() {
  local kind="$1" filter
  {
    while IFS= read -r filter; do
      case "${kind}" in
        instance)
          aws ec2 describe-instances --filters "${filter}" \
            "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
            --query 'Reservations[].Instances[].InstanceId' --output text ;;
        eni)
          aws ec2 describe-network-interfaces --filters "${filter}" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' --output text ;;
        nat)
          aws ec2 describe-nat-gateways --filter "${filter}" \
            "Name=state,Values=pending,available,deleting" \
            --query 'NatGateways[].NatGatewayId' --output text ;;
        volume)
          aws ec2 describe-volumes --filters "${filter}" \
            --query 'Volumes[].VolumeId' --output text ;;
      esac
    done < <(tag_filters)
    if [[ -n "${VPC_ID}" ]]; then
      case "${kind}" in
        instance)
          aws ec2 describe-instances --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
            --query 'Reservations[].Instances[].InstanceId' --output text ;;
        eni)
          aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' --output text ;;
        nat)
          aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" \
            "Name=state,Values=pending,available,deleting" \
            --query 'NatGateways[].NatGatewayId' --output text ;;
        volume) : ;;
      esac
    fi
  } 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' | sort -u || true
}

no_leftover() { [[ -z "$(list_leftover "$1")" ]]; }

# report_leftovers GRACE_SECONDS: PASS/FAIL per kind, returns 1 if any remains.
report_leftovers() {
  local grace="$1" kind ids bad=0
  for kind in instance eni nat volume; do
    if wait_until "${grace}" 20 "no ${kind} left" no_leftover "${kind}"; then
      pass "no ${kind} tagged for the cluster remains"
    else
      ids="$(list_leftover "${kind}" | tr '\n' ' ')"
      log "FAIL ${kind} left after destroy: ${ids}"
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

ARGOCD_JSON="null"
if [[ -n "${ARGOCD_IDC_INSTANCE_ARN}" && -n "${ARGOCD_IDC_REGION}" && -n "${ARGOCD_ADMIN_GROUP_IDS}" ]]; then
  groups_json="$(printf '%s' "${ARGOCD_ADMIN_GROUP_IDS}" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}}')"
  ARGOCD_JSON="{\"idc_instance_arn\":\"${ARGOCD_IDC_INSTANCE_ARN}\",\"idc_region\":\"${ARGOCD_IDC_REGION}\",\"admin_group_ids\":[${groups_json}]}"
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
  || fail "terraform init with the S3 backend (key ${STATE_KEY})"
pass "terraform init with the S3 backend, key ${STATE_KEY}"

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
fi

# ------------------------------------- 4. Karpenter from the outputs only

cat >"${WORK_DIR}/karpenter-values.yaml" <<YAML
serviceAccount:
  name: karpenter
settings:
  clusterName: ${CLUSTER}
  interruptionQueue: ${QUEUE_NAME}
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
YAML
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" --namespace kube-system \
  --values "${WORK_DIR}/karpenter-values.yaml" --wait --timeout 10m \
  || fail "helm install karpenter ${KARPENTER_VERSION}"
pass "Karpenter ${KARPENTER_VERSION} installed in kube-system with service account karpenter"

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

instance_of_node() {
  kubectl get node "$1" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}'
}

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

instances_terminated() {
  local states
  states="$(aws ec2 describe-instances --instance-ids "${KARPENTER_INSTANCE_IDS[@]}" \
    --query 'Reservations[].Instances[].State.Name' --output text 2>/dev/null | tr '\t' '\n' | sort -u)"
  [[ -z "${states}" || "${states}" == "terminated" ]]
}
wait_until "${E2E_LEFTOVER_GRACE_SECONDS}" 20 "Karpenter instances terminated" instances_terminated \
  || fail "Karpenter instance(s) ${KARPENTER_INSTANCE_IDS[*]} not terminated after destroy"
pass "Karpenter instance(s) ${KARPENTER_INSTANCE_IDS[*]} terminated"

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" \
  || fail "resources tagged for the cluster remain after destroy"

if aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" >/dev/null 2>&1; then
  fail "VPC ${VPC_ID} still exists after destroy"
fi
pass "VPC removed"
