#!/usr/bin/env bash
# Orchestrates the miles-on-Trainium real-machine smoke test on the EC2 runner.
# Builds a fresh cell with infra/foundation, bootstraps gitops at --revision
# exp/miles-trainium (so Argo CD picks up gitops/cells/${NAME}/capacity-pool/
# trn.yaml, a trn2.3xlarge light-tier pool copied from dp-a19-trn-r3), applies
# experiments/miles-trainium-smoke/{job.yaml + a ConfigMap built from
# train_grpo_smoke.py}, waits for the Job, captures logs, and ALWAYS tears
# down via terraform destroy (trap on EXIT) followed by an independent
# tag-based leftover sweep, mirroring gitops/tests/1.e2e.sh's own sweep.
set -euo pipefail

NAME="${NAME:?set NAME, the cell name}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
STATE_BUCKET="${STATE_BUCKET:?set STATE_BUCKET}"
STATE_REGION="${STATE_REGION:?set STATE_REGION}"
ADMIN_PRINCIPAL_ARN="${ADMIN_PRINCIPAL_ARN:?set ADMIN_PRINCIPAL_ARN}"
MY_CIDR="${MY_CIDR:?set MY_CIDR}"
export AWS_PROFILE="${AWS_PROFILE:-default}"

REPO_ROOT="$(pwd)"
RUN_LOG_DIR="${REPO_ROOT}/../evidence-${NAME}"
mkdir -p "${RUN_LOG_DIR}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

VPC_ID=""
TEARDOWN_DONE=0

teardown() {
  if [[ "${TEARDOWN_DONE}" == "1" ]]; then return; fi
  TEARDOWN_DONE=1
  log "=== TEARDOWN start ==="
  kubectl delete job miles-grpo-smoke -n distai-smoke --ignore-not-found --wait=true --timeout=120s 2>&1 | tee -a "${RUN_LOG_DIR}/teardown.log" || true
  kubectl delete configmap miles-grpo-smoke-script -n distai-smoke --ignore-not-found 2>&1 | tee -a "${RUN_LOG_DIR}/teardown.log" || true
  cd "${REPO_ROOT}/infra/foundation"
  terraform destroy -auto-approve 2>&1 | tee -a "${RUN_LOG_DIR}/terraform-destroy.log" || log "WARN: terraform destroy exited non-zero, continuing to the read-only sweep anyway"
  log "=== independent read-only leftover sweep (${NAME}) ==="
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

log "=== PHASE 1: terraform apply (infra/foundation), cell=${NAME} region=${AWS_REGION} ==="
cd "${REPO_ROOT}/infra/foundation"
export TF_VAR_name="${NAME}"
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_endpoint_public_access_cidrs="[\"${MY_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_PRINCIPAL_ARN}\"]"
terraform init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true" | tee "${RUN_LOG_DIR}/terraform-init.log"
terraform apply -auto-approve | tee "${RUN_LOG_DIR}/terraform-apply.log"
VPC_ID="$(terraform output -raw vpc_id)"
log "vpc_id=${VPC_ID}"

log "=== PHASE 2: kubeconfig + gitops bootstrap (revision exp/miles-trainium) ==="
aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
kubectl get nodes
"${REPO_ROOT}/gitops/bootstrap/bootstrap.sh" --tf-outputs <(terraform output -json) --revision exp/miles-trainium

log "=== PHASE 3: wait for Argo CD to render the trn NodePool/EC2NodeClass ==="
for i in $(seq 1 60); do
  if kubectl get nodepool trn >/dev/null 2>&1 && kubectl get ec2nodeclass trn >/dev/null 2>&1; then
    log "NodePool/EC2NodeClass 'trn' present after ${i}0s"
    break
  fi
  sleep 10
done
kubectl get nodepool,ec2nodeclass | tee "${RUN_LOG_DIR}/nodepool.log"
kubectl get pods -n kube-system -l app.kubernetes.io/name=neuron-helm-chart -o wide 2>&1 | tee -a "${RUN_LOG_DIR}/nodepool.log" || true

log "=== PHASE 4: apply the Job (ConfigMap generated from train_grpo_smoke.py) ==="
kubectl create configmap miles-grpo-smoke-script -n distai-smoke \
  --from-file=train_grpo_smoke.py="${REPO_ROOT}/experiments/miles-trainium-smoke/train_grpo_smoke.py" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/experiments/miles-trainium-smoke/job.yaml"

log "=== PHASE 5: wait for the pod to schedule on a real trn2.3xlarge node ==="
POD=""
for i in $(seq 1 90); do
  POD="$(kubectl get pods -n distai-smoke -l app=miles-grpo-smoke -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
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

log "=== PHASE 7: stream logs until the Job finishes (deadline ~45min) ==="
kubectl logs -f "${POD}" -n distai-smoke --timestamps 2>&1 | tee "${RUN_LOG_DIR}/job.log" &
LOGS_PID=$!
DEADLINE=$((SECONDS + 2700))
STATUS="unknown"
while (( SECONDS < DEADLINE )); do
  STATUS="$(kubectl get job miles-grpo-smoke -n distai-smoke -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || true)"
  if [[ "${STATUS}" == "Complete" || "${STATUS}" == "Failed" ]]; then
    break
  fi
  sleep 15
done
sleep 5
kill "${LOGS_PID}" 2>/dev/null || true
wait "${LOGS_PID}" 2>/dev/null || true
log "=== JOB STATUS: ${STATUS} ==="
kubectl get job miles-grpo-smoke -n distai-smoke -o yaml | tee "${RUN_LOG_DIR}/job-final.yaml" >/dev/null
echo "job_status=${STATUS}" > "${RUN_LOG_DIR}/RESULT.txt"
grep -E "STEP_SUMMARY|DONE|FATAL|Error|Traceback" "${RUN_LOG_DIR}/job.log" | tee -a "${RUN_LOG_DIR}/RESULT.txt" || true

log "=== PHASE 7 done; teardown runs automatically on exit ==="
