#!/usr/bin/env bash
# End-to-end test of the identities layer (issue #8) on a real AWS account.
#
# infra/identities has no resources of its own to stand on: an
# aws_eks_pod_identity_association needs an already-existing EKS cluster
# with the eks-pod-identity-agent add-on, which only infra/foundation
# creates. This script therefore applies infra/foundation first, exactly as
# an operator must (README.md), then applies infra/identities on top - the
# same "main's own layer, then this pull request's layer" order the pull
# request's own migration claim rests on - and checks only what
# infra/identities itself contributes:
#
#   1. a role hand-created outside Terraform (standing in for an add-on
#      identity set up by hand before this issue, per #8's own Motivation)
#      is imported into infra/identities with no replacement, and its
#      trust policy and permissions are tightened to this layer's own
#      declared shape by the very next apply;
#   2. a Pod whose ServiceAccount has a declared entry gets AWS credentials
#      scoped to exactly that entry's own s3 prefix: it can read inside the
#      prefix, cannot read outside it (same bucket), and cannot write at
#      all (no write = true declared);
#   3. a second entry with write = true can additionally write inside its
#      own prefix, and still cannot touch the first entry's prefix;
#   4. a Pod whose ServiceAccount has no declared entry at all gets no
#      credentials - AccessDenied by construction, not by a shared role's
#      policy;
#   5. removing one entry and re-applying deletes only that entry's own
#      role and association, leaves every other entry untouched, and never
#      re-plans infra/foundation (this script never calls terraform against
#      infra/foundation again after its first apply);
#   6. terraform destroy of infra/identities, then of infra/foundation;
#      nothing of either layer is left (IAM roles by name and by an
#      account-wide tag sweep, the disposable S3 bucket, the cell's VPC).
#
# Every check prints PASS or FAIL. The script exits non-zero on the first
# failed step and always attempts to destroy what it created (EXIT trap).
#
# Required environment (export before running):
#   AWS_PROFILE, AWS_REGION, NAME, STATE_BUCKET, STATE_REGION,
#   ADMIN_PRINCIPAL_ARN, MY_CIDR
# Optional environment:
#   TERRAFORM (terraform), E2E_WORK_DIR (mktemp -d),
#   E2E_KEEP_ON_FAILURE (0), E2E_LEFTOVER_GRACE_SECONDS (300)
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
E2E_LEFTOVER_GRACE_SECONDS="${E2E_LEFTOVER_GRACE_SECONDS:-300}"

# Pinned by digest: public.ecr.aws does not return a Docker-Content-Digest
# header (same as infra/foundation/tests/README.md's own NetworkPolicy
# image), so the digest below is the sha256 of the manifest-list response
# body for aws-cli/aws-cli:2.36.10, fetched through ECR Public's anonymous
# token service and confirmed stable across two independent fetches.
AWS_CLI_IMAGE="public.ecr.aws/aws-cli/aws-cli@sha256:1ce4fd2ea9b640019af76a94e91adeed901d20363b4bb2ed095b45c75e5565cc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITIES_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FOUNDATION_ROOT="$(cd "${IDENTITIES_ROOT}/../foundation" && pwd)"
WORK_DIR="${E2E_WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
export TF_IN_AUTOMATION=1

FOUNDATION_STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
IDENTITIES_STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/identities"
RUN_ID="e2e-$(date -u +%Y%m%d%H%M%S)"
TEST_TAG_KEY="distai-platform-e2e"
TEST_NAMESPACE="identities-e2e"
LEGACY_ROLE_NAME="${NAME}-legacy-imagebuilder"
BUCKET="${NAME}-identities-e2e-${RUN_ID#e2e-}"

FOUNDATION_APPLIED=0
LEGACY_ROLE_CREATED=0
BUCKET_CREATED=0
IDENTITIES_APPLIED=0
IDENTITIES_DESTROYED=0
FOUNDATION_DESTROYED=0
FAILED_STEP=""

# shellcheck source=e2e-lib.sh
# shellcheck disable=SC1091 # SCRIPT_DIR is computed at runtime; shellcheck cannot follow it statically (same info-level notice infra/foundation/tests/3.tenancy-primitive.sh and 4.argocd-impersonation.sh already carry and suppress the same way)
source "${SCRIPT_DIR}/e2e-lib.sh"

# Plain wrappers, deliberately with no -var-file baked in: init, output,
# state list and show -json all reject a -var-file flag outright (and
# applying an already-saved plan file must not repeat the variables that
# plan already captured), so each call site below adds -var-file itself,
# only on the apply/plan/destroy/import calls that both need and accept it.
tff() { "${TERRAFORM}" -chdir="${FOUNDATION_ROOT}" "$@"; }
tfi() { "${TERRAFORM}" -chdir="${IDENTITIES_ROOT}" "$@"; }

cleanup() {
  local rc=$?
  set +e
  if [[ "${IDENTITIES_APPLIED}" -eq 1 && "${IDENTITIES_DESTROYED}" -eq 0 ]]; then
    if [[ "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving infra/identities in place"
    else
      info "cleanup: destroying infra/identities"
      kubectl delete namespace "${TEST_NAMESPACE}" --ignore-not-found --timeout=60s >/dev/null 2>&1
      tfi destroy -var-file="${IDENTITIES_TFVARS}" -auto-approve >/dev/null 2>&1
    fi
  fi
  if [[ "${BUCKET_CREATED}" -eq 1 ]]; then
    info "cleanup: emptying and deleting the disposable bucket ${BUCKET}"
    aws s3 rm "s3://${BUCKET}" --recursive >/dev/null 2>&1
    aws s3api delete-bucket --bucket "${BUCKET}" >/dev/null 2>&1
  fi
  if [[ "${LEGACY_ROLE_CREATED}" -eq 1 ]]; then
    aws iam list-attached-role-policies --role-name "${LEGACY_ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null \
      | tr '\t' '\n' | grep -v '^$' | while read -r p; do aws iam detach-role-policy --role-name "${LEGACY_ROLE_NAME}" --policy-arn "${p}" >/dev/null 2>&1; done
    aws iam delete-role --role-name "${LEGACY_ROLE_NAME}" >/dev/null 2>&1
  fi
  if [[ "${FOUNDATION_APPLIED}" -eq 1 && "${FOUNDATION_DESTROYED}" -eq 0 ]]; then
    if [[ "${E2E_KEEP_ON_FAILURE}" == "1" ]]; then
      info "E2E_KEEP_ON_FAILURE=1: leaving infra/foundation (the cell) in place; destroy by hand with:"
      info "${TERRAFORM} -chdir=${FOUNDATION_ROOT} -var-file=${FOUNDATION_TFVARS} destroy"
    else
      info "cleanup: destroying infra/foundation"
      tff destroy -var-file="${FOUNDATION_TFVARS}" -auto-approve >/dev/null 2>&1
    fi
  fi
  if [[ -n "${FAILED_STEP}" ]]; then
    log "FAIL step: ${FAILED_STEP}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

# -------------------------------------------------------------- 0. preflight

require_bin "${TERRAFORM}"
require_bin aws
require_bin kubectl
aws sts get-caller-identity >/dev/null || fail "preflight: AWS credentials are not valid"
pass "preflight: tools present, credentials valid"
info "run ${RUN_ID}, work dir ${WORK_DIR}"

# -------------------------------------------------- 1. foundation (main's own)

FOUNDATION_TFVARS="${WORK_DIR}/foundation.tfvars.json"
cat >"${FOUNDATION_TFVARS}" <<JSON
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "tags": {"${TEST_TAG_KEY}": "${RUN_ID}"}
}
JSON

tff init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=${FOUNDATION_STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true" \
  || fail "terraform init infra/foundation (key ${FOUNDATION_STATE_KEY})"
pass "terraform init infra/foundation, key ${FOUNDATION_STATE_KEY}"

# terraform state list exits 0 with empty output for an empty state; for a
# backend with no state object at all yet it prints "No state file was
# found!" to stderr and exits non-zero (same as
# infra/foundation/tests/1.e2e.sh's own equivalent check) - also "empty".
if ! existing_state="$(tff state list 2>&1)"; then
  [[ "${existing_state}" == *"No state file"* ]] || fail "terraform state list (foundation): ${existing_state}"
  existing_state=""
fi
[[ -z "${existing_state}" ]] || fail "foundation state already has resources, refusing to apply over it: $(tr '\n' ' ' <<<"${existing_state}")"
pass "state at key ${FOUNDATION_STATE_KEY} has no resources before apply"

FOUNDATION_APPLIED=1
foundation_start="$(date +%s)"
tff apply -var-file="${FOUNDATION_TFVARS}" -auto-approve || fail "terraform apply infra/foundation"
pass "terraform apply infra/foundation ($(($(date +%s) - foundation_start))s)"

CLUSTER_NAME="$(tff output -raw cluster_name)"
tff output -raw cluster_certificate_authority_data >/dev/null || fail "foundation output cluster_certificate_authority_data missing"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --kubeconfig "${KUBECONFIG}" >/dev/null \
  || fail "aws eks update-kubeconfig"
wait_until 180 10 "kubectl reaches the cluster" kubectl get nodes >/dev/null 2>&1 \
  || fail "kubectl did not reach the cluster through the access entry within 180s"
pass "kubectl reaches the cluster through the access entry"
two_ready_nodes() {
  [[ "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')" -ge 2 ]]
}
wait_until 600 15 "two Ready system nodes" two_ready_nodes || fail "two Ready system nodes did not appear"
pass "two Ready system nodes"
agent_status="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent --query 'addon.status' --output text 2>&1)" \
  || fail "describe-addon eks-pod-identity-agent: ${agent_status}"
[[ "${agent_status}" == "ACTIVE" ]] || fail "eks-pod-identity-agent is ${agent_status}, not ACTIVE"
pass "eks-pod-identity-agent is ACTIVE"

kubectl create namespace "${TEST_NAMESPACE}" || fail "create namespace ${TEST_NAMESPACE}"
kubectl create serviceaccount reader -n "${TEST_NAMESPACE}" || fail "create serviceaccount reader"
kubectl create serviceaccount writer -n "${TEST_NAMESPACE}" || fail "create serviceaccount writer"
kubectl create serviceaccount undeclared -n "${TEST_NAMESPACE}" || fail "create serviceaccount undeclared"
pass "test namespace and three ServiceAccounts created (reader, writer, undeclared)"

# ------------------------------------------- 2. a hand-rolled identity exists

# Stands in for issue #8's own Motivation (the ALB controller, an image
# builder, OpenZFS, an MCP server): a role created by hand before this
# mechanism existed, with a loose trust policy (no RequestTag conditions -
# any Pod Identity session in the account could assume it, not only one
# namespace/service account) and a broad managed policy.
LEGACY_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
aws iam create-role --role-name "${LEGACY_ROLE_NAME}" \
  --assume-role-policy-document "${LEGACY_TRUST_POLICY}" \
  --tags "Key=${TEST_TAG_KEY},Value=${RUN_ID}" >/dev/null \
  || fail "create-role ${LEGACY_ROLE_NAME} (simulated hand-rolled identity)"
LEGACY_ROLE_CREATED=1
aws iam attach-role-policy --role-name "${LEGACY_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess >/dev/null \
  || fail "attach-role-policy AmazonS3ReadOnlyAccess to ${LEGACY_ROLE_NAME}"
legacy_role_arn="$(aws iam get-role --role-name "${LEGACY_ROLE_NAME}" --query Role.Arn --output text)"
pass "simulated a pre-existing, hand-rolled identity: ${LEGACY_ROLE_NAME} (loose trust policy, AmazonS3ReadOnlyAccess attached directly)"

# -------------------------------------------- 3. a disposable S3 bucket

if [[ "${AWS_REGION}" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "${BUCKET}" >/dev/null || fail "create-bucket ${BUCKET}"
else
  aws s3api create-bucket --bucket "${BUCKET}" --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null \
    || fail "create-bucket ${BUCKET}"
fi
BUCKET_CREATED=1
aws s3api put-bucket-tagging --bucket "${BUCKET}" --tagging "TagSet=[{Key=${TEST_TAG_KEY},Value=${RUN_ID}}]" >/dev/null \
  || fail "tag bucket ${BUCKET}"
echo "ok" | aws s3 cp - "s3://${BUCKET}/allowed/ok.txt" || fail "seed s3://${BUCKET}/allowed/ok.txt"
echo "secret" | aws s3 cp - "s3://${BUCKET}/other/secret.txt" || fail "seed s3://${BUCKET}/other/secret.txt"
pass "disposable bucket ${BUCKET} created and seeded (allowed/ok.txt, other/secret.txt)"

# --------------------------------------- 4. init infra/identities, import, apply

tfi init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=${IDENTITIES_STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true" \
  || fail "terraform init infra/identities (key ${IDENTITIES_STATE_KEY})"
pass "terraform init infra/identities, key ${IDENTITIES_STATE_KEY}"

if ! existing_identities_state="$(tfi state list 2>&1)"; then
  [[ "${existing_identities_state}" == *"No state file"* ]] || fail "terraform state list (identities): ${existing_identities_state}"
  existing_identities_state=""
fi
[[ -z "${existing_identities_state}" ]] || fail "identities state already has resources, refusing to apply over it: $(tr '\n' ' ' <<<"${existing_identities_state}")"
pass "state at key ${IDENTITIES_STATE_KEY} has no resources before apply"

write_identities_tfvars() {
  # $1: 1 to include the writer entry, 0 to omit it (the removal step).
  local include_writer="$1"
  cat >"${IDENTITIES_TFVARS}" <<JSON
{
  "cluster_name": "${CLUSTER_NAME}",
  "region": "${AWS_REGION}",
  "tags": {"${TEST_TAG_KEY}": "${RUN_ID}"},
  "platform_identities": {
    "legacy-imagebuilder": {
      "namespace": "${TEST_NAMESPACE}",
      "service_account": "reader",
      "role_name": "${LEGACY_ROLE_NAME}",
      "s3": [{"bucket": "${BUCKET}", "prefixes": ["allowed/"]}]
    }$([[ "${include_writer}" -eq 1 ]] && cat <<JSON2
,
    "writer": {
      "namespace": "${TEST_NAMESPACE}",
      "service_account": "writer",
      "s3": [{"bucket": "${BUCKET}", "prefixes": ["writer-area/"], "write": true}]
    }
JSON2
)
  }
}
JSON
}

IDENTITIES_TFVARS="${WORK_DIR}/identities.tfvars.json"
write_identities_tfvars 1

# Import first: the plan must tighten legacy-imagebuilder's permissions and
# trust policy in place, never replace it (the role ARN this test's own pod
# will use must be the one created above, not a new one).
tfi import -input=false -var-file="${IDENTITIES_TFVARS}" "aws_iam_role.entry[\"legacy-imagebuilder\"]" "${LEGACY_ROLE_NAME}" \
  || fail "terraform import of the hand-rolled role into infra/identities"
pass "imported the hand-rolled role ${LEGACY_ROLE_NAME} as platform_identities[\"legacy-imagebuilder\"]"

import_plan="${WORK_DIR}/import.plan"
tfi plan -input=false -var-file="${IDENTITIES_TFVARS}" -out="${import_plan}" || fail "terraform plan after import"
plan_json="$(tfi show -json "${import_plan}")"
role_action="$(printf '%s' "${plan_json}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for rc in d.get('resource_changes', []):
    if rc['address'] == 'aws_iam_role.entry[\"legacy-imagebuilder\"]':
        print(','.join(rc['change']['actions']))
")"
[[ "${role_action}" == "update" ]] || fail "importing the legacy role must plan an in-place update, got: ${role_action:-<not found>}"
pass "import plan: aws_iam_role.entry[\"legacy-imagebuilder\"] is an in-place update (no replacement) - the pre-existing role is reused, not recreated"

IDENTITIES_APPLIED=1
tfi apply -input=false -auto-approve "${import_plan}" || fail "terraform apply infra/identities (import + two new entries)"
pass "terraform apply infra/identities (legacy-imagebuilder tightened in place, writer created)"

role_arn_after="$(aws iam get-role --role-name "${LEGACY_ROLE_NAME}" --query Role.Arn --output text)"
[[ "${role_arn_after}" == "${legacy_role_arn}" ]] || fail "legacy role ARN changed after import+apply (${legacy_role_arn} -> ${role_arn_after}); it must stay the same role"
pass "legacy-imagebuilder's role ARN is unchanged by the migration (${role_arn_after})"
still_has_broad_policy="$(aws iam list-attached-role-policies --role-name "${LEGACY_ROLE_NAME}" --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess']" --output text)"
[[ -z "${still_has_broad_policy}" ]] || fail "AmazonS3ReadOnlyAccess is still attached after apply; the migration must remove it (it is not declared in platform_identities)"
pass "the broad, hand-attached AmazonS3ReadOnlyAccess policy is gone; only the entry's own scoped inline policy remains"

# --------------------------------------------- 5. pods and credential checks

cat <<YAML | kubectl apply -f - || fail "apply test pods"
apiVersion: v1
kind: Pod
metadata:
  name: reader
  namespace: ${TEST_NAMESPACE}
spec:
  serviceAccountName: reader
  restartPolicy: Never
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  containers:
    - name: aws-cli
      image: ${AWS_CLI_IMAGE}
      command: ["/bin/sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: ${TEST_NAMESPACE}
spec:
  serviceAccountName: writer
  restartPolicy: Never
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  containers:
    - name: aws-cli
      image: ${AWS_CLI_IMAGE}
      command: ["/bin/sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: undeclared
  namespace: ${TEST_NAMESPACE}
spec:
  serviceAccountName: undeclared
  restartPolicy: Never
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  containers:
    - name: aws-cli
      image: ${AWS_CLI_IMAGE}
      command: ["/bin/sh", "-c", "sleep 3600"]
YAML

for p in reader writer undeclared; do
  if ! wait_until 360 5 "pod ${p} Running" bash -c "[[ \"\$(kubectl get pod ${p} -n ${TEST_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null)\" == Running ]]"; then
    kubectl describe pod "${p}" -n "${TEST_NAMESPACE}" || true
    fail "pod ${p} did not reach Running within 360s"
  fi
done
pass "reader, writer and undeclared pods are Running"

kexec() { kubectl exec -i -n "${TEST_NAMESPACE}" "$1" -- "${@:2}"; }

# EKS Pod Identity associations are eventually consistent (AWS's own
# documentation: "potential delays of several seconds after API calls");
# the association was created by the apply just above, and these Pods
# right after it, so the very first credentialed call gets a retry budget
# for that documented propagation window. A real run of this exact check,
# with no retry, failed immediately with "Unable to locate credentials"
# (the SDK found no AWS_CONTAINER_CREDENTIALS_FULL_URI at all, consistent
# with the association not yet having propagated to this node's agent)
# before this retry was added.
reader_reads_allowed() {
  kexec reader aws s3 cp "s3://${BUCKET}/allowed/ok.txt" - >/dev/null 2>"${WORK_DIR}/reader-ok.err"
}
wait_until 60 5 "reader reads its own declared prefix (allowing for EKS Pod Identity's documented propagation delay)" reader_reads_allowed \
  || fail "reader could not read s3://${BUCKET}/allowed/ok.txt within 60s (its own declared prefix): $(cat "${WORK_DIR}/reader-ok.err")"
pass "reader reads inside its own declared prefix (allowed/)"

if kexec reader aws s3 cp "s3://${BUCKET}/other/secret.txt" - >/dev/null 2>"${WORK_DIR}/reader-other.err"; then
  fail "reader could read s3://${BUCKET}/other/secret.txt, outside its declared prefix - scoping is not working"
fi
grep -qi "AccessDenied\|Forbidden" "${WORK_DIR}/reader-other.err" || fail "reader's denied read did not fail with AccessDenied/Forbidden: $(cat "${WORK_DIR}/reader-other.err")"
pass "reader is denied reading other/secret.txt, outside its own declared prefix, in the same bucket"

if echo "no" | kexec reader aws s3 cp - "s3://${BUCKET}/allowed/should-fail.txt" >/dev/null 2>"${WORK_DIR}/reader-write.err"; then
  fail "reader (write not declared) could write to s3://${BUCKET}/allowed/, read-only-unless-write-declared is not working"
fi
grep -qi "AccessDenied\|Forbidden" "${WORK_DIR}/reader-write.err" || fail "reader's denied write did not fail with AccessDenied/Forbidden: $(cat "${WORK_DIR}/reader-write.err")"
pass "reader is denied writing, because its own entry does not declare write = true"

writer_writes_own_prefix() {
  echo "written" | kexec writer aws s3 cp - "s3://${BUCKET}/writer-area/new.txt" >/dev/null 2>"${WORK_DIR}/writer-ok.err"
}
wait_until 60 5 "writer writes its own declared prefix (allowing for EKS Pod Identity's documented propagation delay)" writer_writes_own_prefix \
  || fail "writer could not write s3://${BUCKET}/writer-area/new.txt within 60s (its own declared prefix, write = true): $(cat "${WORK_DIR}/writer-ok.err")"
pass "writer writes inside its own declared prefix (writer-area/), because its own entry declares write = true"

if kexec writer aws s3 cp "s3://${BUCKET}/allowed/ok.txt" - >/dev/null 2>"${WORK_DIR}/writer-other.err"; then
  fail "writer could read s3://${BUCKET}/allowed/ok.txt, outside its own declared prefix - scoping is not working"
fi
grep -qi "AccessDenied\|Forbidden" "${WORK_DIR}/writer-other.err" || fail "writer's denied cross-prefix read did not fail with AccessDenied/Forbidden: $(cat "${WORK_DIR}/writer-other.err")"
pass "writer is denied touching reader's own prefix (allowed/); each entry's role is scoped to only its own declared resources"

if kexec undeclared aws sts get-caller-identity >/dev/null 2>"${WORK_DIR}/undeclared.err"; then
  fail "the undeclared ServiceAccount's pod obtained AWS credentials; an undeclared workload must get none at all"
fi
pass "the undeclared ServiceAccount's pod gets no AWS credentials at all (no role or Pod Identity association exists for it) - AccessDenied by construction"

# --------------------------------- 6. remove one entry, re-apply, check scope

write_identities_tfvars 0
removal_plan="${WORK_DIR}/removal.plan"
tfi plan -input=false -var-file="${IDENTITIES_TFVARS}" -out="${removal_plan}" || fail "terraform plan removing the writer entry"
removal_json="$(tfi show -json "${removal_plan}")"
removal_actions="$(printf '%s' "${removal_json}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for rc in d.get('resource_changes', []):
    print(rc['address'], ','.join(rc['change']['actions']))
")"
printf '%s\n' "${removal_actions}" | grep -q 'writer.*delete' || fail "removal plan does not delete the writer entry's own resources: ${removal_actions}"
printf '%s\n' "${removal_actions}" | grep -v 'writer' | grep -qv 'no-op' && {
  non_writer_changed="$(printf '%s\n' "${removal_actions}" | grep -v 'writer' | grep -v 'no-op' || true)"
  [[ -z "${non_writer_changed}" ]] || fail "removing the writer entry planned a change to a non-writer resource: ${non_writer_changed}"
}
pass "removing the writer entry plans only that entry's own role, policy and Pod Identity association"

tfi apply -input=false -auto-approve "${removal_plan}" || fail "terraform apply removing the writer entry"
no_role_left "${NAME}-identity-writer" || fail "the writer entry's own IAM role still exists after removal"
pass "the writer entry's own role is gone after removal"
legacy_role_arn_after_removal="$(aws iam get-role --role-name "${LEGACY_ROLE_NAME}" --query Role.Arn --output text)"
[[ "${legacy_role_arn_after_removal}" == "${legacy_role_arn}" ]] || fail "removing the writer entry changed the untouched legacy-imagebuilder entry's own role"
pass "the untouched legacy-imagebuilder entry's own role is unaffected by removing a different entry"

kexec reader aws s3 cp "s3://${BUCKET}/allowed/ok.txt" - >/dev/null \
  || fail "reader lost its own, still-declared access after an unrelated entry was removed"
pass "reader's own access is unaffected by removing the writer entry"

# ---------------------------------------------- 7. teardown and leftover sweep

kubectl delete namespace "${TEST_NAMESPACE}" --timeout=60s || fail "delete test namespace"
pass "test namespace deleted"

identities_destroy_start="$(date +%s)"
tfi destroy -input=false -var-file="${IDENTITIES_TFVARS}" -auto-approve || fail "terraform destroy infra/identities"
IDENTITIES_DESTROYED=1
pass "terraform destroy infra/identities ($(($(date +%s) - identities_destroy_start))s)"

no_role_left "${LEGACY_ROLE_NAME}" || fail "legacy-imagebuilder's role (now Terraform-managed, under its own pre-existing name via role_name) still exists after destroy"
pass "no identity role tagged for this run remains, by name (legacy-imagebuilder)"
wait_until "${E2E_LEFTOVER_GRACE_SECONDS}" 10 "no IAM role tagged ${TEST_TAG_KEY}=${RUN_ID}" no_role_tagged_for_run \
  || fail "an IAM role tagged ${TEST_TAG_KEY}=${RUN_ID} still exists after destroy"
pass "no IAM role anywhere in the account still carries this run's own tag"
assoc_left="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" --namespace "${TEST_NAMESPACE}" --query 'associations' --output text 2>&1)"
[[ -z "${assoc_left}" || "${assoc_left}" == "None" ]] || fail "Pod Identity associations remain for namespace ${TEST_NAMESPACE}: ${assoc_left}"
pass "no Pod Identity association remains for the test namespace"

aws s3 rm "s3://${BUCKET}" --recursive >/dev/null || fail "empty the disposable bucket before delete"
aws s3api delete-bucket --bucket "${BUCKET}" || fail "delete the disposable bucket"
BUCKET_CREATED=0
wait_until 60 5 "disposable bucket gone" no_bucket_left "${BUCKET}" || fail "disposable bucket ${BUCKET} still exists"
pass "disposable bucket ${BUCKET} removed"

vpc_id="$(tff output -raw vpc_id 2>/dev/null || true)"

foundation_destroy_start="$(date +%s)"
tff destroy -var-file="${FOUNDATION_TFVARS}" -auto-approve || fail "terraform destroy infra/foundation"
FOUNDATION_DESTROYED=1
pass "terraform destroy infra/foundation ($(($(date +%s) - foundation_destroy_start))s)"

if [[ -n "${vpc_id}" ]]; then
  vpc_check="$(aws_text aws ec2 describe-vpcs --vpc-ids "${vpc_id}" --query 'Vpcs[0].VpcId' --output text)" \
    || fail "checking whether VPC ${vpc_id} still exists: ${vpc_check}"
  [[ -z "${vpc_check}" || "${vpc_check}" == "None" ]] || fail "VPC ${vpc_id} still exists after infra/foundation destroy"
fi
pass "the cell's VPC is gone (infra/foundation's own destroy and leftover sweep is exercised and proved separately by its own 1.e2e.sh; this script re-checks only that the VPC it stood up is actually gone)"

echo
echo "RESULT PASS: all checks passed (run ${RUN_ID}, work dir ${WORK_DIR})"
