#!/usr/bin/env bash
# Unit tests for infra/foundation/scripts/network-guard.sh against a
# scripted fake `aws` CLI: no AWS credentials, no network calls, each case
# runs in well under a second (a no-op `sleep` on the PATH removes the
# guard's real waits). These exercise paths the real end-to-end tests
# (1.e2e.sh, 2.e2e-partial-apply.sh) do not reach, because they never leave
# a cluster behind, never leave an interface attached, and never need a
# second attempt at deleting the security group: refusing while a cluster
# with this name still exists, waiting out (and timing out on) interfaces
# that never become detached, retrying the security group delete on
# DependencyViolation, and treating NotFound on it as already gone.
#
# Each case checks the guard's exit code and log output, and, through
# CALL_LOG, which `ec2 delete-network-interface`/`ec2 delete-security-group`
# calls the fake `aws` actually saw - a case that only checks a log line
# could still pass if the guard logged an action without taking it.
#
# Prints PASS/FAIL per case and exits non-zero if any failed.
# Run from this directory: ./network-guard-unit-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDS_DIR="$(cd "${SCRIPT_DIR}/../scripts" && pwd)"

FAKE_BIN="$(mktemp -d)"
CALL_LOG="$(mktemp)"
SG_DELETE_ATTEMPTS_FILE="$(mktemp)"
trap 'rm -rf "${FAKE_BIN}"; rm -f "${CALL_LOG}" "${SG_DELETE_ATTEMPTS_FILE}"' EXIT

# A no-op sleep: network-guard.sh polls with a real 15s sleep between
# rounds, by design, up to 40 rounds (10 minutes). These are unit tests of
# its logic and must not pay that real wait; MAX_POLLS still bounds the
# fake loop to a fixed, small number of fast iterations.
cat >"${FAKE_BIN}/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod +x "${FAKE_BIN}/sleep"

# Scripted fake of the AWS CLI. Reads each call's canned result from an
# environment variable the test case sets. ACCOUNT_ID is read directly from
# the environment network-guard.sh itself requires, so require_cell_account
# sees a matching account without a separate variable for it. CALL_LOG
# records every delete-network-interface/delete-security-group call the
# guard actually makes. SG_DELETE_ATTEMPTS_FILE counts delete-security-group
# calls, so FAKE_SG_DELETE_RESULT can differ by attempt (DependencyViolation
# then success).
cat >"${FAKE_BIN}/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail
service="$1"; action="$2"
case "${service} ${action}" in
  "sts get-caller-identity")
    echo "${ACCOUNT_ID}"
    ;;
  "eks describe-cluster")
    if [[ "${FAKE_CLUSTER_EXISTS:-0}" == "1" ]]; then
      echo "ACTIVE"
    else
      echo "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found for name: ${CLUSTER_NAME}." >&2
      exit 254
    fi
    ;;
  "ec2 describe-network-interfaces")
    if [[ "$*" == *"group-id"* ]]; then
      echo "${FAKE_SG_USERS:-}"
    elif [[ "$*" == *"status,Values=available"* ]]; then
      echo "${FAKE_DETACHED_ENIS:-}"
    else
      echo "${FAKE_REMAINING_ENIS:-}"
    fi
    ;;
  "ec2 delete-network-interface")
    echo "delete-network-interface $4" >>"${CALL_LOG}"
    exit 0
    ;;
  "ec2 describe-security-groups")
    echo "${FAKE_SG_LIST:-}"
    ;;
  "ec2 delete-security-group")
    attempt=0
    [[ -s "${SG_DELETE_ATTEMPTS_FILE}" ]] && attempt="$(cat "${SG_DELETE_ATTEMPTS_FILE}")"
    attempt=$((attempt + 1))
    echo "${attempt}" >"${SG_DELETE_ATTEMPTS_FILE}"
    echo "delete-security-group $4 attempt${attempt}" >>"${CALL_LOG}"
    case "${FAKE_SG_DELETE_RESULTS:-success}" in
      dependency-then-success)
        if [[ "${attempt}" -eq 1 ]]; then
          echo "An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation: resource has a dependent object." >&2
          exit 254
        fi
        ;;
      not-found)
        echo "An error occurred (InvalidGroup.NotFound) when calling the DeleteSecurityGroup operation: The security group '$4' does not exist." >&2
        exit 254
        ;;
      always-dependency-violation)
        echo "An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation: resource has a dependent object." >&2
        exit 254
        ;;
    esac
    ;;
  *)
    echo "fake aws: unhandled call: $*" >&2
    exit 1
    ;;
esac
FAKE_AWS
chmod +x "${FAKE_BIN}/aws"

failures=0

# run_guard: runs network-guard.sh with CALL_LOG and the attempt counter
# reset first, PATH pointed at the fakes. Sets OUT and RC.
run_guard() {
  : >"${CALL_LOG}"
  : >"${SG_DELETE_ATTEMPTS_FILE}"
  set +e
  OUT="$(PATH="${FAKE_BIN}:${PATH}" bash "${GUARDS_DIR}/network-guard.sh" 2>&1)"
  RC=$?
  set -e
}

# check LABEL DESCRIPTION COMMAND...
# Runs COMMAND (no shell re-parsing of its arguments - safe even if OUT or a
# call log contains shell metacharacters) and reports PASS/FAIL by its exit
# code.
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

export CLUSTER_NAME=test-cluster ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 \
  VPC_ID=vpc-0123456789abcdef0 CALL_LOG SG_DELETE_ATTEMPTS_FILE

# Case A: a cluster with this name still exists. Must refuse: exit 1, log
# it, and delete nothing - this is the safety property that keeps the guard
# from touching a cluster it does not own the teardown of.
export FAKE_CLUSTER_EXISTS=1 FAKE_DETACHED_ENIS="" FAKE_REMAINING_ENIS="" FAKE_SG_LIST="" FAKE_SG_DELETE_RESULTS="success"
run_guard
check "cluster still exists" "exit 1" test "${RC}" -eq 1
check "cluster still exists" "refuses" grep -qF "refusing to remove its network resources" <<<"${OUT}"
check "cluster still exists" "deletes nothing" test ! -s "${CALL_LOG}"

# Case B: the ordinary path - cluster gone, no interfaces, one security
# group found and deleted on the first attempt. Checked by CALL_LOG, not
# only a log line.
export FAKE_CLUSTER_EXISTS=0 FAKE_DETACHED_ENIS="" FAKE_REMAINING_ENIS="" \
  FAKE_SG_LIST="sg-0123456789abcdef0" FAKE_SG_DELETE_RESULTS="success"
run_guard
check "ordinary path" "exit 0" test "${RC}" -eq 0
check "ordinary path" "logs done" grep -qF "done" <<<"${OUT}"
check "ordinary path" "calls delete-security-group once" bash -c '[ "$(cat "$1")" = "delete-security-group sg-0123456789abcdef0 attempt1" ]' _ "${CALL_LOG}"

# Case C: interfaces that never become detached (FAKE_REMAINING_ENIS is
# never empty). Must time out: exit non-zero, log the IDs still present,
# and never reach the security group step (CALL_LOG empty).
export FAKE_CLUSTER_EXISTS=0 FAKE_DETACHED_ENIS="" \
  FAKE_REMAINING_ENIS="eni-0a1b2c3d4e5f60789	in-use" FAKE_SG_LIST="" FAKE_SG_DELETE_RESULTS="success"
run_guard
check "interfaces never settle" "exit non-zero" test "${RC}" -ne 0
check "interfaces never settle" "logs the IDs still present" grep -qF "VPC CNI network interfaces still present" <<<"${OUT}"
check "interfaces never settle" "never reaches delete-security-group" test ! -s "${CALL_LOG}"

# Case D: the security group is in use when first tried (DependencyViolation)
# and gone the next time something else finishes using it. Must retry and
# succeed: exit 0, two delete-security-group calls for the same group.
export FAKE_CLUSTER_EXISTS=0 FAKE_DETACHED_ENIS="" FAKE_REMAINING_ENIS="" \
  FAKE_SG_LIST="sg-0123456789abcdef0" FAKE_SG_DELETE_RESULTS="dependency-then-success" FAKE_SG_USERS=""
run_guard
check "security group retried" "exit 0" test "${RC}" -eq 0
check "security group retried" "retries after DependencyViolation" grep -qF "still in use; retrying" <<<"${OUT}"
check "security group retried" "calls delete-security-group twice" bash -c '[ "$(cat "$1")" = "delete-security-group sg-0123456789abcdef0 attempt1
delete-security-group sg-0123456789abcdef0 attempt2" ]' _ "${CALL_LOG}"

# Case E: the security group is already gone (NotFound) - another process,
# or EKS itself, removed it first. Must treat this as done, not fatal.
export FAKE_CLUSTER_EXISTS=0 FAKE_DETACHED_ENIS="" FAKE_REMAINING_ENIS="" \
  FAKE_SG_LIST="sg-0123456789abcdef0" FAKE_SG_DELETE_RESULTS="not-found"
run_guard
check "security group already gone" "exit 0" test "${RC}" -eq 0
check "security group already gone" "logs already gone" grep -qF "already gone: sg-0123456789abcdef0" <<<"${OUT}"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all network guard unit tests passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
