#!/usr/bin/env bash
# gitops/bootstrap/team-onboard.sh - RFC #22 Decision 10 H11, Option A
# (issue #57 item 1's own comparison table: "same-namespace Role/RoleBinding
# on team projects, synced through a per-team identity").
#
# What this closes: before this script, #22's own team AppProject did not
# exist in code (confirmed on issue #57's own comment thread), and H11 as
# originally written put RoleBinding on every team project's
# namespaceResourceBlacklist outright -- a blanket deny that issue #57
# found refuses any chart shipping its own namespaced RBAC (exactly what
# examples/inference/vllm/disagg-pd-llmd's sidecar needs). The fix
# confirmed on real hardware by infra/foundation/tests/4.argocd-impersonation.sh
# (run once, see that test's own header and this repository's PR history
# for the result) is Argo CD sync impersonation: the team's own
# AppProject declares a `destinationServiceAccounts` default so every
# sync into the team's namespace runs as that namespace's own
# ServiceAccount, not Argo CD's cluster-admin controller identity. Once
# the sync itself carries only that ServiceAccount's own permissions, the
# Kubernetes API server's own RBAC authorizer -- not an Argo CD
# resource-kind list -- is what stops a team's chart from creating a
# Role/RoleBinding that grants more than the team's own ServiceAccount
# already holds (the server rejects that write with "attempting to grant
# RBAC permissions not currently held", regardless of who asked for it).
# RoleBinding (and Role, which H11's original text also implicitly denied
# by never allowing it) can therefore come off the blacklist and the
# object kind itself stops being the boundary.
#
# What this script creates, run once per team by an admin (or an admin's
# own automation -- never by a team's own Application, which is exactly
# the boundary this design keeps):
#   1. (idempotent, cluster-wide, not per-team) enables Argo CD sync
#      impersonation in argocd-cm if not already on.
#   2. the team's own Namespace (if it does not already exist).
#   3. the team's own ServiceAccount + namespace-scoped Role + RoleBinding
#      -- the impersonation identity itself, and therefore the real
#      ceiling on what any Application in this team's project can ever
#      sync, independent of what that Application's own manifests ask
#      for. Deliberately excludes: anything cluster-scoped, the
#      "escalate"/"bind"/"impersonate" RBAC verbs, and Secrets (narrower
#      than the project's own namespaceResourceWhitelist on purpose --
#      Decision below).
#   4. the team's own AppProject, with destinationServiceAccounts set to
#      that ServiceAccount, destinations restricted to exactly this one
#      namespace, clusterResourceWhitelist empty (teams get zero
#      cluster-scoped kinds through GitOps, full stop), and
#      namespaceResourceWhitelist covering the namespaced workload kinds
#      a team's own chart may legitimately ship.
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
# future Argo CD version could change). namespaceResourceWhitelist lists
# exactly the kinds the Role above also grants (rule 3's own comment),
# so the two enforcement points agree by construction, not by two
# people remembering to keep them in sync.
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
  description: "Team ${TEAM}'s own self-service project (RFC #22 Decision 10 H11, Option A)."
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
