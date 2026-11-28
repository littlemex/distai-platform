#!/usr/bin/env bash
# Shared plumbing for this tool's shell checks (lib/checks/*.sh). Sourced,
# not executed. lib/checks/1-neff-compile-load-check.py writes the same
# result schema itself (see write_result there); keep the two in step.
#
# Result schema, one file per check, RESULTS_DIR/check-<name>.json:
#   check      the check's own name, e.g. "0-neuron-ls"
#   status     PASS, WARN or FAIL (lib/aggregate-results.py treats anything
#              else as FAIL)
#   message    one human-readable line
#   evidence   the raw output the verdict was read from, verbatim
#   node       NODE_NAME (the Job sets it from spec.nodeName), or ""
#   instance_type  INSTANCE_TYPE, or ""
#   timestamp  UTC, ISO 8601

# write_result <check> <status> <message> [evidence]
# Writes RESULTS_DIR/check-<check>.json and prints one "[STATUS] check:
# message" line. Returns 2 (and writes nothing) for an unknown status or an
# unset RESULTS_DIR, so a typo in a check cannot produce a result file the
# aggregator would have to guess about.
write_result() {
    local check="$1" status="$2" message="$3" evidence="${4:-}"
    if [[ -z "${RESULTS_DIR:-}" ]]; then
        echo "[common.sh] write_result: RESULTS_DIR is not set" >&2
        return 2
    fi
    case "${status}" in
        PASS | WARN | FAIL) ;;
        *)
            echo "[common.sh] write_result: unknown status '${status}' for ${check}" >&2
            return 2
            ;;
    esac
    mkdir -p "${RESULTS_DIR}"
    # JSON is written by python3 (present in the Job's base image and on
    # the static-check runner), not by hand-escaping in bash: evidence is
    # arbitrary tool output, including quotes, backslashes and newlines.
    CHECK="${check}" STATUS="${status}" MESSAGE="${message}" EVIDENCE="${evidence}" \
        python3 - "${RESULTS_DIR}/check-${check}.json" <<'PYEOF' || return 2
import datetime
import json
import os
import sys

doc = {
    "check": os.environ["CHECK"],
    "status": os.environ["STATUS"],
    "message": os.environ["MESSAGE"],
    "evidence": os.environ["EVIDENCE"],
    "node": os.environ.get("NODE_NAME", ""),
    "instance_type": os.environ.get("INSTANCE_TYPE", ""),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PYEOF
    echo "[${status}] ${check}: ${message}"
}

# require_int <name> <value>
# Fails (returns 1) unless value is a non-negative integer with no leading
# zero (0 itself is the only value allowed to start with 0). Every caller of
# this value later does an arithmetic comparison (bash's `-ne`/`-gt`, not a
# string compare), and bash's arithmetic evaluator reads a leading-zero
# operand as octal: "08" is not valid octal and raises
# "value too great for base" from inside `[[ ... ]]` itself (not a subshell
# this script's own `set -uo pipefail` would catch), and "010" would
# silently compare as 8, not 10. Rejecting a leading zero here, in the one
# place every EXPECTED_* value passes through, keeps that failure mode out
# of every check script rather than requiring each one to re-guard it.
require_int() {
    local name="$1" value="$2"
    if [[ ! "${value}" =~ ^(0|[1-9][0-9]*)$ ]]; then
        echo "[common.sh] ${name}='${value}' is not a non-negative integer with no leading zero" >&2
        return 1
    fi
}
