#!/usr/bin/env bash
# Static checks for the identities layer: formatting, validation and lint.
# Runs every check, prints PASS/FAIL per check and exits non-zero if any
# failed. No AWS credentials are needed; the backend is not initialised.
# Mirrors infra/foundation/tests/0.static.sh.
set -euo pipefail

TERRAFORM="${TERRAFORM:-terraform}"
TFLINT="${TFLINT:-tflint}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Keep provider downloads out of the module directory so that a later
# backend init starts clean.
TF_DATA_DIR="$(mktemp -d)"
export TF_DATA_DIR
trap 'rm -rf "${TF_DATA_DIR}"' EXIT

failures=0

run_check() {
  local label="$1"
  shift
  echo "--- ${label}: $*"
  if "$@"; then
    echo "PASS ${label}"
  else
    echo "FAIL ${label}"
    failures=$((failures + 1))
  fi
}

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FAIL $1 not found (set $2 to its path)"
    exit 1
  fi
}

require_bin "${TERRAFORM}" TERRAFORM
require_bin "${TFLINT}" TFLINT
require_bin "${SHELLCHECK}" SHELLCHECK

for f in main.tf variables.tf outputs.tf versions.tf identities.tf; do
  if [[ ! -f "${ROOT}/${f}" ]]; then
    echo "FAIL ${ROOT}/${f} is missing"
    failures=$((failures + 1))
  fi
done

run_check "terraform fmt" "${TERRAFORM}" -chdir="${ROOT}" fmt -check -recursive -diff
run_check "terraform init" "${TERRAFORM}" -chdir="${ROOT}" init -backend=false -input=false
run_check "terraform validate" "${TERRAFORM}" -chdir="${ROOT}" validate
run_check "tflint init" "${TFLINT}" --chdir="${ROOT}" --init
run_check "tflint" "${TFLINT}" --chdir="${ROOT}"
run_check "terraform test (input validation and IAM-shape assertions, mocked provider)" "${TERRAFORM}" -chdir="${ROOT}" test
# Both e2e scripts, unlike infra/foundation/tests/0.static.sh's own choice
# not to blanket-shellcheck 1.e2e.sh/2.e2e-partial-apply.sh there (those
# two carry pre-existing findings this repository has not fixed): these two
# are new with this change and start clean, so they are checked from day
# one instead of being added to a list of known-dirty exceptions.
run_check "shellcheck 1.e2e.sh" "${SHELLCHECK}" -x "${SCRIPT_DIR}/1.e2e.sh"
run_check "shellcheck e2e-lib.sh" "${SHELLCHECK}" -x "${SCRIPT_DIR}/e2e-lib.sh"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all static checks passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
