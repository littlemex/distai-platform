#!/usr/bin/env bash
# gitops/bootstrap/team-onboard.sh - RFC #22 Decision 10 H11.
#
# issue #57's own goal (unchanged by any of this file's history): a team
# installs a chart shipping its own namespaced Role/RoleBinding into its
# own namespace with no admin pre-creating that RBAC by hand. The first
# version of this script tried to get there via Argo CD sync
# impersonation (#22 Decision 10 H11 "Option A", issue #57 item 1's own
# comparison table): make the team's own ServiceAccount the real actor,
# and let the Kubernetes API server's own RBAC-escalation check be the
# boundary. infra/foundation/tests/4.argocd-impersonation.sh's own
# real-hardware differential check found that premise false: Argo CD
# sync impersonation is not engaged on the EKS managed Argo CD
# capability (no customer-reachable way to set
# `application.sync.impersonation.enabled`; destinationServiceAccounts
# is accepted by the AppProject CRD's schema but has no observed
# effect), so every sync still runs as the capability's own identity --
# which `infra/foundation/argocd.tf`'s own comment on
# aws_eks_access_policy_association.argocd confirms is bound to
# AmazonEKSClusterAdminPolicy, i.e. already holds every permission there
# is. An escalation check against an identity that already holds
# everything never fires, no matter how narrow the team's own
# ServiceAccount's Role (step 3 below) is kept -- that Role is never the
# identity actually performing the write. Narrowing it is still useful
# (a direct caller using this identity, e.g. kubectl --as, IS checked
# against it -- infra/foundation/tests/4.argocd-impersonation.sh's own
# check 4), but it does not by itself make Role/RoleBinding safe to
# whitelist for Argo CD's own sync.
#
# The actual fix (gitops/bootstrap/team-rbac-guard.yaml, applied by step
# 1 below, cluster-wide): a ValidatingAdmissionPolicy that runs for
# every Role/RoleBinding write in a team namespace regardless of who
# the caller is -- including Argo CD's own cluster-admin-equivalent sync
# identity, since admission runs after authorization already let the
# request through, independent of the caller's own RBAC. It denies the
# specific shapes that would otherwise let a team's own chart grant
# itself (or anyone) more than intended: a RoleBinding referencing a
# ClusterRole (cluster-admin among them), and a Role granting
# escalate/bind/impersonate, any rbac.authorization.k8s.io permission, a
# wildcard apiGroup/resource/verb, or any permission on Secrets. With
# that guard in place, Role and RoleBinding are back in the team
# AppProject's own namespaceResourceWhitelist (step 4) -- issue #57's
# own goal is restored, on an admission-based boundary instead of an
# RBAC-escalation-based one that this capability does not actually
# enforce for Argo CD's own identity.
#
# What this script creates, run once per team by an admin (or an admin's
# own automation -- never by a team's own Application, which is exactly
# the boundary this design keeps):
#   1. (cluster-wide, not per-team, idempotent) the team-rbac-guard
#      ValidatingAdmissionPolicy/Binding (gitops/bootstrap/team-rbac-guard.yaml
#      verbatim), the real boundary described above. Also attempts to
#      enable Argo CD sync impersonation in argocd-cm, best-effort (see
#      the code's own comment): on this capability it always finds no
#      such ConfigMap and logs a warning instead of failing, since that
#      is the now-confirmed, expected state -- kept only so this starts
#      working with no further change if AWS ever fixes the underlying
#      gap; nothing here currently depends on it succeeding.
#   2. the team's own Namespace (if it does not already exist), labeled
#      distai.dev/team -- what team-rbac-guard.yaml's own
#      namespaceSelector matches on.
#   3. the team's own ServiceAccount + namespace-scoped Role + RoleBinding
#      -- a team identity usable for a direct caller (kubectl --as, or a
#      future human/pod identity path; checked directly by
#      infra/foundation/tests/4.argocd-impersonation.sh's own check 4).
#      Deliberately excludes: anything cluster-scoped, the
#      "escalate"/"bind"/"impersonate" RBAC verbs, and Secrets -- the
#      same ceiling team-rbac-guard.yaml enforces on any Role a team's
#      own chart ships, kept here too so a direct caller using this
#      identity is held to the same standard.
#   4. the team's own AppProject: destinationServiceAccounts is set
#      (harmless today since it has no observed effect; kept so this
#      starts working with no further change if AWS ever fixes the
#      underlying gap), destinations restricted to exactly this one
#      namespace, clusterResourceWhitelist empty (teams get zero
#      cluster-scoped kinds through GitOps, full stop), and
#      namespaceResourceWhitelist covering the namespaced workload kinds
#      a team's own chart may ship, including Role and RoleBinding --
#      safe because team-rbac-guard.yaml (step 1) constrains their
#      content regardless of sync identity.
#
# Deliberately NOT created here (left to a later PR, so this one stays
# checkable against what it actually claims):
#   - ResourceQuota/LimitRange/LocalQueue (#22's own admin-owned envelope
#     objects -- creating a LocalQueue needs a real ClusterQueue to point
#     at, which is issue #17/#27's own territory and is not wired to a
#     team name yet; a team onboarded by this script alone has no Kueue
#     quota until that wiring exists, which issue #56's own
#     accelerator-pool-and-Kueue-admission check already covers
#     independently of teams).
#   - a human team member's own interactive kubectl access (an EKS access
#     entry mapping an IAM principal to a Kubernetes group bound to this
#     same Role is a second, separate identity path -- this script's own
#     ServiceAccount is only Argo CD's sync identity for this team's
#     Applications, never a human's).
#   - team offboarding (deleting a team's own objects) -- not symmetric
#     with onboarding by design yet; do it by hand
#     (kubectl delete namespace/serviceaccount/role/rolebinding/appproject)
#     until a real need for an automated path shows up.
#
# Usage:
#   team-onboard.sh --team <name> --tf-outputs <(terraform output -json) \
#     --source-repo <git-url> [--source-repo <git-url> ...]
#
# --tf-outputs is required, same convention as bootstrap.sh: the only way
# this script learns about the cell, so it cannot drift from what
# Terraform actually built.
#
# Idempotent: re-running with the same --team changes nothing live (every
# object here is applied, never created-then-ignored).
#
# Safety: aborts before writing anything if the live kubeconfig's server
# does not match --tf-outputs' cluster_endpoint (same check as
# bootstrap.sh), or if --team is not a valid Kubernetes name (used
# verbatim as both the Namespace name and the AppProject name).

set -euo pipefail

usage() {
  echo "Usage: $0 --team <name> --tf-outputs <path-or-process-substitution> --source-repo <git-url> [--source-repo <git-url> ...]" >&2
  exit 1
}

TEAM=""
TF_OUTPUTS=""
SOURCE_REPOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)
      TEAM="${2:-}"
      shift 2
      ;;
    --tf-outputs)
      TF_OUTPUTS="${2:-}"
      shift 2
      ;;
    --source-repo)
      SOURCE_REPOS+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

[[ -n "${TEAM}" ]] || usage
[[ -n "${TF_OUTPUTS}" ]] || usage
# At least one --source-repo is required, with no "*" fallback: an
# AppProject's own sourceRepos is what stops this project's Applications
# from sourcing an attacker-controlled repository once anything less
# than full Argo CD ADMIN can create an Application in it (a future
# per-project Argo CD role is exactly the direction #22 Decision 13
# heads); defaulting this to "*" here would quietly reopen that even
# though destinationServiceAccounts/the namespace whitelist stay narrow.
[[ "${#SOURCE_REPOS[@]}" -gt 0 ]] || { echo "at least one --source-repo <git-url> is required (the repo(s) this team's own Applications may source from)" >&2; exit 1; }
# RFC 1123 label: lowercase alphanumeric and "-", must start/end
# alphanumeric, <=63 chars -- the same rule a Kubernetes Namespace name
# itself enforces, checked here too so this script fails with its own
# clear message instead of a raw apiserver 422.
[[ "${TEAM}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || { echo "--team '${TEAM}' is not a valid Kubernetes name (lowercase alphanumeric and '-', must start/end alphanumeric, <=63 chars)" >&2; exit 1; }

for bin in kubectl jq; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "prerequisite: ${bin} not found" >&2; exit 1; }
done

[[ -r "${TF_OUTPUTS}" ]] || { echo "cannot read --tf-outputs: ${TF_OUTPUTS}" >&2; exit 1; }
TF_JSON="$(cat "${TF_OUTPUTS}")"

tf_out() {
  local key="$1"
  local v
  v="$(echo "${TF_JSON}" | jq -r --arg k "${key}" '.[$k].value // empty')"
  [[ -n "${v}" && "${v}" != "null" ]] || { echo "terraform output ${key} is missing or null; was this cell applied with var.argocd set?" >&2; exit 1; }
  echo "${v}"
}

CLUSTER_NAME="$(tf_out cluster_name)"
CLUSTER_ENDPOINT="$(tf_out cluster_endpoint)"
ARGOCD_NAMESPACE="$(tf_out argocd_namespace)"

# --- Safety check: the kubeconfig in use really is this cell's own -------
LIVE_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
[[ -n "${LIVE_SERVER}" ]] || { echo "no current kubeconfig context; run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region <region>" >&2; exit 1; }
[[ "${LIVE_SERVER}" == "${CLUSTER_ENDPOINT}" ]] || {
  echo "current kubeconfig server does not match --tf-outputs' cluster_endpoint; this looks like the wrong cluster's kubeconfig" >&2
  exit 1
}

SERVICE_ACCOUNT="${TEAM}-deployer"

echo "onboarding team '${TEAM}' on cluster ${CLUSTER_NAME} (namespace ${TEAM}, ServiceAccount ${SERVICE_ACCOUNT})" >&2

# --- 1. enable Argo CD sync impersonation, cluster-wide, once (best-effort) -
# On a self-hosted Argo CD install, argocd-cm is a plain ConfigMap in the
# same cluster the controller runs in, and `kubectl patch --type merge`
# either adds this key or leaves an existing "true" alone. The EKS
# **managed** Argo CD capability is not that: AWS's own `create-capability`
# API documentation states the capability's own infrastructure (the
# application-controller, repo-server, and therefore argocd-cm itself)
# runs "outside of your cluster" -- confirmed on a real capability
# (infra/foundation/tests/4.argocd-impersonation.sh's own first real run):
# the only ConfigMap present in the capability's namespace was the
# built-in kube-root-ca.crt; no argocd-cm, argocd-rbac-cm or argocd-secret
# exists for a customer to read or patch. The `aws eks create-capability`/
# `update-eks-capability-configuration` APIs' own `argoCd` configuration
# object (checked against `aws eks create-capability help`) has exactly
# four fields -- namespace, awsIdc, rbacRoleMappings, networkAccess -- and
# none of them is an impersonation switch either.
#
# This step is therefore best-effort, not a hard requirement: it attempts
# the patch (in case a future capability version, or a self-hosted
# install this script is also pointed at, does expose argocd-cm), and
# continues with a clear, loud warning instead of failing outright when
# the ConfigMap genuinely does not exist -- because whether sync
# impersonation actually engages on the managed capability without this
# flag ever being set by a customer is exactly the open question
# infra/foundation/tests/4.argocd-impersonation.sh's own differential
# check (narrow the team's Role, force a resync, see whether it is
# impersonation-enforced) is designed to answer; failing here would
# make that check impossible to ever run.
if kubectl get configmap argocd-cm -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  IMPERSONATION_ALREADY_ON="$(kubectl get configmap argocd-cm -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.data.application\.sync\.impersonation\.enabled}' 2>/dev/null || true)"
  if [[ "${IMPERSONATION_ALREADY_ON}" == "true" ]]; then
    echo "argocd-cm already has application.sync.impersonation.enabled: \"true\"" >&2
  else
    kubectl patch configmap argocd-cm -n "${ARGOCD_NAMESPACE}" --type merge \
      -p '{"data":{"application.sync.impersonation.enabled":"true"}}' \
      || { echo "kubectl patch configmap argocd-cm (impersonation flag)" >&2; exit 1; }
    echo "set argocd-cm application.sync.impersonation.enabled: \"true\"" >&2
  fi
else
  echo "WARNING: no argocd-cm ConfigMap exists in namespace ${ARGOCD_NAMESPACE} -- this looks like the EKS managed Argo CD capability, whose own control plane (and therefore argocd-cm) runs outside this cluster and is not customer-reachable; continuing WITHOUT being able to confirm this cluster-wide flag is set. Whether destinationServiceAccounts below actually impersonates without it is unconfirmed by this script alone." >&2
fi

# --- 1a. the real boundary: team-rbac-guard (cluster-wide, once) ---------
# Applied verbatim from the sibling file so there is exactly one copy of
# this policy's own text (this script's own header explains why it is
# needed regardless of whether step 1 above ever succeeds). Idempotent
# kubectl apply, like every other object this script creates; both
# objects are cluster-scoped (a ValidatingAdmissionPolicy/Binding is not
# itself per-namespace -- its own namespaceSelector is what scopes which
# namespaces it actually constrains), so this is safe to re-run for
# every team onboarded without creating a second copy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -f "${SCRIPT_DIR}/team-rbac-guard.yaml" \
  || { echo "kubectl apply gitops/bootstrap/team-rbac-guard.yaml" >&2; exit 1; }
echo "applied gitops/bootstrap/team-rbac-guard.yaml (ValidatingAdmissionPolicy team-rbac-guard + its Binding)" >&2

# --- 2. the team's own Namespace ------------------------------------------
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEAM}
  labels:
    distai.dev/team: "${TEAM}"
EOF

# --- 3. the impersonation identity: ServiceAccount + Role + RoleBinding ---
# Every rule here is namespace-scoped (no clusterRole anywhere in this
# script) and every verb list stops short of "escalate"/"bind"/
# "impersonate" on purpose: this Role is the real ceiling on every
# Application this team's own AppProject will ever sync, so it is
# deliberately not given the power to grant permissions beyond itself
# (the Kubernetes RBAC authorizer's own escalation check already refuses
# that for any Role/RoleBinding this identity tries to create -- see
# this script's own header), and it does not include "secrets": the
# project's own namespaceResourceWhitelist below is also missing Secret,
# so a team cannot GitOps-sync one through this path at all (a team
# wanting a Secret in its own namespace creates it directly with
# kubectl, outside GitOps, exactly like every other repository that
# treats "sync impersonation can create it" and "GitOps may create it"
# as two separate questions).
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT}
  namespace: ${TEAM}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${SERVICE_ACCOUNT}-role
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
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${SERVICE_ACCOUNT}-binding
  namespace: ${TEAM}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${SERVICE_ACCOUNT}-role
subjects:
  - kind: ServiceAccount
    name: ${SERVICE_ACCOUNT}
    namespace: ${TEAM}
EOF

# --- 4. the team's own AppProject -----------------------------------------
# clusterResourceWhitelist is intentionally absent (an AppProject with no
# clusterResourceWhitelist key denies every cluster-scoped kind --
# confirmed against the Argo CD CRD's own default, which is an empty
# list, not "*"; explicitly setting `clusterResourceWhitelist: []` below
# makes that denial a stated fact in this file rather than a default a
# future Argo CD version could change). namespaceResourceWhitelist is
# narrower than what team-a-deployer-role above grants (that Role also
# covers roles/rolebindings, for a direct caller using this identity --
# this script's own header explains why those two kinds are
# deliberately absent from this whitelist regardless).
SOURCE_REPOS_YAML=""
for repo in "${SOURCE_REPOS[@]}"; do
  SOURCE_REPOS_YAML="${SOURCE_REPOS_YAML}
    - \"${repo}\""
done
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${TEAM}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  description: "Team ${TEAM}'s own self-service project (RFC #22 Decision 10 H11; Option A not adopted, see this script's own header)."
  # Required (same as the platform AppProject, gitops/bootstrap/bootstrap.sh's
  # own Object 2): without an explicit sourceNamespaces entry naming the
  # capability's own namespace, Argo CD refuses every Application here
  # with "is not permitted to use project ${TEAM}" even though the
  # Application lives in that very namespace (confirmed on real
  # hardware -- this script's own second real e2e attempt FAILed on
  # exactly this before this field was added).
  sourceNamespaces:
    - "${ARGOCD_NAMESPACE}"
  sourceRepos:${SOURCE_REPOS_YAML}
  destinations:
    - name: "${CLUSTER_NAME}"
      namespace: "${TEAM}"
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: ""
      kind: ServiceAccount
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Pod
    - group: ""
      kind: Service
    # Role and RoleBinding ARE here (issue #57's own goal), safe only
    # because team-rbac-guard.yaml (step 1a above) constrains their
    # content regardless of sync identity -- not because Argo CD sync
    # impersonation constrains who performs the write (confirmed NOT
    # engaged on this capability, infra/foundation/tests/4.argocd-impersonation.sh's
    # own check 6). Without that guard, allowing these two kinds here
    # would let a team's own chart ship a RoleBinding to an existing,
    # more privileged ClusterRole, or a Role granting broad permissions,
    # and Argo CD's own unconstrained, capability-wide sync identity
    # would apply it with no RBAC-escalation check against the team at
    # all (this script's own header explains why that check never
    # fires for that identity). This whitelist entry and
    # team-rbac-guard.yaml's own existence are therefore not
    # independent of each other -- removing the guard without also
    # removing Role/RoleBinding here would reopen the gap.
    - group: "rbac.authorization.k8s.io"
      kind: Role
    - group: "rbac.authorization.k8s.io"
      kind: RoleBinding
    - group: "apps"
      kind: Deployment
    - group: "apps"
      kind: StatefulSet
    - group: "apps"
      kind: DaemonSet
    - group: "batch"
      kind: Job
    - group: "batch"
      kind: CronJob
    - group: "policy"
      kind: PodDisruptionBudget
    - group: "networking.k8s.io"
      kind: NetworkPolicy
  destinationServiceAccounts:
    - server: "${CLUSTER_NAME}"
      namespace: "${TEAM}"
      defaultServiceAccount: "${SERVICE_ACCOUNT}"
EOF

echo "onboarding complete: team ${TEAM} has its own Namespace, ServiceAccount ${SERVICE_ACCOUNT} (+ namespace-scoped Role/RoleBinding), and AppProject ${TEAM} (destinationServiceAccounts -> ${SERVICE_ACCOUNT})" >&2
echo "point the team's own Application at: spec.project: ${TEAM}, spec.destination: {name: ${CLUSTER_NAME}, namespace: ${TEAM}}" >&2
