#!/usr/bin/env bash
# This investigation's own end-to-end verification -- NOT the example's "copy-paste" procedure
# in README.md, which assumes a cell already exists. This script builds a disposable cell from
# scratch (infra/foundation + the platform's own gitops bootstrap) so the example can be
# verified without touching a shared cell, then always tears the cell down (trap on EXIT) with
# an independent tag-based leftover sweep.
#
# Needs a gitops/cells/${NAME}/capacity-pool/*.yaml with a trn2.3xlarge light-tier pool to exist
# on whatever revision GITOPS_REVISION names (gitops/README.md "Adding a cell" -- this example
# does not add one of its own, since a new permanent cell fixture is a separate decision from
# this one example). Point NAME/GITOPS_REVISION at an existing fixture, or add your own cell
# directory first.
set -euo pipefail

NAME="${NAME:?set NAME, the cell name}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
STATE_BUCKET="${STATE_BUCKET:?set STATE_BUCKET}"
STATE_REGION="${STATE_REGION:?set STATE_REGION}"
ADMIN_PRINCIPAL_ARN="${ADMIN_PRINCIPAL_ARN:?set ADMIN_PRINCIPAL_ARN}"
MY_CIDR="${MY_CIDR:?set MY_CIDR}"
ARGOCD_IDC_INSTANCE_ARN="${ARGOCD_IDC_INSTANCE_ARN:?set ARGOCD_IDC_INSTANCE_ARN}"
ARGOCD_IDC_IDENTITY_STORE_ID="${ARGOCD_IDC_IDENTITY_STORE_ID:?set ARGOCD_IDC_IDENTITY_STORE_ID}"
ARGOCD_IDC_REGION="${ARGOCD_IDC_REGION:?set ARGOCD_IDC_REGION}"
GITOPS_REVISION="${GITOPS_REVISION:-stable}"
export AWS_PROFILE="${AWS_PROFILE:-default}"

REPO_ROOT="$(pwd)"
EXDIR="${REPO_ROOT}/examples/training/miles-trainium"
RUN_LOG_DIR="${REPO_ROOT}/../evidence-${NAME}"
mkdir -p "${RUN_LOG_DIR}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

VPC_ID=""
IDC_GROUP_ID=""
TEARDOWN_DONE=0

teardown() {
  if [[ "${TEARDOWN_DONE}" == "1" ]]; then return; fi
  TEARDOWN_DONE=1
  log "=== TEARDOWN start ==="
  kubectl delete job miles-trainium-grpo -n distai-smoke --ignore-not-found --wait=true --timeout=180s 2>&1 | tee -a "${RUN_LOG_DIR}/teardown.log" || true
  kubectl delete configmap miles-trainium-script -n distai-smoke --ignore-not-found 2>&1 | tee -a "${RUN_LOG_DIR}/teardown.log" || true
  kubectl delete secret ecr-public-pull -n distai-smoke --ignore-not-found 2>&1 | tee -a "${RUN_LOG_DIR}/teardown.log" || true
  cd "${REPO_ROOT}/infra/foundation"
  terraform destroy -auto-approve 2>&1 | tee -a "${RUN_LOG_DIR}/terraform-destroy.log" || log "WARN: terraform destroy exited non-zero, continuing to the read-only sweep anyway"
  if [[ -n "${IDC_GROUP_ID}" ]]; then
    if aws identitystore delete-group --identity-store-id "${ARGOCD_IDC_IDENTITY_STORE_ID}" \
      --region "${ARGOCD_IDC_REGION}" --group-id "${IDC_GROUP_ID}" >>"${RUN_LOG_DIR}/teardown.log" 2>&1; then
      log "deleted temporary Identity Center group ${IDC_GROUP_ID}"
    else
      log "WARN: could not delete temporary Identity Center group ${IDC_GROUP_ID}, remove it by hand"
    fi
  fi
  log "=== independent read-only leftover sweep (${NAME}) ==="
  # Known limitation: every query below swallows its own errors (2>/dev/null || true), so an API
  # error or an unexpectedly-missing tag prints the same "<none>" a genuinely clean sweep would.
  # "Independently re-verified torn down clean" in this PR's own Test Results rests on this sweep
  # plus terraform destroy's own reported resource count agreeing, not on this sweep alone.
  for kind in instance eni nat volume launch-template; do
    out=""
    case "${kind}" in
      instance)
        out="$(aws ec2 describe-instances --region "${AWS_REGION}" \
          --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" "Name=tag:karpenter.sh/discovery,Values=${NAME}" \
          "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)" ;;
      launch-template)
        out="$(aws ec2 describe-launch-templates --region "${AWS_REGION}" \
          --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" \
          --query 'LaunchTemplates[].LaunchTemplateId' --output text 2>/dev/null || true)" ;;
      eni)
        if [[ -n "${VPC_ID}" ]]; then
          out="$(aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
            --filters "Name=vpc-id,Values=${VPC_ID}" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)"
        fi ;;
      nat)
        if [[ -n "${VPC_ID}" ]]; then
          out="$(aws ec2 describe-nat-gateways --region "${AWS_REGION}" \
            --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=pending,available,deleting" \
            --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)"
        fi ;;
      volume)
        out="$(aws ec2 describe-volumes --region "${AWS_REGION}" \
          --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" \
          --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)" ;;
    esac
    out="$(printf '%s' "${out}" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' || true)"
    echo "sweep ${kind}: ${out:-<none>}" | tee -a "${RUN_LOG_DIR}/sweep.log"
  done
  if [[ -n "${VPC_ID}" ]]; then
    vpc_out="$(aws ec2 describe-vpcs --region "${AWS_REGION}" --vpc-ids "${VPC_ID}" --query 'Vpcs[].VpcId' --output text 2>&1 || true)"
    echo "sweep vpc ${VPC_ID}: ${vpc_out}" | tee -a "${RUN_LOG_DIR}/sweep.log"
  fi
  log "=== TEARDOWN done, see ${RUN_LOG_DIR}/sweep.log ==="
}
trap teardown EXIT

log "=== PHASE 0: temporary Identity Center group for the Argo CD capability ==="
IDC_GROUP_ID="$(aws identitystore create-group --identity-store-id "${ARGOCD_IDC_IDENTITY_STORE_ID}" \
  --region "${ARGOCD_IDC_REGION}" --display-name "${NAME}" \
  --description "distai-platform miles-on-Trainium investigation (sglang-neuron rollout), deleted at the end of this run" \
  --query GroupId --output text)"
log "created temporary Identity Center group ${IDC_GROUP_ID} (${NAME})"

log "=== PHASE 1: terraform apply (infra/foundation), cell=${NAME} region=${AWS_REGION} ==="
cd "${REPO_ROOT}/infra/foundation"
export TF_VAR_name="${NAME}"
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_endpoint_public_access_cidrs="[\"${MY_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_PRINCIPAL_ARN}\"]"
export TF_VAR_argocd="{\"idc_instance_arn\":\"${ARGOCD_IDC_INSTANCE_ARN}\",\"idc_region\":\"${ARGOCD_IDC_REGION}\",\"role_mappings\":[{\"role\":\"ADMIN\",\"group_ids\":[\"${IDC_GROUP_ID}\"]}]}"
terraform init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true" | tee "${RUN_LOG_DIR}/terraform-init.log"
terraform apply -auto-approve | tee "${RUN_LOG_DIR}/terraform-apply.log"
VPC_ID="$(terraform output -raw vpc_id)"
log "vpc_id=${VPC_ID}"

log "=== PHASE 2: kubeconfig + gitops bootstrap (revision ${GITOPS_REVISION}) ==="
aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
kubectl get nodes
"${REPO_ROOT}/gitops/bootstrap/bootstrap.sh" --tf-outputs <(terraform output -json) --revision "${GITOPS_REVISION}"

log "=== PHASE 3: wait for Argo CD to render the trn NodePool/EC2NodeClass ==="
for i in $(seq 1 60); do
  if kubectl get nodepool trn >/dev/null 2>&1 && kubectl get ec2nodeclass trn >/dev/null 2>&1; then
    log "NodePool/EC2NodeClass 'trn' present after ${i}0s"
    break
  fi
  sleep 10
done
kubectl get nodepool,ec2nodeclass | tee "${RUN_LOG_DIR}/nodepool.log"

log "=== PHASE 4: apply the Job (authenticated ECR Public pull + ConfigMap from train_grpo.py) ==="
ECR_PUBLIC_PASSWORD="$(aws ecr-public get-login-password --region us-east-1)"
kubectl create secret docker-registry ecr-public-pull -n distai-smoke \
  --docker-server=public.ecr.aws --docker-username=AWS \
  --docker-password="${ECR_PUBLIC_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset ECR_PUBLIC_PASSWORD
kubectl create configmap miles-trainium-script -n distai-smoke \
  --from-file=train_grpo.py="${EXDIR}/train_grpo.py" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${EXDIR}/job.yaml"

log "=== PHASE 5: wait for the pod to schedule on a real trn2.3xlarge node ==="
POD=""
for i in $(seq 1 90); do
  POD="$(kubectl get pods -n distai-smoke -l app=miles-trainium-grpo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${POD}" ]]; then
    phase="$(kubectl get pod "${POD}" -n distai-smoke -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    node="$(kubectl get pod "${POD}" -n distai-smoke -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    log "pod=${POD} phase=${phase:-<none>} node=${node:-<none>} (${i}0s)"
    if [[ -n "${node}" ]]; then break; fi
  else
    log "pod not created yet (${i}0s)"
  fi
  sleep 10
done
[[ -n "${POD}" ]] || { log "FAIL: pod never created"; exit 1; }

log "=== PHASE 6: confirm the node is real trn2.3xlarge with the neuron device plugin ==="
NODE="$(kubectl get pod "${POD}" -n distai-smoke -o jsonpath='{.spec.nodeName}')"
kubectl get node "${NODE}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{.status.allocatable}' | tee "${RUN_LOG_DIR}/node.log"
echo >> "${RUN_LOG_DIR}/node.log"
aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=private-dns-name,Values=${NODE}" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle,State.Name]' --output text \
  | tee -a "${RUN_LOG_DIR}/node.log"

log "=== PHASE 7: stream logs until the Job finishes (deadline ~55min) ==="
# The real-machine attempt that produced this PR's own Test Results (README.md "What actually
# ran") lost every application log line this way, running this script's own predecessor: a
# single `kubectl logs -f` started while the container was still ContainerCreating hit its own
# client-side "context deadline exceeded" and exited for good BEFORE the container ever started,
# with nothing there to restart it -- the container went on to run and fail (exit code 2, visible
# only in `kubectl get events`/the Job's own status, never in that run's captured log) with zero
# stdout recorded. This loop relaunches `kubectl logs -f` any time it exits early, as long as the
# Job itself has not finished. Not re-verified against a real failure of this kind.
LOGS_PID=""
relaunch_logs() {
  if [[ -n "${LOGS_PID}" ]] && kill -0 "${LOGS_PID}" 2>/dev/null; then return; fi
  # Overwrite (>), not append (>>): kubectl logs -f dumps the container's FULL log from the
  # start every time it (re-)attaches, so appending across relaunches would duplicate it once
  # per relaunch; each relaunch's full dump fully supersedes the previous one.
  kubectl logs -f "${POD}" -n distai-smoke --timestamps >"${RUN_LOG_DIR}/job.log" 2>&1 &
  LOGS_PID=$!
}
relaunch_logs
DEADLINE=$((SECONDS + 3300))
STATUS="unknown"
LAST_PHASE=""
while (( SECONDS < DEADLINE )); do
  # .status.conditions[0].type is not reliable here: this script's own real-machine attempt 3
  # saw conditions[0]=FailureTarget with Failed only second, which this loop originally checked
  # for and therefore ran its full deadline instead of stopping. .status.succeeded/.status.failed
  # are the Job controller's own terminal counters and do not depend on condition ordering.
  SUCCEEDED="$(kubectl get job miles-trainium-grpo -n distai-smoke -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  FAILED_COUNT="$(kubectl get job miles-trainium-grpo -n distai-smoke -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  PHASE_NOW="$(kubectl get pod "${POD}" -n distai-smoke -o jsonpath='{.status.phase}{" "}{.status.containerStatuses[0].state}' 2>/dev/null || true)"
  if [[ "${PHASE_NOW}" != "${LAST_PHASE}" ]]; then
    log "pod phase/state: ${PHASE_NOW}"
    LAST_PHASE="${PHASE_NOW}"
  fi
  relaunch_logs
  if (( SECONDS % 120 < 15 )); then
    kubectl get events -n distai-smoke --field-selector involvedObject.name="${POD}" --sort-by='.lastTimestamp' 2>/dev/null \
      | tail -5 | tee -a "${RUN_LOG_DIR}/events.log" || true
  fi
  if [[ -n "${SUCCEEDED}" && "${SUCCEEDED}" -ge 1 ]]; then
    STATUS="Complete"
    break
  fi
  if [[ -n "${FAILED_COUNT}" && "${FAILED_COUNT}" -ge 1 ]]; then
    STATUS="Failed"
    break
  fi
  sleep 15
done
sleep 5
kill "${LOGS_PID}" 2>/dev/null || true
wait "${LOGS_PID}" 2>/dev/null || true
# Belt-and-suspenders: a plain (non-follow) `kubectl logs` after the Job finished, in case every
# `-f` attempt above still raced the container's own short lifetime.
kubectl logs "${POD}" -n distai-smoke --timestamps >"${RUN_LOG_DIR}/job.log" 2>&1 || true
log "=== JOB STATUS: ${STATUS} ==="
kubectl get events -n distai-smoke --field-selector involvedObject.name="${POD}" --sort-by='.lastTimestamp' 2>&1 | tee "${RUN_LOG_DIR}/events-final.log" || true
kubectl get job miles-trainium-grpo -n distai-smoke -o yaml | tee "${RUN_LOG_DIR}/job-final.yaml" >/dev/null
echo "job_status=${STATUS}" > "${RUN_LOG_DIR}/RESULT.txt"
grep -E "STEP_SUMMARY|DONE|FATAL|Error|Traceback" "${RUN_LOG_DIR}/job.log" | tee -a "${RUN_LOG_DIR}/RESULT.txt" || true

log "=== PHASE 7 done; teardown runs automatically on exit ==="
