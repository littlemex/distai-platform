#!/usr/bin/env bash
# Render the merged instance-profiles.conf this tool actually runs with:
# upstream's own vendored file, byte for byte, plus this platform's own
# profiles/g6e-overlay.conf appended. Never writes into vendor/ -- that tree
# stays byte-for-byte upstream (checked by tests/0.static.sh) so a future
# `vendor/update-vendor.sh` re-pin has a clean diff against upstream alone.
#
# Usage: render-profiles.sh [--inject-bad-efa-count <instance-type>]
#
# --inject-bad-efa-count is for this tool's own deliberate-failure Test Plan
# step only: it rewrites the named instance type's own EFA_COUNT field to one
# more than the real value, so a run against real hardware proves check 2
# (EFA enumeration) actually fails when the profile disagrees with the
# hardware -- not only that it passes when everything is correct. Never pass
# this flag for a real pre-flight.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_CONF="${BASE_DIR}/vendor/awsome-distributed-ai/instance-profiles.conf"
OVERLAY_CONF="${BASE_DIR}/profiles/g6e-overlay.conf"

INJECT_TYPE=""
case "${1:-}" in
    --inject-bad-efa-count)
        INJECT_TYPE="${2:?--inject-bad-efa-count needs an instance type}"
        ;;
    "") ;;
    *)
        echo "unknown argument: ${1}" >&2
        exit 2
        ;;
esac

[[ -f "${VENDOR_CONF}" ]] || { echo "missing ${VENDOR_CONF}" >&2; exit 1; }
[[ -f "${OVERLAY_CONF}" ]] || { echo "missing ${OVERLAY_CONF}" >&2; exit 1; }

if [[ -n "${INJECT_TYPE}" ]] && ! awk -F'|' -v t="${INJECT_TYPE}" '$1==t{found=1} END{exit !found}' "${VENDOR_CONF}" "${OVERLAY_CONF}"; then
    echo "--inject-bad-efa-count: no row for instance type '${INJECT_TYPE}' -- refusing to render a profile set that silently injects nothing" >&2
    exit 1
fi

cat "${VENDOR_CONF}" "${OVERLAY_CONF}" | awk -F'|' -v OFS='|' -v inj="${INJECT_TYPE}" '
/^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
{
    if (inj != "" && $1 == inj) {
        $3 = $3 + 1
        print "# TEST ONLY: EFA_COUNT bumped by +1 for --inject-bad-efa-count (" inj ")"
    }
    print
}'
