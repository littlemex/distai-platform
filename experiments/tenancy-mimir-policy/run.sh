#!/usr/bin/env bash
# Real-machine experiment for littlemex/distai-platform Issue #22 / #41.
# Two questions, one disposable cluster:
#   A) Does Grafana Mimir separate team metrics by tenant, and is the tenant
#      mechanically derived (not team-chosen)?
#   B) Can Kyverno / Gatekeeper / Capsule replace the self-built pieces of
#      #22's tenancy self-service plan (namespace defaults, Pod Security,
#      NetworkPolicy defaults, Kueue LocalQueue/ResourceFlavor limits)?
#
# This script is run ONLY through runner/run.sh on the EC2 runner, never on
# the Mac. Individual kubectl/helm steps are allowed to fail without
# aborting the whole run (a denial IS the test result for several of them);
# `set -e` is deliberately not used. A trap guarantees terraform destroy and
# a read-only AWS sweep run exactly once, no matter how the middle of the
# script went, so nothing billable is left behind.
set -uo pipefail

: "${NAME:?set NAME to a cell name unused by any other cell}"
: "${AWS_REGION:?}"
: "${STATE_BUCKET:?}"
: "${STATE_REGION:?}"
: "${ADMIN_PRINCIPAL_ARN:?}"
: "${MY_CIDR:?}"
export AWS_PROFILE=default

ROOT="$(pwd)"
EVIDENCE_DIR="${ROOT}/experiments/tenancy-mimir-policy/evidence"
mkdir -p "${EVIDENCE_DIR}"

say() { echo; echo "===== $(date -u +%H:%M:%SZ) PHASE: $* ====="; }
capture() { # capture <file> <cmd...>
  local f="$1"; shift
  { "$@" ; } >"${EVIDENCE_DIR}/${f}" 2>&1
  echo "--- ${f} ---"; cat "${EVIDENCE_DIR}/${f}"
}
apply_capture() { # apply_capture <file>   (reads manifest from stdin)
  local f="$1"
  kubectl apply -f - >"${EVIDENCE_DIR}/${f}" 2>&1
  echo "--- ${f} ---"; cat "${EVIDENCE_DIR}/${f}"
}

TORN_DOWN=0
final_teardown() {
  if [ "${TORN_DOWN}" = "1" ]; then return 0; fi
  TORN_DOWN=1
  say "7. teardown: delete workloads, uninstall shared infra, destroy terraform"
  kubectl delete pod nodepool-pacer --ignore-not-found >/dev/null 2>&1
  for ns in t-kyv t-gk t-cap t-cap-2 t-m-a t-m-b mimir kyverno gatekeeper-system capsule-system; do
    kubectl delete ns "${ns}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
  done
  kubectl delete clusterpolicy --all --ignore-not-found >/dev/null 2>&1
  kubectl delete constrainttemplate --all --ignore-not-found >/dev/null 2>&1
  kubectl delete tenant --all --ignore-not-found >/dev/null 2>&1
  kubectl delete clusterqueue --all --ignore-not-found >/dev/null 2>&1
  kubectl delete resourceflavor --all --ignore-not-found >/dev/null 2>&1
  # drain the Karpenter-launched node(s) before terraform destroy tears down
  # the network under them (same ordering the real teardown guard uses).
  kubectl delete nodepool test-workloads --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
  kubectl delete ec2nodeclass test-workloads --ignore-not-found >/dev/null 2>&1
  helm uninstall cert-manager -n cert-manager --wait >/dev/null 2>&1
  kubectl delete ns cert-manager --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
  helm uninstall kueue -n kueue-system --wait >/dev/null 2>&1
  helm uninstall karpenter -n kube-system --wait >/dev/null 2>&1
  helm uninstall karpenter-crd -n kube-system --wait >/dev/null 2>&1
  kubectl delete ns kueue-system --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1

  pushd "${ROOT}/infra/foundation" >/dev/null
  terraform destroy -auto-approve 2>&1 | tee "${EVIDENCE_DIR}/07-terraform-destroy.txt"
  popd >/dev/null

  say "8. independent read-only leftover sweep (${NAME})"
  capture "08-sweep-eks.txt" aws eks describe-cluster --name "${NAME}" --region "${AWS_REGION}"
  capture "08-sweep-ec2-instances.txt" aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:karpenter.sh/discovery,Values=${NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped"
  capture "08-sweep-launch-templates.txt" aws ec2 describe-launch-templates --region "${AWS_REGION}" \
    --filters "Name=tag:eks:eks-cluster-name,Values=${NAME}"
  capture "08-sweep-vpcs.txt" aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=*${NAME}*"
  capture "08-sweep-iam-roles.txt" bash -c "aws iam list-roles --query \"Roles[?contains(RoleName,'${NAME}')].RoleName\" --output text"
  capture "08-sweep-sqs.txt" bash -c "aws sqs list-queues --region ${AWS_REGION} --queue-name-prefix ${NAME}"

  say "DONE"
  echo "Evidence directory: ${EVIDENCE_DIR}"
  ls -la "${EVIDENCE_DIR}"
}
trap final_teardown EXIT

#############################################
say "0. terraform apply the foundation layer (cell: ${NAME})"
#############################################
export TF_VAR_name="${NAME}"
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_endpoint_public_access_cidrs="[\"${MY_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_PRINCIPAL_ARN}\"]"

pushd infra/foundation >/dev/null
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"
if ! terraform apply -auto-approve; then
  echo "FATAL: terraform apply failed, going straight to teardown"
  popd >/dev/null
  exit 1
fi
INTERRUPTION_QUEUE="$(terraform output -raw karpenter_interruption_queue_name)"
NODE_ROLE_NAME="$(terraform output -raw karpenter_node_role_name)"
popd >/dev/null

aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
capture "00-nodes.txt" kubectl get nodes -o wide

#############################################
say "1. install Karpenter + Kueue (shared infra for the rest of the run)"
#############################################
helm install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version 1.15.2 -n kube-system --wait
helm install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.2 -n kube-system --skip-crds --wait \
  --set settings.clusterName="${NAME}" \
  --set serviceAccount.name=karpenter \
  --set controller.env[0].name=AWS_REGION \
  --set controller.env[0].value="${AWS_REGION}" \
  --set settings.interruptionQueue="${INTERRUPTION_QUEUE}" \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists
helm install kueue oci://registry.k8s.io/kueue/charts/kueue --version 0.20.6 -n kueue-system --create-namespace --wait \
  --set controllerManager.tolerations[0].key=CriticalAddonsOnly \
  --set controllerManager.tolerations[0].operator=Exists
capture "01-karpenter-kueue.txt" bash -c 'kubectl -n kube-system get deploy karpenter; kubectl -n kueue-system get deploy'

# kubectl's client-side discovery cache (~/.kube/cache) can be primed stale
# by the "kubectl get nodes" call above, before Kueue's CRDs existed, and
# reused for its ~10-minute TTL by every later kubectl process sharing the
# same cache directory. Attempt 2 (dp-ten-x2) cleared only the discovery/
# subdirectory and still saw "ensure CRDs are installed first" for
# ResourceFlavor/ClusterQueue/LocalQueue minutes later -- clear the whole
# cache directory this time and verify against the apiserver's own raw
# discovery document (bypasses kubectl's RESTMapper cache entirely), not
# just the existence of the CRD object.
rm -rf ~/.kube/cache/* 2>/dev/null || true
sleep 15
for i in $(seq 1 40); do
  kubectl get --raw "/apis/kueue.x-k8s.io/v1beta1" 2>/dev/null | grep -q '"kind":"ResourceFlavor"' && break
  rm -rf ~/.kube/cache/* 2>/dev/null || true
  sleep 3
done
capture "01-kueue-crd-check.txt" kubectl get --raw "/apis/kueue.x-k8s.io/v1beta1"

# None of the test workloads below (Kyverno/Gatekeeper/Capsule/cert-manager/
# Mimir/Prometheus) tolerate the system node group's CriticalAddonsOnly
# taint, and no Karpenter NodePool exists yet -- every one of them would
# stay Pending forever (attempt 1, dp-ten-x1, showed exactly this; attempt 2,
# dp-ten-x2, still hit it for cert-manager specifically because this
# NodePool was created AFTER cert-manager's own install in that attempt).
# Give Karpenter one small, untainted, on-demand NodePool now, before
# anything else in this phase that needs a node (light tier: on-demand
# m/t-family only).
cat <<EOF | apply_capture "01-nodepool-apply.txt"
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: test-workloads
spec:
  amiFamily: AL2023
  amiSelectorTerms:
  - alias: al2023@latest
  role: ${NODE_ROLE_NAME}
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: ${NAME}
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: ${NAME}
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: test-workloads
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: test-workloads
      requirements:
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["m", "t"]
      - key: karpenter.k8s.aws/instance-generation
        operator: Gt
        values: ["6"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]
  limits:
    cpu: "8"
    memory: 16Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s
EOF
# force at least one node to exist before any phase below needs one: a
# throwaway pacer pod with no toleration, so Karpenter provisions for it.
kubectl run nodepool-pacer --image=public.ecr.aws/docker/library/pause:3.9 --restart=Never >/dev/null 2>&1 || true
kubectl wait --for=condition=Ready pod/nodepool-pacer --timeout=300s || true
capture "01-nodepool-nodes.txt" kubectl get nodes -o wide
kubectl delete pod nodepool-pacer --ignore-not-found >/dev/null 2>&1

# cert-manager: Capsule's chart (phase 5) needs its Certificate/Issuer CRDs
# for the admission webhook's TLS (attempt 2, dp-ten-x2, found this
# installed after the NodePool above so its own pod had nowhere to
# schedule and the install timed out). Installed here, after the NodePool
# exists, as shared infra like Karpenter/Kueue, uninstalled in teardown.
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1
helm repo update jetstack >/dev/null 2>&1
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true --wait --timeout 5m \
  --set 'tolerations[0].key=CriticalAddonsOnly' --set 'tolerations[0].operator=Exists'
rm -rf ~/.kube/cache/* 2>/dev/null || true

#############################################
say "2. Kueue-native test: ClusterQueue.namespaceSelector, no policy engine involved"
#############################################
kubectl create ns t-kyv --dry-run=client -o yaml | kubectl label --local -f - distai.dev/team=t-kyv -o yaml | kubectl apply -f -
kubectl create ns t-gk  --dry-run=client -o yaml | kubectl label --local -f - distai.dev/team=t-gk  -o yaml | kubectl apply -f -
kubectl create ns t-cap --dry-run=client -o yaml | kubectl label --local -f - distai.dev/team=t-cap -o yaml | kubectl apply -f -

cat <<'EOF' | apply_capture "02-resourceflavor.txt"
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
EOF

for t in t-kyv t-gk t-cap; do
cat <<EOF | apply_capture "02-clusterqueue-${t}.txt"
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: cq-${t}
spec:
  namespaceSelector:
    matchLabels:
      distai.dev/team: ${t}
  resourceGroups:
  - coveredResources: ["cpu", "memory"]
    flavors:
    - name: default-flavor
      resources:
      - name: cpu
        nominalQuota: "2"
      - name: memory
        nominalQuota: 4Gi
EOF
done

# own LocalQueue: must be admitted (namespaceSelector matches)
cat <<'EOF' | apply_capture "02-localqueue-own.txt"
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: lq-own
  namespace: t-kyv
spec:
  clusterQueue: cq-t-kyv
EOF
sleep 5
capture "02-localqueue-own-status.txt" kubectl -n t-kyv get localqueue lq-own -o jsonpath='{.status}'

# cross-tenant LocalQueue: t-gk's namespace is not selected by cq-t-kyv's namespaceSelector
cat <<'EOF' | apply_capture "02-localqueue-cross-tenant.txt"
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: lq-cross
  namespace: t-gk
spec:
  clusterQueue: cq-t-kyv
EOF
sleep 5
capture "02-localqueue-cross-tenant-status.txt" kubectl -n t-gk get localqueue lq-cross -o jsonpath='{.status}'
kubectl -n t-gk delete localqueue lq-cross --ignore-not-found >/dev/null 2>&1

#############################################
say "3. Kyverno: generate-on-create and a validating rule, on t-kyv"
#############################################
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1
helm repo update kyverno >/dev/null 2>&1
KYVERNO_CHART_VERSION="$(helm search repo kyverno/kyverno -o json | python3 -I -c 'import json,sys;print(json.load(sys.stdin)[0]["version"])')"
echo "kyverno chart version: ${KYVERNO_CHART_VERSION}" > "${EVIDENCE_DIR}/03-kyverno-version.txt"
helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --timeout 5m
kubectl -n kyverno get deploy -o wide >> "${EVIDENCE_DIR}/03-kyverno-version.txt"

# Attempt 2 (dp-ten-x2) found this chart installs Kyverno v1.20, which
# rejects creation of the legacy kyverno.io/v1 ClusterPolicy kind outright
# ("Kyverno v1.20 removed execution of legacy kyverno.io policy types").
# The replacement, CEL-based policies.kyverno.io/v1, ships ValidatingPolicy,
# MutatingPolicy, GeneratingPolicy, DeletingPolicy and ImageValidatingPolicy.
# Only the validating half is re-tested here (confirmed schema, from
# kyverno.io's own ValidatingPolicy docs); the generate/mutate-on-create
# half is not re-verified live this round -- noted as a gap in the report,
# not claimed as tested.
cat <<'EOF' | apply_capture "03-kyverno-policy-apply.txt"
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: deny-privileged
spec:
  validationActions: ["Deny"]
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - message: "privileged containers are not allowed"
      expression: "!object.spec.containers.exists(c, has(c.securityContext) && has(c.securityContext.privileged) && c.securityContext.privileged == true)"
EOF
sleep 8
capture "03-kyverno-gen-resourcequota.txt" kubectl -n t-kyv get resourcequota -o yaml
capture "03-kyverno-gen-networkpolicy.txt" kubectl -n t-kyv get networkpolicy -o yaml
capture "03-kyverno-mutate-psa.txt" kubectl get ns t-kyv -o jsonpath='{.metadata.labels}'
cat <<'EOF' > /tmp/priv-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: priv-test
spec:
  containers:
  - name: c
    image: busybox:1.37
    command: ["sleep", "60"]
    securityContext:
      privileged: true
EOF
{ kubectl -n t-kyv apply -f /tmp/priv-pod.yaml; } >"${EVIDENCE_DIR}/03-kyverno-deny-privileged.txt" 2>&1
echo "--- 03-kyverno-deny-privileged.txt ---"; cat "${EVIDENCE_DIR}/03-kyverno-deny-privileged.txt"
kubectl -n t-kyv delete pod priv-test --ignore-not-found >/dev/null 2>&1

kubectl delete validatingpolicy --all --ignore-not-found >/dev/null 2>&1
helm uninstall kyverno -n kyverno --wait >/dev/null 2>&1
kubectl delete clusterpolicy --all --ignore-not-found >/dev/null 2>&1
kubectl delete ns kyverno --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1

#############################################
say "4. Gatekeeper: validating-only, confirm it cannot generate defaults"
#############################################
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts >/dev/null 2>&1
helm repo update gatekeeper >/dev/null 2>&1
GK_CHART_VERSION="$(helm search repo gatekeeper/gatekeeper -o json | python3 -I -c 'import json,sys;print(json.load(sys.stdin)[0]["version"])')"
echo "gatekeeper chart version: ${GK_CHART_VERSION}" > "${EVIDENCE_DIR}/04-gatekeeper-version.txt"
helm install gatekeeper gatekeeper/gatekeeper -n gatekeeper-system --create-namespace --wait --timeout 5m
kubectl -n gatekeeper-system get deploy -o wide >> "${EVIDENCE_DIR}/04-gatekeeper-version.txt"

cat <<'EOF' | apply_capture "04-gatekeeper-template-apply.txt"
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sdenyprivileged
spec:
  crd:
    spec:
      names:
        kind: K8sDenyPrivileged
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package k8sdenyprivileged
      violation[{"msg": msg}] {
        c := input.review.object.spec.containers[_]
        c.securityContext.privileged == true
        msg := "privileged containers are not allowed"
      }
EOF
sleep 8
cat <<'EOF' | apply_capture "04-gatekeeper-constraint-apply.txt"
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sDenyPrivileged
metadata:
  name: deny-privileged
spec:
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    namespaces: ["t-gk"]
EOF
sleep 10
{ kubectl -n t-gk apply -f /tmp/priv-pod.yaml; } >"${EVIDENCE_DIR}/04-gatekeeper-deny-privileged.txt" 2>&1
echo "--- 04-gatekeeper-deny-privileged.txt ---"; cat "${EVIDENCE_DIR}/04-gatekeeper-deny-privileged.txt"
kubectl -n t-gk delete pod priv-test --ignore-not-found >/dev/null 2>&1

# Confirm the absence of generate: nothing created these in t-gk (only the
# Namespace itself was created by this script, with the same team label
# Kyverno's generate rule reacted to for t-kyv).
capture "04-gatekeeper-no-generate.txt" bash -c 'kubectl -n t-gk get resourcequota,limitrange,networkpolicy 2>&1'

helm uninstall gatekeeper -n gatekeeper-system --wait >/dev/null 2>&1
kubectl delete constrainttemplate k8sdenyprivileged --ignore-not-found >/dev/null 2>&1
kubectl delete ns gatekeeper-system --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1

#############################################
say "5. Capsule: Tenant defaults + self-service namespace creation by the owner identity"
#############################################
helm repo add projectcapsule https://projectcapsule.github.io/charts >/dev/null 2>&1
helm repo update projectcapsule >/dev/null 2>&1
CAP_CHART_VERSION="$(helm search repo projectcapsule/capsule -o json | python3 -I -c 'import json,sys;print(json.load(sys.stdin)[0]["version"])')"
echo "capsule chart version: ${CAP_CHART_VERSION}" > "${EVIDENCE_DIR}/05-capsule-version.txt"
helm install capsule projectcapsule/capsule -n capsule-system --create-namespace --wait --timeout 5m
kubectl -n capsule-system get deploy -o wide >> "${EVIDENCE_DIR}/05-capsule-version.txt"

kubectl delete ns t-cap --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1
kubectl create sa cap-team-bot -n kube-system --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | apply_capture "05-capsule-tenant-apply.txt"
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: cap-team
spec:
  owners:
  - name: "system:serviceaccount:kube-system:cap-team-bot"
    kind: ServiceAccount
  namespaceOptions:
    quota: 1
    additionalMetadata:
      labels:
        pod-security.kubernetes.io/enforce: baseline
        pod-security.kubernetes.io/warn: baseline
  resourceQuotas:
    scope: Tenant
    items:
    - hard:
        requests.cpu: "2"
        requests.memory: 4Gi
        pods: "20"
  networkPolicies:
    items:
    - podSelector: {}
      policyTypes: ["Ingress"]
      ingress:
      - from:
        - namespaceSelector:
            matchLabels:
              capsule.clastix.io/tenant: cap-team
EOF
sleep 8
capture "05-capsule-tenant-status.txt" kubectl get tenant cap-team -o yaml

# self-service: the owner identity creates its own namespace, no admin step
capture "05-capsule-self-service-create.txt" kubectl create ns t-cap --as=system:serviceaccount:kube-system:cap-team-bot
sleep 8
capture "05-capsule-defaults-on-create.txt" bash -c 'kubectl get ns t-cap -o jsonpath="{.metadata.labels}"; echo; kubectl -n t-cap get resourcequota,networkpolicy -o yaml'

# quota=1: a second namespace by the same owner must be denied
capture "05-capsule-quota-denied.txt" kubectl create ns t-cap-2 --as=system:serviceaccount:kube-system:cap-team-bot

helm uninstall capsule -n capsule-system --wait >/dev/null 2>&1
kubectl delete tenant cap-team --ignore-not-found >/dev/null 2>&1
kubectl delete ns capsule-system --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1

#############################################
say "6. Grafana Mimir: tenant isolation and the spoofing question"
#############################################
kubectl create ns mimir --dry-run=client -o yaml | kubectl apply -f -
cat <<'EOF' | apply_capture "06-mimir-apply.txt"
apiVersion: v1
kind: ConfigMap
metadata:
  name: mimir-config
  namespace: mimir
data:
  mimir.yaml: |
    multitenancy_enabled: true
    server:
      http_listen_port: 8080
    ingester:
      ring:
        replication_factor: 1
    blocks_storage:
      backend: filesystem
      filesystem:
        dir: /tmp/mimir/blocks
      tsdb:
        dir: /tmp/mimir/tsdb
    compactor:
      data_dir: /tmp/mimir/compactor
    ruler_storage:
      backend: filesystem
      filesystem:
        dir: /tmp/mimir/ruler
    alertmanager_storage:
      backend: filesystem
      filesystem:
        dir: /tmp/mimir/alertmanager
    alertmanager:
      data_dir: /tmp/mimir/alertmanager-data
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mimir
  namespace: mimir
spec:
  replicas: 1
  selector:
    matchLabels: {app: mimir}
  template:
    metadata:
      labels: {app: mimir}
    spec:
      containers:
      - name: mimir
        image: grafana/mimir:latest
        args: ["-config.file=/etc/mimir/mimir.yaml"]
        ports: [{containerPort: 8080}]
        volumeMounts: [{name: cfg, mountPath: /etc/mimir}]
      volumes:
      - name: cfg
        configMap: {name: mimir-config}
---
apiVersion: v1
kind: Service
metadata:
  name: mimir
  namespace: mimir
spec:
  selector: {app: mimir}
  ports: [{port: 8080, targetPort: 8080}]
EOF
kubectl -n mimir rollout status deploy/mimir --timeout=180s
capture "06-mimir-pods.txt" bash -c 'kubectl -n mimir get pods -o wide; kubectl -n mimir logs deploy/mimir --tail=40'

for t in t-m-a t-m-b; do
  kubectl create ns "${t}" --dry-run=client -o yaml | kubectl apply -f -
done

# one emitter + one tiny Prometheus per team namespace; the remote_write
# header is the namespace name itself, wired in by this script (the
# "platform"), not something the team's own workload chose.
for pair in "t-m-a:t_m_a_canary" "t-m-b:t_m_b_canary"; do
  ns="${pair%%:*}"; metric="${pair##*:}"
cat <<EOF | apply_capture "06-team-${ns}-apply.txt"
apiVersion: v1
kind: ConfigMap
metadata:
  name: emitter
  namespace: ${ns}
data:
  index.py: |
    import http.server, socketserver
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Type","text/plain"); self.end_headers()
            self.wfile.write(b"${metric} 1\n")
    socketserver.TCPServer(("0.0.0.0", 9100), H).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: emitter
  namespace: ${ns}
spec:
  replicas: 1
  selector: {matchLabels: {app: emitter}}
  template:
    metadata: {labels: {app: emitter}}
    spec:
      containers:
      - name: emitter
        image: python:3.12-slim
        command: ["python3", "/cfg/index.py"]
        volumeMounts: [{name: cfg, mountPath: /cfg}]
      volumes:
      - name: cfg
        configMap: {name: emitter}
---
apiVersion: v1
kind: Service
metadata:
  name: emitter
  namespace: ${ns}
spec:
  selector: {app: emitter}
  ports: [{port: 9100, targetPort: 9100}]
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prom-cfg
  namespace: ${ns}
data:
  prometheus.yml: |
    global: {scrape_interval: 5s}
    scrape_configs:
    - job_name: emitter
      static_configs: [{targets: ["emitter.${ns}.svc:9100"]}]
    remote_write:
    - url: http://mimir.mimir.svc:8080/api/v1/push
      headers:
        X-Scope-OrgID: "${ns}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prom
  namespace: ${ns}
spec:
  replicas: 1
  selector: {matchLabels: {app: prom}}
  template:
    metadata: {labels: {app: prom}}
    spec:
      containers:
      - name: prom
        image: prom/prometheus:latest
        args: ["--config.file=/cfg/prometheus.yml"]
        volumeMounts: [{name: cfg, mountPath: /cfg}]
      volumes:
      - name: cfg
        configMap: {name: prom-cfg}
EOF
done

sleep 45
capture "06-prom-rollout.txt" bash -c 'kubectl -n t-m-a rollout status deploy/prom --timeout=120s; kubectl -n t-m-b rollout status deploy/prom --timeout=120s'
sleep 20

# a plain query client pod, started in t-m-a, with no special privilege
kubectl -n t-m-a run q --image=curlimages/curl:latest --restart=Never --command -- sleep 3600
kubectl -n t-m-a wait --for=condition=Ready pod/q --timeout=60s

q() { kubectl -n t-m-a exec q -- curl -s -H "X-Scope-OrgID: $1" "http://mimir.mimir.svc:8080/prometheus/api/v1/query?query=$2"; }

capture "06-own-tenant-sees-own-metric.txt" bash -c "$(declare -f q); q t-m-a t_m_a_canary"
capture "06-own-tenant-cannot-see-other.txt" bash -c "$(declare -f q); q t-m-a t_m_b_canary"
capture "06-SPOOF-cross-tenant-header.txt" bash -c "$(declare -f q); q t-m-b t_m_b_canary"

say "6b. mitigation: NetworkPolicy restricts who may reach Mimir at all"
cat <<'EOF' | apply_capture "06-networkpolicy-apply.txt"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: only-prom
  namespace: mimir
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels: {app: prom}
EOF
sleep 10
capture "06-after-networkpolicy-spoof-blocked.txt" bash -c "$(declare -f q); q t-m-b t_m_b_canary"

kubectl -n t-m-a delete pod q --ignore-not-found >/dev/null 2>&1

# phases 7 and 8 run from the EXIT trap (final_teardown), guaranteed exactly
# once, whether this point is reached normally or something above failed.
