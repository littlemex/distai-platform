#!/usr/bin/env bash
# Values/template contract test for examples/inference/vllm/neuron/disagg-pd
# and vllm/neuron/agg-baseline (Issue #80): the GPU disagg-pd placement
# contract (decode-only required podAntiAffinity against prefill, the two
# nodeSelectorValues, placement.sameNodeMeasurement retargeting both roles to
# placement.sharedPoolValue, the transport.ucx.tcpPortRange guard) plus the
# Neuron-specific parts (aws.amazon.com/neuron requested per
# neuronCoresPerEngine, engine.compileCacheVolume mounted at VLLM_CACHE_ROOT,
# NEURON_VISIBLE_DEVICES never set), checked from `helm template` output
# alone. No AWS credentials, no cluster.
#
# The checks themselves live in check_neuron_placement_transport.py; this
# script only supplies a pinned PyYAML through uv, the same way
# test_placement_transport.sh does. A missing chart is a FAIL naming its path.
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
  python3 "${SCRIPT_DIR}/check_neuron_placement_transport.py" \
  --helm "${HELM}" \
  --disagg "${INFERENCE_ROOT}/vllm/neuron/disagg-pd" \
  --agg "${INFERENCE_ROOT}/vllm/neuron/agg-baseline" \
  --work-dir "${WORK_DIR}"
