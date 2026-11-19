#!/usr/bin/env bash
# Values/template contract test for examples/inference/vllm/disagg-pd and
# agg-baseline: placement (nodeSelector on the role key, decode-only
# podAntiAffinity against prefill by default, placement.sameNodeMeasurement
# plus placement.enforceAntiAffinity switching to a shared pool and a
# required podAffinity) and transport (transport.forceEfaSameNode,
# transport.backend) are checked from `helm template` output alone. No AWS
# credentials, no cluster.
#
# The checks themselves live in check_placement_transport.py; this script
# only supplies a pinned PyYAML through uv, the same way gitops/tests does.
#
# Optional environment: HELM (helm), UV (uv), PYTHON_YAML_VERSION (6.0.2).
set -euo pipefail

HELM="${HELM:-helm}"
UV="${UV:-uv}"
PYTHON_YAML_VERSION="${PYTHON_YAML_VERSION:-6.0.2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFERENCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

for b in "${HELM}" "${UV}"; do
  command -v "${b}" >/dev/null 2>&1 || {
    echo "FAIL ${b} not found (set HELM / UV to its path)"
    exit 1
  }
done

"${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_placement_transport.py" \
  --helm "${HELM}" \
  --disagg "${INFERENCE_ROOT}/vllm/disagg-pd" \
  --agg "${INFERENCE_ROOT}/vllm/agg-baseline" \
  --work-dir "${WORK_DIR}"
