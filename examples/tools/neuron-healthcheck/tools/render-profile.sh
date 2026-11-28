#!/usr/bin/env bash
# Print the instance-profile table this tool actually runs with:
# profiles/instance-profiles.conf, byte for byte. There is no vendored table
# to merge with (unlike ../gpu-healthcheck's render-profiles.sh), so the
# only transformation this script ever makes is the test-only one below.
#
# Usage: render-profile.sh [--inject-bad-device-count <instance-type>]
#
# --inject-bad-device-count is for this tool's own deliberate-failure Test
# Plan step only: it rewrites the named instance type's own DEVICE_COUNT
# field to one more than the real value, so a run against real hardware
# proves check 0 (neuron-ls device count) actually fails when the profile
# disagrees with the hardware -- not only that it passes when everything is
# correct. Never pass this flag for a real pre-flight.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILE_CONF="${BASE_DIR}/profiles/instance-profiles.conf"

INJECT_TYPE=""
case "${1:-}" in
    --inject-bad-device-count)
        INJECT_TYPE="${2:?--inject-bad-device-count needs an instance type}"
        ;;
    "") ;;
    *)
        echo "unknown argument: ${1}" >&2
        exit 2
        ;;
esac

[[ -f "${PROFILE_CONF}" ]] || { echo "missing ${PROFILE_CONF}" >&2; exit 1; }

if [[ -z "${INJECT_TYPE}" ]]; then
    cat "${PROFILE_CONF}"
    exit 0
fi

if ! awk -F'|' -v t="${INJECT_TYPE}" '$1==t{found=1} END{exit !found}' "${PROFILE_CONF}"; then
    echo "--inject-bad-device-count: no row for instance type '${INJECT_TYPE}' -- refusing to render a profile set that silently injects nothing" >&2
    exit 1
fi

awk -F'|' -v OFS='|' -v inj="${INJECT_TYPE}" '
/^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
{
    if ($1 == inj) {
        $2 = $2 + 1
        print "# TEST ONLY: DEVICE_COUNT bumped by +1 for --inject-bad-device-count (" inj ")"
    }
    print
}' "${PROFILE_CONF}"
