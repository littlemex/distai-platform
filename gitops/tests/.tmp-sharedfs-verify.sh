#!/usr/bin/env bash
# Real-machine verification for issue #18 (sharedfs per-team checkpoint and
# shared dataset directories). Originally written as a scratch, one-time
# script meant to be removed before this branch merges; kept instead
# (2026-11-27/28), since all five checks below pass and deleting the one
# thing that proves this feature works, with no permanent replacement built
# yet, would be a regression rather than a cleanup. Folding these checks
# into a GITOPS_RUN_SHAREDFS_E2E section of gitops/tests/1.e2e.sh (the same
# shape GITOPS_RUN_ACCEL_E2E already uses) is tracked as follow-up scope.
#
# Needs a Linux/amd64 host: gitops/bootstrap/sharedfs-image-publish.sh,
# which this script calls, downloads a `go${GO_VERSION}.linux-amd64.tar.gz`
# toolchain unconditionally (no `uname`-based platform detection), the same
# x86_64-only scoping this platform's own system node group already has -
# not macOS, and not arm64. Tools: aws, terraform, kubectl, jq, git,
# python3, curl, tar, sha256sum. This task round ran it on this
# repository's own EC2 runner:
#   runner/run.sh --ref feat/18-sharedfs-storage --detach \
#     -- bash gitops/tests/.tmp-sharedfs-verify.sh
# but nothing about the script itself requires that specific host, only
# the platform/tool list above.
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

# NAME must match a committed gitops/cells/<NAME>/ fixture directory: the
# cells/addons-optional ApplicationSets both generate Applications from a
# Git file generator keyed on this exact cluster name
# (gitops/appsets/cells.ApplicationSet.yaml, gitops/appsets/
# addons-optional.ApplicationSet.yaml), and this PR's only committed
# fixture is gitops/cells/dp-18-sharedfs-r1/. A different NAME is not an
# error this script's earlier steps would ever surface - terraform apply,
# bootstrap.sh and sharedfs-image-publish.sh all succeed regardless, and
# the convergence loop below reports every (zero) cell-specific
# Application "Synced" vacuously, so the first visible symptom used to be
# `kubectl wait` failing on a CustomResourceDefinition that was simply
# never generated in the first place, after a full EKS + FSx build had
# already run (found the hard way, 2026-11-27: this task round's own
# second real-machine attempt). Checked here, before `terraform init`,
# so a wrong NAME fails in under a second instead of after ~15 minutes
# of real AWS resource creation.
for required_dir in capacity-pool sharedfs smoke; do
  [[ -d "${ROOT}/gitops/cells/${NAME}/${required_dir}" ]] || {
    echo "[sharedfs-verify] FAIL: gitops/cells/${NAME}/${required_dir}/ does not exist in this checkout - NAME must match a committed cell fixture directory (this PR's own fixture is dp-18-sharedfs-r1), not an arbitrary unused cell name" >&2
    exit 1
  }
done

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
  # Captured before anything else in this trap touches $? - this is the
  # main script body's own exit status (0 if every check passed, non-zero
  # if one failed), not this trap's. PROBLEM tracks whether cleanup itself
  # finds anything wrong (a failed destroy, a leftover resource, a sweep
  # call that failed for a reason other than "not found"); set below by
  # every branch that logs WARNING/LEFTOVER/UNKNOWN. Found by a review
  # round (2026-11-27/28): this function used to only log those lines and
  # never touch the exit code at all, so a run could print "ALL CHECKS
  # PASS" and still exit 0 even if the destroy that followed left a real,
  # billable EKS cluster or FSx file system running - the exact failure
  # mode this trap exists to catch. An EXIT trap's own `exit N` does
  # override the script's final exit status; without one here, bash just
  # keeps the original.
  local original_rc=$?
  local problem=0
  log "cleanup: start"
  if [[ "${INITIALIZED}" == "1" ]]; then
    ( cd "${ROOT}/infra/foundation" && terraform destroy -auto-approve \
      -var "name=${NAME}" -var "region=${AWS_REGION}" \
      -var "endpoint_public_access_cidrs=[\"${MY_CIDR}\"]" \
      -var "admin_principal_arns=[\"${ADMIN_PRINCIPAL_ARN}\"]" \
      -var "argocd={idc_instance_arn=\"${ARGOCD_IDC_INSTANCE_ARN}\",idc_region=\"${ARGOCD_IDC_REGION}\",role_mappings=[{role=\"ADMIN\",group_ids=[\"${IDC_GROUP_ID}\"]}]}" \
      -var "shared_fsx_lustre={deployment_type=\"SCRATCH_2\",storage_capacity_gib=1200,skip_final_backup=true}" \
    ) || { log "WARNING: terraform destroy did not exit 0; a leftover sweep follows regardless"; problem=1; }
  fi
  if [[ -n "${IDC_GROUP_ID}" ]]; then
    # Not a `problem=1` branch: unlike the six checks below, this group is
    # not a billable AWS resource, and "already gone" (this call's own
    # failure branch, indistinguishable here from a real delete failure)
    # is an expected, harmless outcome on more than one path - logged as a
    # WARNING for a human to notice, not treated as the kind of leftover
    # this trap's own exit code exists to catch.
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
  # set -e (this script's own, near the top) would otherwise abort the whole sweep (skipping every
  # check after the first failure) the moment any one call's own exit
  # status is read directly, rather than let each check run to completion
  # and report its own result.
  set +e
  sweep_err="$(mktemp)"

  aws eks describe-cluster --name "${NAME}" --region "${AWS_REGION}" >/dev/null 2>"${sweep_err}"
  eks_rc=$?
  if [[ "${eks_rc}" -eq 0 ]]; then
    { log "LEFTOVER: eks cluster ${NAME} still exists"; problem=1; }
  elif grep -q "ResourceNotFoundException" "${sweep_err}"; then
    log "ok: eks cluster ${NAME} absent"
  else
    { log "UNKNOWN: aws eks describe-cluster for ${NAME} failed for a reason other than \"not found\" - investigate manually: $(cat "${sweep_err}")"; problem=1; }
  fi

  instances_out="$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>"${sweep_err}")"
  instances_rc=$?
  if [[ "${instances_rc}" -ne 0 ]]; then
    { log "UNKNOWN: aws ec2 describe-instances for ${NAME} failed - investigate manually: $(cat "${sweep_err}")"; problem=1; }
  elif [[ -z "${instances_out}" ]]; then
    log "ok: no EC2 instances tagged eks:eks-cluster-name=${NAME}"
  else
    { log "LEFTOVER: instances ${instances_out}"; problem=1; }
  fi

  vpcs_out="$(aws ec2 describe-vpcs --region "${AWS_REGION}" --filters "Name=tag:Name,Values=${NAME}" --query 'Vpcs[].VpcId' --output text 2>"${sweep_err}")"
  vpcs_rc=$?
  if [[ "${vpcs_rc}" -ne 0 ]]; then
    { log "UNKNOWN: aws ec2 describe-vpcs for ${NAME} failed - investigate manually: $(cat "${sweep_err}")"; problem=1; }
  elif [[ -z "${vpcs_out}" ]]; then
    log "ok: no VPC tagged Name=${NAME}"
  else
    { log "LEFTOVER: VPCs ${vpcs_out}"; problem=1; }
  fi

  repos_out="$(aws ecr describe-repositories --region "${AWS_REGION}" --query "repositories[?starts_with(repositoryName, '${NAME}-')].repositoryName" --output text 2>"${sweep_err}")"
  repos_rc=$?
  if [[ "${repos_rc}" -ne 0 ]]; then
    { log "UNKNOWN: aws ecr describe-repositories for ${NAME}-* failed - investigate manually: $(cat "${sweep_err}")"; problem=1; }
  elif [[ -z "${repos_out}" ]]; then
    log "ok: no ECR repository ${NAME}-*"
  else
    { log "LEFTOVER: ECR repositories ${repos_out}"; problem=1; }
  fi

  fs_out="$(aws fsx describe-file-systems --region "${AWS_REGION}" --query "FileSystems[?Tags[?Key=='Name' && Value=='${NAME}-shared']].FileSystemId" --output text 2>"${sweep_err}")"
  fs_rc=$?
  if [[ "${fs_rc}" -ne 0 ]]; then
    { log "UNKNOWN: aws fsx describe-file-systems for ${NAME}-shared failed - investigate manually: $(cat "${sweep_err}")"; problem=1; }
  elif [[ -z "${fs_out}" ]]; then
    log "ok: no FSx file system tagged Name=${NAME}-shared"
  else
    { log "LEFTOVER: FSx file system ${fs_out} (deletion may still be in progress; re-check)"; problem=1; }
  fi

  # IAM role: fsx.tf's own aws_iam_role.fsx_csi_driver (#18) - not swept by
  # any check above, and not covered by the VPC/EKS/ECR/FSx checks either
  # (an IAM role is account-global, not VPC- or cluster-scoped).
  aws iam get-role --role-name "${NAME}-fsx-csi-driver" >/dev/null 2>"${sweep_err}"
  role_rc=$?
  if [[ "${role_rc}" -eq 0 ]]; then
    { log "LEFTOVER: IAM role ${NAME}-fsx-csi-driver still exists"; problem=1; }
  elif grep -q "NoSuchEntity" "${sweep_err}"; then
    log "ok: IAM role ${NAME}-fsx-csi-driver absent"
  else
    { log "UNKNOWN: aws iam get-role for ${NAME}-fsx-csi-driver failed for a reason other than \"not found\" - investigate manually: $(cat "${sweep_err}")"; problem=1; }
  fi

  rm -f "${sweep_err}"
  set -e
  if [[ "${problem}" -eq 1 ]]; then
    log "cleanup: done, but found at least one problem above (WARNING/LEFTOVER/UNKNOWN) - exiting non-zero regardless of the main script's own exit status (${original_rc}) so this run is never read as a clean pass"
    exit 1
  fi
  log "cleanup: done, no leftovers"
  exit "${original_rc}"
}
trap cleanup EXIT

# run_test_pod <name> <namespace> <sa-or-empty> <pvc-name> <command string>
# Every pod this helper creates runs through team-a/team-b's own Pod
# Security "restricted" (gitops/bootstrap/team-onboard.sh): runAsNonRoot,
# a non-zero runAsUser (the busybox image's own default user is root, so
# Kubernetes cannot verify non-root without one), no privilege
# escalation, every capability dropped, RuntimeDefault seccomp. fs-admin
# is baseline, not restricted (gitops/charts/sharedfs-shares' own
# namespace.yaml, needed for templates/seed.yaml's own uid 0 + CAP_CHOWN)
# - the one caller against fs-admin (check 3's own seed pod) does not use
# this helper at all, for exactly that reason; every call site below
# that does use it targets team-a or team-b only. runAsGroup: 1000
# matches checkpoints' own FilesystemShare provision.gid (not datasets,
# which carries no provision at all - see gitops/charts/sharedfs-shares'
# own templates/filesystemshares.yaml) - sharedfs's own README: "Pods
# write as a member of the directory's group: set runAsGroup ... fsGroup
# has no effect on these volumes" -- without it, even a read against a
# 2770-mode directory is denied to every uid outside that group.
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

log "waiting for Argo CD to converge (platform/cells/addons-optional Applications Synced, Healthy where they report health, except vigil-controller - see EXCLUDED_APPS below)"
DEADLINE=$(( $(date +%s) + 1800 ))
while true; do
  NOT_SYNCED="$(kubectl get applications.argoproj.io -n "${ARGOCD_NS}" -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = []
# EXCLUDED_APPS: found real-machine, this attempt (this task round, after
# merging main): '\${NAME}-vigil-controller' fails Sync outright with
# 'Service ... must be no more than 63 characters' - the chart's own
# fixed Service name suffix combined with this cell's own name exceeds
# the Kubernetes DNS-label limit. Confirmed unrelated to sharedfs: (1)
# gitops/addons/vigil-controller/addon.yaml did not exist at this
# branch's own merge-base at all - introduced into main by a sibling PR
# (#103) after this branch started, pulled in only by this branch's own
# merge of main for an unrelated README conflict; (2) vigil-controller's
# entire function is removing capacity-pool's own pool.startupTaints,
# and this PR's own fixture (gitops/cells/dp-18-sharedfs-r1/
# capacity-pool/cpu.yaml) sets no startupTaints at all, so nothing this
# test exercises depends on vigil-controller doing anything. Excluding
# it from this convergence wait narrows what this one verify script
# proves (it does not also prove vigil-controller is healthy), not what
# the four required checks below need - this is not a fix to
# vigil-controller's own bug, tracked as issue #112: remove this
# exclusion once that issue closes.
EXCLUDED_APPS = {'${NAME}-vigil-controller'}
for a in d.get('items', []):
    name = a['metadata']['name']
    if name in EXCLUDED_APPS:
        continue
    sync = a.get('status', {}).get('sync', {}).get('status', 'Unknown')
    health = a.get('status', {}).get('health', {}).get('status', 'Unknown')
    if sync != 'Synced' or health not in ('Healthy', 'Unknown'):
        bad.append(f'{name}: sync={sync} health={health}')
print(chr(10).join(bad))
")"
  if [[ -z "${NOT_SYNCED}" ]]; then
    log "every checked Application Synced (and Healthy where they report health) - vigil-controller excluded, see EXCLUDED_APPS"
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

# A review round raised a real gap in the convergence loop above:
# Synced/Healthy alone reflects whether Argo CD applied an Application's
# regular objects, not whether templates/seed.yaml's own PostSync hook Job
# (which creates the `checkpoints`/`datasets` top-level directories the
# FilesystemShare objects below need to already exist) has itself
# finished - status.sync.status is a continuous diff against desired
# state, not gated on a hook phase. A first candidate gate
# (operationState.phase == Succeeded on the whole Application) was tried
# and reverted: it is a condition on every Application this script waits
# on, including ones with no hook at all, and no real-machine attempt had
# confirmed it does not also hold a genuinely converged Application for
# no reason. This gate instead targets the one resource that actually
# matters: sharedfs-shares' own PostSync hook Job by name, read from the
# owning Application's own `status.operationState.syncResult.resources`
# entry for it - the one place Argo CD's own documented resource-result
# shape (ResourceResult: group/version/kind/namespace/name/status/
# message/hookPhase/hookType) should keep a hook's own outcome even
# after the hook-delete-policy's own `HookSucceeded` deletes the Job
# object itself. Not yet confirmed on real hardware when this was
# written: the diagnostic dump below logs the actual field once, before
# this gate's own assertion runs at all, specifically so a wrong
# assumption about this field's shape shows up as a clear "not found" in
# the log rather than a silent false pass.
SHAREDFS_SHARES_APP="${NAME}-sharedfs-shares"
SEED_JOB_DEADLINE=$(( $(date +%s) + 300 ))
SEED_JOB_DIAGNOSTIC_LOGGED=0
log "waiting for ${SHAREDFS_SHARES_APP}'s own PostSync seed Job (sharedfs-seed-top-level-dirs) to report hookPhase Succeeded"
while true; do
  APP_JSON="$(kubectl get application "${SHAREDFS_SHARES_APP}" -n "${ARGOCD_NS}" -o json)"
  if [[ "${SEED_JOB_DIAGNOSTIC_LOGGED}" == "0" ]]; then
    log "diagnostic (once, before this gate's own assertion): ${SHAREDFS_SHARES_APP}'s own status.operationState.syncResult.resources"
    echo "${APP_JSON}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
resources = d.get('status', {}).get('operationState', {}).get('syncResult', {}).get('resources', [])
print(json.dumps(resources, indent=2))
" >&2
    SEED_JOB_DIAGNOSTIC_LOGGED=1
  fi
  SEED_HOOK_PHASE="$(echo "${APP_JSON}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
resources = d.get('status', {}).get('operationState', {}).get('syncResult', {}).get('resources', [])
for r in resources:
    if r.get('kind') == 'Job' and r.get('name') == 'sharedfs-seed-top-level-dirs':
        print(r.get('hookPhase', ''))
        break
")"
  if [[ "${SEED_HOOK_PHASE}" == "Succeeded" ]]; then
    log "sharedfs-seed-top-level-dirs reported hookPhase Succeeded"
    break
  fi
  if [[ "$(date +%s)" -ge "${SEED_JOB_DEADLINE}" ]]; then
    log "FAIL: sharedfs-seed-top-level-dirs did not reach hookPhase Succeeded within 5 minutes (last seen: '${SEED_HOOK_PHASE}')"
    kubectl get job sharedfs-seed-top-level-dirs -n fs-admin -o yaml >&2 || log "(Job object itself already gone - expected if it succeeded and HookSucceeded deleted it, or if it never ran at all)"
    kubectl describe job sharedfs-seed-top-level-dirs -n fs-admin >&2 || true
    kubectl get events -n fs-admin --field-selector involvedObject.name=sharedfs-seed-top-level-dirs >&2 || true
    exit 1
  fi
  sleep 10
done
#
# An earlier version of this comment claimed sharedfs's own controller
# sets Ready only once it can confirm the seed Job's work is done; that
# claim is not supported by the FilesystemShare CRD (its own conditions
# are only `Ready`, with `Resolved` as attempt 9's own observed reason -
# nothing in the CRD ties it to a specific namespace's directory, which
# is FilesystemShareDirectory's own `Prepared` condition instead) and is
# retracted. The Ready wait below still has independent value (it also
# waits for sharedfs's own controller to have reconciled the `checkpoints`/
# `datasets` definitions themselves, not only the hook), just not the
# ordering guarantee this comment used to claim for it.
#
# Found by this real-machine attempt (round 4, 2026-11-27): even after the
# Argo CD loop above reports every Application (including `sharedfs`, which
# owns these two CRDs) Synced and Healthy, the very next kubectl call here
# failed outright with "error: the server doesn't have a resource type
# \"fss\"" - not a timeout, an immediate resolution failure. Argo CD's own
# Synced/Healthy status reflects that the CRD's own create/apply call
# returned success, not that the CustomResourceDefinition has actually
# finished establishing (status.conditions NamesAccepted/Established) and
# propagated to every kube-apiserver behind the control plane's own load
# balancer, nor that this process's own kubectl discovery cache (shared
# across every kubectl call in this script via the same $HOME) has already
# picked that up - a real, if short, race the Argo CD loop's own two
# conditions do not cover. kubectl wait --for=condition=Established on the
# CRD objects themselves blocks on the one condition that is actually true
# right when this is safe; the short retry loop after it is a second,
# independent guard against the discovery-cache half of the race (a CRD
# reporting Established on the apiserver this call happens to hit does not
# guarantee a client-side cache already populated from a different
# apiserver has invalidated itself yet).
log "waiting for the FilesystemShare/FilesystemShareDirectory CRDs to report Established"
kubectl wait --for=condition=Established \
  crd/filesystemshares.sharedfs.io crd/filesystemsharedirectories.sharedfs.io --timeout=120s
DEADLINE=$(( $(date +%s) + 60 ))
while ! kubectl get filesystemshares.sharedfs.io >/dev/null 2>&1; do
  if [[ "$(date +%s)" -ge "${DEADLINE}" ]]; then
    log "FAIL: kubectl still cannot resolve the fss (FilesystemShare) resource type 60s after the CRD reported Established"
    kubectl get crd filesystemshares.sharedfs.io -o yaml >&2 || true
    exit 1
  fi
  sleep 5
done
log "waiting for FilesystemShare objects to report Ready"
kubectl wait --for=condition=Ready filesystemshares.sharedfs.io/checkpoints filesystemshares.sharedfs.io/datasets --timeout=300s

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
[[ "${PHASE}" != "Bound" ]] && log "CHECK 2b PASS (part 1): ungranted namespace's claim stayed ${PHASE:-Pending}, not Bound" || { log "CHECK 2b FAIL: ungranted namespace's claim bound"; exit 1; }
# A review round asked for more than "never bound" here: a claim can also
# stay Pending for reasons unrelated to the grant at all (sharedfs's own
# controller not running, a transient AWS throttle). sharedfs's own
# controller reports the actual reason as a PersistentVolumeClaim event
# with Reason NotGranted (confirmed by attempt 9's own log: "FilesystemShare
# checkpoints grants namespace ungranted no ReadWrite access") - asserting
# the Reason, not the full message text, so an upstream wording change
# does not break this on its own.
grep -q "NotGranted" "${RESULTS_DIR}/check2b-ungranted-pvc-events.log" && log "CHECK 2b PASS (part 2): sharedfs's own controller reported NotGranted for this claim" || { log "CHECK 2b FAIL: claim stayed unbound, but no NotGranted event was reported - the reason is not confirmed"; exit 1; }

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
# Not run_test_pod (uid 1000/gid 1000 fixed): templates/seed.yaml
# (#18's own AI-review fix round) creates `datasets` as root:root 0755,
# not group-writable, since it carries no `provision` (and so no
# provision.gid/mode) at all - only root can write directly under it.
# fs-admin's own Pod Security is baseline, not restricted (the same
# reason templates/seed.yaml itself runs as uid 0), so this one pod can
# run as uid 0 too, matching the actual permissions the directory it
# writes to was created with.
kubectl run seed -n fs-admin --image="${IMAGE}" --restart=Never \
  --overrides='{
    "spec": {
      "securityContext": {"runAsNonRoot": false, "runAsUser": 0, "seccompProfile": {"type": "RuntimeDefault"}},
      "containers": [{"name": "seed", "image": "'"${IMAGE}"'",
        "command": ["sh", "-c", "echo shared-dataset-content > /mnt/data.txt"],
        "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
        "volumeMounts": [{"name": "v", "mountPath": "/mnt"}]}],
      "volumes": [{"name": "v", "persistentVolumeClaim": {"claimName": "datasets-seed"}}],
      "restartPolicy": "Never"
    }
  }'
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
  # "Read-only file system" specifically, not also "Permission denied":
  # templates/seed.yaml creates datasets as root:root 0755 (no `provision`,
  # so no group-write bit), so a non-root team pod's write would get
  # "Permission denied" from the directory's own raw unix mode alone,
  # whether or not the datasets-ro mount itself actually enforces
  # read-only access at all - that reading would make this assertion
  # pass even if sharedfs's own controller had a real bug and granted
  # read-write access by mistake. "Read-only file system" (EROFS) is the
  # message a genuinely read-only mount gives, which only a correctly
  # enforced grant produces.
  grep -q "Read-only file system" "${RESULTS_DIR}/check3-${team}-dataset-read.log" || { log "CHECK 3 FAIL: ${team}'s write attempt against datasets-ro did not fail with Read-only file system (a directory-permission denial would look the same without proving the mount itself is read-only)"; exit 1; }
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

log "check 5: a team claiming datasets-rw (not datasets-ro) never gets write access to the shared dataset - the datasets FilesystemShare's own grants list a ReadWrite grant for fs-admin specifically and a ReadOnly grant for any team namespace, never a ReadWrite grant for a team, so sharedfs's own controller has no matching grant to provision a team's datasets-rw claim against. The object is still created (RBAC grants create persistentvolumeclaims generically, same as check 1/2) but never Bound, the same shape as check 2b's ungranted-namespace case, not an admission-time rejection"
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
log "CHECK 5 PASS (part 1): team-a's datasets-rw claim stayed ${PHASE:-Pending}, not Bound"
# Same reasoning as check 2b's own second assertion: confirmed by attempt
# 9's own log ("FilesystemShare datasets grants namespace team-a no
# ReadWrite access"); asserting the Reason, not the full message.
grep -q "NotGranted" "${RESULTS_DIR}/check5-datasets-rw-pvc-events.log" && log "CHECK 5 PASS (part 2): sharedfs's own controller reported NotGranted for this claim" || { log "CHECK 5 FAIL: claim stayed unbound, but no NotGranted event was reported - the reason is not confirmed"; exit 1; }

log "ALL CHECKS PASS"
kubectl get filesystemshares.sharedfs.io -A | tee "${RESULTS_DIR}/final-fss-status.log"
kubectl get fsd -A | tee "${RESULTS_DIR}/final-fsd-status.log"
