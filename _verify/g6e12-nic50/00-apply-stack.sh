set -euo pipefail
echo "=== issue #50 real-hardware check: g6e.12xlarge, C=1 E=1 generated pool.networkInterfaces ==="
date -u +%FT%TZ

: "${AWS_REGION:?}"; : "${NAME:?}"; : "${STATE_BUCKET:?}"; : "${STATE_REGION:?}"
: "${ADMIN_PRINCIPAL_ARN:?}"; : "${MY_CIDR:?}"; export AWS_PROFILE="${AWS_PROFILE:-default}"

TF="terraform -chdir=infra/foundation"
STATE_KEY="distai-platform/${AWS_REGION}/${NAME}/foundation"
TFVARS="$(pwd)/e2e.tfvars.json"
export TF_DATA_DIR="$(pwd)/.terraform-${NAME}"
export KUBECONFIG="$(pwd)/kubeconfig-${NAME}"

cat >"${TFVARS}" <<JSON
{
  "name": "${NAME}",
  "region": "${AWS_REGION}",
  "endpoint_public_access_cidrs": ["${MY_CIDR}"],
  "admin_principal_arns": ["${ADMIN_PRINCIPAL_ARN}"],
  "argocd": null,
  "tags": {"distai-platform-issue50-verify": "${NAME}"}
}
JSON

echo "--- terraform init ---"
$TF init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"

cleanup() {
  rc=$?
  set +e
  echo "--- cleanup (rc so far: ${rc}) ---"
  helm uninstall g6e12-verify-pool 2>/dev/null || true
  kubectl delete pod efa-check --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete nodepool g6e12-verify --ignore-not-found --wait=true --timeout=300s 2>/dev/null || true
  helm uninstall efa-device-plugin-verify -n kube-system 2>/dev/null || true
  helm uninstall kueue -n kube-system 2>/dev/null || true
  helm uninstall karpenter -n kube-system 2>/dev/null || true
  helm uninstall karpenter-crd -n kube-system 2>/dev/null || true
  echo "--- terraform destroy ---"
  $TF destroy -auto-approve -input=false -var-file="${TFVARS}"
  drc=$?
  echo "terraform destroy exit=${drc}"
  echo "--- leftover sweep (independent, read-only) ---"
  aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
  aws ec2 describe-vpcs --region "${AWS_REGION}" --filters "Name=tag:Name,Values=*${NAME}*" --query 'Vpcs[].VpcId' --output text
  aws ec2 describe-launch-templates --region "${AWS_REGION}" --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}" --query 'LaunchTemplates[].LaunchTemplateId' --output text
  date -u +%FT%TZ
  echo "=== FINISHED outer_rc=${rc} destroy_rc=${drc} ==="
  exit "${rc}"
}
trap cleanup EXIT

echo "--- terraform apply ---"
$TF apply -auto-approve -input=false -var-file="${TFVARS}"

CLUSTER="$($TF output -raw cluster_name)"
NODE_ROLE="$($TF output -raw karpenter_node_role_name)"
echo "cluster=${CLUSTER} node_role=${NODE_ROLE}"

aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}" --kubeconfig "${KUBECONFIG}"
kubectl get --raw /readyz
echo "PASS: kubectl reaches the cluster"

echo "--- install karpenter-crd / karpenter (stand-in helm install, no Argo CD for this ad hoc check) ---"
helm install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version 1.15.2 -n kube-system --wait --timeout 5m
helm install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.2 -n kube-system --skip-crds --wait --timeout 5m \
  --set serviceAccount.name=karpenter \
  --set "controller.env[0].name=AWS_REGION" \
  --set "controller.env[0].value=${AWS_REGION}" \
  --set settings.clusterName="${CLUSTER}" \
  --set settings.interruptionQueue="$($TF output -raw karpenter_interruption_queue_name)" \
  --set "tolerations[0].key=CriticalAddonsOnly" \
  --set "tolerations[0].operator=Exists"
kubectl -n kube-system rollout status deploy/karpenter --timeout=180s
echo "PASS: karpenter controller Ready"

echo "--- install the EFA device plugin (aws-efa-k8s-device-plugin, pinned as in addons/accel-efa-device-plugin-nvidia) ---"
helm install efa-device-plugin-verify aws-efa-k8s-device-plugin \
  --repo https://aws.github.io/eks-charts --version v0.5.35 -n kube-system --wait --timeout 5m \
  --set 'image.tag=v0.5.22-eksbuild.9@sha256:a392d84ff82b23580fd92d0a6c770136c56d4a6ee979a47d1bf4e379a7171647' \
  --set-string 'nodeSelector.distai\.dev/nvidia-gpu-method=device-plugin' \
  --set-string 'nodeSelector.distai\.dev/efa-attached=true' \
  --set securityContext.privileged=false \
  --set securityContext.allowPrivilegeEscalation=false \
  --set securityContext.runAsNonRoot=false \
  --set securityContext.runAsUser=0 \
  --set 'securityContext.capabilities.drop[0]=ALL'
echo "PASS: efa-device-plugin-verify installed (DaemonSet; no node matches its selector yet, Pod stays Pending until the g6e.12xlarge node joins)"

echo "--- install kueue (same values as gitops/addons/kueue/addon.yaml: CriticalAddonsOnly toleration + anti-affinity away from Karpenter nodes; capacity-pool's own release needs its ResourceFlavor admission webhook SERVING, not only the CRD) ---"
helm install kueue oci://registry.k8s.io/kueue/charts/kueue --version 0.20.6 -n kube-system --wait --timeout 5m \
  --set "controllerManager.tolerations[0].key=CriticalAddonsOnly" \
  --set "controllerManager.tolerations[0].operator=Exists" \
  --set "controllerManager.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=karpenter.sh/nodepool" \
  --set "controllerManager.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=DoesNotExist"
kubectl -n kube-system rollout status deploy/kueue-controller-manager --timeout=180s
echo "PASS: kueue controller Ready (Deployment rollout complete)"
echo "--- waiting up to 60s for the ResourceFlavor validating webhook to actually have serving endpoints (the controller Deployment going Ready does not guarantee the webhook Service's endpoints are populated yet -- the exact gap that failed the previous attempt) ---"
deadline=$((SECONDS + 60))
EP=""
while [ "${SECONDS}" -lt "${deadline}" ]; do
  EP="$(kubectl get endpoints kueue-webhook-service -n kube-system -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  [ -n "${EP}" ] && break
  sleep 5
done
[ -n "${EP}" ] && echo "PASS: kueue-webhook-service has a serving endpoint (${EP})" \
  || { echo "FAIL: kueue-webhook-service has no endpoints after 60s"; kubectl get endpoints -n kube-system; exit 1; }

echo "--- render this PR's own generated g6e.12xlarge pool.networkInterfaces into capacity-pool values ---"
cat >g6e12-verify-values.yaml <<YAML
clusterName: "${CLUSTER}"
nodeRole: "${NODE_ROLE}"
pool:
  name: g6e12-verify
  capacityType: flex
  requirements:
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64"]
    - key: node.kubernetes.io/instance-type
      operator: In
      values: ["g6e.12xlarge"]
  limits:
    cpu: "64"
  networkInterfaces:
    - networkCardIndex: 0
      deviceIndex: 0
      interfaceType: interface
    - networkCardIndex: 0
      deviceIndex: 1
      interfaceType: efa-only
accelerator:
  resourceName: nvidia.com/gpu
  methodLabel:
    key: distai.dev/nvidia-gpu-method
    value: device-plugin
YAML
diff <(tail -n +3 gitops/charts/capacity-pool/tools/fixtures/g6e.12xlarge.networkInterfaces.yaml) \
     <(sed -n '/networkInterfaces:/,/^accelerator:/p' g6e12-verify-values.yaml | sed '1d;$d' | sed 's/^    //') \
  && echo "PASS: values file's networkInterfaces is exactly this PR's committed g6e.12xlarge fixture (byte-level, modulo indent)" \
  || echo "WARN: diff above (cosmetic indent only expected, verify by eye)"

helm install g6e12-verify-pool "$(pwd)/gitops/charts/capacity-pool" -f g6e12-verify-values.yaml --wait=false
echo "PASS: capacity-pool release installed (pool.name=g6e12-verify, capacityType=flex, instance-type=g6e.12xlarge)"

kubectl get nodepool g6e12-verify -o yaml
kubectl get ec2nodeclass g6e12-verify -o yaml

cat >efa-check-pod.yaml <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: efa-check
spec:
  nodeSelector:
    karpenter.sh/nodepool: g6e12-verify
  tolerations:
    - operator: Exists
  containers:
    - name: efa-check
      image: public.ecr.aws/docker/library/busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
      command: ["sleep", "3600"]
      resources:
        requests: {cpu: "100m", memory: "64Mi"}
      volumeMounts:
        - {name: hostsys, mountPath: /host-sys, readOnly: true}
  volumes:
    - name: hostsys
      hostPath: {path: /sys}
YAML
kubectl apply -f efa-check-pod.yaml
echo "PASS: efa-check Pod created (nodeSelector karpenter.sh/nodepool=g6e12-verify; this triggers Karpenter to launch the real g6e.12xlarge spot node)"

echo "--- waiting up to 10 minutes for the real g6e.12xlarge node (GPU-time budget starts counting now) ---"
deadline=$((SECONDS + 600))
NODE=""
while [ "${SECONDS}" -lt "${deadline}" ]; do
  NODE="$(kubectl get nodes -l karpenter.sh/nodepool=g6e12-verify -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${NODE}" ] && kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True && break
  sleep 15
done
[ -n "${NODE}" ] || { echo "FAIL: no Ready node joined within 10 minutes"; exit 1; }
echo "PASS: real node ${NODE} is Ready"
kubectl get node "${NODE}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}'
INSTTYPE="$(kubectl get node "${NODE}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')"
[ "${INSTTYPE}" = "g6e.12xlarge" ] && echo "PASS: node is g6e.12xlarge as requested" || echo "FAIL: node instance-type is ${INSTTYPE}, expected g6e.12xlarge"
kubectl get node "${NODE}" -o jsonpath='{.metadata.labels.distai\.dev/efa-attached}{"\n"}' | grep -q true \
  && echo "PASS: node template label distai.dev/efa-attached=true carried onto the real node" \
  || echo "FAIL: distai.dev/efa-attached label missing on the real node"

echo "--- waiting up to 5 minutes for the EFA device plugin DaemonSet to advertise the extended resource on this node ---"
deadline=$((SECONDS + 300))
EFA_ALLOC=""
while [ "${SECONDS}" -lt "${deadline}" ]; do
  EFA_ALLOC="$(kubectl get node "${NODE}" -o jsonpath='{.status.allocatable.vpc\.amazonaws\.com/efa}' 2>/dev/null || true)"
  [ -n "${EFA_ALLOC}" ] && [ "${EFA_ALLOC}" != "0" ] && break
  sleep 10
done
echo "kubectl allocatable vpc.amazonaws.com/efa = ${EFA_ALLOC:-<empty>}"
[ "${EFA_ALLOC}" = "1" ] && echo "PASS: allocatable.vpc.amazonaws.com/efa == 1 (matches g6e.12xlarge's EfaInfo.MaximumEfaInterfaces, this PR's generated layout)" \
  || echo "FAIL: allocatable.vpc.amazonaws.com/efa is ${EFA_ALLOC:-<empty>}, expected 1"

echo "--- waiting for the efa-check Pod to run on the real node, then reading /sys directly on it ---"
kubectl wait --for=condition=Ready pod/efa-check --timeout=180s || { kubectl describe pod efa-check; exit 1; }
ACTUAL_NODE="$(kubectl get pod efa-check -o jsonpath='{.spec.nodeName}')"
[ "${ACTUAL_NODE}" = "${NODE}" ] || echo "WARN: efa-check pod landed on ${ACTUAL_NODE}, expected ${NODE}"

echo "fi/RDMA devices (expect 1, the one EFA-capable card on g6e.12xlarge):"
IB_COUNT="$(kubectl exec efa-check -- sh -c 'ls /host-sys/class/infiniband 2>/dev/null | wc -l')"
echo "ls /sys/class/infiniband | wc -l = ${IB_COUNT}"
[ "${IB_COUNT}" = "1" ] && echo "PASS: 1 real EFA (RDMA) device visible in the guest OS" \
  || echo "FAIL: ${IB_COUNT} RDMA devices visible, expected 1"

echo "network (ENA) interfaces other than loopback (expect exactly 1 -- only the primary card's ENA function, no stray secondary ENA interface):"
NET_COUNT="$(kubectl exec efa-check -- sh -c "ls /host-sys/class/net | grep -v '^lo$' | wc -l")"
kubectl exec efa-check -- sh -c "ls /host-sys/class/net"
echo "non-loopback /sys/class/net entries = ${NET_COUNT}"
[ "${NET_COUNT}" = "1" ] && echo "PASS: exactly 1 ENA network interface (the primary card's eth0); no stray secondary ENA device" \
  || echo "FAIL: ${NET_COUNT} non-loopback network interfaces, expected 1"

echo "=== all substantive checks printed above; cleanup runs next via EXIT trap ==="
