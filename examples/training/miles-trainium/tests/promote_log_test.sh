#!/usr/bin/env bash
# A pure-bash, no-AWS unit test for 0.verify.sh's own promote_log() function (PHASE 7's log
# capture), extracted verbatim from that script rather than copied by hand -- so this test can
# never silently drift from what actually ships. Exercises exactly the case a round of review
# found broken in an earlier version: a short, non-empty capture (a client-side kubectl error
# after the pod is gone) must not overwrite an earlier, fuller capture; only a genuinely fuller
# capture, or the very first one, may promote.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SH="${SCRIPT_DIR}/../0.verify.sh"

RUN_LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${RUN_LOG_DIR}"' EXIT

# Extract promote_log()'s own definition (from the line starting "promote_log()" to its closing
# brace) and load only that function -- not the rest of 0.verify.sh, which needs AWS/kubectl/
# terraform and real environment variables this test does not set.
promote_log_src="$(sed -n '/^promote_log() {$/,/^}$/p' "${VERIFY_SH}")"
[[ -n "${promote_log_src}" ]] || { echo "FAIL: could not find promote_log() in ${VERIFY_SH} -- this test's own extraction broke, not necessarily the function itself"; exit 1; }
eval "${promote_log_src}"

failures=0
check() {
  local label="$1" want="$2" got="$3"
  if [[ "${want}" == "${got}" ]]; then
    echo "PASS ${label} (${got} lines)"
  else
    echo "FAIL ${label}: wanted ${want} lines, got ${got}"
    failures=$((failures + 1))
  fi
}
line_count() { [[ -f "${RUN_LOG_DIR}/job.log" ]] && wc -l <"${RUN_LOG_DIR}/job.log" | tr -d ' ' || echo 0; }

# 1. The first capture (job.log does not exist yet) always promotes.
printf 'line1\nline2\nline3\nline4\nline5\n' >"${RUN_LOG_DIR}/c1"
promote_log "${RUN_LOG_DIR}/c1"
check "first capture promotes" 5 "$(line_count)"

# 2. A short, non-empty capture (the bug this test exists to catch: a one-line client-side
# error such as kubectl's own "Error from server (NotFound)" after the pod is gone) must not
# overwrite the fuller capture already in job.log.
printf 'Error from server (NotFound)\n' >"${RUN_LOG_DIR}/c2"
promote_log "${RUN_LOG_DIR}/c2"
check "short non-empty capture does not overwrite" 5 "$(line_count)"

# 3. An empty capture (stdout empty because the error went to a separate stderr file instead,
# as 0.verify.sh's own relaunch_logs/final capture do) must not overwrite it either.
: >"${RUN_LOG_DIR}/c3"
promote_log "${RUN_LOG_DIR}/c3"
check "empty capture does not overwrite" 5 "$(line_count)"

# 4. A genuinely fuller capture (the container kept running and produced more output) does
# promote -- the fix must not become "never promote again".
printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\n' >"${RUN_LOG_DIR}/c4"
promote_log "${RUN_LOG_DIR}/c4"
check "a genuinely fuller capture promotes" 7 "$(line_count)"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: promote_log behaves correctly on all 4 cases"
else
  echo "RESULT FAIL: ${failures} case(s) failed"
  exit 1
fi
