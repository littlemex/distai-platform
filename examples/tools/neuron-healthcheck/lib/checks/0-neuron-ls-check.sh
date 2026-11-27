#!/usr/bin/env bash
# Check 0: Neuron device and NeuronCore count, read from the real device.
#
# Runs `neuron-ls --json-output` and asserts:
#   (a) the number of device entries == EXPECTED_DEVICE_COUNT
#   (b) every device entry's own nc_count == EXPECTED_NEURONCORE_COUNT
#
# (a) is the same assertion gitops/tests/1.e2e.sh's check_accel_layer1
# Neuron probe makes, with the same JSON-parsing rule (a top-level list, or
# an object wrapping exactly one list), lifted into a standalone script.
# (b) is new here: that e2e probe proves "exactly one device", not the
# NeuronCore count (issue #97, point 1). nc_count is read from neuron-ls,
# never from Karpenter's instance-type data, which is wrong for trn2.3xlarge
# (see profiles/instance-profiles.conf).
#
# Environment: EXPECTED_DEVICE_COUNT, EXPECTED_NEURONCORE_COUNT, RESULTS_DIR.
# Exit status: 0 PASS, 1 FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

CHECK_NAME="0-neuron-ls"

if ! require_int EXPECTED_DEVICE_COUNT "${EXPECTED_DEVICE_COUNT:-}" \
    || ! require_int EXPECTED_NEURONCORE_COUNT "${EXPECTED_NEURONCORE_COUNT:-}"; then
    write_result "${CHECK_NAME}" FAIL "expectations missing or malformed: EXPECTED_DEVICE_COUNT='${EXPECTED_DEVICE_COUNT:-}' EXPECTED_NEURONCORE_COUNT='${EXPECTED_NEURONCORE_COUNT:-}'"
    exit 1
fi
if [[ "${EXPECTED_DEVICE_COUNT}" -lt 1 ]] || [[ "${EXPECTED_NEURONCORE_COUNT}" -lt 1 ]]; then
    write_result "${CHECK_NAME}" FAIL "expectations are not a real expectation to check against: EXPECTED_DEVICE_COUNT=${EXPECTED_DEVICE_COUNT} EXPECTED_NEURONCORE_COUNT=${EXPECTED_NEURONCORE_COUNT} (both must be at least 1)"
    exit 1
fi

if ! command -v neuron-ls >/dev/null 2>&1; then
    write_result "${CHECK_NAME}" FAIL "neuron-ls not found on PATH (${PATH}) -- the base image must ship aws-neuronx-tools"
    exit 1
fi

LS_RC=0
LS_ERR_FILE="$(mktemp)"
trap 'rm -f "${LS_ERR_FILE}"' EXIT
LS_OUT="$(neuron-ls --json-output 2>"${LS_ERR_FILE}")" || LS_RC=$?
LS_ERR="$(cat "${LS_ERR_FILE}")"
# stdout and stderr are kept apart on purpose: the JSON parser below reads
# only LS_OUT. A 2>&1 merge would let anything neuron-ls writes to its own
# stderr -- a warning unrelated to the JSON it writes to stdout -- land
# inside the string this check parses as JSON, turning a real PASS into a
# parse-failure FAIL for a reason that has nothing to do with the device
# count or core count this check exists to verify. LS_ERR is logged and
# attached as evidence either way, never silently dropped.
if [[ -n "${LS_ERR}" ]]; then
    echo "[INFO] neuron-ls stderr (not parsed, logged only): ${LS_ERR}"
fi
if [[ "${LS_RC}" -ne 0 ]]; then
    write_result "${CHECK_NAME}" FAIL "neuron-ls --json-output exited ${LS_RC}" "stdout: ${LS_OUT}"$'\n'"stderr: ${LS_ERR}"
    exit 1
fi

# Prints "<device_count> <comma-separated nc_count per device>", or
# "-1 <reason>" when the output is not the shape this check understands.
PARSED="$(python3 -c '
import json, sys
try:
    doc = json.loads(sys.stdin.read())
except Exception as exc:
    print("-1 not valid JSON: %s" % exc); sys.exit(0)
if isinstance(doc, dict):
    lists = [v for v in doc.values() if isinstance(v, list)]
    doc = lists[0] if len(lists) == 1 else None
if not isinstance(doc, list):
    print("-1 neither a list nor an object wrapping exactly one list"); sys.exit(0)
cores = []
for entry in doc:
    nc = entry.get("nc_count") if isinstance(entry, dict) else None
    cores.append(str(nc) if isinstance(nc, int) else "missing")
print("%d %s" % (len(doc), ",".join(cores)))
' <<<"${LS_OUT}")"

DEVICE_COUNT="${PARSED%% *}"
DETAIL="${PARSED#* }"
if [[ "${DEVICE_COUNT}" == "-1" ]]; then
    write_result "${CHECK_NAME}" FAIL "could not parse neuron-ls --json-output: ${DETAIL}" "${LS_OUT}"
    exit 1
fi

if [[ "${DEVICE_COUNT}" -ne "${EXPECTED_DEVICE_COUNT}" ]]; then
    write_result "${CHECK_NAME}" FAIL "Neuron device count mismatch: expected=${EXPECTED_DEVICE_COUNT}, detected=${DEVICE_COUNT}" "${LS_OUT}"
    exit 1
fi

BAD=""
IFS=',' read -r -a CORES <<<"${DETAIL}"
for i in "${!CORES[@]}"; do
    if [[ "${CORES[$i]}" != "${EXPECTED_NEURONCORE_COUNT}" ]]; then
        BAD="${BAD} device[${i}].nc_count=${CORES[$i]}"
    fi
done
if [[ -n "${BAD}" ]]; then
    write_result "${CHECK_NAME}" FAIL "NeuronCore count mismatch: expected nc_count=${EXPECTED_NEURONCORE_COUNT} per device, got${BAD}" "${LS_OUT}"
    exit 1
fi

write_result "${CHECK_NAME}" PASS "${DEVICE_COUNT} Neuron device(s), nc_count=${EXPECTED_NEURONCORE_COUNT} each" "${LS_OUT}"
exit 0
