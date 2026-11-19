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
# Prints PASS/FAIL per case and exits non-zero if any failed.
# Run from this directory: ./guard-unit-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDS_DIR="$(cd "${SCRIPT_DIR}/../scripts" && pwd)"

FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "${FAKE_BIN}"' EXIT

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
# sees a matching account without a separate variable for it.
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
    if [[ "${FAKE_PROFILES_RESULT:-}" == "NoSuchEntity" ]]; then
      echo "An error occurred (NoSuchEntity) when calling the ListInstanceProfilesForRole operation: The role with name ${NODE_ROLE_NAME} cannot be found." >&2
      exit 254
    fi
    echo "${FAKE_PROFILES_RESULT:-}"
    ;;
  "iam list-instance-profile-tags")
    if [[ "${FAKE_TAGS_RESULT:-}" == "NoSuchEntity" ]]; then
      echo "An error occurred (NoSuchEntity) when calling the ListInstanceProfileTags operation: Instance profile not found." >&2
      exit 254
    fi
    echo "${FAKE_TAGS_RESULT:-}"
    ;;
  "iam remove-role-from-instance-profile" | "iam delete-instance-profile")
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

# run_case LABEL EXPECT_EXIT EXPECT_SUBSTRING COMMAND...
# FAKE_* variables are set as a prefix on the call to this function, so they
# are exported only for the one case being run.
run_case() {
  local label="$1" expect_exit="$2" expect_grep="$3"
  shift 3
  local out rc
  set +e
  out="$(PATH="${FAKE_BIN}:${PATH}" "$@" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne "${expect_exit}" ]]; then
    echo "FAIL ${label}: exit ${rc}, expected ${expect_exit}"
    echo "${out}"
    failures=$((failures + 1))
    return
  fi
  if ! grep -qF "${expect_grep}" <<<"${out}"; then
    echo "FAIL ${label}: output does not contain '${expect_grep}'"
    echo "${out}"
    failures=$((failures + 1))
    return
  fi
  echo "PASS ${label}"
}

export CLUSTER_NAME=test-cluster ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 \
  VPC_ID=vpc-0123456789abcdef0 NODE_ROLE_NAME=test-cluster-karpenter-node

# issue #26: the node role itself was already deleted by the time this guard
# reached step 4.
FAKE_PROFILES_RESULT="NoSuchEntity" \
  run_case "node role already gone (issue #26)" 0 "already gone: node role" \
  bash "${GUARDS_DIR}/teardown-guard.sh"

# The same failure one step later: the role still exists and lists one
# profile, but that profile was deleted between being listed and being read
# again.
FAKE_PROFILES_RESULT="test-profile" FAKE_TAGS_RESULT="NoSuchEntity" \
  run_case "instance profile already gone" 0 "already gone: instance profile test-profile" \
  bash "${GUARDS_DIR}/teardown-guard.sh"

# Regression check: the ordinary path (a profile Karpenter owns) still gets
# deleted, so the two fixes above did not come at the cost of this one.
FAKE_PROFILES_RESULT="owned-profile" FAKE_TAGS_RESULT="owned" \
  run_case "owned instance profile still deleted" 0 "deleting instance profile owned-profile" \
  bash "${GUARDS_DIR}/teardown-guard.sh"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all guard unit tests passed"
else
  echo "RESULT FAIL: ${failures} case(s) failed"
  exit 1
fi
