#!/usr/bin/env bash
# Check 2: EFA PCI enumeration.
#
# Counts EFA PCI functions with `lspci | grep -ci EFA` and compares against
# EXPECTED_EFA_COUNT. The technique mirrors the PCI sub-check of upstream
# awslabs/awsome-distributed-ai's own check 2
# (../gpu-healthcheck/vendor/awsome-distributed-ai/checks/2-efa-enumeration.sh),
# which ../gpu-healthcheck/README.md already calls genuinely
# accelerator-agnostic; it is written fresh here rather than imported across
# examples/ subtrees. The PCI count catches the wrong number of interfaces
# being attached (a deviceIndex mistake) and does not depend on the EFA
# kernel module or on libfabric userspace tools, so no EFA installer runs.
#
# Same posture as upstream toward the kernel module: a count that matches
# but an `efa` module that is not loaded is a WARN, not a FAIL.
#
# Environment: EXPECTED_EFA_COUNT, RESULTS_DIR.
# Exit status: 0 PASS or WARN, 1 FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

CHECK_NAME="2-efa-enumeration"

if ! require_int EXPECTED_EFA_COUNT "${EXPECTED_EFA_COUNT:-}"; then
    write_result "${CHECK_NAME}" FAIL "expectation missing or malformed: EXPECTED_EFA_COUNT='${EXPECTED_EFA_COUNT:-}'"
    exit 1
fi

if command -v lspci >/dev/null 2>&1; then
    echo "[INFO] lspci present: $(command -v lspci)"
else
    echo "[INFO] lspci not on PATH -- installing pciutils"
    INSTALL_LOG=""
    INSTALL_RC=0
    if command -v apt-get >/dev/null 2>&1; then
        INSTALL_LOG="$( { DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends pciutils; } 2>&1)" || INSTALL_RC=$?
    else
        INSTALL_LOG="no apt-get in this image"
        INSTALL_RC=127
    fi
    if [[ "${INSTALL_RC}" -ne 0 ]] || ! command -v lspci >/dev/null 2>&1; then
        write_result "${CHECK_NAME}" FAIL "lspci unavailable and installing pciutils failed (rc=${INSTALL_RC}) -- EFA count could not be read" "${INSTALL_LOG}"
        exit 1
    fi
    echo "[INFO] pciutils installed: $(command -v lspci)"
fi

LSPCI_OUT="$(lspci 2>&1)" || {
    write_result "${CHECK_NAME}" FAIL "lspci failed" "${LSPCI_OUT}"
    exit 1
}
EFA_PCI_COUNT="$(grep -ci EFA <<<"${LSPCI_OUT}" || true)"
EVIDENCE="$(lspci -nn 2>&1 | grep -i EFA || true)"

if [[ "${EFA_PCI_COUNT}" -ne "${EXPECTED_EFA_COUNT}" ]]; then
    write_result "${CHECK_NAME}" FAIL "EFA PCI device count mismatch: expected=${EXPECTED_EFA_COUNT}, detected=${EFA_PCI_COUNT}" "${EVIDENCE:-${LSPCI_OUT}}"
    exit 1
fi

if [[ "${EXPECTED_EFA_COUNT}" -gt 0 && ! -d /sys/module/efa ]]; then
    write_result "${CHECK_NAME}" WARN "EFA PCI device count matches (${EFA_PCI_COUNT}) but the efa kernel module is not loaded (/sys/module/efa absent) -- the interfaces are attached but not usable for traffic yet" "${EVIDENCE}"
    exit 0
fi

write_result "${CHECK_NAME}" PASS "${EFA_PCI_COUNT} EFA PCI device(s), as expected" "${EVIDENCE}"
exit 0
