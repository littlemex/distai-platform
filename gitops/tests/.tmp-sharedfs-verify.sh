#!/usr/bin/env bash
# Scratch, one-time real-machine verification for issue #18 (sharedfs per-team
# checkpoint and shared dataset directories). Not a permanent fixture: removed
# before this branch is merged. The permanent regression coverage is the
# GITOPS_RUN_SHAREDFS_E2E section of gitops/tests/1.e2e.sh (a separate,
# parallel workstream on this same issue).
#
# Run via the EC2 runner only:
#   runner/run.sh --ref feat/18-sharedfs-storage --detach \
#     -- bash gitops/tests/.tmp-sharedfs-verify.sh
#
# shellcheck disable=SC2015
# Every "A && B || C" below has only log/exit calls (which always
# succeed) as B, never a command whose own failure the "||" branch is
# meant to catch - not the misuse this check warns about.
set -euo pipefail

: "${AWS_REGION:?}"
: "${NAME:?}"
: "${STATE_BUCKET:?}"
: "${STATE_REGION:?}"
: "${ADMIN_PRINCIPAL_ARN:?}"
: "${MY_CIDR:?}"
: "${ARGOCD_IDC_INSTANCE_ARN:?}"
: "${ARGOCD_IDC_REGION:?}"
: "${ARGOCD_IDC_IDENTITY_STORE_ID:?}"
: "${REVISION:?}"
export AWS_PROFILE="${AWS_PROFILE:-default}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
IDC_GROUP_NAME="dp18-sfs-$(date +%s)"
IDC_GROUP_ID=""
# Set right after `terraform init` (not after `terraform apply`): a
# PARTIALLY failed apply still records every resource that did complete
# into the state file before the failing resource is reached (confirmed
# the hard way, 2026-11-26 - two attempts whose own apply failed at FSx
# creation, after already creating a real EKS cluster, VPC and Argo CD
# capability, both skipped this cleanup's own terraform destroy entirely
# because this flag was gated on apply succeeding, leaving those real,
# billable resources running with no further attempt of this script
# left to clean them up). `terraform destroy` against an initialized
# root with a non-empty state is always the right call once init has
# happened, whether or not apply ever finished; destroy on an empty
# state is a harmless no-op.
INITIALIZED=0
IMAGE="public.ecr.aws/docker/library/busybox:1.37"

log() { echo "[sharedfs-verify] $*" >&2; }

cleanup() {
  log "cleanup: start"
  if [[ "${INITIALIZED}" == "1" ]]; then
    ( cd "${ROOT}/infra/foundation" && terraform destroy -auto-approve \
      -var "name=${NAME}" -var "region=${AWS_REGION}" \
      -var "endpoint_public_access_cidrs=[\"${MY_CIDR}\"]" \
      -var "admin_principal_arns=[\"${ADMIN_PRINCIPAL_ARN}\"]" \
      -var "argocd={idc_instance_arn=\"${ARGOCD_IDC_INSTANCE_ARN}\",idc_region=\"${ARGOCD_IDC_REGION}\",role_mappings=[{role=\"ADMIN\",group_ids=[\"${IDC_GROUP_ID}\"]}]}" \
      -var "shared_fsx_lustre={deployment_type=\"SCRATCH_2\",storage_capacity_gib=1200,skip_final_backup=true}" \
    ) || log "WARNING: terraform destroy did not exit 0; a leftover sweep follows regardless"
  fi
  if [[ -n "${IDC_GROUP_ID}" ]]; then
    aws identitystore delete-group --identity-store-id "${ARGOCD_IDC_IDENTITY_STORE_ID}" \
      --region "${ARGOCD_IDC_REGION}" --group-id "${IDC_GROUP_ID}" >/dev/null 2>&1 \
      && log "deleted IdC group ${IDC_GROUP_ID}" || log "WARNING: IdC group ${IDC_GROUP_ID} delete failed or already gone"
  fi
  log "independent read-only leftover sweep (cell ${NAME}, region ${AWS_REGION})"
  # Every check below used to read an AWS CLI call's own failure (for any
  # reason - throttling, a permissions error, a transient API outage) the
  # same as "the resource is absent", because the previous `2>&1 && X ||
  # Y`/`2>/dev/null || true` shapes cannot tell the two apart. That is
  # exactly backwards for a sweep whose whole purpose is to catch a real
  # leftover a buggy or disabled teardown step left behind: a sweep that
  # reads its own inability to check as "clean" can silently hide the
  # thing it exists to catch. Each check now captures the call's own
  # stdout, stderr and exit code separately (sweep_err) and only reads
  # "absent" from the AWS-documented not-found signature for that API,
  # reporting anything else as UNKNOWN for a human to investigate rather
  # than as ok. `set +e`/`set -e` bracket this block: this script's own
  # set -e (line 16) would otherwise abort the whole sweep (skipping every
  # check after the first failure) the moment any one call's own exit
  # status is read directly, rather than let each check run to completion
  # and report its own result.
  set +e
  sweep_err="$(mktemp)"

  aws eks describe-cluster --name "${NAME}" --region "${AWS_REGION}" >/dev/null 2>"${sweep_err}"
  eks_rc=$?
  if [[ "${eks_rc}" -eq 0 ]]; then
    log "LEFTOVER: eks cluster ${NAME} still exists"
  elif grep -q "ResourceNotFoundException" "${sweep_err}"; then
    log "ok: eks cluster ${NAME} absent"
  else
    log "UNKNOWN: aws eks describe-cluster for ${NAME} failed for a reason other than \"not found\" - investigate manually: $(cat "${sweep_err}")"
  fi

  instances_out="$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>"${sweep_err}")"
  instances_rc=$?
  if [[ "${instances_rc}" -ne 0 ]]; then
    log "UNKNOWN: aws ec2 describe-instances for ${NAME} failed - investigate manually: $(cat "${sweep_err}")"
  elif [[ -z "${instances_out}" ]]; then
    log "ok: no EC2 instances tagged eks:eks-cluster-name=${NAME}"
  else
    log "LEFTOVER: instances ${instances_out}"
  fi

  vpcs_out="$(aws ec2 describe-vpcs --region "${AWS_REGION}" --filters "Name=tag:Name,Values=${NAME}" --query 'Vpcs[].VpcId' --output text 2>"${sweep_err}")"
  vpcs_rc=$?
  if [[ "${vpcs_rc}" -ne 0 ]]; then
    log "UNKNOWN: aws ec2 describe-vpcs for ${NAME} failed - investigate manually: $(cat "${sweep_err}")"
  elif [[ -z "${vpcs_out}" ]]; then
    log "ok: no VPC tagged Name=${NAME}"
  else
    log "LEFTOVER: VPCs ${vpcs_out}"
  fi

  repos_out="$(aws ecr describe-repositories --region "${AWS_REGION}" --query "repositories[?starts_with(repositoryName, '${NAME}-')].repositoryName" --output text 2>"${sweep_err}")"
  repos_rc=$?
  if [[ "${repos_rc}" -ne 0 ]]; then
    log "UNKNOWN: aws ecr describe-repositories for ${NAME}-* failed - investigate manually: $(cat "${sweep_err}")"
  elif [[ -z "${repos_out}" ]]; then
    log "ok: no ECR repository ${NAME}-*"
  else
    log "LEFTOVER: ECR repositories ${repos_out}"
  fi

  fs_out="$(aws fsx describe-file-systems --region "${AWS_REGION}" --query "FileSystems[?Tags[?Key=='Name' && Value=='${NAME}-shared']].FileSystemId" --output text 2>"${sweep_err}")"
  fs_rc=$?
  if [[ "${fs_rc}" -ne 0 ]]; then
    log "UNKNOWN: aws fsx describe-file-systems for ${NAME}-shared failed - investigate manually: $(cat "${sweep_err}")"
  elif [[ -z "${fs_out}" ]]; then
    log "ok: no FSx file system tagged Name=${NAME}-shared"
  else
    log "LEFTOVER: FSx file system ${fs_out} (deletion may still be in progress; re-check)"
  fi

  # IAM role: fsx.tf's own aws_iam_role.fsx_csi_driver (#18) - not swept by
  # any check above, and not covered by the VPC/EKS/ECR/FSx checks either
  # (an IAM role is account-global, not VPC- or cluster-scoped).
  aws iam get-role --role-name "${NAME}-fsx-csi-driver" >/dev/null 2>"${sweep_err}"
  role_rc=$?
  if [[ "${role_rc}" -eq 0 ]]; then
    log "LEFTOVER: IAM role ${NAME}-fsx-csi-driver still exists"
  elif grep -q "NoSuchEntity" "${sweep_err}"; then
    log "ok: IAM role ${NAME}-fsx-csi-driver absent"
  else
    log "UNKNOWN: aws iam get-role for ${NAME}-fsx-csi-driver failed for a reason other than \"not found\" - investigate manually: $(cat "${sweep_err}")"
  fi

  rm -f "${sweep_err}"
  set -e
  log "cleanup: done"
}
trap cleanup EXIT

# run_test_pod <name> <namespace> <sa-or-empty> <pvc-name> <command string>
# Every pod this script creates in a namespace at Pod Security "restricted"
# (team-a, team-b, fs-admin -- gitops/bootstrap/team-onboard.sh and
# gitops/charts/sharedfs-shares' own fs-admin namespace.yaml) must itself
# satisfy "restricted": runAsNonRoot, a non-zero runAsUser (the busybox
# image's own default user is root, so Kubernetes cannot verify
# non-root without one), no privilege escalation, every capability
# dropped, RuntimeDefault seccomp. runAsGroup: 1000 matches every
# FilesystemShare's own provision.gid in this PR's gitops/charts/
# sharedfs-shares (sharedfs's own README: "Pods write as a member of
# the directory's group: set runAsGroup ... fsGroup has no effect on
# these volumes") -- without it, even a read against a 2770-mode
# directory is denied to every uid outside that group.
run_test_pod() {
  local name="$1" ns="$2" sa="$3" pvc="$4" cmd="$5"
  local sa_json=""
  [[ -n "${sa}" ]] && sa_json="\"serviceAccountName\": \"${sa}\","
  kubectl run "${name}" -n "${ns}" --image="${IMAGE}" --restart=Never \
    --overrides="{
      \"spec\": {
        ${sa_json}
        \"securityContext\": {\"runAsNonRoot\": true, \"runAsUser\": 1000, \"runAsGroup\": 1000, \"seccompProfile\": {\"type\": \"RuntimeDefault\"}},
        \"containers\": [{\"name\": \"${name}\", \"image\": \"${IMAGE}\",
          \"command\": [\"sh\", \"-c\", \"${cmd}\"],
          \"securityContext\": {\"allowPrivilegeEscalation\": false, \"capabilities\": {\"drop\": [\"ALL\"]}},
          \"volumeMounts\": [{\"name\": \"v\", \"mountPath\": \"/mnt\"}]}],
        \"volumes\": [{\"name\": \"v\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc}\"}}],
        \"restartPolicy\": \"Never\"
      }
    }"
}

cd "${ROOT}/infra/foundation"

log "terraform init (state key ${STATE_KEY})"
terraform init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" -backend-config="use_lockfile=true"
INITIALIZED=1

log "creating disposable Identity Center group ${IDC_GROUP_NAME}"
IDC_GROUP_ID="$(aws identitystore create-group --identity-store-id "${ARGOCD_IDC_IDENTITY_STORE_ID}" \
  --region "${ARGOCD_IDC_REGION}" --display-name "${IDC_GROUP_NAME}" \
  --description "disposable, issue #18 real-machine verification" \
  --query GroupId --output text)"
log "IdC group id ${IDC_GROUP_ID}"

log "terraform apply (this is the slow step: EKS + FSx for Lustre SCRATCH_2 1200 GiB)"
terraform apply -auto-approve -input=false \
  -var "name=${NAME}" -var "region=${AWS_REGION}" \
  -var "endpoint_public_access_cidrs=[\"${MY_CIDR}\"]" \
  -var "admin_principal_arns=[\"${ADMIN_PRINCIPAL_ARN}\"]" \
  -var "argocd={idc_instance_arn=\"${ARGOCD_IDC_INSTANCE_ARN}\",idc_region=\"${ARGOCD_IDC_REGION}\",role_mappings=[{role=\"ADMIN\",group_ids=[\"${IDC_GROUP_ID}\"]}]}" \
  -var "shared_fsx_lustre={deployment_type=\"SCRATCH_2\",storage_capacity_gib=1200,skip_final_backup=true}"

aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"

log "bootstrap.sh"
"${ROOT}/gitops/bootstrap/bootstrap.sh" --tf-outputs <(terraform output -json) --revision "${REVISION}"

ECR_URL="$(terraform output -raw sharedfs_controller_ecr_repository_url)"
ARGOCD_NS="$(terraform output -raw argocd_namespace)"
log "sharedfs-image-publish.sh (ecr repo ${ECR_URL})"
"${ROOT}/gitops/bootstrap/sharedfs-image-publish.sh" \
  --ecr-repository-url "${ECR_URL}" --region "${AWS_REGION}" \
  --cluster-registration-namespace "${ARGOCD_NS}"

log "team-onboard.sh team-a"
"${ROOT}/gitops/bootstrap/team-onboard.sh" --team team-a --tf-outputs <(terraform output -json) \
  --source-repo https://github.com/littlemex/distai-platform.git
log "team-onboard.sh team-b"
"${ROOT}/gitops/bootstrap/team-onboard.sh" --team team-b --tf-outputs <(terraform output -json) \
  --source-repo https://github.com/littlemex/distai-platform.git

log "waiting for Argo CD to converge (platform/cells/addons-optional Applications Synced, Healthy where they report health)"
DEADLINE=$(( $(date +%s) + 1800 ))
while true; do
  NOT_SYNCED="$(kubectl get applications.argoproj.io -n "${ARGOCD_NS}" -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = []
for a in d.get('items', []):
    name = a['metadata']['name']
    sync = a.get('status', {}).get('sync', {}).get('status', 'Unknown')
    health = a.get('status', {}).get('health', {}).get('status', 'Unknown')
    if sync != 'Synced' or health not in ('Healthy', 'Unknown'):
        bad.append(f'{name}: sync={sync} health={health}')
print(chr(10).join(bad))
")"
  if [[ -z "${NOT_SYNCED}" ]]; then
    log "all Applications Synced (and Healthy where they report health)"
    break
  fi
  if [[ "$(date +%s)" -ge "${DEADLINE}" ]]; then
    log "FAIL: Applications still not converged after 30 minutes:"
    echo "${NOT_SYNCED}" >&2
    kubectl get applications.argoproj.io -n "${ARGOCD_NS}" >&2 || true
    # The one-line sync/health pair above (attempt 6, 2026-11-26) was not
    # enough to root-cause which object a stuck Application could not
    # apply: status.conditions and status.operationState carry Argo CD's
    # own error message for that, and the cluster is gone by the time
    # anyone reads this log (this trap's own cleanup tears it down right
    # after). Dump both for every not-converged Application so the next
    # real-machine attempt does not have to spend its own budget
    # rediscovering the same gap.
    while IFS= read -r app_line; do
      [[ -z "${app_line}" ]] && continue
      app_name="${app_line%%:*}"
      log "diagnostics for ${app_name}:"
      kubectl get application "${app_name}" -n "${ARGOCD_NS}" -o jsonpath='{.status.conditions}' >&2 || true
      echo >&2
      kubectl get application "${app_name}" -n "${ARGOCD_NS}" -o jsonpath='{.status.operationState}' >&2 || true
      echo >&2
      kubectl get application "${app_name}" -n "${ARGOCD_NS}" -o jsonpath='{.status.resources}' >&2 || true
      echo >&2
    done <<< "${NOT_SYNCED}"
    exit 1
  fi
  sleep 20
done

log "waiting for FilesystemShare objects to report Ready"
kubectl wait --for=condition=Ready fss/checkpoints fss/datasets --timeout=300s

RESULTS_DIR="${HOME}/sharedfs-verify-results"
mkdir -p "${RESULTS_DIR}"

log "check 1: team-a creates its own checkpoints-rw PVC and writes/reads back a file"
kubectl apply -n team-a --as=system:serviceaccount:team-a:team-a-deployer -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ckpt-a
spec:
  storageClassName: checkpoints-rw
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/ckpt-a -n team-a --timeout=120s
run_test_pod team-a-writer team-a team-a-deployer ckpt-a "echo team-a-secret > /mnt/hello.txt && cat /mnt/hello.txt"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/team-a-writer -n team-a --timeout=180s
kubectl logs pod/team-a-writer -n team-a | tee "${RESULTS_DIR}/check1-team-a-write.log"
grep -q team-a-secret "${RESULTS_DIR}/check1-team-a-write.log" && log "CHECK 1 PASS: team-a wrote and read back its own checkpoint" || { log "CHECK 1 FAIL"; exit 1; }

log "check 2: team-b's own checkpoints-rw claim never sees team-a's directory at all (path-scoped mount, not an in-mount denial), and an ungranted namespace's claim stays unbound"
kubectl apply -n team-b --as=system:serviceaccount:team-b:team-b-deployer -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ckpt-b
spec:
  storageClassName: checkpoints-rw
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/ckpt-b -n team-b --timeout=120s
run_test_pod team-b-reader team-b team-b-deployer ckpt-b "ls -la /mnt; cat /mnt/hello.txt 2>&1; echo ---; echo team-b-own-write > /mnt/own.txt && cat /mnt/own.txt"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/team-b-reader -n team-b --timeout=180s
kubectl logs pod/team-b-reader -n team-b | tee "${RESULTS_DIR}/check2-team-b-isolation.log"
grep -q "team-a-secret" "${RESULTS_DIR}/check2-team-b-isolation.log" && { log "CHECK 2a FAIL: team-b read team-a's file"; exit 1; } || log "CHECK 2a PASS (part 1): team-a's own checkpoint content was not found under team-b's own checkpoints-rw mount"
grep -q "team-b-own-write" "${RESULTS_DIR}/check2-team-b-isolation.log" || { log "CHECK 2a FAIL: team-b could not write to its own directory (unrelated to isolation -- the mount itself is broken)"; exit 1; }
# Part 1 above only proves hello.txt is not directly under /mnt; if the
# mount were (incorrectly) rooted at the whole file system instead of
# checkpoints/team-b, hello.txt would sit at
# /mnt/checkpoints/team-a/hello.txt instead, grep for the literal string
# would still miss it, and part 1 alone would read that as a PASS. The
# pod's own `ls -la /mnt` (captured in the same log) is what actually
# distinguishes the two: a correctly-scoped mount's root has no
# "checkpoints" entry at all (team-b's own files only), so asserting its
# absence is what rules out the broader mount, not just the absence of
# one specific file at one specific path.
grep -q "checkpoints" "${RESULTS_DIR}/check2-team-b-isolation.log" && { log "CHECK 2a FAIL: team-b's own mount root shows a checkpoints/ entry - this mount is rooted at the whole file system, not team-b's own directory (hello.txt's absence above was not proof of isolation, only of looking in the wrong place)"; exit 1; }
log "CHECK 2a PASS (part 2): team-b's own mount root carries no checkpoints/ entry at all, confirming the mount itself is scoped to checkpoints/team-b, not the whole file system"
kubectl create namespace ungranted --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n ungranted -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ckpt-ungranted
spec:
  storageClassName: checkpoints-rw
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
EOF
# 60s, not 20s: this PVC should never bind (no team namespace list ever
# names "ungranted"), so there is no pending future event a short wait
# could legitimately miss - but a longer wait gives more room for a real
# implementation bug (one that eventually provisions it anyway) to
# surface, rather than a short window that would read a slow-but-still-
# wrong eventual bind as an early, false PASS.
sleep 60
kubectl get pvc ckpt-ungranted -n ungranted -o json | tee "${RESULTS_DIR}/check2b-ungranted-pvc.json"
kubectl describe pvc ckpt-ungranted -n ungranted | tee "${RESULTS_DIR}/check2b-ungranted-pvc-events.log"
PHASE="$(kubectl get pvc ckpt-ungranted -n ungranted -o jsonpath='{.status.phase}')"
[[ "${PHASE}" != "Bound" ]] && log "CHECK 2b PASS: ungranted namespace's claim stayed ${PHASE:-Pending}, not Bound" || { log "CHECK 2b FAIL: ungranted namespace's claim bound"; exit 1; }

log "check 3: both teams read the shared, admin-seeded dataset; a team's write against it is refused"
kubectl apply -n fs-admin -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: datasets-seed
spec:
  storageClassName: datasets-rw
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/datasets-seed -n fs-admin --timeout=120s
run_test_pod seed fs-admin "" datasets-seed "echo shared-dataset-content > /mnt/data.txt"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/seed -n fs-admin --timeout=180s
for team in team-a team-b; do
  kubectl apply -n "${team}" --as="system:serviceaccount:${team}:${team}-deployer" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ds-${team}
spec:
  storageClassName: datasets-ro
  accessModes: [ReadOnlyMany]
  resources: {requests: {storage: 1Gi}}
EOF
  kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/ds-${team}" -n "${team}" --timeout=120s
  run_test_pod "ds-reader-${team}" "${team}" "${team}-deployer" "ds-${team}" "cat /mnt/data.txt; echo ---; echo team-write-attempt > /mnt/evil.txt 2>&1; echo RC=\$?"
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/ds-reader-${team}" -n "${team}" --timeout=180s
  kubectl logs "pod/ds-reader-${team}" -n "${team}" | tee "${RESULTS_DIR}/check3-${team}-dataset-read.log"
  grep -q "shared-dataset-content" "${RESULTS_DIR}/check3-${team}-dataset-read.log" || { log "CHECK 3 FAIL: ${team} could not read the shared dataset"; exit 1; }
  grep -qE "Read-only|Permission denied|RC=[1-9]" "${RESULTS_DIR}/check3-${team}-dataset-read.log" || { log "CHECK 3 FAIL: ${team}'s write attempt against datasets-ro did not fail"; exit 1; }
done
log "CHECK 3 PASS: both teams read the admin-seeded dataset; neither could write to it"

log "check 4: PVC creation by a team's own onboarding ServiceAccount matches the design (its own namespace only, never another team's)"
# `kubectl auth can-i` exits 1 for a "no" answer, by its own documented
# design - not a script-vs-kubectl-API error. Under set -e (this script's
# own line 16), the second call below would abort the whole run right
# here on the correct, expected "no" answer, never reaching the grep that
# is supposed to confirm it. `|| true` on each call keeps set -e from
# firing on either answer; the grep immediately after is still what
# actually decides pass/fail, same as before.
kubectl auth can-i create persistentvolumeclaims --as=system:serviceaccount:team-a:team-a-deployer -n team-a | tee "${RESULTS_DIR}/check4-own-namespace.log" || true
kubectl auth can-i create persistentvolumeclaims --as=system:serviceaccount:team-a:team-a-deployer -n team-b | tee "${RESULTS_DIR}/check4-cross-namespace.log" || true
grep -q "^yes" "${RESULTS_DIR}/check4-own-namespace.log" || { log "CHECK 4 FAIL: team-a-deployer cannot create a PVC in its own namespace"; exit 1; }
grep -q "^no" "${RESULTS_DIR}/check4-cross-namespace.log" || { log "CHECK 4 FAIL: team-a-deployer can create a PVC in team-b's namespace"; exit 1; }
log "CHECK 4 PASS: a team's own onboarding identity can create a PVC in its own namespace only (namespaced Role, no persistentvolumes grant)"

log "check 5: a team claiming datasets-rw (not datasets-ro) never gets write access to the shared dataset - fs-admin's own reserving PVC (gitops/charts/sharedfs-shares) already holds the one PV this storageClassName can ever bind, so the object is created (RBAC grants create persistentvolumeclaims generically, same as check 1/2) but never Bound, the same shape as check 2b's ungranted-namespace case, not an admission-time rejection"
kubectl apply -n team-a --as=system:serviceaccount:team-a:team-a-deployer -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ds-rw-attempt
spec:
  storageClassName: datasets-rw
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
EOF
sleep 60
kubectl get pvc ds-rw-attempt -n team-a -o json | tee "${RESULTS_DIR}/check5-datasets-rw-pvc.json"
kubectl describe pvc ds-rw-attempt -n team-a | tee "${RESULTS_DIR}/check5-datasets-rw-pvc-events.log"
PHASE="$(kubectl get pvc ds-rw-attempt -n team-a -o jsonpath='{.status.phase}')"
[[ "${PHASE}" != "Bound" ]] || { log "CHECK 5 FAIL: team-a's datasets-rw claim bound (a team should never get write access to the shared dataset)"; exit 1; }
log "CHECK 5 PASS: team-a's datasets-rw claim stayed ${PHASE:-Pending}, not Bound"

log "ALL CHECKS PASS"
kubectl get fss -A | tee "${RESULTS_DIR}/final-fss-status.log"
kubectl get fsd -A | tee "${RESULTS_DIR}/final-fsd-status.log"
