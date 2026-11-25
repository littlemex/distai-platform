#!/usr/bin/env bash
# Real-hardware check of issue #57's own goal -- a team installs a
# chart shipping its own namespaced Role/RoleBinding into its own
# namespace with no admin pre-creating that RBAC by hand -- and of #22
# Decision 10 H11's own two candidate boundaries for making that safe:
# Argo CD sync impersonation ("Option A") and an admission-time guard
# (gitops/bootstrap/team-rbac-guard.yaml). Closes the one thing an
# earlier real-hardware probe (recorded as comments on #56/#57 and a
# fact update to #22) left open: that probe confirmed the live
# AppProject CRD's own OpenAPI schema declares
# spec.destinationServiceAccounts and the value round-trips unchanged on
# a real `kubectl apply`, but it built foundation + the capability only,
# with no delivered Application, so it never attempted one real
# impersonated sync.
#
# CONFIRMED ANSWER, real hardware, 2026-11-25 (check 7 below): Argo CD
# sync impersonation is **not** engaged on the EKS managed Argo CD
# capability. destinationServiceAccounts is accepted by the AppProject
# CRD's own schema but has no observed effect, because there is no
# customer-reachable way to set `application.sync.impersonation.enabled`
# (a documented upstream prerequisite for the feature) -- this
# capability's own namespace holds no argocd-cm at all, and
# `aws eks create-capability help`'s own `argoCd` configuration object
# (namespace, awsIdc, rbacRoleMappings, networkAccess) has no such field
# either. Filed to the upstream tracking issue (#49). Option A is
# therefore NOT adopted for safety on its own. Because every sync still
# runs as the capability's own identity, which
# infra/foundation/argocd.tf's own comment confirms is bound to
# AmazonEKSClusterAdminPolicy (already holds every permission there is),
# the Kubernetes RBAC-escalation check never fires for that identity no
# matter what any team's own ServiceAccount's Role says -- checks 2 and
# 3 below show this concretely, including the actual exploit shape
# (a RoleBinding to the built-in cluster-admin ClusterRole).
#
# The boundary that actually works regardless of sync identity:
# gitops/bootstrap/team-rbac-guard.yaml, a ValidatingAdmissionPolicy
# that runs for every Role/RoleBinding write in a team namespace no
# matter who the caller is (admission runs after authorization already
# let the request through). With that guard in place,
# gitops/bootstrap/team-onboard.sh's own AppProject whitelists
# Role/RoleBinding again -- #57's own goal is restored (check 2) -- and
# the guard itself refuses the one shape that would otherwise reopen the
# gap (check 3).
#
# What this checks, each against the real API server (not a dry run):
#   1. a team's own Application, in its own team AppProject, self-syncs
#      an ordinary, non-RBAC workload chart (ServiceAccount+ConfigMap)
#      into its own namespace with no admin pre-creating it.
#   2. the SAME team project self-syncs a chart shipping its own benign,
#      namespace-scoped Role/RoleBinding -- the exact #57 item 1 scenario
#      (examples/inference/vllm/disagg-pd-llmd's sidecar RBAC) -- with no
#      admin pre-creating that RBAC. Issue #57's own goal.
#   3. the SAME team project refuses a RoleBinding referencing the
#      built-in cluster-admin ClusterRole, synced by Argo CD's own
#      capability-wide (cluster-admin-equivalent) identity -- refused by
#      team-rbac-guard.yaml's own ValidatingAdmissionPolicy, not by
#      anything checking the caller's own RBAC (there is nothing to
#      check: the caller already holds cluster-admin).
#   4. the SAME non-RBAC manifest as check 1, synced through the SAME
#      team project but aimed at a different namespace, is refused by
#      the AppProject's own destinations list, before the API server is
#      even asked. Argo CD's own project-level policy, independent of
#      which identity performs the sync.
#   5. a bare cluster-scoped object (ClusterRole), synced through the same
#      team project, is refused by the project's own empty
#      clusterResourceWhitelist. Also Argo CD's own project-level policy,
#      independent of sync identity.
#   6. the team's own ServiceAccount, asked directly (kubectl --as, no Argo
#      CD involved) to create a Role granting 'secrets', is refused with
#      a plain authorization denial -- this identity holds no permission
#      on rbac.authorization.k8s.io resources at all (not merely a
#      narrower one), so there is nothing for an RBAC-escalation check
#      to even evaluate. Says nothing about whether Argo CD's own sync
#      ever acts as this identity (that is check 7, next).
#   7. (the differential check that actually distinguishes impersonated
#      from non-impersonated sync, and the reason this script does not
#      rely on RBAC-escalation checks for checks 2-3's own safety):
#      removing a permission from the team's own ServiceAccount's Role,
#      then forcing a resync of the already-Synced Application from
#      check 1, still SUCCEEDS -- proving Argo CD performed that sync
#      (and checks 1-3's own syncs) with its own capability-wide
#      identity throughout, never impersonating the team's
#      ServiceAccount. Checks 4-6 alone would have been consistent with
#      real self-service tenancy; this check is what shows they were
#      not evidence of it, and why checks 2-3 instead rest on
#      team-rbac-guard.yaml, not on narrowing a Role nobody's sync
#      actually uses.
#   8. team-rbac-guard.yaml's own two rules (RoleBinding->ClusterRole,
#      and the Role-content allow-list), applied
#      directly with kubectl (the same cluster-admin-equivalent identity
#      this whole script runs as, not Argo CD) -- decouples each denial
#      from Argo CD's own sync behavior entirely, which check 3 already
#      showed can obscure a clean deny message behind an unrelated
#      internal crash.
#   9. (mutation check): deleting only team-rbac-guard-binding (a
#      ValidatingAdmissionPolicy with no Binding enforces nothing) and
#      retrying check 8's own wildcard case shows it now succeeds --
#      the closest proof available that the guard itself, not some
#      other cluster behavior, was responsible for check 8's denials.
#  10. (PR #66's own first remaining caveat, addressed): one sync of an
#      Application using syncPolicy.managedNamespaceMetadata (CreateNamespace=true)
#      that omits distai.dev/team and explicitly sets
#      pod-security.kubernetes.io/enforce: privileged against the
#      EXISTING team namespace, with team-namespace-guard-binding
#      deleted (the discovery), and one more of the SAME Application
#      with the Binding restored (the fix verification). The
#      discovery phase records its own outcome (did either label
#      actually change?) without asserting a specific answer, since
#      that is the fact under discovery; the fix-verification phase
#      DOES assert that distai.dev/team and
#      pod-security.kubernetes.io/enforce stay unchanged -- that is
#      this check's own actual pass/fail condition. A direct
#      kubectl overwrite of the protected pod-security.kubernetes.io/enforce
#      label itself (not an unprotected key) confirms the Binding is
#      actually deleted and inactive before the discovery sync runs. A
#      brand-new marker label is asserted present after the discovery
#      sync specifically (ruling out "the sync's own
#      managedNamespaceMetadata step never ran at all" as an
#      explanation for "nothing changed" on THAT phase), then removed
#      before the fix-verification phase and read again afterward,
#      this time combined with the guard's own message (not read in
#      isolation) into a three-way classification -- admitted, denied,
#      or inconclusive -- that fails loudly on the third outcome; see
#      that read's own comment for what the marker alone does and does
#      not distinguish. The fix verification reads the
#      Namespace's own labels directly, not operationState.phase: there
#      is no Namespace entry in this Application's own manifest at
#      all, only syncPolicy's own field, and Argo CD's own
#      namespace-metadata reconciliation is not an ordinary synced
#      resource the way a denied Role/RoleBinding is in checks 2-3 --
#      whether a denial there would even surface as a non-Succeeded
#      phase is untested (the two real-hardware runs below never
#      produced a denial to observe either way), so the Namespace's
#      own labels, not the phase, are what this check actually relies
#      on. Confirmed on real EKS, re-run against this exact wording
#      (issue #67, closed): the managedNamespaceMetadata step does not
#      engage at all with the team namespace, on either the discovery
#      or the fix-verification attempt -- no syncResult entry for kind
#      Namespace, the brand-new marker label never lands either way.
#      Argo CD's own documented CreateNamespace/managedNamespaceMetadata
#      adoption rule explains why: management only engages on first
#      sync if the namespace doesn't already exist, or already exists
#      with no labels/annotations set; team-onboard.sh creates the team
#      namespace via a client-side kubectl apply with labels already
#      set, which needs upgrading to server-side apply first (not done
#      on this platform) before Argo CD will adopt it. Earlier, on two
#      real-hardware runs of an
#      earlier form of this check (before this exact wording and the
#      marker-clearing fix above), Argo CD's own managedNamespaceMetadata
#      reconciliation did not
#      visibly attempt to overwrite either pre-existing label, with or
#      without the guard -- those two runs did not exercise the
#      guard's own denial either time, which is what check 11 below is
#      for.
#  11. (mutation check, decouples the guard's own correctness from
#      check 10's own finding that two prior runs of it never showed
#      Argo CD actually attempting the overwrite): three attempts --
#      overwriting pod-security.kubernetes.io/enforce to privileged,
#      removing distai.dev/team outright, and introducing
#      pod-security.kubernetes.io/enforce-version (rule 3) -- applied
#      directly with kubectl (no Argo CD, same cluster-admin-equivalent
#      identity this script runs as), same pattern as checks 8-9. All
#      three are denied by team-namespace-guard.yaml's own message;
#      deleting team-namespace-guard-binding makes the SAME three
#      attempts succeed; restoring the Binding denies them again. A
#      scope check on OTHER_NS (no distai.dev/team, but a Pod Security
#      label for an unrelated reason) is included here too, confirming
#      it is NOT constrained.
#  12. (PR #66's own second remaining caveat, addressed; an earlier
#      form of this exact check already passed on real hardware, this
#      revised form has since been re-run on real EKS and confirmed
#      PASS -- issue #67, closed): the real
#      chart issue #57 item 1 named
#      (examples/inference/vllm/disagg-pd-llmd, pinned at
#      feat/disagg-pd-reference's own commit) self-syncs through the
#      SAME team project as every other check here, with no admin
#      pre-creating anything -- its sidecar Role, and its
#      llm-d-router-gateway dependency chart's own namespaced Role, both
#      pass team-rbac-guard.yaml once that guard's own allow-list is
#      widened (team-rbac-guard.yaml's own comment on the widening), and
#      its InferencePool/HTTPRoute objects pass the AppProject's own
#      namespaceResourceWhitelist once that list is widened the same
#      way (gitops/bootstrap/team-onboard.sh's own comment). GPU/EFA/a
#      real Gateway are not required: this only checks that every
#      object the chart renders is admitted and the Application reaches
#      Synced, not that the engine Pods reach Running.
#  13. the same as check 12, for
#      examples/inference/sglang/disagg-pd-llmd (an identical
#      sidecar-rbac.yaml and the same router dependency, per that
#      chart's own comment) -- confirms the fix generalizes across both
#      charts issue #57 item 1 named, not just one.
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
#   TERRAFORM (terraform), E2E_WORK_DIR (mktemp -d),
#   E2E_KEEP_ON_FAILURE (0), E2E_LEFTOVER_GRACE_SECONDS (600),
#   IDC_REGION (the region to call sso-admin/identitystore in; defaults to
#   AWS_REGION)
# Requires Kubernetes 1.30+ on the target cluster (ValidatingAdmissionPolicy
# is a stable, non-beta API from 1.30 on; EKS 1.37 here is well past that).
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
IDC_REGION="${IDC_REGION:-${AWS_REGION}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/../.." && pwd)"
# Pinned to the exact commit this checkout is at, never "HEAD" (Argo CD's
# own meaning of "HEAD" is the remote's default branch, main -- not this
# checkout's own ref; this script's fixtures live only on the branch this
# PR is on, so "HEAD" fails every sync with "app path does not exist",
# confirmed on real hardware).
REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
# Checks 12-13's own real charts (examples/inference/{vllm,sglang}/disagg-pd-llmd)
# live on a different, unmerged branch (PR #51, feat/disagg-pd-reference),
# not on this PR's own branch -- Argo CD sources from any branch/commit of
# the same repoURL, so this does not need to match REVISION above. Pinned
# to that branch's own commit at the time these checks were written, same
# reasoning as REVISION's own comment (never a branch name).
DISAGG_PD_REVISION="246b7efac86945530c1dc0374ed523730663e37e"
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
        kubectl delete application team-a-chart team-a-rbac-probe team-a-clusteradmin-probe team-a-cross-ns team-a-clusterrole team-a-nsmeta-strip team-a-vllm-disagg team-a-sglang-disagg -n "${argons}" --ignore-not-found --wait=false >/dev/null 2>&1
        kubectl apply -f "${REPO_ROOT}/gitops/bootstrap/team-namespace-guard.yaml" >/dev/null 2>&1 || true
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

for b in "${TERRAFORM}" aws kubectl jq; do require_bin "${b}"; done
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
# cross-namespace target in check 4, never itself onboarded as a team).
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
# a real run: the capability's namespace held only
# the built-in kube-root-ca.crt ConfigMap, and `aws eks create-capability
# help`'s own argoCd configuration object has no impersonation field
# either) -- so this script cannot read back a cluster-wide flag the way
# it would on a self-hosted install. This is a fact about the platform,
# recorded here rather than asserted away: whether sync impersonation is
# actually engaged without that flag ever being set by a customer was
# already confirmed NOT to be (check 7 below), empirically, on this
# platform -- not something this script can confirm by reading a
# ConfigMap first.
if kubectl get configmap argocd-cm -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  IMPERSONATION_FLAG="$(kubectl get configmap argocd-cm -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.data.application\.sync\.impersonation\.enabled}')"
  [[ "${IMPERSONATION_FLAG}" == "true" ]] \
    || fail "argocd-cm exists and its application.sync.impersonation.enabled is '${IMPERSONATION_FLAG}', expected true after team-onboard.sh"
  pass "argocd-cm exists in ${ARGOCD_NAMESPACE} and application.sync.impersonation.enabled is true"
else
  info "no argocd-cm ConfigMap in ${ARGOCD_NAMESPACE} (the managed capability's own control plane runs outside this cluster, confirmed by 'aws eks create-capability help'); proceeding without it -- check 7 below already confirms destinationServiceAccounts does not impersonate anyway"
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
# -------------------------------------------------     ordinary
# -------------------------------------------------     (non-RBAC) chart
# -------------------------------------------------     self-syncs

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
pass "CHECK 1/13: team-a-chart (project ${TEAM}) self-synced an ordinary, non-RBAC workload chart (ServiceAccount+ConfigMap) into its own namespace ${TEAM} with no admin pre-creating it"

# ------------------------------------------------ 4a2. issue #57's own goal:
# ------------------------------------------------      a chart shipping its
# ------------------------------------------------      own benign namespaced
# ------------------------------------------------      RBAC self-syncs, with
# ------------------------------------------------      team-rbac-guard.yaml
# ------------------------------------------------      as the real boundary

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
trigger_sync team-a-rbac-probe || fail "trigger team-a-rbac-probe's sync"
rbac_probe_op_done() { local p; p="$(operation_phase team-a-rbac-probe)"; [[ "${p}" == "Succeeded" || "${p}" == "Failed" || "${p}" == "Error" ]]; }
wait_until 180 5 "team-a-rbac-probe's sync operation to finish" rbac_probe_op_done \
  || fail "team-a-rbac-probe's sync did not finish within 180s (phase: $(operation_phase team-a-rbac-probe))"
[[ "$(operation_phase team-a-rbac-probe)" == "Succeeded" ]] \
  || fail "team-a-rbac-probe's sync did not Succeed (phase $(operation_phase team-a-rbac-probe), message: $(operation_message team-a-rbac-probe)) -- #57's own goal (a benign chart shipping its own namespaced Role/RoleBinding self-syncing) should work once team-rbac-guard.yaml is the boundary instead of excluding the kind outright"
kubectl get role probe-sidecar-role -n "${TEAM}" >/dev/null 2>&1 \
  || fail "Role probe-sidecar-role was not actually created in ${TEAM} despite a Succeeded sync"
kubectl get rolebinding probe-sidecar-binding -n "${TEAM}" >/dev/null 2>&1 \
  || fail "RoleBinding probe-sidecar-binding was not actually created in ${TEAM} despite a Succeeded sync"
pass "CHECK 2/13: team-a-rbac-probe (project ${TEAM}) self-synced its own benign, namespace-scoped Role/RoleBinding (#57 item 1's exact scenario) with no admin pre-creating it -- #57's own goal, restored, with gitops/bootstrap/team-rbac-guard.yaml (not Argo CD sync impersonation, confirmed not engaged -- check 7 below) as the real boundary"

# ------------------------------------------------ 4a3. team-rbac-guard.yaml
# ------------------------------------------------      refuses the concrete
# ------------------------------------------------      exploit: a RoleBinding
# ------------------------------------------------      to an existing,
# ------------------------------------------------      more privileged
# ------------------------------------------------      ClusterRole

kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF || fail "kubectl apply Application team-a-clusteradmin-probe"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-a-clusteradmin-probe
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: ${TEAM}
  source:
    repoURL: https://github.com/littlemex/distai-platform.git
    targetRevision: ${REVISION}
    path: infra/foundation/tests/fixtures/tenancy-argocd-impersonation/malicious-clusteradmin-probe
  destination:
    name: "${CLUSTER}"
    namespace: ${TEAM}
EOF
clusteradmin_probe_message() {
  kubectl get application team-a-clusteradmin-probe -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.conditions[*].message}{.status.operationState.message}{.status.operationState.syncResult.resources[*].message}' 2>/dev/null
}
clusteradmin_probe_op_done() { local p; p="$(operation_phase team-a-clusteradmin-probe)"; [[ "${p}" == "Succeeded" || "${p}" == "Failed" || "${p}" == "Error" ]]; }
trigger_sync team-a-clusteradmin-probe || fail "trigger team-a-clusteradmin-probe's sync"
wait_until 120 5 "team-a-clusteradmin-probe's sync operation to finish" clusteradmin_probe_op_done \
  || fail "team-a-clusteradmin-probe's sync did not finish within 120s (phase: $(operation_phase team-a-clusteradmin-probe))"
CLUSTERADMIN_PROBE_PHASE="$(operation_phase team-a-clusteradmin-probe)"
CLUSTERADMIN_PROBE_MESSAGE="$(clusteradmin_probe_message)"
# The decisive assertions are phase != Succeeded and the object's own
# absence, not the message text: this run's own real-hardware result
# found Argo CD's internal
# "kubectl auth reconcile" RBAC-reconciliation path crashes with a nil
# pointer dereference when the API server denies the write, instead of
# cleanly surfacing team-rbac-guard's own deny message -- the sync still
# correctly reaches Failed (never Succeeded) and the object is still
# never created, which is what actually matters; this script does not
# depend on Argo CD's own error-reporting path for that RBAC kind being
# clean to prove the guard worked. If the guard's own message text IS
# present, it is logged for a stronger PASS; if not (this Argo CD crash
# case), the phase+absence evidence alone still PASSes, with that fact
# recorded, not hidden.
[[ "${CLUSTERADMIN_PROBE_PHASE}" != "Succeeded" ]] \
  || fail "team-a-clusteradmin-probe's sync SUCCEEDED -- a RoleBinding to ClusterRole cluster-admin was created in ${TEAM}; team-rbac-guard.yaml did not block it"
if kubectl get rolebinding probe-escalation-binding -n "${TEAM}" >/dev/null 2>&1; then
  fail "RoleBinding probe-escalation-binding (roleRef ClusterRole cluster-admin) was actually created in ${TEAM} despite team-rbac-guard's own refusal"
fi
if [[ "${CLUSTERADMIN_PROBE_MESSAGE}" == *"team-rbac-guard"* || "${CLUSTERADMIN_PROBE_MESSAGE}" == *"may not reference a ClusterRole"* ]]; then
  pass "CHECK 3/13: a RoleBinding referencing the built-in cluster-admin ClusterRole, synced through the same team project ${TEAM} by Argo CD's own capability-wide (cluster-admin-equivalent) sync identity, was refused by the team-rbac-guard ValidatingAdmissionPolicy (phase ${CLUSTERADMIN_PROBE_PHASE}; message: ${CLUSTERADMIN_PROBE_MESSAGE}) -- admission runs regardless of the caller's own RBAC, closing the exact gap check 7 below shows RBAC-escalation checks leave open for this identity; no such RoleBinding was created"
else
  pass "CHECK 3/13: a RoleBinding referencing the built-in cluster-admin ClusterRole, synced through the same team project ${TEAM}, did NOT succeed (phase ${CLUSTERADMIN_PROBE_PHASE}) and no such RoleBinding was created in ${TEAM} -- team-rbac-guard's own deny message was not surfaced cleanly this time (Argo CD's own 'kubectl auth reconcile' RBAC-reconciliation path crashed with a nil pointer dereference instead of reporting it, message: ${CLUSTERADMIN_PROBE_MESSAGE}; an Argo CD-side defect worth tracking at #49, not evidence the guard itself failed to act -- the object's own confirmed absence is)"
fi
kubectl delete application team-a-rbac-probe team-a-clusteradmin-probe -n "${ARGOCD_NAMESPACE}" --wait=false >/dev/null 2>&1 || true

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
if kubectl get configmap probe-config -n "${OTHER_NS}" >/dev/null 2>&1; then
  fail "ConfigMap probe-config was actually created in ${OTHER_NS} despite the AppProject's own destination refusal"
fi
pass "CHECK 4/13: the same non-RBAC manifest, same team project ${TEAM}, aimed at ${OTHER_NS} instead of its own ${TEAM}, was refused by the AppProject's own destinations list before anything was written to ${OTHER_NS}"
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
if kubectl get clusterrole tenancy-probe-clusterrole-should-be-rejected >/dev/null 2>&1; then
  fail "ClusterRole tenancy-probe-clusterrole-should-be-rejected was actually created despite the AppProject's own empty clusterResourceWhitelist"
fi
pass "CHECK 5/13: a bare ClusterRole, synced through the same team project ${TEAM}, was refused by the AppProject's own empty clusterResourceWhitelist; no ClusterRole was created"
kubectl delete application team-a-clusterrole -n "${ARGOCD_NAMESPACE}" --wait=false >/dev/null 2>&1 || true

# ------------------------------------------------- 4d. the team's own
# -------------------------------------------------     ServiceAccount
# -------------------------------------------------     holds no
# -------------------------------------------------     RBAC-management
# -------------------------------------------------     permission at all

# team-a-deployer-role (gitops/bootstrap/team-onboard.sh step 3) grants
# nothing on rbac.authorization.k8s.io resources, so this is a plain
# authorization denial (the API server refuses the request before any
# RBAC-escalation check would even run, since that check only applies
# to a caller who can already create/update the resource type at all),
# not the nuanced "attempting to grant RBAC permissions not currently
# held" escalation message -- a stronger, simpler guarantee than
# escalation-limited access would have been, and the reason this check
# does not require that specific message text.
DEPLOYER="system:serviceaccount:${TEAM}:${TEAM}-deployer"
CAN_I_CREATE_ROLES="$(kubectl auth can-i create roles.rbac.authorization.k8s.io -n "${TEAM}" --as="${DEPLOYER}" || true)"
[[ "${CAN_I_CREATE_ROLES}" == "no" ]] \
  || fail "kubectl auth can-i create roles.rbac.authorization.k8s.io --as=${DEPLOYER} returned '${CAN_I_CREATE_ROLES}', expected no (team-onboard.sh's own Role grants nothing on rbac.authorization.k8s.io)"
DENY_ERR="$(kubectl create role escalate-attempt -n "${TEAM}" \
  --verb=get,list,watch,create,update,patch,delete --resource=secrets \
  --as="${DEPLOYER}" 2>&1)" && fail "kubectl create role escalate-attempt --as=${DEPLOYER} SUCCEEDED -- it should have been refused"
[[ "${DENY_ERR}" == *"is forbidden"* ]] \
  || fail "kubectl create role escalate-attempt --as=${DEPLOYER} failed, but not with 'is forbidden': ${DENY_ERR}"
[[ "${DENY_ERR}" == *"${DEPLOYER}"* ]] \
  || fail "the refusal did not name ${DEPLOYER} as the subject: ${DENY_ERR}"
if kubectl get role escalate-attempt -n "${TEAM}" >/dev/null 2>&1; then
  fail "Role escalate-attempt was actually created in ${TEAM} despite the refusal"
fi
pass "CHECK 6/13: ${DEPLOYER}, which holds no permission on rbac.authorization.k8s.io resources at all, was refused when asked to create a Role granting 'secrets', naming ${DEPLOYER} in the refusal ('${DENY_ERR}'); no such Role was created"

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
# RESULT, confirmed on real hardware (2026-11-25, after several earlier
# attempts each fixing one genuine bug in this script itself --
# team-onboard.sh's own prior steps, checks 1-6 above, all PASSed
# first): the resync SUCCEEDED.
# Impersonation is NOT engaged. This is consistent with -- and now
# explains -- the other real fact already on record for this issue: the
# EKS managed Argo CD capability has no customer-reachable argocd-cm
# (checks above), and
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
pass "CHECK 7/13 (differential check, confirmed finding): even after ${DEPLOYER} itself lost the 'configmaps' permission, the SAME Application's resync still Succeeded and recreated probe-config -- sync impersonation is NOT actually engaged on this capability (tracked at #49; #22 Decision 10 H11 Option A is not viable as of 2026-11-25). Argo CD performed this sync with its own capability-wide identity throughout, not team-a-deployer's"

# Restore team-a-deployer-role to its original rules regardless (leaves
# the cell in the same state checks 1-6 left it in, for a clean
# teardown -- not itself a check, since check 7 just above already showed this
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

# ------------------------------------------------- 6. team-rbac-guard.yaml's
# -------------------------------------------------    own two rules,
# -------------------------------------------------    tested directly
# -------------------------------------------------    (no Argo CD),
# -------------------------------------------------    against eight
# -------------------------------------------------    distinct shapes

# Checks 1-3 above went through Argo CD's own sync path, which check 3
# showed can obscure a clean deny message behind an unrelated internal
# crash. These assertions apply team-rbac-guard.yaml's own two rules
# (RoleBinding->ClusterRole, and the Role-content allow-list) directly
# with kubectl (the same cluster-admin-equivalent identity this whole
# script already runs as -- ADMIN_PRINCIPAL_ARN's own access entry, not
# a lesser identity), against eight distinct shapes a review round
# found were not all covered by this guard's own first (deny-list)
# design: impersonate verb, rbac.authorization.k8s.io group, a bare "*"
# wildcard, Secrets, serviceaccounts/token, pods/exec, a
# wildcard-subresource form ("*/exec", which a bare-"*" check alone
# does not catch), and -- the shape that settled the allow-list
# redesign -- a Role granting "patch" on the "namespaces" resource
# itself (which would let a team's own chart strip
# team-rbac-guard.yaml's own namespaceSelector label or
# gitops/bootstrap/team-onboard.sh's own Pod Security label from its
# own Namespace). Each denial is attributed to the guard's own rule, by
# its own message text, independent of Argo CD's own behavior.
assert_rbac_denied() {
  local resource="$1" name="$2" manifest="$3" expected_substr="$4"
  local err
  err="$(kubectl apply -n "${TEAM}" -f - <<<"${manifest}" 2>&1)" && \
    fail "direct kubectl apply of ${resource}/${name} SUCCEEDED -- team-rbac-guard did not deny it"
  [[ "${err}" == *"${expected_substr}"* ]] \
    || fail "direct kubectl apply of ${resource}/${name} was refused, but not with the expected message ('${expected_substr}'): ${err}"
  if kubectl get "${resource}" "${name}" -n "${TEAM}" >/dev/null 2>&1; then
    fail "${resource}/${name} was actually created in ${TEAM} despite the refusal"
  fi
}

ALLOWLIST_MSG="may grant only"

assert_rbac_denied rolebinding guard-check-clusterrolebind "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: guard-check-clusterrolebind
  namespace: ${TEAM}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: probe-sidecar
    namespace: ${TEAM}
RBAC
)" "may not reference a ClusterRole"

assert_rbac_denied role guard-check-escalate "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-escalate
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["impersonate"]
RBAC
)" "${ALLOWLIST_MSG}"

assert_rbac_denied role guard-check-rbacgroup "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-rbacgroup
  namespace: ${TEAM}
rules:
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles"]
    verbs: ["get"]
RBAC
)" "${ALLOWLIST_MSG}"

assert_rbac_denied role guard-check-wildcard "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-wildcard
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["get"]
RBAC
)" "${ALLOWLIST_MSG}"

# Isolates the apiGroups clause specifically: resources ("pods") and
# verbs ("get") are both otherwise-allowed, so this case only fails
# because apiGroups is "*" -- guard-check-wildcard above instead
# combines an allowed apiGroups with a wildcard resources, which does
# not independently confirm the apiGroups clause itself denies a
# wildcard (a review round's own finding: deleting the apiGroups clause
# from the allow-list expression would still pass every other case in
# this check).
assert_rbac_denied role guard-check-apigroups "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-apigroups
  namespace: ${TEAM}
rules:
  - apiGroups: ["*"]
    resources: ["pods"]
    verbs: ["get"]
RBAC
)" "${ALLOWLIST_MSG}"

assert_rbac_denied role guard-check-secrets "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-secrets
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
RBAC
)" "${ALLOWLIST_MSG}"

assert_rbac_denied role guard-check-satoken "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-satoken
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    verbs: ["create"]
RBAC
)" "${ALLOWLIST_MSG}"

assert_rbac_denied role guard-check-podsexec "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-podsexec
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
RBAC
)" "${ALLOWLIST_MSG}"

assert_rbac_denied role guard-check-wildcardsubresource "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-wildcardsubresource
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["*/exec"]
    verbs: ["create"]
RBAC
)" "${ALLOWLIST_MSG}"

assert_rbac_denied role guard-check-namespaces "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-namespaces
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "patch"]
RBAC
)" "${ALLOWLIST_MSG}"

# Verb-narrowing for the three resources this PR's own allow-list
# widening added (issue #57 item 1): inferencepools, read-only in both
# real charts' own Role, must not also grant delete.
assert_rbac_denied role guard-check-inferencepools-delete "$(cat <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-inferencepools-delete
  namespace: ${TEAM}
rules:
  - apiGroups: ["inference.networking.k8s.io"]
    resources: ["inferencepools"]
    verbs: ["get", "delete"]
RBAC
)" "${ALLOWLIST_MSG}"
pass "CHECK 8/13: eleven distinct shapes (RoleBinding->ClusterRole; a Role granting the impersonate verb, the rbac.authorization.k8s.io group, a wildcard resources with an allowed apiGroups, a wildcard apiGroups with allowed resources/verbs [isolating that clause specifically], Secrets, serviceaccounts/token, pods/exec, a wildcard-subresource form, 'patch' on namespaces itself, or 'delete' on inferencepools [verb-narrowing for the three resources this allow-list's own widening added]) are all denied by a direct kubectl apply (no Argo CD) by the cluster-admin-equivalent identity this script runs as, each naming the guard's own rule in the refusal; no object was created for any of the eleven"

# ------------------------------------------------- 7. mutation check: delete
# -------------------------------------------------    the guard's own
# -------------------------------------------------    Binding, confirm the
# -------------------------------------------------    SAME manifest now
# -------------------------------------------------    succeeds, confirms
# -------------------------------------------------    the guard -- not
# -------------------------------------------------    something else --
# -------------------------------------------------    was responsible;
# -------------------------------------------------    then confirm
# -------------------------------------------------    restoring it denies
# -------------------------------------------------    the SAME case again

# A ValidatingAdmissionPolicy with no ValidatingAdmissionPolicyBinding
# enforces nothing (upstream Kubernetes's own documented behavior): the
# Binding is what actually turns validationActions on. Deleting only
# the Binding, retrying the SAME wildcard manifest check 8 already
# proved denied, and seeing it succeed this time is the closest this
# script comes to a proof-by-elimination that the guard itself, not an
# unrelated cluster behavior, was what denied it the first time.
# wait_until (not an immediate retry) covers the gap between the API
# server's own write completing and its in-process admission-policy
# cache noticing the Binding is gone or back -- a review round flagged
# an immediate retry as a possible race.
kubectl delete validatingadmissionpolicybinding team-rbac-guard-binding \
  || fail "kubectl delete validatingadmissionpolicybinding team-rbac-guard-binding"
# Deletes the Role before every single attempt, inside the retried
# function itself: a plain retry-until-success here would let a first
# attempt that happens to land right as the Binding is torn down create
# the Role, after which every later attempt is a no-op UPDATE against
# an object that already matches -- a review round's own finding, to
# guard against regardless of whether such a no-op is actually
# re-validated by this API server version. Deleting first makes every
# attempt a clean CREATE.
mutation_role_succeeds() {
  kubectl delete role guard-check-wildcard-mutation -n "${TEAM}" --ignore-not-found >/dev/null 2>&1
  kubectl apply -n "${TEAM}" -f - <<EOF >/dev/null 2>&1
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-wildcard-mutation
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["get"]
EOF
}
wait_until 60 3 "guard-check-wildcard-mutation to succeed once the Binding is gone" mutation_role_succeeds \
  || fail "guard-check-wildcard-mutation did not succeed within 60s of deleting team-rbac-guard-binding -- something else (not team-rbac-guard) was the reason check 8's wildcard case was denied"
kubectl get role guard-check-wildcard-mutation -n "${TEAM}" >/dev/null 2>&1 \
  || fail "guard-check-wildcard-mutation was not actually created even after mutation_role_succeeds reported success"
kubectl delete role guard-check-wildcard-mutation -n "${TEAM}" --ignore-not-found \
  || fail "kubectl delete role guard-check-wildcard-mutation"
kubectl apply -f "${REPO_ROOT}/gitops/bootstrap/team-rbac-guard.yaml" \
  || fail "kubectl apply gitops/bootstrap/team-rbac-guard.yaml (restore the Binding)"
# Matches the guard's own message specifically, not just any non-zero
# exit (a plain authorization or validation error unrelated to this
# guard would also make the apply fail, which an "any failure counts"
# check could not tell apart from the guard itself).
mutation_role_denied_again() {
  local err
  kubectl delete role guard-check-wildcard-mutation -n "${TEAM}" --ignore-not-found >/dev/null 2>&1
  err="$(kubectl apply -n "${TEAM}" -f - <<EOF 2>&1
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: guard-check-wildcard-mutation
  namespace: ${TEAM}
rules:
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["get"]
EOF
)" && return 1
  [[ "${err}" == *"${ALLOWLIST_MSG}"* ]]
}
wait_until 60 3 "guard-check-wildcard-mutation to be denied again (by team-rbac-guard specifically) once the Binding is restored" mutation_role_denied_again \
  || fail "guard-check-wildcard-mutation was not denied by team-rbac-guard's own message within 60s of restoring team-rbac-guard-binding -- the restore did not actually re-enable the guard, or a different gate (not team-rbac-guard) is now the reason"
if kubectl get role guard-check-wildcard-mutation -n "${TEAM}" >/dev/null 2>&1; then
  fail "guard-check-wildcard-mutation was actually created on the post-restore attempt despite mutation_role_denied_again reporting denial"
fi
pass "CHECK 9/13 (mutation check): the SAME wildcard-granting Role check 8 showed denied SUCCEEDS once team-rbac-guard-binding is deleted, and is DENIED AGAIN, by the guard's own message, once the Binding is restored -- confirms the guard itself, not an unrelated cluster behavior, was responsible for check 8's own denials, in both directions"

# ------------------------------------------------------- 8. PR #66's own
# -------------------------------------------------------    first remaining
# -------------------------------------------------------    caveat:
# -------------------------------------------------------    managedNamespaceMetadata
# -------------------------------------------------------    and the
# -------------------------------------------------------    Namespace's own
# -------------------------------------------------------    security-relevant
# -------------------------------------------------------    labels

# Same before/after shape as check 9: delete team-namespace-guard-binding,
# attempt the exploit through an actual Argo CD sync (not a plain kubectl
# apply, since what matters is whether Argo CD's own
# managedNamespaceMetadata reconciliation -- not this script -- performs
# the write), record exactly what happened (the discovery -- this script
# does not presuppose which way Argo CD's own namespace-metadata
# reconciliation behaves), then restore the Binding and require the SAME
# attempt to leave both labels unchanged (the fix verification, which is
# the assertion that actually fails this script if wrong).
# Dedicated functions (not one parameterized by key): kubectl's own
# jsonpath implementation splits a bare field path on ".", so a label
# key containing "." must escape every dot -- the exact form
# team-onboard.sh's own EXISTING_LABEL check already uses successfully
# for distai.dev/team. A bracket-with-quotes form
# ({.metadata.labels['key']}) was tried first and silently returned
# empty instead of erroring (2>/dev/null hid the parse failure) --
# this file's own working precedent is escaped dots, not quoted
# brackets, so this follows it instead of inventing a second form.
read_team_label() { kubectl get namespace "${TEAM}" -o jsonpath='{.metadata.labels.distai\.dev/team}' 2>/dev/null; }
read_psa_label() { kubectl get namespace "${TEAM}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null; }
# Loud on error, not folded into 2>/dev/null the way the three direct
# reads of this label used to be (a round 3 review finding: an API
# error would otherwise read identically to "the label is absent").
read_version_label() {
  local out err rc
  err="$(mktemp)"
  set +e
  out="$(kubectl get namespace "${TEAM}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce-version}' 2>"${err}")"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    # Every caller of this function invokes it inside "$(...)" -- the
    # shared fail() helper prints to stdout (e2e-lib.sh's own log()),
    # which that same "$(...)" would capture and discard on the exit
    # below rather than show it. Printed to stderr directly instead,
    # so the diagnostic is actually visible when this aborts the
    # script (a round 5 review finding).
    echo "FAIL read_version_label: kubectl get namespace ${TEAM} failed (exit ${rc}): $(cat "${err}")" >&2
    exit 1
  fi
  rm -f "${err}"
  echo -n "${out}"
}

ORIG_TEAM_LABEL="$(read_team_label)"
ORIG_PSA_LABEL="$(read_psa_label)"
[[ "${ORIG_TEAM_LABEL}" == "${TEAM}" ]] \
  || fail "namespace ${TEAM} does not carry distai.dev/team=${TEAM} before the managedNamespaceMetadata probe (got '${ORIG_TEAM_LABEL}')"
[[ "${ORIG_PSA_LABEL}" == "restricted" ]] \
  || fail "namespace ${TEAM} does not carry pod-security.kubernetes.io/enforce=restricted before the managedNamespaceMetadata probe (got '${ORIG_PSA_LABEL}')"

read_marker_label() { kubectl get namespace "${TEAM}" -o jsonpath='{.metadata.labels.distai\.dev/nsmeta-probe-marker}' 2>/dev/null; }
# Captures stderr separately and fails loudly on it, rather than
# folding it into 2>/dev/null the way an earlier version of
# read_ns_label did (the bug this file's own check 10 comment already
# describes) -- an empty result from THIS function means "the
# Namespace is genuinely absent from syncResult.resources", not "the
# jsonpath itself errored and this masked it".
sync_result_for_namespace() {
  local out err rc
  err="$(mktemp)"
  # set +e around this one assignment: under this script's own set -e
  # (active even inside this function, which a caller always invokes
  # inside a "$(...)" subshell), a failing command on the right-hand
  # side of "out=$(...)" would abort this subshell immediately, before
  # the next line ever reads $? -- the loud fail() below would never
  # run, and the caller would just see an empty, silent failure (a
  # round 3 review finding).
  set +e
  out="$(kubectl get application team-a-nsmeta-strip -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath="{.status.operationState.syncResult.resources[?(@.kind=='Namespace')]}" 2>"${err}")"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    # Same reasoning as read_version_label's own comment: printed to
    # stderr directly, not through fail() (which prints to stdout and
    # would be captured and discarded by this function's own callers,
    # all of which invoke it inside "$(...)").
    echo "FAIL sync_result_for_namespace: kubectl get application team-a-nsmeta-strip failed (exit ${rc}): $(cat "${err}")" >&2
    exit 1
  fi
  rm -f "${err}"
  echo -n "${out}"
}

apply_nsmeta_strip_app() {
  kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-a-nsmeta-strip
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
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    managedNamespaceMetadata:
      labels:
        distai.dev/nsmeta-probe-marker: "1"
        pod-security.kubernetes.io/enforce: privileged
EOF
}
nsmeta_strip_op_done() { local p; p="$(operation_phase team-a-nsmeta-strip)"; [[ "${p}" == "Succeeded" || "${p}" == "Failed" || "${p}" == "Error" ]]; }

kubectl delete validatingadmissionpolicybinding team-namespace-guard-binding \
  || fail "kubectl delete validatingadmissionpolicybinding team-namespace-guard-binding"
# Confirms the Binding is actually gone and ineffective RIGHT NOW, with a
# plain kubectl label (no Argo CD involved), before relying on an Argo CD
# sync to exercise anything -- decouples "the guard is inactive" from "Argo
# CD attempted a write", so this test's own later finding about Argo CD's
# own behavior cannot be explained by a Binding-deletion propagation delay
# instead.
# A probe on a key the policy does NOT protect would succeed whether
# the Binding is active or not, and prove nothing -- this overwrites
# pod-security.kubernetes.io/enforce itself (the same key check 11's
# own overwrite_psa_succeeds uses), the one write this policy's own
# rule 2 actually exists to deny, then restores it.
overwrite_psa_to_baseline_succeeds() { kubectl label namespace "${TEAM}" --overwrite "pod-security.kubernetes.io/enforce=baseline" >/dev/null 2>&1; }
wait_until 60 3 "direct kubectl label (baseline) to succeed right after deleting team-namespace-guard-binding" overwrite_psa_to_baseline_succeeds \
  || fail "direct kubectl label (pod-security.kubernetes.io/enforce=baseline) did not succeed within 60s of deleting team-namespace-guard-binding -- the Binding's own deletion has not actually taken effect yet"
[[ "$(read_psa_label)" == "baseline" ]] \
  || fail "pod-security.kubernetes.io/enforce is '$(read_psa_label)', not 'baseline', even though the direct kubectl label reported success"
kubectl label namespace "${TEAM}" --overwrite "pod-security.kubernetes.io/enforce=restricted" \
  || fail "kubectl label namespace ${TEAM} (restore pod-security.kubernetes.io/enforce before the discovery sync)"
pass "confirmed team-namespace-guard-binding is deleted and inactive (a plain kubectl overwrite of the protected pod-security.kubernetes.io/enforce label itself succeeded) before triggering the discovery sync below"
apply_nsmeta_strip_app || fail "kubectl apply Application team-a-nsmeta-strip (first attempt, guard absent)"
trigger_sync team-a-nsmeta-strip || fail "trigger team-a-nsmeta-strip's first sync (guard absent)"
wait_until 120 5 "team-a-nsmeta-strip's first sync operation to finish" nsmeta_strip_op_done \
  || fail "team-a-nsmeta-strip's first sync did not finish within 120s (phase: $(operation_phase team-a-nsmeta-strip))"
DISCOVERY_TEAM_LABEL="$(read_team_label)"
DISCOVERY_PSA_LABEL="$(read_psa_label)"
DISCOVERY_MARKER_LABEL="$(read_marker_label)"
DISCOVERY_NS_SYNCRESULT="$(sync_result_for_namespace)"
info "discovery (team-namespace-guard-binding absent, sync phase $(operation_phase team-a-nsmeta-strip)): distai.dev/team is now '${DISCOVERY_TEAM_LABEL}' (was '${ORIG_TEAM_LABEL}'), pod-security.kubernetes.io/enforce is now '${DISCOVERY_PSA_LABEL}' (was '${ORIG_PSA_LABEL}'), distai.dev/nsmeta-probe-marker (a key that never existed before, declared only in managedNamespaceMetadata, no 'once set' rule could explain it either way) is now '${DISCOVERY_MARKER_LABEL}'; the Application's own syncResult entry for kind Namespace: ${DISCOVERY_NS_SYNCRESULT:-<none; the Namespace never appears as a syncResult entry at all>}"
if [[ "${DISCOVERY_MARKER_LABEL}" != "1" && -z "${DISCOVERY_NS_SYNCRESULT}" ]]; then
  # Both signals agree the Application's own namespace-metadata step
  # never engaged at all (not "ran and chose not to overwrite"): no
  # syncResult entry for kind Namespace, and not even the brand-new
  # marker landed. Per Argo CD's own documented CreateNamespace /
  # managedNamespaceMetadata adoption rule (sync-options.md's own
  # "Namespace Metadata" section: management only engages on first
  # sync "if the namespace doesn't already exist, or if it already
  # exists and doesn't already have labels and/or annotations set on
  # it" -- adopting a namespace that already carries labels/
  # annotations from a client-side apply, which is exactly how
  # team-onboard.sh creates ${TEAM}, requires upgrading that resource
  # to server-side apply first, which this platform does not do), this
  # is an expected, non-error outcome here, not a script defect to
  # abort the whole run over -- confirmed identically on two earlier
  # real-hardware runs of an earlier form of this check (recorded
  # above) and now a third time, with the marker making the "never
  # engaged" explanation decisive instead of merely consistent. This no
  # longer hard-fails (round 6 fix, tracked in #67): a `fail` here
  # used to abort the entire script under `set -e`, which meant one
  # outcome of THIS discovery -- itself explicitly described in this
  # check's own top comment as a possible, legitimate finding -- was
  # silently preventing checks 11-13 below from ever running, on every
  # real-hardware attempt of this script's current form.
  DISCOVERY_OUTCOME="the managedNamespaceMetadata step did not engage at all (no syncResult entry for kind Namespace, marker never added) -- expected per Argo CD's own documented namespace-adoption rule, since ${TEAM} already carried labels from team-onboard.sh's own client-side apply before this Application's first sync; both pre-existing labels are necessarily unchanged (distai.dev/team='${DISCOVERY_TEAM_LABEL}', pod-security.kubernetes.io/enforce='${DISCOVERY_PSA_LABEL}')"
  info "on this run, Argo CD's own managedNamespaceMetadata reconciliation did not engage with ${TEAM} at all (confirmed, not merely consistent: the brand-new marker label never landed and the Namespace never appears in this sync's own syncResult) -- team-namespace-guard.yaml is still applied as a stated, defense-in-depth boundary against this surface regardless, and check 11 below tests it directly"
elif [[ "${DISCOVERY_TEAM_LABEL}" != "${ORIG_TEAM_LABEL}" || "${DISCOVERY_PSA_LABEL}" != "${ORIG_PSA_LABEL}" ]]; then
  DISCOVERY_OUTCOME="at least one label CHANGED (distai.dev/team='${DISCOVERY_TEAM_LABEL}', pod-security.kubernetes.io/enforce='${DISCOVERY_PSA_LABEL}') -- the bypass PR #66's own caveat described is real on this run"
  info "CONFIRMED on real hardware: without team-namespace-guard, a team's own Application's managedNamespaceMetadata (CreateNamespace=true, against the EXISTING team namespace) changes at least one of these labels -- the bypass PR #66's own caveat described is real"
elif [[ "${DISCOVERY_MARKER_LABEL}" == "1" ]]; then
  DISCOVERY_OUTCOME="both labels unchanged (distai.dev/team='${DISCOVERY_TEAM_LABEL}', pod-security.kubernetes.io/enforce='${DISCOVERY_PSA_LABEL}')"
  info "on this run, Argo CD's own managedNamespaceMetadata reconciliation added the brand-new marker label but did not change either pre-existing one, even with team-namespace-guard absent -- team-namespace-guard.yaml is still applied as a stated, defense-in-depth boundary against this surface regardless"
else
  fail "distai.dev/nsmeta-probe-marker is '${DISCOVERY_MARKER_LABEL}' and the Namespace's own syncResult entry is '${DISCOVERY_NS_SYNCRESULT}' -- this combination (a syncResult entry exists for kind Namespace, but the brand-new marker still did not land) is not one of the two explained outcomes above and this script cannot currently explain it; the pre-existing labels are distai.dev/team='${DISCOVERY_TEAM_LABEL}', pod-security.kubernetes.io/enforce='${DISCOVERY_PSA_LABEL}'"
fi
# Restore the correct values directly (this script's own state, not
# Argo CD's), independent of whichever way the discovery above went, so
# the rest of this script -- and the fix-verification attempt right
# below -- starts from the same known-good labels every other check
# already assumed. Also removes the marker label discovery just added:
# without this, the fix-verification phase's own read of that marker
# would be satisfied by discovery's own leftover regardless of what
# happens in that phase, proving nothing (a round 2 review finding).
kubectl label namespace "${TEAM}" --overwrite \
  "distai.dev/team=${TEAM}" "pod-security.kubernetes.io/enforce=restricted" \
  || fail "kubectl label namespace ${TEAM} (restore distai.dev/team and pod-security.kubernetes.io/enforce after the discovery attempt)"
kubectl label namespace "${TEAM}" "distai.dev/nsmeta-probe-marker-" \
  || fail "kubectl label namespace ${TEAM} (remove discovery's own marker label before the fix-verification phase)"
kubectl apply -f "${REPO_ROOT}/gitops/bootstrap/team-namespace-guard.yaml" \
  || fail "kubectl apply gitops/bootstrap/team-namespace-guard.yaml (restore the Binding)"

# Fix verification: the SAME managedNamespaceMetadata, retried now that
# team-namespace-guard is back. A fresh Application object (delete then
# recreate, not merely resync) rules out any possibility that Argo CD
# treats this as a no-op against its own prior, already-applied desired
# state rather than a real write attempt.
kubectl delete application team-a-nsmeta-strip -n "${ARGOCD_NAMESPACE}" --wait=true --timeout=60s >/dev/null 2>&1 || true
# Gives the API server's in-process admission-policy cache a moment to
# notice the Binding (re-applied just above) is back, same reasoning as
# check 9's own mutation_role_denied_again, before the retry below.
sleep 10
apply_nsmeta_strip_app || fail "kubectl apply Application team-a-nsmeta-strip (retry, team-namespace-guard restored)"
trigger_sync team-a-nsmeta-strip || fail "trigger team-a-nsmeta-strip's retried sync (team-namespace-guard restored)"
wait_until 120 5 "team-a-nsmeta-strip's retried sync operation to finish" nsmeta_strip_op_done \
  || fail "team-a-nsmeta-strip's retried sync did not finish within 120s (phase: $(operation_phase team-a-nsmeta-strip))"
# The decisive assertion is the Namespace's own labels, not
# operationState.phase: Argo CD's own namespace-metadata management is
# not an ordinary synced resource (there is no Namespace entry in this
# Application's own manifest at all, only syncPolicy's own field), and
# whether a denial on it would even surface as a non-Succeeded phase
# the way a denied Role/RoleBinding does in checks 2-3 above is
# untested here (neither real-hardware run of this check produced a
# denial on this specific field to observe). Logged as info, not
# asserted on, for exactly that reason.
NSMETA_RETRY_PHASE="$(operation_phase team-a-nsmeta-strip)"
NSMETA_PROBE_MESSAGE="$(kubectl get application team-a-nsmeta-strip -n "${ARGOCD_NAMESPACE}" \
  -o jsonpath='{.status.conditions[*].message}{.status.operationState.message}{.status.operationState.syncResult.resources[*].message}' 2>/dev/null)"
RETRY_NS_SYNCRESULT="$(sync_result_for_namespace)"
info "team-a-nsmeta-strip's retried sync (team-namespace-guard restored) reached phase ${NSMETA_RETRY_PHASE} (message: ${NSMETA_PROBE_MESSAGE}; Namespace syncResult entry: ${RETRY_NS_SYNCRESULT:-<none>}); checking the Namespace's own labels directly rather than relying on this phase"
AFTER_FIX_TEAM_LABEL="$(read_team_label)"
AFTER_FIX_PSA_LABEL="$(read_psa_label)"
AFTER_FIX_MARKER_LABEL="$(read_marker_label)"
[[ "${AFTER_FIX_TEAM_LABEL}" == "${TEAM}" ]] \
  || fail "SECURITY: after the retried team-a-nsmeta-strip sync (team-namespace-guard restored, phase ${NSMETA_RETRY_PHASE}), namespace ${TEAM}'s own distai.dev/team label is '${AFTER_FIX_TEAM_LABEL}', not '${TEAM}'"
[[ "${AFTER_FIX_PSA_LABEL}" == "restricted" ]] \
  || fail "SECURITY: after the retried team-a-nsmeta-strip sync (team-namespace-guard restored, phase ${NSMETA_RETRY_PHASE}), namespace ${TEAM}'s own pod-security.kubernetes.io/enforce label is '${AFTER_FIX_PSA_LABEL}', not 'restricted'"
# The marker label was removed just before this retry (not left over
# from the discovery phase -- a round 2 review finding, the earlier
# version of this check read discovery's own leftover here and
# asserted nothing about this phase at all). Read alone, present means
# this UPDATE as a whole was not rejected (consistent with either "the
# guard evaluated it and had nothing to deny this time" or "Argo CD
# did not attempt the protected fields but did add this one"); absent
# is consistent with either "the API server rejected this UPDATE as a
# whole" (CEL admission denies the entire write, not field-by-field,
# so a denial on the protected fields would also keep an unrelated new
# key from landing in the same request) or "Argo CD never sends this
# request at all" -- this read alone cannot tell those two apart,
# which is exactly why check 11 tests the policy directly instead of
# relying on this marker in isolation. Combined with
# NSMETA_PROBE_MESSAGE below, though, it IS a pass/fail signal: the
# classification right after this line fails loudly if neither
# expected combination holds, rather than treating every reading as
# equally fine.
info "distai.dev/nsmeta-probe-marker (removed before this retry) reads '${AFTER_FIX_MARKER_LABEL}' after it -- see the comment above for what that does and does not establish by itself"
# Classify this retry into exactly one of three outcomes, rather than
# reporting a single "closed" claim the code only sometimes actually
# checked: the marker reading "1" means the write was admitted (the
# guard was not exercised this run); the guard's own message appearing
# in NSMETA_PROBE_MESSAGE means the write was denied; neither is
# inconclusive, not a silent PASS, since that combination is not one
# this script can currently explain -- the fail() two lines below
# treats that combination as a real failure, not an edge case to wave
# through.
if [[ "${AFTER_FIX_MARKER_LABEL}" == "1" ]]; then
  RETRY_OUTCOME="admitted (marker present) -- the guard was NOT exercised by this particular retry"
elif [[ "${NSMETA_PROBE_MESSAGE}" == *"may not be removed or"* ]]; then
  RETRY_OUTCOME="denied (guard's own message present in the sync result) -- the guard WAS exercised and did deny the write"
elif [[ -z "${RETRY_NS_SYNCRESULT}" ]]; then
  # Same "never engaged at all" signature as the discovery phase above
  # (no syncResult entry for kind Namespace either), not a third,
  # unexplained combination -- round 6 fix, tracked in #67, same
  # reasoning as the discovery branch above: expected given ${TEAM}
  # already carried labels from a client-side apply before this
  # Application's first sync (Argo CD's own documented
  # CreateNamespace/managedNamespaceMetadata adoption rule). The guard
  # was not exercised here either, for the same reason it was not
  # exercised during discovery: Argo CD never attempted the write that
  # team-rbac-guard would otherwise have to evaluate.
  RETRY_OUTCOME="not engaged at all (no syncResult entry for kind Namespace, marker still absent) -- same as the discovery outcome above, not a new or unexplained combination; the guard was not exercised because Argo CD never attempted the write"
else
  fail "team-a-nsmeta-strip's retried sync (team-namespace-guard restored) is inconclusive: the marker is '${AFTER_FIX_MARKER_LABEL}' (not '1'), NSMETA_PROBE_MESSAGE ('${NSMETA_PROBE_MESSAGE}') does not contain the guard's own message, and the Namespace's own syncResult entry is non-empty ('${RETRY_NS_SYNCRESULT}') -- this script cannot currently explain this combination; the Namespace's own two protected labels are still confirmed correct above, but this retry's own evidence about WHY is not"
fi
pass "CHECK 10/13 (PR #66's own first remaining caveat, addressed): one sync with team-namespace-guard-binding absent and one with it restored, both against a team's own Application using syncPolicy.managedNamespaceMetadata (CreateNamespace=true, against the EXISTING team namespace ${TEAM}) to omit distai.dev/team and set pod-security.kubernetes.io/enforce: privileged -- the discovery's own outcome (Binding absent): ${DISCOVERY_OUTCOME}; the retry's own outcome (Binding restored, phase ${NSMETA_RETRY_PHASE}): ${RETRY_OUTCOME}; the Namespace's own labels after the retry are confirmed distai.dev/team=${TEAM} and pod-security.kubernetes.io/enforce=restricted regardless of either outcome above. Check 11 below tests team-namespace-guard.yaml's own denial directly either way"
kubectl delete application team-a-nsmeta-strip -n "${ARGOCD_NAMESPACE}" --wait=false >/dev/null 2>&1 || true

# ------------------------------------------------------- 8b. team-namespace-guard,
# -------------------------------------------------------     tested directly
# -------------------------------------------------------     (no Argo CD):
# -------------------------------------------------------     on the two
# -------------------------------------------------------     real-hardware
# -------------------------------------------------------     runs of check
# -------------------------------------------------------     10's own
# -------------------------------------------------------     discovery,
# -------------------------------------------------------     neither
# -------------------------------------------------------     showed Argo
# -------------------------------------------------------     CD's own
# -------------------------------------------------------     managedNamespaceMetadata
# -------------------------------------------------------     reconciliation
# -------------------------------------------------------     visibly
# -------------------------------------------------------     attempting to
# -------------------------------------------------------     overwrite
# -------------------------------------------------------     either
# -------------------------------------------------------     pre-existing
# -------------------------------------------------------     label -- so
# -------------------------------------------------------     check 10
# -------------------------------------------------------     alone did not
# -------------------------------------------------------     exercise the
# -------------------------------------------------------     guard's own
# -------------------------------------------------------     denial on
# -------------------------------------------------------     either of
# -------------------------------------------------------     those two
# -------------------------------------------------------     runs. Same
# -------------------------------------------------------     reasoning as
# -------------------------------------------------------     checks 8-9
# -------------------------------------------------------     (team-rbac-guard):
# -------------------------------------------------------     decouple the
# -------------------------------------------------------     guard's own
# -------------------------------------------------------     correctness
# -------------------------------------------------------     from any one
# -------------------------------------------------------     caller's
# -------------------------------------------------------     behavior.

# Only one deviation shape is exercised per label (an outright removal
# for distai.dev/team, a value override for pod-security.kubernetes.io/enforce) --
# not all four combinations (each label could instead take the other
# shape). team-namespace-guard.yaml's own validations check equality
# against the old value for both, so a removal and a value override
# fail that equality check identically; a fourth test of the already-
# proven-equivalent other shape would not exercise a different code
# path.

# expected_substr lets this cover rule 3's own message text too (does
# not share rule 1-2's "may not be removed or" wording).
assert_nsguard_denied() {
  local desc="$1" expected_substr="$2"; shift 2
  local err
  err="$("$@" 2>&1)" && fail "${desc} SUCCEEDED -- team-namespace-guard did not deny it"
  [[ "${err}" == *"${expected_substr}"* ]] \
    || fail "${desc} was refused, but not with team-namespace-guard's own message ('${expected_substr}'): ${err}"
}
REMOVED_MSG="may not be removed or"
VERSION_MSG="may not introduce, remove or change"
assert_nsguard_denied "direct kubectl: overwriting pod-security.kubernetes.io/enforce to privileged" "${REMOVED_MSG}" \
  kubectl label namespace "${TEAM}" --overwrite "pod-security.kubernetes.io/enforce=privileged"
[[ "$(read_psa_label)" == "restricted" ]] \
  || fail "SECURITY: after the direct, denied kubectl label attempt, pod-security.kubernetes.io/enforce is '$(read_psa_label)', not 'restricted'"
assert_nsguard_denied "direct kubectl: removing the distai.dev/team label" "${REMOVED_MSG}" \
  kubectl label namespace "${TEAM}" "distai.dev/team-"
[[ "$(read_team_label)" == "${TEAM}" ]] \
  || fail "SECURITY: after the direct, denied kubectl label-removal attempt, distai.dev/team is '$(read_team_label)', not '${TEAM}'"
# Rule 3 (a review round found its own earlier, state-based form
# would have denied every future UPDATE once this key was ever
# present, fixed to a transition check): introducing
# pod-security.kubernetes.io/enforce-version where it was absent must
# also be denied.
assert_nsguard_denied "direct kubectl: introducing pod-security.kubernetes.io/enforce-version" "${VERSION_MSG}" \
  kubectl label namespace "${TEAM}" "pod-security.kubernetes.io/enforce-version=v1.28"
# Assigned to a variable first, not tested inline as [[ -z "$(...)" ]]:
# read_version_label's own fail() exits only the subshell that
# "$(...)" creates, which [[ ]] does not itself check the exit status
# of -- an API error inside read_version_label would otherwise read
# identically to "the label is unset" (a round 4 review finding).
VERSION_LABEL_NOW="$(read_version_label)"
[[ -z "${VERSION_LABEL_NOW}" ]] \
  || fail "SECURITY: after the direct, denied kubectl label attempt, pod-security.kubernetes.io/enforce-version is set"
pass "direct kubectl (no Argo CD): team-namespace-guard denies an explicit value override of pod-security.kubernetes.io/enforce, an outright removal of distai.dev/team, and introducing pod-security.kubernetes.io/enforce-version; none of the three changed anything"

# Mutation check, same shape as check 9: delete team-namespace-guard-binding,
# show all three of the SAME direct attempts now succeed (the guard, not
# something else, was what denied them), restore the correct label
# values, then restore the Binding and show all three are denied again.
# wait_until (not an immediate attempt) covers the gap between the
# Binding's own deletion completing and the API server's in-process
# admission-policy cache noticing it is gone, same reasoning check 9
# already uses the other way around (noticing a restored Binding).
kubectl delete validatingadmissionpolicybinding team-namespace-guard-binding \
  || fail "kubectl delete validatingadmissionpolicybinding team-namespace-guard-binding (second time, direct guard check)"
overwrite_psa_succeeds() { kubectl label namespace "${TEAM}" --overwrite "pod-security.kubernetes.io/enforce=privileged" >/dev/null 2>&1; }
wait_until 60 3 "direct kubectl label (privileged) to succeed once team-namespace-guard-binding is deleted" overwrite_psa_succeeds \
  || fail "direct kubectl label (privileged) did not succeed within 60s of deleting team-namespace-guard-binding -- something else (not team-namespace-guard) was the reason it was denied above"
kubectl get namespace "${TEAM}" >/dev/null 2>&1 \
  || fail "namespace ${TEAM} no longer exists -- an empty label read below would misread as 'removed by the guard-absent attempt' rather than 'namespace gone'"
[[ "$(read_psa_label)" == "privileged" ]] \
  || fail "pod-security.kubernetes.io/enforce is '$(read_psa_label)', not 'privileged', even though the kubectl label command reported success"
remove_team_label_succeeds() { kubectl label namespace "${TEAM}" "distai.dev/team-" >/dev/null 2>&1; }
wait_until 60 3 "direct kubectl label removal (distai.dev/team) to succeed once team-namespace-guard-binding is deleted" remove_team_label_succeeds \
  || fail "direct kubectl label removal did not succeed within 60s of deleting team-namespace-guard-binding -- something else (not team-namespace-guard) was the reason it was denied above"
kubectl get namespace "${TEAM}" >/dev/null 2>&1 \
  || fail "namespace ${TEAM} no longer exists -- an empty label read below would misread as 'removed by the guard-absent attempt' rather than 'namespace gone'"
[[ -z "$(read_team_label)" ]] \
  || fail "distai.dev/team is still '$(read_team_label)' after a reportedly successful removal"
introduce_version_label_succeeds() { kubectl label namespace "${TEAM}" "pod-security.kubernetes.io/enforce-version=v1.28" >/dev/null 2>&1; }
wait_until 60 3 "direct kubectl label (enforce-version) to succeed once team-namespace-guard-binding is deleted" introduce_version_label_succeeds \
  || fail "direct kubectl label (enforce-version) did not succeed within 60s of deleting team-namespace-guard-binding -- something else (not team-namespace-guard) was the reason it was denied above"
VERSION_LABEL_NOW="$(read_version_label)"
[[ "${VERSION_LABEL_NOW}" == "v1.28" ]] \
  || fail "pod-security.kubernetes.io/enforce-version did not actually get set to v1.28 even though the kubectl label command reported success"
pass "mutation check (guard absent): the SAME three direct attempts check 11 showed denied all SUCCEED once team-namespace-guard-binding is deleted -- confirms the guard itself, not an unrelated cluster behavior, was responsible"
kubectl label namespace "${TEAM}" --overwrite \
  "distai.dev/team=${TEAM}" "pod-security.kubernetes.io/enforce=restricted" \
  || fail "kubectl label namespace ${TEAM} (restore after the mutation check's own guard-absent attempts)"
kubectl label namespace "${TEAM}" "pod-security.kubernetes.io/enforce-version-" \
  || fail "kubectl label namespace ${TEAM} (remove the enforce-version label introduced during the mutation check's own guard-absent attempts)"
kubectl apply -f "${REPO_ROOT}/gitops/bootstrap/team-namespace-guard.yaml" \
  || fail "kubectl apply gitops/bootstrap/team-namespace-guard.yaml (restore the Binding, second time)"
sleep 10
assert_nsguard_denied "direct kubectl (Binding restored): overwriting pod-security.kubernetes.io/enforce to privileged" "${REMOVED_MSG}" \
  kubectl label namespace "${TEAM}" --overwrite "pod-security.kubernetes.io/enforce=privileged"
assert_nsguard_denied "direct kubectl (Binding restored): removing the distai.dev/team label" "${REMOVED_MSG}" \
  kubectl label namespace "${TEAM}" "distai.dev/team-"
assert_nsguard_denied "direct kubectl (Binding restored): introducing pod-security.kubernetes.io/enforce-version" "${VERSION_MSG}" \
  kubectl label namespace "${TEAM}" "pod-security.kubernetes.io/enforce-version=v1.28"
[[ "$(read_team_label)" == "${TEAM}" && "$(read_psa_label)" == "restricted" ]] \
  || fail "after restoring team-namespace-guard-binding, labels are distai.dev/team='$(read_team_label)' pod-security.kubernetes.io/enforce='$(read_psa_label)', expected ${TEAM}/restricted"
VERSION_LABEL_NOW="$(read_version_label)"
[[ -z "${VERSION_LABEL_NOW}" ]] \
  || fail "after restoring team-namespace-guard-binding, pod-security.kubernetes.io/enforce-version is still set"

# Scope check (round 2 review item 1): a namespace that carries a Pod
# Security label for a reason that has nothing to do with this guard
# (OTHER_NS, never onboarded as a team, carries no distai.dev/team)
# must NOT be constrained by team-namespace-guard -- the earlier,
# OR-based matchConditions would have constrained it; the current,
# distai.dev/team-only gate must not.
kubectl label namespace "${OTHER_NS}" --overwrite "pod-security.kubernetes.io/enforce=baseline" \
  || fail "kubectl label namespace ${OTHER_NS} (give it an unrelated Pod Security label for the scope check)"
kubectl label namespace "${OTHER_NS}" --overwrite "pod-security.kubernetes.io/enforce=privileged" \
  || fail "SCOPE: relabeling pod-security.kubernetes.io/enforce on ${OTHER_NS} (which carries no distai.dev/team) was denied with team-namespace-guard-binding present -- this guard's own matchConditions is constraining a namespace it should not"
[[ "$(kubectl get namespace "${OTHER_NS}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)" == "privileged" ]] \
  || fail "pod-security.kubernetes.io/enforce on ${OTHER_NS} did not actually change to privileged even though the kubectl label command reported success"
pass "scope check: team-namespace-guard did not constrain ${OTHER_NS} (a namespace with a Pod Security label but no distai.dev/team) even with team-namespace-guard-binding present"
pass "CHECK 11/13 (mutation check, team-namespace-guard tested directly): all three direct attempts are denied again, by the guard's own message, once team-namespace-guard-binding is restored -- exercises the guard's own denial directly, independent of whether any particular Argo CD sync ever reaches for the fields it protects"

# ------------------------------------------------------- 9. PR #66's own
# -------------------------------------------------------    second
# -------------------------------------------------------    remaining
# -------------------------------------------------------    caveat: the
# -------------------------------------------------------    real charts
# -------------------------------------------------------    issue #57
# -------------------------------------------------------    item 1 named
# -------------------------------------------------------    self-sync
# -------------------------------------------------------    through the
# -------------------------------------------------------    SAME team
# -------------------------------------------------------    project

# Gateway API v1.6.2 and Gateway API Inference Extension v1.6.2 CRDs:
# both charts render an HTTPRoute and an InferencePool (cluster-scoped
# CRDs an administrator installs once, cluster-wide -- same split as
# examples/inference/vllm/disagg-pd-llmd's own README, "Prerequisites").
# No Gateway implementation, GatewayClass or Gateway object is installed
# -- this script only checks that every object each chart renders is
# admitted and the Application reaches Synced, not that its own
# HTTPRoute is Accepted or that any engine Pod reaches Running (no GPU,
# no EFA, no Gateway implementation on this foundation-only cluster).
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml \
  || fail "kubectl apply --server-side gateway-api v1.6.2 standard-install.yaml"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.6.2/v1-manifests.yaml \
  || fail "kubectl apply --server-side gateway-api-inference-extension v1.6.2 v1-manifests.yaml"
crds_ready() { kubectl get crd httproutes.gateway.networking.k8s.io inferencepools.inference.networking.k8s.io >/dev/null 2>&1; }
wait_until 120 5 "Gateway API + Gateway API Inference Extension CRDs present" crds_ready \
  || fail "httproutes.gateway.networking.k8s.io / inferencepools.inference.networking.k8s.io CRDs never appeared"
pass "installed the Gateway API v1.6.2 and Gateway API Inference Extension v1.6.2 CRDs (cluster administrator's own step, same split as the charts' own README)"

sync_real_chart() {
  local app="$1" chart_path="$2" check_label="$3"
  kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<EOF || fail "kubectl apply Application ${app}"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: ${TEAM}
  source:
    repoURL: https://github.com/littlemex/distai-platform.git
    targetRevision: ${DISAGG_PD_REVISION}
    path: ${chart_path}
    helm:
      parameters:
        - name: model.name
          value: "distai-platform-ci/tenancy-probe-not-a-real-model"
  destination:
    name: "${CLUSTER}"
    namespace: ${TEAM}
EOF
  trigger_sync "${app}" || fail "trigger ${app}'s sync"
  chart_op_done() { local p; p="$(operation_phase "${app}")"; [[ "${p}" == "Succeeded" || "${p}" == "Failed" || "${p}" == "Error" ]]; }
  wait_until 300 10 "${app}'s sync operation to finish" chart_op_done \
    || fail "${app}'s sync did not finish within 300s (phase: $(operation_phase "${app}"))"
  [[ "$(operation_phase "${app}")" == "Succeeded" ]] \
    || fail "${app}'s sync did not Succeed (phase $(operation_phase "${app}"), message: $(operation_message "${app}")) -- ${chart_path}'s own Role or one of its rendered object kinds does not fit team-rbac-guard.yaml's own allow-list or the AppProject's own namespaceResourceWhitelist as currently widened; the message above names which"
  # Every lookup below is scoped to THIS release (by app.kubernetes.io/instance
  # or by exact name, both derived from the Application's own name, which
  # Argo CD uses as the Helm release name since no releaseName override is
  # set) rather than "any object of this kind in the namespace" -- the two
  # charts render objects of the same kinds with the same component labels,
  # so an unscoped lookup for one chart's own check would also be satisfied
  # by the OTHER chart's own objects left over from the --wait=false delete
  # at the end of this same function on a prior call.
  kubectl get role -n "${TEAM}" -l "app.kubernetes.io/component=routing-sidecar,app.kubernetes.io/instance=${app}" --no-headers 2>/dev/null | grep -q . \
    || fail "${app}: no Role with labels app.kubernetes.io/component=routing-sidecar,app.kubernetes.io/instance=${app} was created in ${TEAM} despite a Succeeded sync -- the sidecar RBAC (templates/sidecar-rbac.yaml) was not actually applied"
  # The llm-d-router-gateway dependency chart's own "non-sa" Role is the
  # one that actually needed this PR's own allow-list widening
  # (inferencepools/inferenceobjectives/inferencemodelrewrites) -- its
  # own labels carry no app.kubernetes.io/instance (that chart's own
  # llm-d-router.labels sets only app.kubernetes.io/name and
  # app.kubernetes.io/version, unlike this chart's own disagg.labels),
  # so it is checked by its own exact, computed name instead:
  # llm-d-router.name renders "<release-name>-epp" (lowercased,
  # truncated to 40 chars), and templates/rbac.yaml appends "-non-sa".
  # Every name in this function (this one, and the InferencePool and
  # HTTPRoute names below) was confirmed by running `helm template`
  # against both charts at this exact commit on the EC2 runner (not
  # just read from the templates) -- for vllm:
  # team-a-vllm-disagg-epp-non-sa, team-a-vllm-disagg-epp-sa,
  # team-a-vllm-disagg-vllm-disagg-pd-llmd-routing-sidecar; for sglang:
  # team-a-sglang-disagg-epp-non-sa, team-a-sglang-disagg-epp-sa,
  # team-a-sglang-disagg-sglang-disagg-pd-llmd-routing-sidecar; both
  # charts' own InferencePool and HTTPRoute are named exactly the
  # release name, with no suffix. Every name below is correct for
  # every app name this script itself chooses (already lowercase, well
  # under 40 characters) -- not a general name-derivation helper.
  kubectl get role "${app}-epp-non-sa" -n "${TEAM}" >/dev/null 2>&1 \
    || fail "${app}: no Role named ${app}-epp-non-sa (the llm-d-router-gateway dependency chart's own Role, the one that needed team-rbac-guard.yaml's own inferencepools/inferenceobjectives/inferencemodelrewrites widening) was created in ${TEAM} despite a Succeeded sync"
  kubectl get inferencepool "${app}" -n "${TEAM}" >/dev/null 2>&1 \
    || fail "${app}: no InferencePool named ${app} was created in ${TEAM} despite a Succeeded sync"
  kubectl get httproute "${app}" -n "${TEAM}" >/dev/null 2>&1 \
    || fail "${app}: no HTTPRoute named ${app} was created in ${TEAM} despite a Succeeded sync"
  # "Admitted" (Synced) is not "runnable": confirms Pod Security Admission
  # (restricted, set by team-onboard.sh) did not reject the Pod objects
  # outright, without requiring them to reach Running -- no GPU/EFA is
  # available on this foundation-only cluster, so they are expected to
  # stay Pending. wait_until (not an immediate read) covers the gap
  # between the Deployment/ReplicaSet controllers noticing the Succeeded
  # sync and actually creating their own Pod objects. "At least one"
  # does not rule out one compliant Pod (e.g. the prefill or decode
  # Deployment's own) masking a different one PSA actually rejected --
  # this chart's own values.yaml sets the same restricted-compliant
  # securityContext shape on every container it renders, so that is a
  # stated, accepted gap, not a claim every Pod this chart could ever
  # render was individually checked.
  pod_for_release_exists() { kubectl get pods -n "${TEAM}" -l "app.kubernetes.io/instance=${app}" --no-headers 2>/dev/null | grep -q .; }
  wait_until 60 3 "at least one Pod with label app.kubernetes.io/instance=${app} to exist in ${TEAM}" pod_for_release_exists \
    || fail "${app}: no Pod with label app.kubernetes.io/instance=${app} was created in ${TEAM} within 60s of a Succeeded sync -- Pod Security Admission (restricted) may have rejected it. (A rejected Pod would fail this check the same way a slow-to-create one would -- if this fails, confirm which by reading the ReplicaSet's own events before assuming either.)"
  pass "${check_label}: ${chart_path} (pinned at feat/disagg-pd-reference@${DISAGG_PD_REVISION}) self-synced through the SAME team project ${TEAM} with no admin pre-creating anything -- its own sidecar Role, its llm-d-router-gateway dependency chart's own namespaced Role, its InferencePool, its HTTPRoute and at least one Pod (not rejected by Pod Security Admission) were all admitted and created (phase $(operation_phase "${app}"))"
  kubectl delete application "${app}" -n "${ARGOCD_NAMESPACE}" --wait=false >/dev/null 2>&1 || true
}

sync_real_chart team-a-vllm-disagg "examples/inference/vllm/disagg-pd-llmd" "CHECK 12/13"
sync_real_chart team-a-sglang-disagg "examples/inference/sglang/disagg-pd-llmd" "CHECK 13/13"

# ------------------------------------------------------- 10. teardown

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
