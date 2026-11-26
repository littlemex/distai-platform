# shellcheck shell=bash
# Helpers shared by infra/identities/tests/1.e2e.sh. Sourced, not executed.
# Deliberately not shared with infra/foundation/tests/e2e-lib.sh: that file
# reads foundation-specific globals (VPC_ID, the VPC/ENI/NAT leftover
# kinds) this layer has no use for, and infra/identities must not need
# anything under infra/foundation/ to run its own test (the two roots stay
# independently plannable, issue #8's own acceptance criterion).
#
# Reads these globals of the calling script at call time:
#   TEST_TAG_KEY, RUN_ID   the run tag this test applies to every resource
#                          it creates directly (IAM roles, the S3 bucket)
#   FAILED_STEP            set by fail()

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
pass() { log "PASS $*"; }
fail() {
  # Read by the calling script's EXIT trap.
  # shellcheck disable=SC2034
  FAILED_STEP="$*"
  log "FAIL $*"
  exit 1
}
info() { log "INFO $*"; }

wait_until() {
  local timeout="$1" interval="$2" desc="$3"
  shift 3
  local start now
  start="$(date +%s)"
  while true; do
    if "$@"; then
      return 0
    fi
    now="$(date +%s)"
    if ((now - start >= timeout)); then
      log "timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep "${interval}"
  done
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "prerequisite: $1 not found"
}

# aws_text CMD ARGS...: same contract as infra/foundation/tests/e2e-lib.sh's
# own aws_text (a "*.NotFound*"/NotFoundException error reads as "nothing
# found", any other error is a hard failure the caller must fail() on).
aws_text() {
  local out err errfile ok=1
  errfile="$(mktemp)"
  if ! out="$("$@" 2>"${errfile}")"; then
    ok=0
  fi
  err="$(cat "${errfile}")"
  rm -f "${errfile}"
  if [[ "${ok}" -eq 1 ]]; then
    printf '%s' "${out}"
    return 0
  fi
  if [[ "${err}" == *".NotFound"* || "${err}" == *"NotFoundException"* || "${err}" == *"NoSuchEntity"* || "${err}" == *"NoSuchBucket"* ]]; then
    return 0
  fi
  printf '%s: %s' "$*" "${err}"
  return 1
}

# no_role_left ROLE_NAME: true if the IAM role no longer exists.
no_role_left() {
  local out
  if ! out="$(aws_text aws iam get-role --role-name "$1" --query Role.RoleName --output text)"; then
    fail "checking for leftover IAM role $1: ${out}"
  fi
  [[ -z "${out}" ]]
}

# no_bucket_left BUCKET: true if the S3 bucket no longer exists.
no_bucket_left() {
  local out
  if ! out="$(aws_text aws s3api head-bucket --bucket "$1" 2>&1)"; then
    fail "checking for leftover S3 bucket $1: ${out}"
  fi
  true
}

# no_role_tagged_for_run: true if no IAM role anywhere in the account still
# carries this run's own tag (TEST_TAG_KEY=RUN_ID) - the independent sweep
# that does not rely on this script's own list of role names, the same
# "describe by tag, do not trust your own bookkeeping" shape
# infra/foundation/tests/e2e-lib.sh's list_leftover uses for EC2 resources.
no_role_tagged_for_run() {
  local out
  if ! out="$(aws_text aws iam list-roles --query "Roles[?Tags[?Key=='${TEST_TAG_KEY}' && Value=='${RUN_ID}']].RoleName" --output text)"; then
    fail "checking for IAM roles tagged ${TEST_TAG_KEY}=${RUN_ID}: ${out}"
  fi
  [[ -z "${out}" || "${out}" == "None" ]]
}
