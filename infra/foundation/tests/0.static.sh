#!/usr/bin/env bash
# Static checks for the foundation layer: formatting, validation and lint.
# Runs every check, prints PASS/FAIL per check and exits non-zero if any failed.
# No AWS credentials are needed; the backend is not initialised.
set -euo pipefail

TERRAFORM="${TERRAFORM:-terraform}"
TFLINT="${TFLINT:-tflint}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"

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
require_bin "${SHELLCHECK}" SHELLCHECK

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
run_check "network guard unit tests (scripted fake AWS CLI)" bash "${SCRIPT_DIR}/network-guard-unit-tests.sh"
# Issue #56/#57: this is this new file's own static check, not a blanket
# shellcheck of every *.sh in this directory. Both infra/foundation/tests/1.e2e.sh
# and infra/foundation/tests/2.e2e-partial-apply.sh already carry a
# pre-existing SC1091 (confirmed: `shellcheck -x` against each prints it),
# and 1.e2e.sh also carries SC2034 for a VPC_ID assigned but never read
# directly in that file (the same pattern 3.tenancy-primitive.sh's own
# comments explain for itself) -- neither this PR nor this check touches
# or claims either file clean. Widening this to `find ... -name '*.sh'` the
# way gitops/tests/0.static.sh does would make this check start failing
# on that unrelated, pre-existing pair, which this PR does not fix.
run_check "shellcheck 3.tenancy-primitive.sh" "${SHELLCHECK}" -x "${SCRIPT_DIR}/3.tenancy-primitive.sh"
# Issue #22/#57: same reasoning as 3.tenancy-primitive.sh's own line
# above -- this new file's own static check only, not a widened glob.
run_check "shellcheck 4.argocd-impersonation.sh" "${SHELLCHECK}" -x "${SCRIPT_DIR}/4.argocd-impersonation.sh"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all static checks passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
