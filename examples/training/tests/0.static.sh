#!/usr/bin/env bash
# Static checks for examples/training/ (issue #34's worked example: a
# JobSet-based PyTorch DDP recipe admitted through Kueue, with EFA/NCCL
# environment, a group-restart failurePolicy and checkpoint/resume to
# Amazon S3 through a ServiceAccount meant for an EKS Pod Identity
# association): no AWS credentials needed, no cluster needed. Needs
# network access only for kubeconform's pinned schemas (and kubeconform
# itself, if it is not on PATH).
#
#   1. the files issue #34 and AGENTS.md section 3 name exist (a README
#      per component);
#   2. bash -n and shellcheck on every *.sh under examples/training/;
#   3. py_compile and ruff on every *.py under examples/training/ (the
#      training script included, wherever the chart keeps it);
#   4. check_training_render.py --selftest (the render checks are seen to
#      fail on what they claim to catch before they are trusted green);
#   5. helm lint, and helm template of examples/training/pytorch-ddp with
#      the test values (chart-contract.sh) twice: the default replica
#      count, and the two-node variant (replicas 2) the issue says is "the
#      only difference";
#   6. check_training_render.py on both renders: one JobSet
#      (jobset.x-k8s.io/v1alpha2) carrying the kueue.x-k8s.io/queue-name
#      label it was given, failurePolicy BlockingRecreate with
#      maxRestarts >= 1, one replicatedJob with backoffLimit 0, a torchrun
#      container requesting an accelerator with FI_PROVIDER=efa and NCCL_*
#      env, the given ServiceAccount rendered with no IRSA annotation, the
#      given bucket/prefix reaching the container, Pod Security
#      "restricted", pinned images, every rendered kind creatable by
#      gitops/bootstrap/team-onboard.sh step 3's own deployer Role, and the
#      JobSet valid against gitops/charts/jobset-crd's vendored CRD schema;
#   7. kubeconform -strict of the built-in kinds in both renders (the
#      JobSet itself is validated against its own CRD by step 6);
#   8. the training code prints the resume line 1.e2e.sh greps for
#      (TRAINING_RESUME_LOG_REGEX in chart-contract.sh).
#
# Every check prints PASS or FAIL. Exits non-zero if any failed.
#
# Optional environment:
#   HELM (helm), UV (uv), PYTHON (python3), SHELLCHECK (shellcheck),
#   PYTHON_YAML_VERSION (6.0.2), JSONSCHEMA_VERSION (4.23.0),
#   RUFF_VERSION (0.12.0), KUBECONFORM_VERSION (0.8.0),
#   K8S_SCHEMA_COMMIT (pinned below).
set -euo pipefail

HELM="${HELM:-helm}"
UV="${UV:-uv}"
PYTHON="${PYTHON:-python3}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
PYTHON_YAML_VERSION="${PYTHON_YAML_VERSION:-6.0.2}"
JSONSCHEMA_VERSION="${JSONSCHEMA_VERSION:-4.23.0}"
RUFF_VERSION="${RUFF_VERSION:-0.12.0}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.8.0}"
# The same yannh/kubernetes-json-schema commit gitops/tests/0.static.sh
# and examples/inference/tests/0.static.sh pin (Kubernetes 1.37.0).
K8S_SCHEMA_COMMIT="${K8S_SCHEMA_COMMIT:-11639286f15b208b6c7f1f93bc2c1a70f42cfbcb}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRAINING_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TRAINING_ROOT}/../.." && pwd)"
CHART="${TRAINING_ROOT}/pytorch-ddp"
TEAM_ONBOARD="${REPO_ROOT}/gitops/bootstrap/team-onboard.sh"
WORK_DIR="$(mktemp -d)"
RENDERED_DIR="${WORK_DIR}/rendered"
mkdir -p "${RENDERED_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT
export PYTHONDONTWRITEBYTECODE=1

# shellcheck source=chart-contract.sh
. "${SCRIPT_DIR}/chart-contract.sh"

# The values every render below is given, and the values
# check_training_render.py then looks for in the rendered objects.
STATIC_QUEUE="static-check-queue"
STATIC_SERVICE_ACCOUNT="static-check-trainer"
STATIC_BUCKET="static-check-bucket"
STATIC_PREFIX="static-check/prefix"

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
pass() { echo "PASS $*"; }
fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}
require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FAIL $1 not found (set $2 to its path)"
    exit 1
  }
}

require_bin "${HELM}" HELM
require_bin "${UV}" UV
require_bin "${PYTHON}" PYTHON
require_bin "${SHELLCHECK}" SHELLCHECK

# ---------------------------------------------------- 1. required files

required_files=(
  "README.md"
  "pytorch-ddp/Chart.yaml"
  "pytorch-ddp/values.yaml"
  "pytorch-ddp/README.md"
  "tests/README.md"
  "tests/chart-contract.sh"
  "tests/check_training_render.py"
  "tests/1.e2e.sh"
)
missing=()
for f in "${required_files[@]}"; do
  [[ -f "${TRAINING_ROOT}/${f}" ]] || missing+=("${f}")
done
if [[ "${#missing[@]}" -eq 0 ]]; then
  pass "required files present (${#required_files[@]})"
else
  fail "required files missing under examples/training/: ${missing[*]}"
fi
if [[ -f "${SCRIPT_DIR}/1.e2e.sh" && ! -x "${SCRIPT_DIR}/1.e2e.sh" ]]; then
  fail "tests/1.e2e.sh is not executable"
fi

# ------------------------------------------------- 2. shellcheck, bash -n

shell_scripts=()
while IFS= read -r s; do shell_scripts+=("${s}"); done < <(find "${TRAINING_ROOT}" -name '*.sh' | sort)
if [[ "${#shell_scripts[@]}" -eq 0 ]]; then
  fail "no shell scripts found under examples/training/"
else
  for s in "${shell_scripts[@]}"; do
    run_check "bash -n ${s#"${TRAINING_ROOT}"/}" bash -n "${s}"
    # -P SCRIPTDIR: this script and 1.e2e.sh both `source` chart-contract.sh
    # via "${SCRIPT_DIR}/chart-contract.sh" (a dynamic path shellcheck
    # cannot resolve against the caller's own cwd once invoked with an
    # absolute path from outside this directory, as the EC2 runner does;
    # confirmed: the same invocation with a relative path from inside this
    # directory needs no extra flag at all) -- SCRIPTDIR is shellcheck's own
    # token for "the directory containing the file being checked", not a
    # literal path, and fixes the follow for every script here, not only
    # one.
    run_check "shellcheck ${s#"${TRAINING_ROOT}"/}" "${SHELLCHECK}" -x -P SCRIPTDIR "${s}"
  done
fi

# ---------------------------------------------------- 3. python sources

python_files=()
while IFS= read -r p; do python_files+=("${p}"); done < <(find "${TRAINING_ROOT}" -name '*.py' -not -path '*/__pycache__/*' | sort)
for p in "${python_files[@]}"; do
  run_check "py_compile ${p#"${TRAINING_ROOT}"/}" "${PYTHON}" -c 'import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True, cfile=sys.argv[2])' "${p}" "${WORK_DIR}/pycompile.pyc"
done
if [[ "${#python_files[@]}" -gt 0 ]]; then
  run_check "ruff ${RUFF_VERSION} check" "${UV}" run --no-project -q --with "ruff==${RUFF_VERSION}" \
    ruff check --no-cache --select E,F,W,B --ignore E501 "${python_files[@]}"
fi

# --------------------------------------------- 4. render checks self-test

run_check "training render checks self-test (check_training_render.py --selftest)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_training_render.py" --selftest

# ------------------------------------------- 5. helm lint, helm template

STATIC_SETS=(
  --set-string "${TRAINING_KEY_QUEUE_NAME}=${STATIC_QUEUE}"
  --set-string "${TRAINING_KEY_SERVICE_ACCOUNT}=${STATIC_SERVICE_ACCOUNT}"
  --set-string "${TRAINING_KEY_CHECKPOINT_BUCKET}=${STATIC_BUCKET}"
  --set-string "${TRAINING_KEY_CHECKPOINT_PREFIX}=${STATIC_PREFIX}"
)
# Each render: label, extra helm args, the replica count to expect ("" =
# the chart's own default, not compared).
renders=(
  "default-replicas||"
  "two-node|--set ${TRAINING_KEY_REPLICAS}=2|2"
)
if [[ -f "${CHART}/Chart.yaml" ]]; then
  if [[ -f "${CHART}/Chart.lock" ]]; then
    run_check "helm dependency build pytorch-ddp (the versions in Chart.lock)" "${HELM}" dependency build "${CHART}"
  fi
  run_check "helm lint pytorch-ddp (test values)" "${HELM}" lint "${CHART}" "${STATIC_SETS[@]}"
  for r in "${renders[@]}"; do
    IFS='|' read -r r_label r_args r_replicas <<<"${r}"
    # shellcheck disable=SC2086 # r_args is zero or two words, by construction above
    run_check "helm template pytorch-ddp (${r_label})" \
      bash -c '"$@" > "'"${RENDERED_DIR}/pytorch-ddp-${r_label}.yaml"'"' _ \
      "${HELM}" template ddp-static "${CHART}" --namespace static-check "${STATIC_SETS[@]}" ${r_args}
  done
else
  fail "examples/training/pytorch-ddp/Chart.yaml is missing; nothing to render"
fi

# ------------------------------------------------ 6. rendered-object checks

JOBSET_CRD=""
crd_candidates=()
while IFS= read -r c; do crd_candidates+=("${c}"); done < <(find "${REPO_ROOT}/gitops/charts/jobset-crd/crds" -name '*.yaml' 2>/dev/null | sort)
if [[ "${#crd_candidates[@]}" -eq 1 ]]; then
  JOBSET_CRD="${crd_candidates[0]}"
else
  fail "expected exactly one vendored JobSet CRD under gitops/charts/jobset-crd/crds/ (found ${#crd_candidates[@]}); the JobSet schema check needs it"
fi

for r in "${renders[@]}"; do
  IFS='|' read -r r_label _ r_replicas <<<"${r}"
  rendered="${RENDERED_DIR}/pytorch-ddp-${r_label}.yaml"
  [[ -s "${rendered}" ]] || { fail "no rendered manifest for ${r_label} (helm template failed above)"; continue; }
  args=("${rendered}" --queue "${STATIC_QUEUE}" --service-account "${STATIC_SERVICE_ACCOUNT}"
    --bucket "${STATIC_BUCKET}" --prefix "${STATIC_PREFIX}" --team-onboard "${TEAM_ONBOARD}")
  [[ -n "${r_replicas}" ]] && args+=(--replicas "${r_replicas}")
  [[ -n "${JOBSET_CRD}" ]] && args+=(--jobset-crd "${JOBSET_CRD}")
  run_check "rendered objects (${r_label}, check_training_render.py)" \
    "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" --with "jsonschema==${JSONSCHEMA_VERSION}" \
    python3 "${SCRIPT_DIR}/check_training_render.py" "${args[@]}"
done

# ------------------------------------------------------- 7. kubeconform

KUBECONFORM_BIN="${WORK_DIR}/kubeconform"
if command -v kubeconform >/dev/null 2>&1; then
  KUBECONFORM_BIN="$(command -v kubeconform)"
else
  require_bin curl CURL
  require_bin sha256sum SHA256SUM
  # Same pinned release and checksum as gitops/tests/0.static.sh.
  KUBECONFORM_SHA256="9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883"
  curl -fsSL -o "${WORK_DIR}/kubeconform.tar.gz" \
    "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz"
  got_sha256="$(sha256sum "${WORK_DIR}/kubeconform.tar.gz" | awk '{print $1}')"
  if [[ "${got_sha256}" != "${KUBECONFORM_SHA256}" ]]; then
    echo "FAIL kubeconform v${KUBECONFORM_VERSION} checksum mismatch: got ${got_sha256}, want ${KUBECONFORM_SHA256}"
    exit 1
  fi
  tar -xzf "${WORK_DIR}/kubeconform.tar.gz" -C "${WORK_DIR}" kubeconform
  chmod 0755 "${KUBECONFORM_BIN}"
fi
kubeconform_targets=()
for f in "${RENDERED_DIR}"/*.yaml; do [[ -s "${f}" ]] && kubeconform_targets+=("${f}"); done
if [[ "${#kubeconform_targets[@]}" -gt 0 ]]; then
  # -skip JobSet: no pinned schema catalog carries it; step 6 validated it
  # against the vendored CRD's own schema instead, with undeclared fields
  # rejected the same way -strict rejects them here.
  run_check "kubeconform (${#kubeconform_targets[@]} file(s), k8s 1.37.0, strict, JobSet checked in step 6)" \
    "${KUBECONFORM_BIN}" -strict -summary -kubernetes-version 1.37.0 -skip JobSet \
    -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${K8S_SCHEMA_COMMIT}/{{ .NormalizedKubernetesVersion }}-standalone{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
    "${kubeconform_targets[@]}"
else
  fail "nothing to run kubeconform on (no chart rendered)"
fi

# --------------------------------------------- 8. the resume log contract

# 1.e2e.sh step 4 proves "resumed, not restarted from scratch" by finding
# this line in the restarted Pods' logs; a script that never prints it
# would make that step time out on real hardware instead of failing here.
# Looked for in every file of the chart (the script may live in files/,
# in a ConfigMap template, or as a Python file next to it).
if [[ -d "${CHART}" ]] && grep -rqF "${TRAINING_RESUME_LOG_PREFIX}" "${CHART}"; then
  pass "the chart's training code prints the resume line 1.e2e.sh greps for ('${TRAINING_RESUME_LOG_REGEX}')"
else
  fail "no file under examples/training/pytorch-ddp/ contains '${TRAINING_RESUME_LOG_PREFIX}' -- the training script must log the step it resumed from (tests/chart-contract.sh's TRAINING_RESUME_LOG_REGEX)"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all static checks passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
