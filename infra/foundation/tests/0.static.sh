#!/usr/bin/env bash
# Static checks for the foundation layer: formatting, validation and lint.
# Runs every check, prints PASS/FAIL per check and exits non-zero if any failed.
# No AWS credentials are needed; the backend is not initialised.
set -euo pipefail

TERRAFORM="${TERRAFORM:-terraform}"
TFLINT="${TFLINT:-tflint}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Keep provider downloads out of the module directory so that a later
# backend init (1.e2e.sh) starts clean.
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

for f in main.tf variables.tf outputs.tf versions.tf; do
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
run_check "terraform test (input validation, mocked provider)" "${TERRAFORM}" -chdir="${ROOT}" test
run_check "guard unit tests (scripted fake AWS CLI)" bash "${SCRIPT_DIR}/guard-unit-tests.sh"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all static checks passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
