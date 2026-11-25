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
# check 6), but it does not by itself make Role/RoleBinding safe to
# whitelist for Argo CD's own sync.
#
# The actual fix (gitops/bootstrap/team-rbac-guard.yaml, applied by step
# 1 below, cluster-wide): a ValidatingAdmissionPolicy that runs for
# every Role/RoleBinding write in a team namespace regardless of who
# the caller is -- including Argo CD's own cluster-admin-equivalent sync
# identity, since admission runs after authorization already let the
# request through, independent of the caller's own RBAC. It denies a
# RoleBinding referencing a ClusterRole (cluster-admin among them), and
# denies a Role unless every apiGroup, resource and verb it grants is
# drawn from a fixed allow-list (that file's own header has the exact
# set and why it is an allow-list, not a deny-list, after two review
# rounds each found a shape an earlier deny-list version missed). With
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
#   3. the team's own ServiceAccount + namespace-scoped Role + RoleBinding.
#      This Role grants NOTHING on rbac.authorization.k8s.io resources at
#      all (not merely narrowed to "escalate"/"bind"/"impersonate", which
#      an earlier version of this script tried) -- a reviewer found that
#      a label-based exemption from team-rbac-guard.yaml for this Role's
#      own roles/rolebindings grant was itself attacker-controlled (any
#      team chart could set the same label on its own manifests and skip
#      the guard entirely). Removing the grant here instead means this
#      identity can never create or edit a Role/RoleBinding at all, by
#      any caller, and team-rbac-guard.yaml needs no exemption for
#      anyone. infra/foundation/tests/4.argocd-impersonation.sh's own
#      check 6 checks this directly (kubectl --as this ServiceAccount).
#      This identity is not currently used by Argo CD's own sync at all
#      (confirmed non-functional, above) -- kept as a namespace-scoped
#      placeholder for a future impersonation or human-access path, not
#      as this PR's own safety boundary.
#   4. the team's own AppProject: destinationServiceAccounts is set
#      (harmless today since it has no observed effect; kept so this
#      starts working with no further change if AWS ever fixes the
#      underlying gap), destinations restricted to exactly this one
#      namespace, clusterResourceWhitelist empty (teams get zero
#      cluster-scoped kinds through GitOps, full stop), and
#      namespaceResourceWhitelist covering the namespaced workload kinds
#      a team's own chart may ship, including Role and RoleBinding --
#      safe because team-rbac-guard.yaml (step 1) constrains their
#      content for every caller, with no exemption -- plus InferencePool
#      and HTTPRoute, the two namespace-scoped object kinds (not RBAC)
#      issue #57 item 1's own motivating charts render (checks 12-13).
#
# Known, bounded residual scope (not closed by this PR, stated so the
# "safely" claim above does not overreach): team-rbac-guard.yaml's own
# rule 2 is a fixed allow-list of (apiGroup, resource, verb) -- not a
# derivation from what every real chart actually needs. The allow-list
# was checked against the two real charts issue #57 item 1 named
# (examples/inference/vllm/disagg-pd-llmd and
# examples/inference/sglang/disagg-pd-llmd, both at
# feat/disagg-pd-reference@246b7ef): an EARLIER form of
# infra/foundation/tests/4.argocd-impersonation.sh's own checks 12-13
# synced both charts through this exact script's own AppProject on
# real hardware and found both charts' own sidecar Role, and their
# shared llm-d-router-gateway dependency chart's own namespaced Role,
# fit the allow-list once it was widened to include inferencepools
# (inference.networking.k8s.io) and inferenceobjectives/inferencemodelrewrites
# (llm-d.ai). Checks 12-13 were since revised (scoped lookups, a Pod
# check) and have since been re-run against real hardware too, and
# confirmed PASS (issue #67, closed). See team-rbac-guard.yaml's own comment on
# the widening for exactly which rule needed which resource, and why
# no chart-side change was needed instead. The AppProject's own
# namespaceResourceWhitelist below (step
# 4) was widened the same way, for the two actual object KINDS (not
# merely RBAC content) those charts render that were missing before:
# InferencePool (inference.networking.k8s.io) and HTTPRoute
# (gateway.networking.k8s.io) -- both namespace-scoped, matching every
# other entry already there. Widening either list for a future chart
# that needs more is a one-line, reviewed change to this file or to
# team-rbac-guard.yaml, not a new deny rule to invent. A Role binding to a Role already present in the
# namespace from before team-rbac-guard.yaml existed (never reviewed
# under this policy) is outside what rule 1's own roleRef.kind check
# alone verifies -- this design assumes every Role in a namespace it
# governs was itself created under this same policy. A team's own
# ServiceAccount can also still be reached by a Pod/Deployment the
# team's own chart ships (serviceAccountName) or a RoleBinding naming
# it -- bounded today to this identity's own, now-empty-of-RBAC Role,
# but worth tracking if this identity's own Role is ever widened later.
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
#     same Role is a second, separate identity path, not created here).
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
for repo in "${SOURCE_REPOS[@]}"; do
  [[ "${repo}" != *"*"* ]] \
    || { echo "--source-repo '${repo}' contains a wildcard and is rejected (the comment above explains why: a wildcard would let this team's AppProject source from any repository)" >&2; exit 1; }
done
# RFC 1123 label: lowercase alphanumeric and "-", must start/end
# alphanumeric, <=63 chars -- the same rule a Kubernetes Namespace name
# itself enforces, checked here too so this script fails with its own
# clear message instead of a raw apiserver 422.
[[ "${TEAM}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || { echo "--team '${TEAM}' is not a valid Kubernetes name (lowercase alphanumeric and '-', must start/end alphanumeric, <=63 chars)" >&2; exit 1; }
# Reserved names: this script's own objects would collide with, or
# label into this guard, something it does not own if --team names a
# system/admin namespace or the platform AppProject.
case "${TEAM}" in
  default|kube-system|kube-public|kube-node-lease|argocd|kueue-system|karpenter|platform)
    echo "--team '${TEAM}' is a reserved name (a system namespace or the platform AppProject's own name); choose a different team name" >&2
    exit 1
    ;;
esac

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
# (infra/foundation/tests/4.argocd-impersonation.sh's own real-hardware run):
# the only ConfigMap present in the capability's namespace was the
# built-in kube-root-ca.crt; no argocd-cm, argocd-rbac-cm or argocd-secret
# exists for a customer to read or patch. The `aws eks create-capability`/
# `update-eks-capability-configuration` APIs' own `argoCd` configuration
# object (checked against `aws eks create-capability help`) has exactly
# four fields -- namespace, awsIdc, rbacRoleMappings, networkAccess -- and
# none of them is an impersonation switch either.
#
# This step is therefore best-effort, not a hard requirement: it
# attempts the patch (in case a future capability version, or a
# self-hosted install this script is also pointed at, does expose
# argocd-cm), and continues with a clear, loud warning instead of
# failing outright when the ConfigMap genuinely does not exist. Whether
# sync impersonation actually engages on the managed capability without
# this flag is no longer open: infra/foundation/tests/4.argocd-impersonation.sh's
# own differential check (narrow the team's Role, force a resync)
# already confirmed it does not, on real hardware. This step is kept
# anyway so onboarding starts working with no further change if AWS
# ever exposes a way to set this flag; nothing in this script currently
# depends on it succeeding.
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
  echo "WARNING: no argocd-cm ConfigMap exists in namespace ${ARGOCD_NAMESPACE} -- this looks like the EKS managed Argo CD capability, whose own control plane (and therefore argocd-cm) runs outside this cluster and is not customer-reachable; continuing WITHOUT being able to set this cluster-wide flag. destinationServiceAccounts below does not impersonate without it (confirmed on real hardware, infra/foundation/tests/4.argocd-impersonation.sh's own differential check) -- this is not what makes Role/RoleBinding safe to sync for this team; team-rbac-guard.yaml is." >&2
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

# --- 1b. the same boundary, for the Namespace object's own
# -------  security-relevant labels (cluster-wide, once) -----------------
# team-rbac-guard.yaml's own namespaceSelector decides which namespaces
# it constrains at all by checking whether the namespace carries
# distai.dev/team -- a label that, by code reading alone, looked
# reachable through a team's own Application's
# syncPolicy.managedNamespaceMetadata (issue #57 item 1's own PR #66
# caveat; see gitops/bootstrap/team-namespace-guard.yaml's own header
# for the full finding, including what
# infra/foundation/tests/4.argocd-impersonation.sh's own checks 10-11
# actually confirmed and did not). Applied the same way as
# team-rbac-guard.yaml, for the same reason.
kubectl apply -f "${SCRIPT_DIR}/team-namespace-guard.yaml" \
  || { echo "kubectl apply gitops/bootstrap/team-namespace-guard.yaml" >&2; exit 1; }
echo "applied gitops/bootstrap/team-namespace-guard.yaml (ValidatingAdmissionPolicy team-namespace-guard + its Binding)" >&2

# --- 2. the team's own Namespace ------------------------------------------
# Refuses to adopt a pre-existing Namespace this script did not itself
# create: one that exists but was never labeled distai.dev/team by this
# script may already carry Roles/RoleBindings team-rbac-guard.yaml never
# reviewed (that guard assumes every Role in a namespace it governs was
# itself created under this same policy -- its own header), or Pods
# whose own ServiceAccount already holds more than this script's own
# team identity would grant. A namespace this script created earlier
# (already carrying the label) is fine to re-apply onto, idempotently.
EXISTING_LABEL="$(kubectl get namespace "${TEAM}" -o jsonpath='{.metadata.labels.distai\.dev/team}' 2>/dev/null || true)"
if kubectl get namespace "${TEAM}" >/dev/null 2>&1 && [[ "${EXISTING_LABEL}" != "${TEAM}" ]]; then
  echo "Namespace ${TEAM} already exists and was not created by this script (missing or mismatched distai.dev/team label: got '${EXISTING_LABEL}'); refusing to adopt it. Delete it first, or choose a different --team, if this namespace is safe to replace." >&2
  exit 1
fi
# pod-security.kubernetes.io/enforce: restricted (a built-in Kubernetes
# Pod Security Admission label, no extra controller needed) closes a
# gap team-rbac-guard.yaml's own RBAC-content rules do not reach at all:
# the AppProject's own namespaceResourceWhitelist (step 4) permits
# DaemonSet, so a team's chart could otherwise ship a privileged
# DaemonSet with hostPath: / (root on every node) or a hostNetwork pod
# (reaching the node's own IMDS/IAM credentials) -- neither is an RBAC
# question at all, so no Role/RoleBinding rule in team-rbac-guard.yaml
# could ever stop it. "restricted" is Pod Security Admission's
# strictest built-in level (denies hostPath, hostNetwork, hostPID,
# hostIPC, privileged containers, and more) -- a team workload namespace
# never legitimately needs any of those.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEAM}
  labels:
    distai.dev/team: "${TEAM}"
    pod-security.kubernetes.io/enforce: restricted
EOF

# --- 3. a team identity: ServiceAccount + Role + RoleBinding --------------
# Every rule here is namespace-scoped (no ClusterRole anywhere in this
# script). This Role grants NOTHING on rbac.authorization.k8s.io
# resources (no roles/rolebindings verbs at all) and nothing on Secrets
# -- on purpose, and not merely narrowed: gitops/bootstrap/team-rbac-guard.yaml
# denies ANY Role (admin-created or team-authored) that grants any
# rbac.authorization.k8s.io permission at all, with no exemption for
# this script's own objects (an earlier version of this script tried a
# label-based exemption instead of removing this grant; a reviewer
# found that label is attacker-controlled -- any team chart synced
# through Argo CD can set the same label on its own manifests and skip
# the guard entirely, which defeats the guard outright, not just this
# Role's own narrow case. Removing the grant here instead closes that
# for good: there is no exemption of any kind in team-rbac-guard.yaml
# to attack). This also means this identity can never itself be used to
# create or edit a Role/RoleBinding, by direct caller or otherwise --
# infra/foundation/tests/4.argocd-impersonation.sh's own check 6 checks
# this directly (kubectl --as this ServiceAccount).
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
# future Argo CD version could change). Role and RoleBinding ARE in
# namespaceResourceWhitelist below (issue #57's own goal) even though
# step 3's own Role grants neither -- the two are deliberately
# independent now: what a team's chart may ship through Argo CD is
# bounded by team-rbac-guard.yaml (content-based, every caller), not by
# mirroring step 3's own identity Role (which is namespace-scoped
# workload access only, nothing RBAC-related at all).
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
  # hardware -- an earlier real e2e attempt FAILed on
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
    # because team-rbac-guard.yaml (step 1 above) constrains their
    # content for every caller -- not because Argo CD sync impersonation
    # constrains who performs the write (confirmed NOT engaged on this
    # capability, infra/foundation/tests/4.argocd-impersonation.sh's own
    # check 7). Without that guard, allowing these two kinds here would
    # let a team's own chart ship a RoleBinding to an existing, more
    # privileged ClusterRole, or a Role granting broad permissions, and
    # Argo CD's own unconstrained, capability-wide sync identity would
    # apply it with no RBAC-escalation check against the team at all
    # (this script's own header explains why that check never fires for
    # that identity). This whitelist entry and team-rbac-guard.yaml's
    # own existence are therefore not independent of each other --
    # removing the guard without also removing Role/RoleBinding here
    # would reopen the gap.
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
    # InferencePool and HTTPRoute: not RBAC content (team-rbac-guard.yaml
    # has no rule for either), namespace-scoped like every other kind on
    # this list, and the two object kinds -- not merely RBAC -- that
    # issue #57 item 1's own motivating charts
    # (examples/inference/vllm/disagg-pd-llmd,
    # examples/inference/sglang/disagg-pd-llmd) actually render through
    # their llm-d-router-gateway dependency chart (an InferencePool
    # grouping this release's own engine Pods, and an HTTPRoute
    # attaching to an admin-installed Gateway named by the chart's own
    # values -- that chart's own README states the Gateway, its
    # GatewayClass, the Gateway implementation and the Gateway API CRDs
    # themselves are cluster-scoped and administrator-installed, never
    # rendered by this chart). An EARLIER form of
    # infra/foundation/tests/4.argocd-impersonation.sh's own checks
    # 12-13 confirmed this with a real sync, not merely a dry run;
    # that form has since been revised, re-run against real EKS and
    # confirmed PASS too (issue #67, closed).
    # Caveat (not checked by that real sync, which
    # installed no Gateway at all): whether a team's own HTTPRoute can
    # claim a hostname another team also expects depends entirely on
    # the shared, admin-installed Gateway's own listeners and
    # allowedRoutes.namespaces -- a Gateway API-level control this
    # AppProject's own namespaceResourceWhitelist has no say over
    # either way. Sizing that control correctly is the administrator's
    # own responsibility when installing the Gateway (RFC #37's own
    # serving add-on wave), not something HTTPRoute's presence on this
    # whitelist grants or withholds.
    - group: "inference.networking.k8s.io"
      kind: InferencePool
    - group: "gateway.networking.k8s.io"
      kind: HTTPRoute
  # Note: inert today (destinationServiceAccounts has no observed
  # effect -- confirmed, infra/foundation/tests/4.argocd-impersonation.sh's
  # own check 7), kept only for forward compatibility. Whether "server"
  # here should actually be CLUSTER_NAME (matching this AppProject's own
  # destinations[].name, which the cell-registration Secret names the
  # cluster by, and which this script's own checks confirm Argo CD does
  # match) or the cluster's ARN (what that same Secret's own "server"
  # field holds, Object 1 in gitops/bootstrap/bootstrap.sh) is itself
  # unverified -- upstream Argo CD's own documented convention for
  # destinationServiceAccounts[].server predates this capability's
  # name-based destination matching, so neither value has been checked
  # against a real impersonated sync (which cannot happen on this
  # capability today to check it against). A second reason this field's
  # own correctness does not currently matter, on top of impersonation
  # not engaging at all.
  destinationServiceAccounts:
    - server: "${CLUSTER_NAME}"
      namespace: "${TEAM}"
      defaultServiceAccount: "${SERVICE_ACCOUNT}"
EOF

echo "onboarding complete: team ${TEAM} has its own Namespace, ServiceAccount ${SERVICE_ACCOUNT} (+ namespace-scoped Role/RoleBinding), and AppProject ${TEAM} (destinationServiceAccounts -> ${SERVICE_ACCOUNT})" >&2
echo "point the team's own Application at: spec.project: ${TEAM}, spec.destination: {name: ${CLUSTER_NAME}, namespace: ${TEAM}}" >&2
