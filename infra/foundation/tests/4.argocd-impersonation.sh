#!/usr/bin/env bash
# Real-hardware check of whether Argo CD sync impersonation actually runs
# on the EKS managed Argo CD capability -- issue #22 Decision 10 H11,
# issue #57 item 1, closing the one thing an earlier real-hardware probe
# (recorded as comments on #56/#57 and a fact update to #22) left open:
# that probe confirmed the live AppProject CRD's own OpenAPI schema
# declares spec.destinationServiceAccounts and the value round-trips
# unchanged on a real `kubectl apply`, but it built foundation + the
# capability only, with no delivered Application, so it never attempted
# one real impersonated sync. This script does, and the confirmed answer
# (checks 1-6 below, real hardware, 2026-11-25) is: **no, it does not**.
# destinationServiceAccounts is accepted by the AppProject CRD's own
# schema but has no observed effect, because there is no
# customer-reachable way to set `application.sync.impersonation.enabled`
# (a documented upstream prerequisite for the feature) on this managed
# capability -- its own namespace holds no argocd-cm at all (checks
# below), and `aws eks create-capability help`'s own `argoCd`
# configuration object (namespace, awsIdc, rbacRoleMappings,
# networkAccess) has no such field either. Filed to the upstream tracking
# issue (#49). #22 Decision 10 H11 Option A ("same-namespace
# Role/RoleBinding on team projects, synced through a per-team identity")
# is therefore NOT adopted by this PR; gitops/bootstrap/team-onboard.sh's
# own AppProject keeps H11's original deny (no Role/RoleBinding in its
# namespaceResourceWhitelist), which checks 1b and 6 below both exercise.
#
# What this checks, each against the real API server (not a dry run):
#   1. a team's own Application, in its own team AppProject, self-syncs
#      an ordinary, non-RBAC workload chart (ServiceAccount+ConfigMap)
#      into its own namespace with no admin pre-creating it -- ordinary
#      self-service still works once Role/RoleBinding are excluded.
#   1b. the SAME team project refuses a chart shipping its own namespaced
#      Role/RoleBinding -- the exact #57 item 1 scenario
#      (examples/inference/vllm/disagg-pd-llmd's sidecar RBAC) -- because
#      gitops/bootstrap/team-onboard.sh's own AppProject does not
#      whitelist those two kinds (H11's original deny).
#   2. the SAME non-RBAC manifest as check 1, synced through the SAME
#      team project but aimed at a different namespace, is refused by
#      the AppProject's own destinations list, before the API server is
#      even asked. Argo CD's own project-level policy, independent of
#      which identity performs the sync.
#   3. a bare cluster-scoped object (ClusterRole), synced through the same
#      team project, is refused by the project's own empty
#      clusterResourceWhitelist. Also Argo CD's own project-level policy,
#      independent of sync identity.
#   4. the team's own ServiceAccount, asked directly (kubectl --as, no Argo
#      CD involved) to create a Role granting a permission it does not
#      itself hold (secrets, which gitops/bootstrap/team-onboard.sh's own
#      Role never grants), is refused by the Kubernetes API server's own
#      RBAC escalation check. This proves the escalation check works on
#      this identity when IT is the one making the request directly -- it
#      says nothing about whether Argo CD's own sync ever acts as this
#      identity (that is check 6, next).
#   6. (the differential check that actually distinguishes impersonated
#      from non-impersonated sync, and the reason checks 1b/H11's deny
#      are kept rather than relaxed): removing a permission from the
#      team's own ServiceAccount's Role, then forcing a resync of the
#      already-Synced Application from check 1, still SUCCEEDS --
#      proving Argo CD performed that sync (and check 1's own sync) with
#      its own capability-wide identity throughout, never impersonating
#      the team's ServiceAccount. Checks 2-4 alone would have been
#      consistent with real self-service tenancy; this check is what
#      shows they were not evidence of it.
#
# A further implication, reasoned from check 6 but not independently
# exploited in this script (recorded as a risk this script's own H11
# deny closes, not a demonstrated exploit it leaves open): had
# Role/RoleBinding been left in a team AppProject's
# namespaceResourceWhitelist on the premise that impersonation would
# constrain them (checks 1b/6 show it would not), a team's own chart
# could have shipped a RoleBinding to any existing ClusterRole (including
# a highly privileged one) or a Role granting broad permissions, and
# Argo CD's own unconstrained identity would have applied it with no
# RBAC-escalation check against the team at all (that check only fires
# against the actual API caller, which checks 1-6 show is never the team
# here). gitops/bootstrap/team-onboard.sh carries this warning verbatim
# in its own header.
#
# This script builds only infra/foundation with var.argocd set (the
# managed Argo CD capability) -- no Karpenter, no Kueue, no accelerator
# pool, CPU-only and foundation-only, independent of
# infra/foundation/tests/1.e2e.sh and infra/foundation/tests/3.tenancy-primitive.sh,
# which this PR does not modify. It creates one temporary IAM Identity
# Center group (deleted in this script's own teardown) purely to satisfy
# var.argocd.role_mappings' validation (at least one ADMIN group is
# required by infra/foundation/variables.tf); this script signs in to
# nothing through it; every object this script applies, it applies
# directly with kubectl through ADMIN_PRINCIPAL_ARN's own access entry.
#
# Required environment (export before running):
#   AWS_PROFILE, AWS_REGION, NAME, STATE_BUCKET, STATE_REGION,
#   ADMIN_PRINCIPAL_ARN, MY_CIDR
# Optional environment:
#   TERRAFORM (terraform), HELM (helm, unused but checked for parity with
#   the other tests in this directory), E2E_WORK_DIR (mktemp -d),
#   E2E_KEEP_ON_FAILURE (0), E2E_LEFTOVER_GRACE_SECONDS (600),
#   IDC_REGION (the region to call sso-admin/identitystore in; defaults to
#   AWS_REGION)
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
IDC_REGION="${IDC_REGION:-${AWS_REGION}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/../.." && pwd)"
# Pinned to the exact commit this checkout is at, never "HEAD" (Argo CD's
# own meaning of "HEAD" is the remote's default branch, main -- not this
# checkout's own ref; this script's fixtures live only on the branch this
# PR is on, so "HEAD" fails every sync with "app path does not exist",
# confirmed on this script's own third real e2e attempt).
REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
TFVARS="${WORK_DIR}/e2e.tfvars.json"
export TF_DATA_DIR="${WORK_DIR}/.terraform"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1

STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
RUN_ID="argoimp-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
TEAM="team-a-${RUN_ID#argoimp-}"
OTHER_NS="team-b-${RUN_ID#argoimp-}"
IDC_GROUP_NAME="dp-${RUN_ID}-admin"

APPLY_ATTEMPTED=0
DESTROYED=0
FAILED_STEP=""
VPC_ID=""
IDC_GROUP_ID=""
IDC_IDENTITY_STORE_ID=""

# shellcheck source=e2e-lib.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/e2e-lib.sh"

cleanup() {
  local rc=$?
  set +e
  if [[ -n "${IDC_GROUP_ID}" && -n "${IDC_IDENTITY_STORE_ID}" ]]; then
    aws identitystore delete-group --region "${IDC_REGION}" \
      --identity-store-id "${IDC_IDENTITY_STORE_ID}" --group-id "${IDC_GROUP_ID}" >/dev/null 2>&1
    info "cleanup: deleted temporary Identity Center group ${IDC_GROUP_NAME} (${IDC_GROUP_ID})"
  fi
  if [[ "${APPLY_ATTEMPTED}" -eq 1 && "${DESTROYED}" -eq 0 ]]; then
    if [[ "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving the cell in place; destroy it with:"
      info "TF_DATA_DIR=${TF_DATA_DIR} ${TERRAFORM} -chdir=${ROOT} destroy -var-file=${TFVARS}"
    else
      info "cleanup: the test did not reach a successful destroy; cleaning up"
      if kubectl get nodes >/dev/null 2>&1; then
        local argons; argons="$(tf_out argocd_namespace 2>/dev/null || echo argocd)"
        kubectl delete application team-a-chart team-a-rbac-probe team-a-cross-ns team-a-clusterrole -n "${argons}" --ignore-not-found --wait=false >/dev/null 2>&1
        kubectl delete appproject "${TEAM}" -n "${argons}" --ignore-not-found --wait=false >/dev/null 2>&1
        kubectl delete namespace "${TEAM}" "${OTHER_NS}" --ignore-not-found --wait=false >/dev/null 2>&1
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

for b in "${TERRAFORM}" "${HELM}" aws kubectl jq; do require_bin "${b}"; done
[[ "${MY_CIDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
  || fail "MY_CIDR must be an IPv4 CIDR, got ${MY_CIDR}"
aws sts get-caller-identity --query Account --output text >/dev/null \
  || fail "aws sts get-caller-identity (check AWS_PROFILE and credentials)"
pass "preflight: tools present, credentials valid"
info "run ${RUN_ID}, work dir ${WORK_DIR}"

# ----------------------------------------------- 1. a temporary IDC group

# var.argocd.role_mappings requires at least one ADMIN group with at
# least one member group_id (infra/foundation/variables.tf); this script
# never signs in through it, so an empty, throwaway group satisfies the
# requirement without granting any human or role sign-in capability.
IDC_INSTANCE_JSON="$(aws sso-admin list-instances --region "${IDC_REGION}" --output json)" \
  || fail "aws sso-admin list-instances --region ${IDC_REGION}"
IDC_INSTANCE_ARN="$(echo "${IDC_INSTANCE_JSON}" | jq -r '.Instances[0].InstanceArn // empty')"
IDC_IDENTITY_STORE_ID="$(echo "${IDC_INSTANCE_JSON}" | jq -r '.Instances[0].IdentityStoreId // empty')"
[[ -n "${IDC_INSTANCE_ARN}" && -n "${IDC_IDENTITY_STORE_ID}" ]] \
  || fail "no IAM Identity Center instance found in ${IDC_REGION} (aws sso-admin list-instances returned none)"
IDC_GROUP_ID="$(aws identitystore create-group --region "${IDC_REGION}" \
  --identity-store-id "${IDC_IDENTITY_STORE_ID}" --display-name "${IDC_GROUP_NAME}" \
  --query GroupId --output text)" \
  || fail "aws identitystore create-group ${IDC_GROUP_NAME}"
pass "temporary Identity Center group ${IDC_GROUP_NAME} (${IDC_GROUP_ID}) created in instance ${IDC_INSTANCE_ARN}"

# ------------------------------------------------- 2. foundation apply with
# -------------------------------------------------    the Argo CD capability

cat >"${TFVARS}" <<JSON
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "argocd": {
    "idc_instance_arn": "${IDC_INSTANCE_ARN}",
    "idc_region": "${IDC_REGION}",
    "role_mappings": [{"role": "ADMIN", "group_ids": ["${IDC_GROUP_ID}"]}]
  },
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
# shellcheck disable=SC2034
VPC_ID="$(tf_out vpc_id)"
ARGOCD_NAMESPACE="$(tf_out argocd_namespace)"
[[ "${CLUSTER}" == "${NAME}" ]] || fail "cluster_name (${CLUSTER}) differs from var.name (${NAME})"

aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}" \
  --kubeconfig "${KUBECONFIG}" >/dev/null || fail "aws eks update-kubeconfig"
kubectl get --raw /readyz >/dev/null || fail "kubectl cannot reach the cluster as ADMIN_PRINCIPAL_ARN"
pass "kubectl reaches the cluster through the access entry"

ARGOCD_ARN="$(tf_out argocd_capability_arn)"
argocd_active() {
  [[ "$(aws eks list-capabilities --cluster-name "${CLUSTER}" \
    --query "capabilities[?arn=='${ARGOCD_ARN}'].status | [0]" --output text 2>/dev/null)" == "ACTIVE" ]]
}
wait_until 1200 30 "Argo CD capability ACTIVE" argocd_active || fail "Argo CD capability ${ARGOCD_ARN} is not ACTIVE"
pass "Argo CD capability ACTIVE (${ARGOCD_ARN}), namespace ${ARGOCD_NAMESPACE}"

argocd_crds_ready() { kubectl get crd appprojects.argoproj.io applications.argoproj.io >/dev/null 2>&1; }
wait_until 300 10 "Argo CD CRDs present" argocd_crds_ready || fail "appprojects.argoproj.io/applications.argoproj.io CRDs never appeared"
pass "Argo CD CRDs present"

# --- register this cluster as its own Argo CD destination ----------------
# Same registration Secret gitops/bootstrap/bootstrap.sh's own Object 1
# writes (this script does not run bootstrap.sh itself, since it needs
# none of bootstrap.sh's other objects -- the platform AppProject or the
# root Application -- for this check).
CLUSTER_ARN="$(tf_out cluster_arn)"
kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF || fail "kubectl apply cell-registration Secret"
apiVersion: v1
kind: Secret
metadata:
  name: cell-registration
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: "${CLUSTER}"
  server: "${CLUSTER_ARN}"
EOF
pass "registered cluster ${CLUSTER} as its own Argo CD destination"

# Diagnostic only (not a check): list every ConfigMap/Secret actually
# present in the capability's own namespace before team-onboard.sh
# assumes a plain argocd-cm exists there. The EKS managed capability is
# not a self-hosted Argo CD helm chart, and nothing in this script's own
# prior research (the probe behind #22's own Decision 10 H11 fact
# update) confirmed argocd-cm's own name, shape, or even presence on
# this capability -- only that the AppProject CRD's own schema accepts
# destinationServiceAccounts.
info "ConfigMaps in ${ARGOCD_NAMESPACE}: $(kubectl get configmap -n "${ARGOCD_NAMESPACE}" -o name 2>&1 | tr '\n' ' ')"
info "Secrets in ${ARGOCD_NAMESPACE}: $(kubectl get secret -n "${ARGOCD_NAMESPACE}" -o name 2>&1 | tr '\n' ' ')"

# ------------------------------------------------- 3. onboard team "team-a"
# -------------------------------------------------    with the real,
# -------------------------------------------------    shipped script

# TEAM is set once, near the top of this script (before the cleanup trap
# is installed, so cleanup can reference it unconditionally).
# gitops/bootstrap/team-onboard.sh requires a DNS-1123-label team name;
# RUN_ID's own timestamp suffix keeps this run's objects from colliding
# with any other concurrent run on the shared runner, same convention
# infra/foundation/tests/3.tenancy-primitive.sh uses for its own
# namespaces. OTHER_NS is a second, ordinary namespace this script
# creates directly (not through team-onboard.sh -- it is the
# cross-namespace target in check 4b, never itself onboarded as a team).
kubectl apply -f - <<EOF || fail "kubectl apply namespace ${OTHER_NS}"
apiVersion: v1
kind: Namespace
metadata:
  name: ${OTHER_NS}
  labels:
    ${TEST_TAG_KEY}: "${RUN_ID}"
EOF

bash "${REPO_ROOT}/gitops/bootstrap/team-onboard.sh" \
  --team "${TEAM}" \
  --tf-outputs <(tf output -json) \
  --source-repo "https://github.com/littlemex/distai-platform.git" \
  || fail "gitops/bootstrap/team-onboard.sh --team ${TEAM}"
pass "gitops/bootstrap/team-onboard.sh onboarded team ${TEAM}"

# No argocd-cm exists on the EKS managed Argo CD capability (confirmed on
# this script's own first real run: the capability's namespace held only
# the built-in kube-root-ca.crt ConfigMap, and `aws eks create-capability
# help`'s own argoCd configuration object has no impersonation field
# either) -- so this script cannot read back a cluster-wide flag the way
# it would on a self-hosted install. This is a fact about the platform,
# recorded here rather than asserted away: whether sync impersonation is
# actually engaged without that flag ever being set by a customer is
# exactly what checks 1-5 below determine empirically, not something
# this script can confirm by reading a ConfigMap first.
if kubectl get configmap argocd-cm -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  IMPERSONATION_FLAG="$(kubectl get configmap argocd-cm -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.data.application\.sync\.impersonation\.enabled}')"
  [[ "${IMPERSONATION_FLAG}" == "true" ]] \
    || fail "argocd-cm exists and its application.sync.impersonation.enabled is '${IMPERSONATION_FLAG}', expected true after team-onboard.sh"
  pass "argocd-cm exists in ${ARGOCD_NAMESPACE} and application.sync.impersonation.enabled is true"
else
  info "no argocd-cm ConfigMap in ${ARGOCD_NAMESPACE} (the managed capability's own control plane runs outside this cluster, confirmed by 'aws eks create-capability help'); proceeding without it, relying on checks 1-5 below to show empirically whether destinationServiceAccounts impersonates anyway"
fi
SA_IN_PROJECT="$(kubectl get appproject "${TEAM}" -n "${ARGOCD_NAMESPACE}" \
  -o jsonpath="{.spec.destinationServiceAccounts[?(@.namespace=='${TEAM}')].defaultServiceAccount}")"
[[ "${SA_IN_PROJECT}" == "${TEAM}-deployer" ]] \
  || fail "AppProject ${TEAM}'s own destinationServiceAccounts does not name ${TEAM}-deployer for namespace ${TEAM} (got '${SA_IN_PROJECT}')"
pass "AppProject ${TEAM} (read back): destinationServiceAccounts -> ${TEAM}-deployer for namespace ${TEAM}"

trigger_sync() {
  local app="$1"
  local rev
  rev="$(kubectl get application "${app}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.source.targetRevision}')"
  kubectl patch application "${app}" -n "${ARGOCD_NAMESPACE}" --type merge \
    -p "{\"operation\":{\"sync\":{\"revision\":\"${rev}\",\"prune\":true,\"syncStrategy\":{\"hook\":{}}}}}"
}
operation_phase() { kubectl get application "$1" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null; }
operation_message() { kubectl get application "$1" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.operationState.message}' 2>/dev/null; }
sync_status() { kubectl get application "$1" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.sync.status}' 2>/dev/null; }

# ------------------------------------------------- 4a. positive case: a
# -------------------------------------------------     team's own
# -------------------------------------------------     namespaced-RBAC
# -------------------------------------------------     chart self-syncs

kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF || fail "kubectl apply Application team-a-chart"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-a-chart
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: ${TEAM}
  source:
    repoURL: https://github.com/littlemex/distai-platform.git
    targetRevision: ${REVISION}
    path: infra/foundation/tests/fixtures/tenancy-argocd-impersonation/plain-workload-probe
  destination:
    name: "${CLUSTER}"
    namespace: ${TEAM}
EOF
trigger_sync team-a-chart || fail "trigger team-a-chart's first sync"
op_done() { local p; p="$(operation_phase team-a-chart)"; [[ "${p}" == "Succeeded" || "${p}" == "Failed" || "${p}" == "Error" ]]; }
wait_until 180 5 "team-a-chart's first sync operation to finish" op_done \
  || fail "team-a-chart's first sync did not finish within 180s (phase: $(operation_phase team-a-chart))"
[[ "$(operation_phase team-a-chart)" == "Succeeded" ]] \
  || fail "team-a-chart's first sync did not Succeed (phase $(operation_phase team-a-chart), message: $(operation_message team-a-chart))"
kubectl get serviceaccount probe-sidecar -n "${TEAM}" >/dev/null 2>&1 \
  || fail "ServiceAccount probe-sidecar was not actually created in ${TEAM} despite a Succeeded sync"
kubectl get configmap probe-config -n "${TEAM}" >/dev/null 2>&1 \
  || fail "ConfigMap probe-config was not actually created in ${TEAM} despite a Succeeded sync"
pass "CHECK 1/6: team-a-chart (project ${TEAM}) self-synced an ordinary, non-RBAC workload chart (ServiceAccount+ConfigMap) into its own namespace ${TEAM} with no admin pre-creating it"

# ------------------------------------------------ 4a2. a team project denies
# ------------------------------------------------      a chart shipping its
# ------------------------------------------------      own namespaced RBAC
# ------------------------------------------------      (H11's original deny,
# ------------------------------------------------      restored -- Option A
# ------------------------------------------------      is not adopted)

kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF || fail "kubectl apply Application team-a-rbac-probe"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-a-rbac-probe
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: ${TEAM}
  source:
    repoURL: https://github.com/littlemex/distai-platform.git
    targetRevision: ${REVISION}
    path: infra/foundation/tests/fixtures/tenancy-argocd-impersonation/team-rbac-probe
  destination:
    name: "${CLUSTER}"
    namespace: ${TEAM}
EOF
rbac_probe_blocked() {
  local cond
  cond="$(kubectl get application team-a-rbac-probe -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.conditions[*].message}{.status.operationState.message}' 2>/dev/null)"
  [[ "${cond}" == *"not permitted in project"* || "${cond}" == *"is not permitted"* ]]
}
trigger_sync team-a-rbac-probe >/dev/null 2>&1 || true
wait_until 120 5 "team-a-rbac-probe refused (Role/RoleBinding not permitted in project)" rbac_probe_blocked \
  || fail "team-a-rbac-probe was not refused: conditions=$(kubectl get application team-a-rbac-probe -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.conditions}') operationState=$(operation_message team-a-rbac-probe)"
kubectl get role probe-sidecar-role -n "${TEAM}" >/dev/null 2>&1 \
  && fail "Role probe-sidecar-role was actually created in ${TEAM} despite the AppProject's own namespaceResourceWhitelist refusal" || true
kubectl get rolebinding probe-sidecar-binding -n "${TEAM}" >/dev/null 2>&1 \
  && fail "RoleBinding probe-sidecar-binding was actually created in ${TEAM} despite the AppProject's own namespaceResourceWhitelist refusal" || true
pass "CHECK 1b/6: a chart shipping its own namespaced Role/RoleBinding (#57 item 1's exact scenario) was refused by the same team project ${TEAM} -- gitops/bootstrap/team-onboard.sh's own AppProject does not whitelist Role/RoleBinding (H11's original deny, restored, since sync impersonation is confirmed not engaged -- check 5 below); no Role/RoleBinding was created"
kubectl delete application team-a-rbac-probe -n "${ARGOCD_NAMESPACE}" --wait=false >/dev/null 2>&1 || true

# ------------------------------------------------- 4b. a team project denies
# -------------------------------------------------     a destination
# -------------------------------------------------     outside its own
# -------------------------------------------------     namespace

kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF || fail "kubectl apply Application team-a-cross-ns"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-a-cross-ns
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: ${TEAM}
  source:
    repoURL: https://github.com/littlemex/distai-platform.git
    targetRevision: ${REVISION}
    path: infra/foundation/tests/fixtures/tenancy-argocd-impersonation/plain-workload-probe
  destination:
    name: "${CLUSTER}"
    namespace: ${OTHER_NS}
EOF
cross_ns_blocked() {
  local cond
  cond="$(kubectl get application team-a-cross-ns -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.conditions[*].message}' 2>/dev/null)"
  [[ "${cond}" == *"do not match any of the allowed destinations"* || "${cond}" == *"not permitted in project"* ]]
}
wait_until 120 5 "team-a-cross-ns's own InvalidSpecError (destination not permitted in project)" cross_ns_blocked \
  || fail "team-a-cross-ns was not refused for its destination namespace ${OTHER_NS}: $(kubectl get application team-a-cross-ns -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.conditions}')"
kubectl get configmap probe-config -n "${OTHER_NS}" >/dev/null 2>&1 \
  && fail "ConfigMap probe-config was actually created in ${OTHER_NS} despite the AppProject's own destination refusal" || true
pass "CHECK 2/6: the same non-RBAC manifest, same team project ${TEAM}, aimed at ${OTHER_NS} instead of its own ${TEAM}, was refused by the AppProject's own destinations list before anything was written to ${OTHER_NS}"
kubectl delete application team-a-cross-ns -n "${ARGOCD_NAMESPACE}" --wait=false >/dev/null 2>&1 || true

# ------------------------------------------------- 4c. a team project denies
# -------------------------------------------------     a cluster-scoped kind

kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF || fail "kubectl apply Application team-a-clusterrole"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-a-clusterrole
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: ${TEAM}
  source:
    repoURL: https://github.com/littlemex/distai-platform.git
    targetRevision: ${REVISION}
    path: infra/foundation/tests/fixtures/tenancy-argocd-impersonation/clusterrole-probe
  destination:
    name: "${CLUSTER}"
    namespace: ${TEAM}
EOF
clusterrole_blocked() {
  local cond
  cond="$(kubectl get application team-a-clusterrole -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.conditions[*].message}{.status.operationState.message}' 2>/dev/null)"
  [[ "${cond}" == *"not permitted in project"* || "${cond}" == *"is not permitted"* ]]
}
trigger_sync team-a-clusterrole >/dev/null 2>&1 || true
wait_until 120 5 "team-a-clusterrole refused (ClusterRole not permitted in project)" clusterrole_blocked \
  || fail "team-a-clusterrole was not refused: conditions=$(kubectl get application team-a-clusterrole -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.conditions}') operationState=$(operation_message team-a-clusterrole)"
kubectl get clusterrole tenancy-probe-clusterrole-should-be-rejected >/dev/null 2>&1 \
  && fail "ClusterRole tenancy-probe-clusterrole-should-be-rejected was actually created despite the AppProject's own empty clusterResourceWhitelist" || true
pass "CHECK 3/6: a bare ClusterRole, synced through the same team project ${TEAM}, was refused by the AppProject's own empty clusterResourceWhitelist; no ClusterRole was created"
kubectl delete application team-a-clusterrole -n "${ARGOCD_NAMESPACE}" --wait=false >/dev/null 2>&1 || true

# ------------------------------------------------- 4d. the team's own
# -------------------------------------------------     ServiceAccount
# -------------------------------------------------     cannot escalate
# -------------------------------------------------     its own privileges

DEPLOYER="system:serviceaccount:${TEAM}:${TEAM}-deployer"
CAN_I_SECRETS="$(kubectl auth can-i create secrets -n "${TEAM}" --as="${DEPLOYER}" || true)"
[[ "${CAN_I_SECRETS}" == "no" ]] \
  || fail "kubectl auth can-i create secrets --as=${DEPLOYER} returned '${CAN_I_SECRETS}', expected no (team-onboard.sh's own Role never grants secrets)"
ESCALATE_ERR="$(kubectl create role escalate-attempt -n "${TEAM}" \
  --verb=get,list,watch,create,update,patch,delete --resource=secrets \
  --as="${DEPLOYER}" 2>&1)" && fail "kubectl create role escalate-attempt --as=${DEPLOYER} SUCCEEDED -- it should have been refused"
[[ "${ESCALATE_ERR}" == *"attempting to grant RBAC permissions not currently held"* || "${ESCALATE_ERR}" == *"is forbidden"* ]] \
  || fail "kubectl create role escalate-attempt --as=${DEPLOYER} failed, but not with the expected RBAC-escalation message: ${ESCALATE_ERR}"
[[ "${ESCALATE_ERR}" == *"${DEPLOYER}"* ]] \
  || fail "the escalation refusal did not name ${DEPLOYER} as the subject: ${ESCALATE_ERR}"
kubectl get role escalate-attempt -n "${TEAM}" >/dev/null 2>&1 \
  && fail "Role escalate-attempt was actually created in ${TEAM} despite the refusal" || true
pass "CHECK 4/6: ${DEPLOYER}, asked to create a Role granting 'secrets' (a resource its own Role does not itself hold), was refused by the Kubernetes API server's own RBAC escalation check, naming ${DEPLOYER} in the refusal; no such Role was created"

# ------------------------------------------------- 5. the differential
# -------------------------------------------------    check: is
# -------------------------------------------------    impersonation
# -------------------------------------------------    actually engaged?

# Removes "configmaps" from team-a-deployer-role entirely (not merely one
# verb), then deletes the live ConfigMap probe-config out from under
# Argo CD (drift) and forces a resync of the SAME, already-Synced
# Application from 4a. If Argo CD is really syncing AS the team's own
# ServiceAccount (destinationServiceAccounts actually honored), this
# resync must now fail with a Forbidden naming that ServiceAccount. If
# Argo CD is still syncing as its own capability-wide controller
# identity -- i.e. destinationServiceAccounts is accepted by the
# AppProject CRD's own schema (confirmed separately, #22 Decision 10
# H11's own fact update) but not actually acted on -- this resync
# succeeds regardless of what team-a-deployer-role says, since that Role
# governs nothing about the controller's own identity.
#
# RESULT, confirmed on real hardware (this script's own eighth real e2e
# attempt, 2026-11-25, after six earlier attempts each fixing one
# genuine bug in this script itself -- team-onboard.sh's own prior
# steps, checks 1-4 above, all PASSed first): the resync SUCCEEDED.
# Impersonation is NOT engaged. This is consistent with -- and now
# explains -- the other real fact already on record for this issue: the
# EKS managed Argo CD capability has no customer-reachable argocd-cm
# (checks above, this script's own earlier attempts), and
# `application.sync.impersonation.enabled` is a documented prerequisite
# for destinationServiceAccounts to do anything at all
# (https://argo-cd.readthedocs.io/en/stable/operator-manual/argocd-cm.yaml);
# with no way for a customer to set that flag, the field accepted by the
# AppProject CRD's own schema has no observed effect. Filed to the
# upstream tracking issue (#49): the capability advertises a CRD field
# whose precondition it gives customers no way to satisfy.
#
# This asserts the CONFIRMED CURRENT behavior (Succeeded), not the
# originally hoped-for one, so this test stays green until the platform
# changes -- if a future AWS update makes argocd-cm reachable, or
# impersonation default-on, this assertion starts failing loudly, which
# is the signal to revisit #22 Decision 10 H11 Option A.
kubectl get role "${TEAM}-deployer-role" -n "${TEAM}" -o json \
  | jq 'del(.rules[] | select(.resources == ["serviceaccounts","configmaps","pods","services"])) | .rules += [{"apiGroups":[""],"resources":["serviceaccounts","pods","services"],"verbs":["get","list","watch","create","update","patch","delete"]}]' \
  > "${WORK_DIR}/role-no-configmaps.json" || fail "jq: build role-no-configmaps.json"
kubectl apply -f "${WORK_DIR}/role-no-configmaps.json" || fail "kubectl apply role-no-configmaps.json (remove configmaps permission)"
CAN_I_CONFIGMAPS_AFTER="$(kubectl auth can-i create configmaps -n "${TEAM}" --as="${DEPLOYER}" || true)"
[[ "${CAN_I_CONFIGMAPS_AFTER}" == "no" ]] \
  || fail "after narrowing ${TEAM}-deployer-role, can-i create configmaps --as=${DEPLOYER} still says '${CAN_I_CONFIGMAPS_AFTER}' -- the Role edit did not take effect"
pass "narrowed ${TEAM}-deployer-role to remove 'configmaps' (confirmed by kubectl auth can-i, not assumed from the apply's own exit code); ${DEPLOYER} itself can no longer create a ConfigMap in ${TEAM} directly"

kubectl delete configmap probe-config -n "${TEAM}" --wait=true --timeout=30s \
  || fail "kubectl delete configmap probe-config -n ${TEAM}"
trigger_sync team-a-chart || fail "trigger team-a-chart's second sync (after narrowing the Role)"
wait_until 180 5 "team-a-chart's second sync operation to finish" op_done \
  || fail "team-a-chart's second sync did not finish within 180s (phase: $(operation_phase team-a-chart))"
SECOND_PHASE="$(operation_phase team-a-chart)"
SECOND_MESSAGE="$(operation_message team-a-chart)"
[[ "${SECOND_PHASE}" == "Succeeded" ]] \
  || fail "team-a-chart's second sync was ${SECOND_PHASE} (message: ${SECOND_MESSAGE}), expected Succeeded -- this would mean impersonation IS now engaged (a change from the confirmed 2026-11-25 behavior this test documents); if so, update this assertion and revisit #22 Decision 10 H11 Option A, do not just make this check pass again"
kubectl get configmap probe-config -n "${TEAM}" >/dev/null 2>&1 \
  || fail "ConfigMap probe-config was not recreated in ${TEAM} despite a Succeeded second sync"
pass "CHECK 6/6 (differential check, confirmed finding): even after ${DEPLOYER} itself lost the 'configmaps' permission, the SAME Application's resync still Succeeded and recreated probe-config -- sync impersonation is NOT actually engaged on this capability (tracked at #49; #22 Decision 10 H11 Option A is not viable as of 2026-11-25). Argo CD performed this sync with its own capability-wide identity throughout, not team-a-deployer's"

# Restore team-a-deployer-role to its original rules regardless (leaves
# the cell in the same state checks 1-4 left it in, for a clean
# teardown -- not itself a check, since check 5 already showed this
# Role's own content does not currently affect Argo CD's own sync).
kubectl apply -f - <<EOF || fail "kubectl apply role-with-configmaps.yaml (restore configmaps permission)"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${TEAM}-deployer-role
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts", "configmaps", "pods", "services"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
pass "restored ${TEAM}-deployer-role to its original rules before teardown"

# ------------------------------------------------------- 6. teardown

kubectl delete application team-a-chart -n "${ARGOCD_NAMESPACE}" --wait=true --timeout=60s \
  || fail "kubectl delete application team-a-chart"
kubectl delete appproject "${TEAM}" -n "${ARGOCD_NAMESPACE}" --wait=true --timeout=60s \
  || fail "kubectl delete appproject ${TEAM}"
kubectl delete namespace "${TEAM}" "${OTHER_NS}" --wait=true --timeout=90s \
  || fail "kubectl delete namespace ${TEAM} ${OTHER_NS}"
pass "deleted the Application, the team AppProject, and both namespaces before terraform destroy"

destroy_start="$(date +%s)"
tf destroy -auto-approve -input=false -var-file="${TFVARS}" \
  || fail "terraform destroy"
DESTROYED=1
pass "terraform destroy completed without manual steps ($(($(date +%s) - destroy_start))s)"

report_leftovers "${E2E_LEFTOVER_GRACE_SECONDS}" \
  || fail "resources tagged for the cluster remain after destroy"

assert_vpc_gone
