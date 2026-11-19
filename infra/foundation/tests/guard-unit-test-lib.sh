# shellcheck shell=bash
# Shared by guard-unit-tests.sh and network-guard-unit-tests.sh. Sourced, not
# executed.

# install_fake_sleep DIR: writes a no-op `sleep` into DIR. Both
# teardown-guard.sh and network-guard.sh poll with a real sleep between
# rounds, by design; unit tests of the logic around that polling must not
# pay the real wait.
install_fake_sleep() {
  cat >"$1/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
  chmod +x "$1/sleep"
}

# check LABEL DESCRIPTION COMMAND...
# Runs COMMAND (no shell re-parsing of its arguments - safe even if a
# guard's output or a call log contains shell metacharacters) and reports
# PASS/FAIL by its exit code. On FAIL, reads RC, OUT and CALL_LOG from the
# caller's scope to print context; the caller must set those before calling
# check, and must have declared `failures=0` beforehand.
check() {
  local label="$1" desc="$2"
  shift 2
  if "$@"; then
    echo "PASS ${label}: ${desc}"
  else
    echo "FAIL ${label}: ${desc}"
    echo "  exit=${RC} call_log=[$(tr '\n' ';' <"${CALL_LOG}")]"
    echo "  output: ${OUT}"
    failures=$((failures + 1))
  fi
}
