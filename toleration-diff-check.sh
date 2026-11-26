#!/usr/bin/env bash
set -euo pipefail
W=$(mktemp -d)
cd "$W"

echo "=== NVIDIA device plugin (0.20.2): before vs after ==="
helm pull nvidia-device-plugin --repo https://nvidia.github.io/k8s-device-plugin --version 0.20.2 --untar
helm template before ./nvidia-device-plugin > before-nvidia.yaml
cat > nvidia-override.yaml <<'VALUES'
nodeSelector:
  distai.dev/nvidia-gpu-method: device-plugin
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: distai.dev/startup-not-ready
    operator: Exists
    effect: NoSchedule
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: distai.dev/nvidia-gpu-method
              operator: In
              values: ["device-plugin"]
VALUES
helm template after ./nvidia-device-plugin -f nvidia-override.yaml > after-nvidia.yaml
echo "--- default tolerations in chart's own values.yaml ---"
grep -A6 "^tolerations:" ./nvidia-device-plugin/values.yaml
echo "--- rendered tolerations, before override ---"
yq -r 'select(.kind=="DaemonSet") | .spec.template.spec.tolerations' before-nvidia.yaml
echo "--- rendered tolerations, after override ---"
yq -r 'select(.kind=="DaemonSet") | .spec.template.spec.tolerations' after-nvidia.yaml

echo
echo "=== Neuron device plugin (1.11.2): before vs after ==="
helm pull oci://public.ecr.aws/neuron/neuron-helm-chart --version 1.11.2 --untar
helm template before ./neuron-helm-chart > before-neuron.yaml
cat > neuron-override.yaml <<'VALUES'
devicePlugin:
  nodeSelector:
    distai.dev/neuron-method: device-plugin
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
    - key: aws.amazon.com/neuron
      operator: Exists
      effect: NoSchedule
    - key: sagemaker.amazonaws.com/node-health-status
      operator: Equal
      value: Unschedulable
      effect: NoSchedule
    - key: distai.dev/startup-not-ready
      operator: Exists
      effect: NoSchedule
draDriver:
  enabled: false
npd:
  namespaceOverride: neuron-device-plugin
VALUES
helm template after ./neuron-helm-chart -f neuron-override.yaml > after-neuron.yaml
echo "--- default devicePlugin.tolerations in chart's own values.yaml ---"
grep -A8 "^devicePlugin:" ./neuron-helm-chart/values.yaml | grep -A6 "tolerations:"
echo "--- rendered device-plugin DaemonSet tolerations, before override ---"
yq -r 'select(.kind=="DaemonSet" and (.metadata.name | test("device-plugin"))) | .spec.template.spec.tolerations' before-neuron.yaml
echo "--- rendered device-plugin DaemonSet tolerations, after override ---"
yq -r 'select(.kind=="DaemonSet" and (.metadata.name | test("device-plugin"))) | .spec.template.spec.tolerations' after-neuron.yaml
echo "--- npd DaemonSet tolerations (should be unchanged, not touched by this PR) ---"
yq -r 'select(.kind=="DaemonSet" and (.metadata.name | test("problem-detector|npd"))) | .spec.template.spec.tolerations' after-neuron.yaml

echo
echo "=== EFA device plugin (v0.5.35): before vs after ==="
helm pull aws-efa-k8s-device-plugin --repo https://aws.github.io/eks-charts --version v0.5.35 --untar
helm template before ./aws-efa-k8s-device-plugin > before-efa.yaml
cat > efa-override.yaml <<'VALUES'
image:
  tag: "v0.5.22-eksbuild.9@sha256:a392d84ff82b23580fd92d0a6c770136c56d4a6ee979a47d1bf4e379a7171647"
nodeSelector:
  distai.dev/nvidia-gpu-method: device-plugin
  distai.dev/efa-attached: "true"
securityContext:
  privileged: false
  allowPrivilegeEscalation: false
  runAsNonRoot: false
  runAsUser: 0
  capabilities:
    drop: ["ALL"]
tolerations:
  - key: distai.dev/startup-not-ready
    operator: Exists
    effect: NoSchedule
VALUES
helm template after ./aws-efa-k8s-device-plugin -f efa-override.yaml > after-efa.yaml
echo "--- default tolerations in chart's own values.yaml ---"
grep -A3 "^tolerations:" ./aws-efa-k8s-device-plugin/values.yaml
echo "--- rendered tolerations, before override ---"
yq -r 'select(.kind=="DaemonSet") | .spec.template.spec.tolerations' before-efa.yaml
echo "--- rendered tolerations, after override ---"
yq -r 'select(.kind=="DaemonSet") | .spec.template.spec.tolerations' after-efa.yaml

echo
echo "=== vigil-controller (0.7.0): config + tolerations/affinity rendered ==="
helm pull vigil-controller --repo https://oss.nextdoor.com/vigil --version 0.7.0 --untar
cat > vigil-override.yaml <<'VALUES'
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: karpenter.sh/nodepool
              operator: DoesNotExist
config:
  taintKey: "distai.dev/startup-not-ready"
  taintEffect: "NoSchedule"
  knownStartupTaintKeys:
    - "distai.dev/startup-not-ready"
  timeoutSeconds: 300
VALUES
helm template v ./vigil-controller -f vigil-override.yaml > vigil-rendered.yaml
echo "--- rendered ConfigMap data (must contain the configured taintKey and timeoutSeconds 300) ---"
yq -r 'select(.kind=="ConfigMap") | .data."config.yaml"' vigil-rendered.yaml
echo "--- rendered Deployment tolerations/affinity ---"
yq -r 'select(.kind=="Deployment") | .spec.template.spec.tolerations' vigil-rendered.yaml
yq -r 'select(.kind=="Deployment") | .spec.template.spec.affinity' vigil-rendered.yaml

echo
echo "=== dcgm-exporter: local wrapper chart defaults ==="

echo
echo "=== every DaemonSet name NVIDIA chart renders, before vs after (same set == no new/missing DaemonSet from the override) ==="
echo "before:"; yq -r 'select(.kind=="DaemonSet") | .metadata.name' before-nvidia.yaml
echo "after:"; yq -r 'select(.kind=="DaemonSet") | .metadata.name' after-nvidia.yaml
echo
echo "=== every DaemonSet name Neuron chart renders, before vs after ==="
echo "before:"; yq -r 'select(.kind=="DaemonSet") | .metadata.name' before-neuron.yaml
echo "after:"; yq -r 'select(.kind=="DaemonSet") | .metadata.name' after-neuron.yaml
echo
echo "=== every DaemonSet name EFA chart renders, before vs after ==="
echo "before:"; yq -r 'select(.kind=="DaemonSet") | .metadata.name' before-efa.yaml
echo "after:"; yq -r 'select(.kind=="DaemonSet") | .metadata.name' after-efa.yaml
