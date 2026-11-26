#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="uv run --no-project -q --with pyyaml==6.0.2 python3"
W=$(mktemp -d)
cd "$W"

echo "=== NVIDIA device plugin (0.20.2): before vs after ==="
helm pull nvidia-device-plugin --repo https://nvidia.github.io/k8s-device-plugin --version 0.20.2 --untar
helm template before ./nvidia-device-plugin -n nvidia-device-plugin > before-nvidia.yaml
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
helm template after ./nvidia-device-plugin -n nvidia-device-plugin -f nvidia-override.yaml > after-nvidia.yaml
echo "--- default tolerations in chart's own values.yaml ---"
grep -A6 "^tolerations:" ./nvidia-device-plugin/values.yaml || true
echo "--- rendered tolerations, before override ---"
${PY} "${SCRIPT_DIR}/extract.py" before-nvidia.yaml DaemonSet '' 'spec.template.spec.tolerations'
echo "--- rendered tolerations, after override ---"
${PY} "${SCRIPT_DIR}/extract.py" after-nvidia.yaml DaemonSet '' 'spec.template.spec.tolerations'

echo
echo "=== Neuron device plugin (1.11.2): before vs after ==="
helm pull oci://public.ecr.aws/neuron/neuron-helm-chart --version 1.11.2 --untar
helm template before ./neuron-helm-chart -n neuron-device-plugin > before-neuron.yaml
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
helm template after ./neuron-helm-chart -n neuron-device-plugin -f neuron-override.yaml > after-neuron.yaml
echo "--- default devicePlugin.tolerations in chart's own values.yaml ---"
grep -A8 "^devicePlugin:" ./neuron-helm-chart/values.yaml | grep -A6 "tolerations:" || true
echo "--- rendered device-plugin DaemonSet tolerations, before override ---"
${PY} "${SCRIPT_DIR}/extract.py" before-neuron.yaml DaemonSet 'device-plugin' 'spec.template.spec.tolerations'
echo "--- rendered device-plugin DaemonSet tolerations, after override ---"
${PY} "${SCRIPT_DIR}/extract.py" after-neuron.yaml DaemonSet 'device-plugin' 'spec.template.spec.tolerations'
echo "--- npd DaemonSet tolerations (should be unchanged, not touched by this PR) ---"
${PY} "${SCRIPT_DIR}/extract.py" after-neuron.yaml DaemonSet 'problem-detector|npd' 'spec.template.spec.tolerations'

echo
echo "=== EFA device plugin (v0.5.35): before vs after ==="
helm pull aws-efa-k8s-device-plugin --repo https://aws.github.io/eks-charts --version v0.5.35 --untar
helm template before ./aws-efa-k8s-device-plugin -n kube-system > before-efa.yaml
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
helm template after ./aws-efa-k8s-device-plugin -n kube-system -f efa-override.yaml > after-efa.yaml
echo "--- default tolerations in chart's own values.yaml ---"
grep -A3 "^tolerations:" ./aws-efa-k8s-device-plugin/values.yaml || true
echo "--- rendered tolerations, before override ---"
${PY} "${SCRIPT_DIR}/extract.py" before-efa.yaml DaemonSet '' 'spec.template.spec.tolerations'
echo "--- rendered tolerations, after override ---"
${PY} "${SCRIPT_DIR}/extract.py" after-efa.yaml DaemonSet '' 'spec.template.spec.tolerations'

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
helm template v ./vigil-controller -n vigil-system -f vigil-override.yaml > vigil-rendered.yaml
echo "--- rendered ConfigMap data (must contain the configured taintKey and timeoutSeconds 300) ---"
${PY} "${SCRIPT_DIR}/extract.py" vigil-rendered.yaml ConfigMap '' 'data'
echo "--- rendered Deployment tolerations/affinity ---"
${PY} "${SCRIPT_DIR}/extract.py" vigil-rendered.yaml Deployment '' 'spec.template.spec.tolerations'
${PY} "${SCRIPT_DIR}/extract.py" vigil-rendered.yaml Deployment '' 'spec.template.spec.affinity'

echo
echo "=== dcgm-exporter: local wrapper chart defaults ==="

echo
echo "=== every DaemonSet name NVIDIA chart renders, before vs after (same set == no new/missing DaemonSet from the override) ==="
echo "before:"; ${PY} "${SCRIPT_DIR}/extract.py" before-nvidia.yaml DaemonSet '' ''
echo "after:"; ${PY} "${SCRIPT_DIR}/extract.py" after-nvidia.yaml DaemonSet '' ''
echo
echo "=== every DaemonSet name Neuron chart renders, before vs after ==="
echo "before:"; ${PY} "${SCRIPT_DIR}/extract.py" before-neuron.yaml DaemonSet '' ''
echo "after:"; ${PY} "${SCRIPT_DIR}/extract.py" after-neuron.yaml DaemonSet '' ''
echo
echo "=== every DaemonSet name EFA chart renders, before vs after ==="
echo "before:"; ${PY} "${SCRIPT_DIR}/extract.py" before-efa.yaml DaemonSet '' ''
echo "after:"; ${PY} "${SCRIPT_DIR}/extract.py" after-efa.yaml DaemonSet '' ''
