#!/usr/bin/env bash
# Unit tests for infra/foundation/scripts/teardown-guard.sh against a
# scripted fake `aws` CLI: no AWS credentials, no network calls, each case
# runs in well under a second. These exercise error handling that the real
# end-to-end tests (1.e2e.sh, 2.e2e-partial-apply.sh) cannot reach on
# demand, because it needs a specific AWS API error at a specific moment -
# in particular, something else (another destroy of the same cell, or an
# operator) deleting the node role or one of its instance profiles between
# the guard listing it and reading it again. Seen for real: exit 254 on
# list-instance-profiles-for-role after the node role had already been
# deleted, right after the guard had just finished terminating every
# instance (us-east-1, 2026-11-20; see issue #26).
#
# Each case checks both the guard's exit code and log output, and, through
# CALL_LOG, which of remove-role-from-instance-profile/delete-instance-profile
# the fake `aws` actually saw - a case that only checks a log line could
# still pass if the guard logged "deleting ..." without ever calling delete.
#
# Prints PASS/FAIL per case and exits non-zero if any failed.
# Run from this directory: ./guard-unit-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDS_DIR="$(cd "${SCRIPT_DIR}/../scripts" && pwd)"

FAKE_BIN="$(mktemp -d)"
CALL_LOG="$(mktemp)"
trap 'rm -rf "${FAKE_BIN}"; rm -f "${CALL_LOG}"' EXIT

# A no-op sleep: teardown-guard.sh sleeps 15s once, by design, to see "no
# instances" twice before concluding none are left (see its comment). These
# are unit tests of the IAM instance-profile step (step 4) and must not pay
# that real wait.
cat >"${FAKE_BIN}/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod +x "${FAKE_BIN}/sleep"

# Scripted fake of the AWS CLI. Reads each call's canned result from an
# environment variable the test case sets; everything the guard needs
# before step 4 (sts, the three "nothing to find" describe calls) is fixed,
# since these cases are about step 4 only. ACCOUNT_ID is read directly from
# the environment teardown-guard.sh itself requires, so require_cell_account
# sees a matching account without a separate variable for it. CALL_LOG
# records every remove-role-from-instance-profile/delete-instance-profile
# call the guard actually makes, by profile name, so a case can assert a
# delete did or did not happen, not only that a log line was printed.
cat >"${FAKE_BIN}/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail
service="$1"; action="$2"
case "${service} ${action}" in
  "sts get-caller-identity")
    echo "${ACCOUNT_ID}"
    ;;
  "ec2 describe-instances" | "ec2 describe-network-interfaces" | "ec2 describe-launch-templates")
    echo ""
    ;;
  "iam list-instance-profiles-for-role")
    case "${FAKE_PROFILES_RESULT:-}" in
      NoSuchEntity)
        echo "An error occurred (NoSuchEntity) when calling the ListInstanceProfilesForRole operation: The role with name ${NODE_ROLE_NAME} cannot be found." >&2
        exit 254
        ;;
      AccessDenied)
        echo "An error occurred (AccessDenied) when calling the ListInstanceProfilesForRole operation: User is not authorized to perform iam:ListInstanceProfilesForRole." >&2
        exit 254
        ;;
    esac
    echo "${FAKE_PROFILES_RESULT:-}"
    ;;
  "iam list-instance-profile-tags")
    case "${FAKE_TAGS_RESULT:-}" in
      NoSuchEntity)
        echo "An error occurred (NoSuchEntity) when calling the ListInstanceProfileTags operation: Instance profile not found." >&2
        exit 254
        ;;
      AccessDenied)
        echo "An error occurred (AccessDenied) when calling the ListInstanceProfileTags operation: User is not authorized to perform iam:ListInstanceProfileTags." >&2
        exit 254
        ;;
    esac
    echo "${FAKE_TAGS_RESULT:-}"
    ;;
  "iam remove-role-from-instance-profile")
    echo "remove-role-from-instance-profile $4" >>"${CALL_LOG}"
    exit 0
    ;;
  "iam delete-instance-profile")
    echo "delete-instance-profile $4" >>"${CALL_LOG}"
    exit 0
    ;;
  *)
    echo "fake aws: unhandled call: $*" >&2
    exit 1
    ;;
esac
FAKE_AWS
chmod +x "${FAKE_BIN}/aws"

failures=0

# run_guard: runs teardown-guard.sh with CALL_LOG reset to empty first, PATH
# pointed at the fakes, and prints combined stdout+stderr. Sets OUT and RC.
run_guard() {
  : >"${CALL_LOG}"
  set +e
  OUT="$(PATH="${FAKE_BIN}:${PATH}" bash "${GUARDS_DIR}/teardown-guard.sh" 2>&1)"
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
  VPC_ID=vpc-0123456789abcdef0 NODE_ROLE_NAME=test-cluster-karpenter-node CALL_LOG

# Case 1 (issue #26): the node role itself was already deleted by the time
# this guard reached step 4. Must exit 0, log it, and delete nothing (there
# is nothing under a role that does not exist).
export FAKE_PROFILES_RESULT="NoSuchEntity" FAKE_TAGS_RESULT=""
run_guard
check "node role already gone (issue #26)" "exit 0" test "${RC}" -eq 0
check "node role already gone (issue #26)" "logs it" grep -qF "already gone: node role" <<<"${OUT}"
check "node role already gone (issue #26)" "deletes nothing" test ! -s "${CALL_LOG}"

# Case 2: the role still exists and lists one profile, but that profile was
# deleted between being listed and being read again. Must exit 0, log it,
# and delete nothing (that one profile is skipped).
export FAKE_PROFILES_RESULT="test-profile" FAKE_TAGS_RESULT="NoSuchEntity"
run_guard
check "instance profile already gone" "exit 0" test "${RC}" -eq 0
check "instance profile already gone" "logs it" grep -qF "already gone: instance profile test-profile" <<<"${OUT}"
check "instance profile already gone" "deletes nothing" test ! -s "${CALL_LOG}"

# Case 3 (regression check): the ordinary path, a profile Karpenter owns,
# still gets removed from the role and deleted - the two fixes above did not
# come at the cost of this one. Checked by CALL_LOG, not only by the log
# line: a guard that logs "deleting ..." without calling delete must fail
# this.
export FAKE_PROFILES_RESULT="owned-profile" FAKE_TAGS_RESULT="owned"
run_guard
check "owned instance profile still deleted" "exit 0" test "${RC}" -eq 0
check "owned instance profile still deleted" "calls remove-role-from-instance-profile" grep -qF "remove-role-from-instance-profile owned-profile" "${CALL_LOG}"
check "owned instance profile still deleted" "calls delete-instance-profile" grep -qF "delete-instance-profile owned-profile" "${CALL_LOG}"

# Case 4: an error that is not NoSuchEntity (here, AccessDenied) must still
# be fatal - the fix above must not have turned step 4 into "every error is
# fine". Must exit non-zero, must not claim "already gone", must delete
# nothing.
export FAKE_PROFILES_RESULT="AccessDenied" FAKE_TAGS_RESULT=""
run_guard
check "other IAM error stays fatal (list-instance-profiles-for-role)" "exit non-zero" test "${RC}" -ne 0
check "other IAM error stays fatal (list-instance-profiles-for-role)" "does not claim already gone" bash -c '! grep -qF "already gone" <<<"$1"' _ "${OUT}"
check "other IAM error stays fatal (list-instance-profiles-for-role)" "deletes nothing" test ! -s "${CALL_LOG}"

# Case 5: same as case 4, one level later - the role lists one profile, but
# reading its tags fails with a non-NoSuchEntity error. Must still be
# fatal: the fix at this call site must not have turned it into "every
# error is fine" either.
export FAKE_PROFILES_RESULT="test-profile" FAKE_TAGS_RESULT="AccessDenied"
run_guard
check "other IAM error stays fatal (list-instance-profile-tags)" "exit non-zero" test "${RC}" -ne 0
check "other IAM error stays fatal (list-instance-profile-tags)" "does not claim already gone" bash -c '! grep -qF "already gone" <<<"$1"' _ "${OUT}"
check "other IAM error stays fatal (list-instance-profile-tags)" "deletes nothing" test ! -s "${CALL_LOG}"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all guard unit tests passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
