#!/usr/bin/env bash
# Real-hardware check of the two Kubernetes-native primitives the tenancy
# RFC (#22) builds its own per-team isolation on top of, independent of
# whether #22's own Argo CD AppProject/admin-envelope machinery exists yet
# (it does not -- see issue #57 item 1 and #22 Decision 10 H11):
#
#   1. a namespace-scoped ServiceAccount+Role+RoleBinding (the "team
#      credential" #22 Decision 1's admin-owned envelope will eventually
#      create per team) can create a workload inside its own namespace and
#      is denied, by the real API server, in a namespace it was not bound
#      in -- "a team installs into its own namespace, and cannot install
#      outside it" (the required self-service check for a team's own namespace);
#   2. a Kueue ClusterQueue's nominalQuota actually holds a second Job back
#      while a first one is still running inside it, on a real cluster with
#      real pods -- issue #56's own accelerator-specific version of this
#      (a real Workload meeting a real quota) is checked separately by
#      gitops/tests/1.e2e.sh step 11 with GITOPS_RUN_ACCEL_E2E=1; this
#      script checks the same Kueue mechanism on plain CPU, cheaply and
#      without Karpenter/accelerator pools, since the quota mechanism
#      itself does not depend on which resource is being counted.
#
# This script builds only infra/foundation (no Argo CD capability, no
# Karpenter NodePool) and installs Kueue directly with `helm install`,
# using gitops/addons/kueue/addon.yaml's own pinned chart/version/values
# verbatim (comment there explains the toleration/affinity) -- it does not
# exercise gitops/ delivery (Argo CD) at all, which gitops/tests/1.e2e.sh
# already covers; it exists to check the RBAC+Kueue primitives on their
# own, without needing the full delivery layer or an accelerator pool to
# stand up first.
#
# RUN_ACCEL_TAINT_CHECK=1 adds one more, opt-in section (2b): a real
# Karpenter + gitops/charts/capacity-pool NodePool with an accelerator
# taint (nvidia.com/gpu, g7/g6e/g5, pool.capacityType=flex -- spot or
# on-demand, whichever Karpenter actually launches; this script reads the
# real node's own karpenter.sh/capacity-type label rather than assuming
# spot). Checks that a pod with no toleration for the taint never gets
# scheduled onto a NodePool that already has a real, Ready node running
# (not merely "no node exists yet", which would stay Pending either way)
# while a pod that does tolerate it reaches Running on a real EC2
# instance that NodePool launched. This does not install the
# nvidia-device-plugin addon or request the nvidia.com/gpu extended
# resource itself -- it checks the taint mechanism issue #56 needed,
# independent of the device plugin/GPU driver path, which issue #19/#28's
# own E0-E4 experiments already verified on real g7.2xlarge/trn2.3xlarge
# hardware, and which gitops/tests/1.e2e.sh step 11/11b checks together
# with Kueue admission end to end with the GITOPS_RUN_ACCEL_E2E=1
# environment variable set.
#
# Required environment (export before running):
#   AWS_PROFILE, AWS_REGION, NAME, STATE_BUCKET, STATE_REGION,
#   ADMIN_PRINCIPAL_ARN, MY_CIDR
# Optional environment:
#   TERRAFORM (terraform), HELM (helm), E2E_WORK_DIR (mktemp -d),
#   E2E_KEEP_ON_FAILURE (0), E2E_LEFTOVER_GRACE_SECONDS (600),
#   RUN_ACCEL_TAINT_CHECK (0), ACCEL_POD_TIMEOUT_SECONDS (900 -- how long
#   the tolerating pod in section 2b may take to reach Running, spot
#   launch included; only read when RUN_ACCEL_TAINT_CHECK=1)
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
HELM="${HELM:-helm}"
E2E_KEEP_ON_FAILURE="${E2E_KEEP_ON_FAILURE:-0}"
E2E_LEFTOVER_GRACE_SECONDS="${E2E_LEFTOVER_GRACE_SECONDS:-600}"
RUN_ACCEL_TAINT_CHECK="${RUN_ACCEL_TAINT_CHECK:-0}"
[[ "${RUN_ACCEL_TAINT_CHECK}" == "0" || "${RUN_ACCEL_TAINT_CHECK}" == "1" ]] \
  || { echo "RUN_ACCEL_TAINT_CHECK must be 0 or 1, got '${RUN_ACCEL_TAINT_CHECK}'" >&2; exit 2; }
ACCEL_POD_TIMEOUT_SECONDS="${ACCEL_POD_TIMEOUT_SECONDS:-900}"

# Kueue chart pin, copied verbatim from gitops/addons/kueue/addon.yaml
# (chart source https://github.com/kubernetes-sigs/kueue tag v0.20.6; do
# not let this drift from that file without updating both).
KUEUE_CHART="oci://registry.k8s.io/kueue/charts/kueue"
KUEUE_VERSION="0.20.6"

# Karpenter chart pins, copied verbatim from gitops/addons/karpenter-crd/
# addon.yaml and gitops/addons/karpenter/addon.yaml (chart source
# https://github.com/aws/karpenter-provider-aws tag v1.15.2). Only read
# when RUN_ACCEL_TAINT_CHECK=1 (section 2b).
KARPENTER_CRD_CHART="oci://public.ecr.aws/karpenter/karpenter-crd"
KARPENTER_CHART="oci://public.ecr.aws/karpenter/karpenter"
KARPENTER_VERSION="1.15.2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/../.." && pwd)"
WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
TFVARS="${WORK_DIR}/e2e.tfvars.json"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1

STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="e2e-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
TEAM_A_NS="team-a-${RUN_ID#e2e-}"
TEAM_B_NS="team-b-${RUN_ID#e2e-}"

APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
# shellcheck disable=SC2034 # read by e2e-lib.sh's own list_leftover/assert_vpc_gone as a global of the calling script, not referenced again in this file directly (same pattern as infra/foundation/tests/1.e2e.sh, which also only assigns it for e2e-lib.sh's own global read; 2.e2e-partial-apply.sh references VPC_ID directly in its own file and so does not trigger this warning)
VPC_ID=""

# shellcheck source=e2e-lib.sh
# shellcheck disable=SC1091 # SCRIPT_DIR is computed at runtime; shellcheck cannot follow it statically (same info-level notice infra/foundation/tests/1.e2e.sh and infra/foundation/tests/2.e2e-partial-apply.sh already carry)
source "${SCRIPT_DIR}/e2e-lib.sh"

# On a mid-run failure, this cleanup deletes the two team namespaces and
# (when RUN_ACCEL_TAINT_CHECK=1 reached section 2b) the accelerator
# NodePool/NodeClaim objects on a best-effort basis, then always calls
# `terraform destroy` regardless. The backstop for a Karpenter-launched
# EC2 instance (and its launch template and instance profile) that this
# best-effort delete misses -- for example a crash before the NodePool
# object even exists, or a NodeClaim stuck mid-launch -- is
# infra/foundation's own `terraform_data.teardown_guard`
# (infra/foundation/teardown.tf and infra/foundation/scripts/teardown-guard.sh): its own
# header states it "terminates the Karpenter instances, waits until they
# are terminated, and deletes their detached network interfaces, launch
# templates and instance profiles", unconditionally, as part of
# `terraform destroy` -- not something this script has to reimplement.
# The same `terraform_data.teardown_guard`'s partial-apply path (destroy
# after an apply that failed before the guard itself was even created)
# has its own dedicated regression test, issue #26's
# infra/foundation/tests/2.e2e-partial-apply.sh, which this PR does not
# modify -- that test does not launch a Karpenter instance itself (this
# layer alone runs no Karpenter), so it covers the guard's own
# partial-apply logic, not specifically "a Karpenter-launched instance
# mid-launch" the way this comment's own next paragraph describes; this
# script relies on the guard rather than re-proving either case. What
# this script's own real runs actually observed: the
# two real failures this script's own development hit (a `helm
# uninstall` that timed out with a live NodeClaim/ResourceFlavor still
# present, i.e. after the instance was already Running) both show "no
# instance tagged for the cluster remains" in the leftover sweep this
# same cleanup() runs below -- this script did not separately force and
# observe the earlier failure mode (a NodeClaim still launching, not yet
# Running, when cleanup fires).
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
        kubectl delete namespace "${TEAM_A_NS}" --ignore-not-found --wait=false >/dev/null 2>&1
        kubectl delete namespace "${TEAM_B_NS}" --ignore-not-found --wait=false >/dev/null 2>&1
        if [[ -n "${ACCEL_POOL:-}" ]]; then
          kubectl delete nodepool "${ACCEL_POOL}" --ignore-not-found --wait=false >/dev/null 2>&1
          kubectl delete ec2nodeclass "${ACCEL_POOL}" --ignore-not-found --wait=false >/dev/null 2>&1
          kubectl delete resourceflavor "${ACCEL_POOL}" --ignore-not-found --wait=false >/dev/null 2>&1
        fi
      fi
      tf destroy -auto-approve -input=false -var-file="${TFVARS}"
      local destroy_rc=$?
      if [[ "${destroy_rc}" -ne 0 ]]; then
        log "FAIL cleanup: terraform destroy exited ${destroy_rc}; remove the cell by hand"
      else
        info "cleanup: terraform destroy completed (terraform_data.teardown_guard runs as part of it; see the leftover sweep below for what is actually confirmed gone)"
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

for b in "${TERRAFORM}" "${HELM}" aws kubectl; do require_bin "${b}"; done
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
  || fail "MY_CIDR must be an IPv4 CIDR, got ${MY_CIDR}"
aws sts get-caller-identity --query Account --output text >/dev/null \
  || fail "aws sts get-caller-identity (check AWS_PROFILE and credentials)"
pass "preflight: tools present, credentials valid"
info "run ${RUN_ID}, work dir ${WORK_DIR}"

# ------------------------------------------------- 1. foundation apply

cat >"${TFVARS}" <<JSON
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "argocd": null,
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

CLUSTER="$(tf_out cluster_name)"
# shellcheck disable=SC2034 # read by e2e-lib.sh's own list_leftover/assert_vpc_gone as a global of the calling script (same pattern infra/foundation/tests/1.e2e.sh already carries; 2.e2e-partial-apply.sh references VPC_ID directly in its own file and so does not)
VPC_ID="$(tf_out vpc_id)"
[[ "${CLUSTER}" == "${NAME}" ]] || fail "cluster_name (${CLUSTER}) differs from var.name (${NAME})"

aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}" \
  --kubeconfig "${KUBECONFIG}" >/dev/null || fail "aws eks update-kubeconfig"
kubectl get --raw /readyz >/dev/null || fail "kubectl cannot reach the cluster as ADMIN_PRINCIPAL_ARN"
pass "kubectl reaches the cluster through the access entry"

ready_system_nodes() {
  kubectl get nodes -l eks.amazonaws.com/nodegroup \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2=="True"' | wc -l | tr -d ' '
}
at_least_one_ready_system_node() { [[ "$(ready_system_nodes)" -ge 1 ]]; }
wait_until 600 15 "a Ready system node" at_least_one_ready_system_node \
  || fail "expected at least one Ready system node, found $(ready_system_nodes)"
pass "kubectl get nodes: system node(s) Ready"

# ------------------------------------------------- 2. install Kueue

"${HELM}" install kueue "${KUEUE_CHART}" --version "${KUEUE_VERSION}" \
  --namespace kueue-system --create-namespace --wait --timeout 5m \
  --set "controllerManager.tolerations[0].key=CriticalAddonsOnly" \
  --set "controllerManager.tolerations[0].operator=Exists" \
  --set-string "controllerManager.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=karpenter.sh/nodepool" \
  --set "controllerManager.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=DoesNotExist" \
  || fail "helm install kueue ${KUEUE_VERSION}"
pass "helm install kueue ${KUEUE_VERSION} reached Healthy (--wait)"

# ------------------------------------------------- 2b. (opt-in) a real
# -------------------------------------------------     accelerator taint

if [[ "${RUN_ACCEL_TAINT_CHECK}" == "1" ]]; then
  "${HELM}" install karpenter-crd "${KARPENTER_CRD_CHART}" --version "${KARPENTER_VERSION}" \
    --namespace kube-system --wait --timeout 3m \
    || fail "helm install karpenter-crd ${KARPENTER_VERSION}"
  pass "helm install karpenter-crd ${KARPENTER_VERSION}"

  KARPENTER_INTERRUPTION_QUEUE="$(tf_out karpenter_interruption_queue_name)"
  "${HELM}" install karpenter "${KARPENTER_CHART}" --version "${KARPENTER_VERSION}" \
    --namespace kube-system --skip-crds --wait --timeout 5m \
    --set serviceAccount.name=karpenter \
    --set settings.clusterName="${CLUSTER}" \
    --set settings.interruptionQueue="${KARPENTER_INTERRUPTION_QUEUE}" \
    --set "controller.env[0].name=AWS_REGION" \
    --set "controller.env[0].value=${AWS_REGION}" \
    --set "controller.tolerations[0].key=CriticalAddonsOnly" \
    --set "controller.tolerations[0].operator=Exists" \
    || fail "helm install karpenter ${KARPENTER_VERSION}"
  pass "helm install karpenter ${KARPENTER_VERSION} reached Healthy (--wait), interruption queue ${KARPENTER_INTERRUPTION_QUEUE}"

  ACCEL_POOL="gpu-taint-${RUN_ID#e2e-}"
  NODE_ROLE="$(tf_out karpenter_node_role_name)"
  "${HELM}" install "${ACCEL_POOL}" "${REPO_ROOT}/gitops/charts/capacity-pool" \
    --namespace kube-system \
    --set clusterName="${CLUSTER}" \
    --set nodeRole="${NODE_ROLE}" \
    --set pool.name="${ACCEL_POOL}" \
    --set pool.capacityType=flex \
    --set "pool.requirements[0].key=kubernetes.io/arch" \
    --set "pool.requirements[0].operator=In" \
    --set-string "pool.requirements[0].values[0]=amd64" \
    --set "pool.requirements[1].key=karpenter.k8s.aws/instance-family" \
    --set "pool.requirements[1].operator=In" \
    --set-string "pool.requirements[1].values[0]=g7" \
    --set-string "pool.requirements[1].values[1]=g6e" \
    --set-string "pool.requirements[1].values[2]=g5" \
    --set "accelerator.resourceName=nvidia.com/gpu" \
    --set "accelerator.taint.key=nvidia.com/gpu" \
    --set-string "accelerator.taint.value=true" \
    --set "accelerator.taint.effect=NoSchedule" \
    || fail "helm install ${ACCEL_POOL} (gitops/charts/capacity-pool)"
  # Read the rendered objects back rather than trusting helm's own exit
  # code: the NodePool's template-level taint, the
  # EC2NodeClass and the ResourceFlavor (same name as the NodePool, per
  # the chart's own resourceflavor.yaml) must all actually exist with the
  # taint this test depends on.
  RENDERED_TAINT="$(kubectl get nodepool "${ACCEL_POOL}" \
    -o jsonpath='{.spec.template.spec.taints[?(@.key=="nvidia.com/gpu")].effect}' 2>/dev/null)"
  [[ "${RENDERED_TAINT}" == "NoSchedule" ]] \
    || fail "NodePool ${ACCEL_POOL} does not carry the nvidia.com/gpu:NoSchedule taint in its own spec.template.spec.taints (got: ${RENDERED_TAINT})"
  kubectl get ec2nodeclass "${ACCEL_POOL}" >/dev/null 2>&1 \
    || fail "EC2NodeClass ${ACCEL_POOL} was not created by the capacity-pool release"
  kubectl get resourceflavor "${ACCEL_POOL}" >/dev/null 2>&1 \
    || fail "ResourceFlavor ${ACCEL_POOL} was not created by the capacity-pool release"
  pass "helm install ${ACCEL_POOL}: NodePool ${ACCEL_POOL} (read back) carries the nvidia.com/gpu=true:NoSchedule taint; its EC2NodeClass and ResourceFlavor both exist; node role ${NODE_ROLE}"

  # 2b-i (checked first): a pod WITH the matching toleration and a
  # nodeAffinity on karpenter.sh/nodepool (never a bare nodeSelector alone
  # -- #22 Decision 10's own distinction) must actually launch a real EC2
  # node through Karpenter and reach Running -- the real-traffic half of
  # the check (apply, then a real instance launches, then a real
  # container runs on it). Checked before 2b-ii on purpose: 2b-ii's own
  # negative result (stays Pending) is only meaningful once a real, Ready
  # node from this exact NodePool already exists -- otherwise "stays
  # Pending" is indistinguishable from "Karpenter has not finished
  # launching anything yet" (found in this script's own first real run,
  # which checked the negative case with zero nodes up and a 30s
  # timeout).
  cat >"${WORK_DIR}/accel-with-toleration.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: accel-with-toleration
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: karpenter.sh/nodepool
                operator: In
                values: ["${ACCEL_POOL}"]
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: probe
      image: public.ecr.aws/docker/library/busybox:1.37
      command: ["sh", "-c", "sleep 300"]
      resources:
        requests:
          cpu: 100m
          memory: 32Mi
YAML
  kubectl apply -f "${WORK_DIR}/accel-with-toleration.yaml" || fail "kubectl apply accel-with-toleration"
  with_toleration_running() {
    [[ "$(kubectl get pod accel-with-toleration -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]
  }
  wait_until "${ACCEL_POD_TIMEOUT_SECONDS}" 15 "accel-with-toleration Running on a real ${ACCEL_POOL} node" with_toleration_running \
    || fail "accel-with-toleration never reached Running within ${ACCEL_POD_TIMEOUT_SECONDS}s: $(kubectl get pod accel-with-toleration -o json 2>&1 | tr '\n' ' ')"
  ACCEL_NODE="$(kubectl get pod accel-with-toleration -o jsonpath='{.spec.nodeName}')"
  ACCEL_NODE_TAINT="$(kubectl get node "${ACCEL_NODE}" -o jsonpath='{.spec.taints[?(@.key=="nvidia.com/gpu")].effect}' 2>/dev/null)"
  [[ "${ACCEL_NODE_TAINT}" == "NoSchedule" ]] \
    || fail "node ${ACCEL_NODE} (where the tolerating pod actually landed) does not carry the nvidia.com/gpu:NoSchedule taint (${ACCEL_NODE_TAINT})"
  ACCEL_NODE_READY="$(kubectl get node "${ACCEL_NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [[ "${ACCEL_NODE_READY}" == "True" ]] \
    || fail "node ${ACCEL_NODE} has a Running pod on it but its own Ready condition is '${ACCEL_NODE_READY}', not True"
  ACCEL_NODE_CAPACITY_TYPE="$(kubectl get node "${ACCEL_NODE}" -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}' 2>/dev/null)"
  ACCEL_NODE_INSTANCE_ID="$(kubectl get node "${ACCEL_NODE}" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
  pass "a pod tolerating nvidia.com/gpu=true:NoSchedule reached Running on real, Ready node ${ACCEL_NODE} (instance ${ACCEL_NODE_INSTANCE_ID}, capacity-type ${ACCEL_NODE_CAPACITY_TYPE:-unknown}), a real EC2 instance Karpenter launched from the ${ACCEL_POOL} NodePool, which itself still carries the taint"

  # 2b-ii: a pod with NO toleration, explicitly aimed at this same
  # NodePool (and therefore at ${ACCEL_NODE}, the only node it has),
  # checked now that a real, Ready node from it exists: it must stay
  # Pending (PodScheduled=False, reason Unschedulable) and Karpenter must
  # not have launched a second NodeClaim to try to satisfy it either --
  # the taint repels it outright rather than Karpenter provisioning
  # another (also tainted) node that it then also cannot use.
  NODECLAIM_COUNT_BEFORE="$(kubectl get nodeclaim -l karpenter.sh/nodepool="${ACCEL_POOL}" -o name 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${NODECLAIM_COUNT_BEFORE}" -ge 1 ]] \
    || fail "expected at least one NodeClaim for ${ACCEL_POOL} (the one accel-with-toleration's own node came from), found ${NODECLAIM_COUNT_BEFORE} -- the selector itself may be wrong, which would make the 'unchanged count' check below pass for the wrong reason"
  cat >"${WORK_DIR}/accel-no-toleration.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: accel-no-toleration
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: karpenter.sh/nodepool
                operator: In
                values: ["${ACCEL_POOL}"]
  containers:
    - name: probe
      image: public.ecr.aws/docker/library/busybox:1.37
      command: ["sh", "-c", "sleep 30"]
      resources:
        requests:
          cpu: 100m
          memory: 32Mi
YAML
  kubectl apply -f "${WORK_DIR}/accel-no-toleration.yaml" || fail "kubectl apply accel-no-toleration"
  sleep 30
  NO_TOLERATION_PHASE="$(kubectl get pod accel-no-toleration -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "${NO_TOLERATION_PHASE}" == "Pending" ]] \
    || fail "accel-no-toleration should still be Pending (the taint has no matching toleration) but phase is ${NO_TOLERATION_PHASE}, 30s after ${ACCEL_NODE} was already Ready"
  NO_TOLERATION_SCHEDULED="$(kubectl get pod accel-no-toleration -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null)"
  [[ "${NO_TOLERATION_SCHEDULED}" == "False" ]] \
    || fail "accel-no-toleration's own PodScheduled condition is '${NO_TOLERATION_SCHEDULED}', expected False (unschedulable)"
  NODECLAIM_COUNT_AFTER="$(kubectl get nodeclaim -l karpenter.sh/nodepool="${ACCEL_POOL}" -o name 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${NODECLAIM_COUNT_AFTER}" == "${NODECLAIM_COUNT_BEFORE}" ]] \
    || fail "NodeClaim count for ${ACCEL_POOL} changed from ${NODECLAIM_COUNT_BEFORE} to ${NODECLAIM_COUNT_AFTER} -- Karpenter tried to launch a second (also tainted, equally useless) node for the non-tolerating pod instead of simply rejecting it"
  pass "a pod with no toleration for nvidia.com/gpu, aimed at the ${ACCEL_POOL} NodePool while its real node ${ACCEL_NODE} was already Ready, stayed Pending (PodScheduled=False) for 30s with no new NodeClaim created (${NODECLAIM_COUNT_BEFORE} unchanged) -- the taint blocks it from a free ride"
  kubectl delete pod accel-no-toleration --ignore-not-found --wait=false >/dev/null 2>&1 || true

  # Deleted and waited on (bounded), not --wait=false: this only empties
  # the node of pods before `helm uninstall` deletes the NodePool itself
  # below, so Karpenter does not also have to drain a still-running pod
  # as part of that deletion. The actual EC2 termination only starts once
  # the NodePool object is deleted; Karpenter's own NodeClaim finalizer on
  # it does not clear until that real instance is actually terminated,
  # which this script's own first real run of this section did not leave
  # enough time for (a 3-minute `helm uninstall --timeout`, since bumped
  # to 8 minutes below).
  kubectl delete pod accel-with-toleration --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true

  "${HELM}" uninstall "${ACCEL_POOL}" --namespace kube-system --wait --timeout 8m || fail "helm uninstall ${ACCEL_POOL}"
  # "Gone", not merely "kubectl get failed for some reason": each check
  # distinguishes a NotFound response from any other error, and
  # all three object kinds the chart creates are checked, not only the
  # NodePool.
  accel_release_gone() {
    local out
    for kind in nodepool ec2nodeclass resourceflavor; do
      out="$(kubectl get "${kind}" "${ACCEL_POOL}" 2>&1)" && return 1
      [[ "${out}" == *"NotFound"* ]] || { log "kubectl get ${kind} ${ACCEL_POOL}: ${out}"; return 1; }
    done
    return 0
  }
  wait_until 300 10 "NodePool/EC2NodeClass/ResourceFlavor ${ACCEL_POOL} gone" accel_release_gone \
    || fail "at least one of NodePool/EC2NodeClass/ResourceFlavor ${ACCEL_POOL} is still present (or erroring, not NotFound) after helm uninstall"
  instance_terminated() {
    [[ "$(aws ec2 describe-instances --instance-ids "${ACCEL_NODE_INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)" == "terminated" ]]
  }
  wait_until 180 10 "EC2 instance ${ACCEL_NODE_INSTANCE_ID} terminated" instance_terminated \
    || fail "EC2 instance ${ACCEL_NODE_INSTANCE_ID} (node ${ACCEL_NODE}) is not terminated after helm uninstall: $(aws ec2 describe-instances --instance-ids "${ACCEL_NODE_INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text 2>&1)"
  pass "helm uninstall ${ACCEL_POOL}: NodePool/EC2NodeClass/ResourceFlavor are gone (read back, not assumed) and EC2 instance ${ACCEL_NODE_INSTANCE_ID} is confirmed terminated by the AWS API"
  "${HELM}" uninstall karpenter --namespace kube-system --wait --timeout 3m || fail "helm uninstall karpenter"
  "${HELM}" uninstall karpenter-crd --namespace kube-system --wait --timeout 3m || fail "helm uninstall karpenter-crd"
  pass "helm uninstall karpenter, karpenter-crd"
else
  info "RUN_ACCEL_TAINT_CHECK != 1: skipping the real-accelerator-taint section (issue #56's own taint+Kueue-admission wiring is checked instead by gitops/tests/1.e2e.sh step 11/11b with GITOPS_RUN_ACCEL_E2E=1, and by code review of the commit that fixed it)"
fi

# A bare ResourceFlavor (no nodeLabels/taints): this script proves the
# RBAC+quota primitives, not capacity-pool's own taint/flavor binding on
# its own real accelerator resource and Kueue coverage of it (issue #56's
# own full subject, exercised above only when RUN_ACCEL_TAINT_CHECK=1, and
# otherwise by gitops/tests/1.e2e.sh step 11/11b independently of this
# script).
cat >"${WORK_DIR}/resourceflavor.yaml" <<YAML
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: system-cpu-${RUN_ID#e2e-}
YAML
kubectl apply -f "${WORK_DIR}/resourceflavor.yaml" || fail "kubectl apply the ResourceFlavor"
pass "created a bare ResourceFlavor system-cpu-${RUN_ID#e2e-}"

# ------------------------------------------------- 3. two team namespaces,
# -------------------------------------------------    one RBAC-scoped SA

cat >"${WORK_DIR}/namespaces.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEAM_A_NS}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEAM_B_NS}
  labels:
    ${TEST_TAG_KEY}: ${RUN_ID}
YAML
kubectl apply -f "${WORK_DIR}/namespaces.yaml" || fail "kubectl apply the two team namespaces"
pass "created namespaces ${TEAM_A_NS} and ${TEAM_B_NS}"

# The "team credential" this check stands in for #22 Decision 1's
# admin-owned envelope: a ServiceAccount bound, by a namespace-scoped
# Role/RoleBinding, to exactly one namespace -- the same primitive #22's
# own per-team AppProject will eventually automate the creation of, kept
# here independent of whether that automation exists yet (it does not,
# issue #57 item 1).
cat >"${WORK_DIR}/team-a-rbac.yaml" <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: team-a-sa
  namespace: ${TEAM_A_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-a-workload
  namespace: ${TEAM_A_NS}
rules:
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create", "get", "list", "watch", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-a-workload
  namespace: ${TEAM_A_NS}
subjects:
  - kind: ServiceAccount
    name: team-a-sa
    namespace: ${TEAM_A_NS}
roleRef:
  kind: Role
  name: team-a-workload
  apiGroup: rbac.authorization.k8s.io
YAML
kubectl apply -f "${WORK_DIR}/team-a-rbac.yaml" || fail "kubectl apply team-a's own ServiceAccount/Role/RoleBinding"
pass "created team-a-sa, bound only inside ${TEAM_A_NS} (no RBAC object of any kind created in ${TEAM_B_NS})"

TEAM_A_USER="system:serviceaccount:${TEAM_A_NS}:team-a-sa"

# ---- 3a. can-i: the boundary as the API server's own RBAC authorizer sees it

# can-i's own stdout is read verbatim ("yes" or "no"), never only its exit
# code: a transport/API error also exits non-zero, which a bare `if
# can_i ...; then fail; fi` would misread as a correct "no". Any
# output other than exactly "yes" or "no" is a hard fail with the output
# attached, not a silent pass.
can_i() {
  local out
  # `kubectl auth can-i` exits 1 for a real, expected "no" answer, not
  # only for a transport/API error -- `|| true` keeps that expected exit
  # from tripping this script's own `set -e`; the caller distinguishes a
  # real "no" from an error by checking this function's own stdout text,
  # never its exit code.
  out="$(kubectl auth can-i "$1" "$2" --as="${TEAM_A_USER}" -n "$3" 2>&1)" || true
  printf '%s' "${out}"
}
CAN_I_OWN_NS="$(can_i create jobs "${TEAM_A_NS}")"
[[ "${CAN_I_OWN_NS}" == "yes" ]] \
  || fail "kubectl auth can-i create jobs --as=${TEAM_A_USER} -n ${TEAM_A_NS}: expected yes, got: ${CAN_I_OWN_NS}"
pass "kubectl auth can-i: ${TEAM_A_USER} CAN create jobs in its own namespace ${TEAM_A_NS}"
CAN_I_OTHER_NS="$(can_i create jobs "${TEAM_B_NS}")"
[[ "${CAN_I_OTHER_NS}" == "no" ]] \
  || fail "kubectl auth can-i create jobs --as=${TEAM_A_USER} -n ${TEAM_B_NS}: expected no, got: ${CAN_I_OTHER_NS}"
pass "kubectl auth can-i: ${TEAM_A_USER} CANNOT create jobs in ${TEAM_B_NS} (not bound there)"

# ---- 3b. the same boundary against a real apply, not only can-i's prediction

# This RBAC-only template carries no kueue.x-k8s.io/queue-name label: at
# this point in the script no LocalQueue exists yet (section 4 creates
# team-a-lq afterwards), and these two Jobs are deleted (--wait=false)
# right after the apply itself is checked, never run to completion -- the
# label is deliberately left to the separate, Kueue-managed template
# below, used only once team-a-lq actually exists.
cat >"${WORK_DIR}/probe-job.yaml.tmpl" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: NAME_PLACEHOLDER
  namespace: NS_PLACEHOLDER
  labels:
    distai-platform-e2e: RUN_PLACEHOLDER
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
      containers:
        - name: probe
          image: public.ecr.aws/docker/library/busybox:1.37
          command: ["sh", "-c", "sleep SLEEP_PLACEHOLDER"]
          resources:
            requests:
              cpu: 750m
              memory: 32Mi
YAML

make_job() { # make_job NAME SLEEP_SECONDS
  sed -e "s/NAME_PLACEHOLDER/$1/" -e "s/SLEEP_PLACEHOLDER/$2/" \
    -e "s/RUN_PLACEHOLDER/${RUN_ID}/" "${WORK_DIR}/probe-job.yaml.tmpl"
}

# The Kueue-managed template used only by section 4, once team-a-lq
# exists. Kueue's Job integration reads kueue.x-k8s.io/queue-name from
# the Job's OWN metadata (confirmed against Kueue's upstream docs:
# `kubectl label job ... kueue.x-k8s.io/queue-name=...`), not from the
# pod template's labels alone -- a label only on spec.template.metadata
# is invisible to the Job-suspending webhook, so the Job is never
# actually managed by Kueue at all (found on this script's own first
# real run: both the holder and the supposedly-blocked Job ran
# immediately, because neither was ever suspended for admission in the
# first place). Carrying the label on both the Job and the pod template
# matches Kueue's own kubectl-label example and its generated Workload's
# own copy of the label.
cat >"${WORK_DIR}/queue-job.yaml.tmpl" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: NAME_PLACEHOLDER
  namespace: NS_PLACEHOLDER
  labels:
    distai-platform-e2e: RUN_PLACEHOLDER
    kueue.x-k8s.io/queue-name: team-a-lq
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        kueue.x-k8s.io/queue-name: team-a-lq
    spec:
      restartPolicy: Never
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
      containers:
        - name: probe
          image: public.ecr.aws/docker/library/busybox:1.37
          command: ["sh", "-c", "sleep SLEEP_PLACEHOLDER"]
          resources:
            requests:
              cpu: 750m
              memory: 32Mi
YAML

make_queue_job() { # make_queue_job NAME SLEEP_SECONDS
  sed -e "s/NAME_PLACEHOLDER/$1/" -e "s/SLEEP_PLACEHOLDER/$2/" \
    -e "s/RUN_PLACEHOLDER/${RUN_ID}/" "${WORK_DIR}/queue-job.yaml.tmpl"
}

# `kubectl create`, not `kubectl apply`: `apply` GETs the object before
# deciding to create or patch it, so against a namespace team-a-sa has no
# RoleBinding in at all, the denial `apply` hits is really a GET denial,
# not proof that the create verb itself is denied (found reviewing this
# script: the Role grants get/list/watch/create/delete together, so this
# distinction never showed up against team-a-sa's OWN namespace, only
# against the other one). `create` exercises exactly the verb "installs
# into its own namespace" means.
#
# team-a-sa installing into its OWN namespace: this is the chart-install
# primitive this check is for -- the API server authorizes the request
# against team-a-sa's own RBAC grant (`--as` impersonates the identity;
# the admin's own credential is only the transport, the authorization
# decision is team-a-sa's), the same decision a real token for that
# ServiceAccount would get.
make_job allowed-in-own-ns 1 | sed "s/NS_PLACEHOLDER/${TEAM_A_NS}/" \
  | kubectl create --as="${TEAM_A_USER}" -f - >"${WORK_DIR}/create-own-ns.out" 2>&1 \
  || fail "team-a-sa could not create a Job in its own namespace ${TEAM_A_NS}: $(cat "${WORK_DIR}/create-own-ns.out")"
pass "team-a-sa created a real Job in its own namespace ${TEAM_A_NS} (kubectl create, API-server-enforced, not just can-i)"

# The same credential against the OTHER team's namespace: must be denied
# by the API server itself, not merely absent from this script's own
# intentions, and the denial must name the create verb.
if make_job denied-outside-ns 1 | sed "s/NS_PLACEHOLDER/${TEAM_B_NS}/" \
  | kubectl create --as="${TEAM_A_USER}" -f - >"${WORK_DIR}/create-other-ns.out" 2>&1; then
  fail "team-a-sa was able to create a Job in ${TEAM_B_NS} (expected Forbidden): $(cat "${WORK_DIR}/create-other-ns.out")"
fi
grep -qi "forbidden" "${WORK_DIR}/create-other-ns.out" \
  || fail "the ${TEAM_B_NS} create failed, but not with Forbidden: $(cat "${WORK_DIR}/create-other-ns.out")"
grep -qi 'cannot create resource "jobs"' "${WORK_DIR}/create-other-ns.out" \
  || fail "the ${TEAM_B_NS} denial did not name the create verb on jobs: $(cat "${WORK_DIR}/create-other-ns.out")"
pass "team-a-sa was denied (Forbidden on the create verb, by the API server) creating the identical Job in ${TEAM_B_NS}"

kubectl delete job allowed-in-own-ns -n "${TEAM_A_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

# ------------------------------------------------- 4. Kueue quota holds a
# -------------------------------------------------    second Job back

cat >"${WORK_DIR}/queue.yaml" <<YAML
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: team-a-queue-${RUN_ID#e2e-}
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${TEAM_A_NS}
  resourceGroups:
    - coveredResources: ["cpu", "memory"]
      flavors:
        - name: system-cpu-${RUN_ID#e2e-}
          resources:
            - name: "cpu"
              nominalQuota: "1"
            - name: "memory"
              nominalQuota: "512Mi"
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  name: team-a-lq
  namespace: ${TEAM_A_NS}
spec:
  clusterQueue: team-a-queue-${RUN_ID#e2e-}
YAML
kubectl apply -f "${WORK_DIR}/queue.yaml" || fail "kubectl apply the ClusterQueue/LocalQueue"
pass "created ClusterQueue team-a-queue-${RUN_ID#e2e-} (nominalQuota cpu=1) and LocalQueue team-a-lq in ${TEAM_A_NS}"

# Admission is read from Kueue's own Workload object, never from the
# Job's spec.suspend or status.active/status.succeeded. Two reasons,
# both found while writing this script:
#   1. status.active (or status.succeeded) cannot tell "Kueue admitted
#      this" apart from "this Job was never managed by Kueue in the
#      first place and simply ran and finished on its own" -- with a
#      short enough sleep, an unmanaged Job reaches status.active=0
#      (already Succeeded) within the same window a genuinely
#      Kueue-held one would.
#   2. spec.suspend has exactly the same problem: a Job's own API
#      default for spec.suspend, when nothing ever sets it (an
#      unmanaged Job, never touched by Kueue's mutating webhook), is
#      also "false" -- so checking spec.suspend=="false" cannot tell
#      "Kueue admitted it" apart from "Kueue never saw this Job at all".
# Kueue's own Workload object does not have this problem: Kueue's
# mutating webhook creates one Workload per managed Job, named
# "job-<job name>-<suffix>" (confirmed on a real run: a Workload named
# "job-quota-blocked-35f7f" existed only because Kueue's webhook
# intercepted the Job in the first place); an unmanaged Job has no
# Workload at all, and this check fails closed on that (no Workload
# found) rather than reading a default value as a false positive.
workload_name_for() { # workload_name_for JOB_NAME
  kubectl get workload -n "${TEAM_A_NS}" -o name 2>/dev/null \
    | sed 's#^workload.kueue.x-k8s.io/##' | grep "^job-$1-" | head -1 || true
}
workload_condition() { # workload_condition WORKLOAD_NAME TYPE
  kubectl get workload "$1" -n "${TEAM_A_NS}" \
    -o jsonpath="{.status.conditions[?(@.type==\"$2\")].status}" 2>/dev/null || true
}
job_admitted() { # job_admitted JOB_NAME
  local wl
  wl="$(workload_name_for "$1")"
  [[ -n "${wl}" ]] || return 1
  [[ "$(workload_condition "${wl}" Admitted)" == "True" ]]
}

# First Job: 750m cpu, sleeps long enough to stay admitted while the second
# Job is submitted and checked. As the queue's own team (team-a-sa), not
# the admin, to match how this queue is actually meant to be used.
make_queue_job quota-holder 180 | sed "s/NS_PLACEHOLDER/${TEAM_A_NS}/" \
  | kubectl apply --as="${TEAM_A_USER}" -f - >/dev/null \
  || fail "kubectl apply the quota-holder Job"
wait_until 180 5 "quota-holder's own Workload reaches Admitted=True" job_admitted quota-holder \
  || fail "quota-holder's Workload was never Admitted (last seen: $(kubectl get workload -n "${TEAM_A_NS}" -o yaml 2>&1 | tr '\n' ' '))"
HOLDER_WORKLOAD="$(workload_name_for quota-holder)"
# The pod's own status.phase (via the Job's own "job-name" selector label,
# set by the Job controller on every pod it creates), not the Job's
# status.active: active also counts a Pending pod, so phase is the more
# specific of the two.
holder_pod_running() {
  [[ "$(kubectl get pods -n "${TEAM_A_NS}" -l job-name=quota-holder \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" == "Running" ]]
}
wait_until 60 5 "quota-holder's own pod reaches Running" holder_pod_running \
  || fail "Workload ${HOLDER_WORKLOAD} is Admitted=True but quota-holder's own pod never reached Running: $(kubectl get pods -n "${TEAM_A_NS}" -l job-name=quota-holder -o json 2>&1 | tr '\n' ' ')"
pass "quota-holder's own Workload ${HOLDER_WORKLOAD} reached Admitted=True and its pod reached Running, holding the ClusterQueue's own cpu=1 quota"

# Second Job: another 750m cpu request on the SAME queue, with the SAME
# 180s sleep as quota-holder, so it cannot finish on its own inside this
# check's own observation window regardless of whether Kueue manages it.
# 750m+750m=1500m exceeds the ClusterQueue's own nominalQuota of 1
# (1000m) cpu, so Kueue must keep this one's own Workload un-admitted
# while quota-holder still holds its share -- this is the actual
# mechanism issue #56 depends on, checked here on plain CPU instead of
# an accelerator resource.
make_queue_job quota-blocked 180 | sed "s/NS_PLACEHOLDER/${TEAM_A_NS}/" \
  | kubectl apply --as="${TEAM_A_USER}" -f - >/dev/null \
  || fail "kubectl apply the quota-blocked Job"

sleep 20
BLOCKED_WORKLOAD="$(workload_name_for quota-blocked)"
[[ -n "${BLOCKED_WORKLOAD}" ]] \
  || fail "no Kueue Workload named job-quota-blocked-* found in ${TEAM_A_NS} -- Kueue never created one for quota-blocked at all"
# Both read as the specific, expected value (never "not True", which an
# empty read from a failed `kubectl get` would also satisfy and pass):
# Kueue sets Admitted=False explicitly while a Workload is pending, and
# QuotaReserved=False while it has not reserved any of the ClusterQueue's
# quota -- an empty string (a transport error, or no such condition at
# all) is a hard fail here, not a silent pass.
BLOCKED_ADMITTED="$(workload_condition "${BLOCKED_WORKLOAD}" Admitted)"
[[ "${BLOCKED_ADMITTED}" == "False" ]] \
  || fail "Workload ${BLOCKED_WORKLOAD}'s own Admitted condition is '${BLOCKED_ADMITTED}', expected False, while quota-holder still holds the queue's entire quota"
BLOCKED_QUOTA_RESERVED="$(workload_condition "${BLOCKED_WORKLOAD}" QuotaReserved)"
[[ "${BLOCKED_QUOTA_RESERVED}" == "False" ]] \
  || fail "Workload ${BLOCKED_WORKLOAD}'s own QuotaReserved condition is '${BLOCKED_QUOTA_RESERVED}', expected False, while quota-holder still holds the queue's entire quota"
pass "20s after submitting it, quota-blocked's own Workload ${BLOCKED_WORKLOAD} has Admitted=False and QuotaReserved=False (holder still holds the only quota) while quota-holder (same 180s sleep, so it cannot have simply finished) holds the queue's cpu=1 quota"

# The strongest proof available: delete quota-holder to free the quota,
# then show quota-blocked's own Workload -- the SAME object, never
# recreated -- is admitted afterward. This is what distinguishes
# "really held by the quota" from any other reason a Workload might not
# be Admitted yet.
kubectl delete job quota-holder -n "${TEAM_A_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
wait_until 60 5 "quota-blocked's own Workload reaches Admitted=True once quota-holder's share is freed" job_admitted quota-blocked \
  || fail "Workload ${BLOCKED_WORKLOAD} never reached Admitted=True after quota-holder was deleted and its quota freed -- the earlier 'held' state was not actually caused by the quota"
pass "quota-blocked's own Workload ${BLOCKED_WORKLOAD} reached Admitted=True once quota-holder was deleted and released the cpu=1 quota it held -- confirms the earlier hold was the ClusterQueue's own nominalQuota, not an unrelated delay"

kubectl delete job quota-blocked -n "${TEAM_A_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

# ------------------------------------------------------- 5. teardown

# ClusterQueue and ResourceFlavor are cluster-scoped, created by a bare
# kubectl apply (section 2/4), never part of the Kueue helm release
# itself -- deleting them explicitly, before uninstalling Kueue, matters:
# Kueue's own finalizer on a ClusterQueue/ResourceFlavor needs its
# controller running to clear ("this run's own first attempt left Kueue's
# controller/webhook gone while these two objects still had a pending
# finalizer, and `helm uninstall --wait` then timed out waiting on a
# namespace that could never finish terminating -- a teardown-ordering
# bug in this script, not a real finding about Kueue; the cluster itself
# was still destroyed cleanly by terraform regardless, confirmed by the
# leftover sweep below").
# Namespaces first (and waited on, bounded): team-a's own LocalQueue is
# what a ClusterQueue's own "still in use" finalizer looks for, so the
# LocalQueue must be gone before the ClusterQueue delete below can clear.
# Each delete is checked, not swallowed with a blanket `|| true`: a
# timeout here is exactly the finalizer-ordering failure mode this
# script's own development hit once already, and silently continuing
# past it is what let that failure reach `helm uninstall` undiagnosed.
kubectl delete namespace "${TEAM_A_NS}" "${TEAM_B_NS}" --wait=true --timeout=90s \
  || fail "kubectl delete namespace ${TEAM_A_NS} ${TEAM_B_NS} did not complete within 90s"
kubectl delete clusterqueue "team-a-queue-${RUN_ID#e2e-}" --wait=true --timeout=60s \
  || fail "kubectl delete clusterqueue team-a-queue-${RUN_ID#e2e-} did not complete within 60s"
kubectl delete resourceflavor "system-cpu-${RUN_ID#e2e-}" --wait=true --timeout=60s \
  || fail "kubectl delete resourceflavor system-cpu-${RUN_ID#e2e-} did not complete within 60s"
"${HELM}" uninstall kueue --namespace kueue-system --wait --timeout 3m || fail "helm uninstall kueue"
kubectl delete namespace kueue-system --wait=true --timeout=90s \
  || fail "kubectl delete namespace kueue-system did not complete within 90s"
pass "deleted the ClusterQueue/ResourceFlavor, uninstalled Kueue, and deleted the two team namespaces (and kueue-system) before terraform destroy"

destroy_start="$(date +%s)"
tf destroy -auto-approve -input=false -var-file="${TFVARS}" \
  || fail "terraform destroy"
DESTROYED=1
pass "terraform destroy completed without manual steps ($(($(date +%s) - destroy_start))s)"

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" \
  || fail "resources tagged for the cluster remain after destroy"

assert_vpc_gone
