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
#   NAME                   cell name; every role name-prefix sweep below is
#                           scoped to it
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
# Not routed through aws_text's generic NotFound-shaped patterns: a HEAD
# request carries no response body, so on a gone bucket the AWS CLI's own
# error text for this specific call is "An error occurred (404) ... Not
# Found", never ".NotFound"/"NotFoundException"/"NoSuchBucket" - confirmed
# against a real run, which found aws_text's generic patterns did not
# match this call's own wording either way (a bucket that still existed
# also read as "gone", because head-bucket's own success produces no
# output for aws_text to distinguish from a recognized NotFound string).
no_bucket_left() {
  local err
  if err="$(aws s3api head-bucket --bucket "$1" 2>&1)"; then
    return 1
  fi
  if [[ "${err}" == *"404"* || "${err}" == *"Not Found"* || "${err}" == *"NoSuchBucket"* ]]; then
    return 0
  fi
  fail "checking for leftover S3 bucket $1: ${err}"
}

# no_role_tagged_for_run: true if no IAM role whose name starts with this
# cell's own NAME still carries this run's own tag (TEST_TAG_KEY=RUN_ID).
# Not account-wide by tag alone: IAM's own ListRoles response never
# includes Tags at all (confirmed against the API's own documentation,
# "ListRoles... does not return... Tags"), and the Resource Groups Tagging
# API's GetResources returned an empty result for a role confirmed, by a
# direct GetRole call, to carry a real tag (confirmed on a real account,
# 2026-11-26) - IAM roles are not actually discoverable through either of
# those two tag-search mechanisms. This instead lists every role name
# under this cell's own prefix (every role this script, or a bug in it,
# could plausibly have created shares that prefix: the derived
# "<cluster_name>-identity-<key>" names and the simulated legacy role,
# "<NAME>-legacy-imagebuilder") and calls GetRole (which does return Tags)
# on each candidate.
no_role_tagged_for_run() {
  local role_names role_name tags
  if ! role_names="$(aws_text aws iam list-roles --query "Roles[?starts_with(RoleName, '${NAME}')].RoleName" --output text)"; then
    fail "listing IAM roles under prefix ${NAME}: ${role_names}"
  fi
  for role_name in ${role_names}; do
    [[ "${role_name}" == "None" || -z "${role_name}" ]] && continue
    if ! tags="$(aws_text aws iam get-role --role-name "${role_name}" --query "Role.Tags[?Key=='${TEST_TAG_KEY}' && Value=='${RUN_ID}']" --output text)"; then
      fail "checking tags on IAM role ${role_name}: ${tags}"
    fi
    [[ -z "${tags}" || "${tags}" == "None" ]] || return 1
  done
  return 0
}
