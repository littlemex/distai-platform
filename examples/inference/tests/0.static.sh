#!/usr/bin/env bash
# Static checks for examples/inference/ (vLLM prefill/decode disaggregation
# reference with its proxy and with the llm-d router, its aggregated
# baseline, and the shared scorer, load driver and dashboard): no AWS
# credentials needed, no cluster needed. Needs network access to fetch the
# pinned llm-d router chart dependency and the pinned upstream schemas.
#
#   1. every file the interface contract names exists at its exact path,
#      with a README per component;
#   2. bash -n and shellcheck on every *.sh under examples/inference/;
#   3. score.py and its tests: py_compile, ruff, then the stdlib unittest
#      suite (_shared/scorer/test_score.py) against score.py;
#   4. helm dependency build (charts with a Chart.lock), then helm lint and
#      helm template of every chart with default values (acceptance
#      criterion 1);
#   5. kubeconform of the rendered charts and of load-job.yaml against
#      pinned upstream schemas, including the Gateway API and Gateway API
#      Inference Extension CRD schemas for vllm/disagg-pd-llmd;
#   6. the placement/transport values contract (test_placement_transport.sh);
#   7. the Grafana dashboard (check_dashboard.py);
#   8. the load driver's own documented guarantees that are visible
#      without a cluster: in-cluster only (no port-forward), the
#      --max-send-lag-ms bound, the GC freeze, the before/after pod
#      snapshots.
#
# Every check prints PASS or FAIL. Exits non-zero if any failed.
#
# Optional environment:
#   HELM (helm), UV (uv), PYTHON (python3), SHELLCHECK (shellcheck),
#   PYTHON_YAML_VERSION (6.0.2), RUFF_VERSION (0.12.0),
#   KUBECONFORM_VERSION (0.8.0), K8S_SCHEMA_COMMIT (pinned below),
#   GATEWAY_API_VERSION (v1.6.2), GAIE_VERSION (v1.6.2).
set -euo pipefail

HELM="${HELM:-helm}"
UV="${UV:-uv}"
PYTHON="${PYTHON:-python3}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
PYTHON_YAML_VERSION="${PYTHON_YAML_VERSION:-6.0.2}"
RUFF_VERSION="${RUFF_VERSION:-0.12.0}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.8.0}"
# The same yannh/kubernetes-json-schema commit gitops/tests/0.static.sh
# pins (Kubernetes 1.37.0 standalone schemas).
K8S_SCHEMA_COMMIT="${K8S_SCHEMA_COMMIT:-11639286f15b208b6c7f1f93bc2c1a70f42cfbcb}"
# The CRD releases vllm/disagg-pd-llmd's README tells the administrator to
# install (the versions llm-d v1.0.0's guides/env.sh pins), with the
# sha256 of each release manifest as downloaded on 2026-11-22.
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.2}"
GATEWAY_API_SHA256="${GATEWAY_API_SHA256:-faede450fa178126aba41337737b97d351ebe87d93c910237ce1e072d1ca40d9}"
GAIE_VERSION="${GAIE_VERSION:-v1.6.2}"
GAIE_SHA256="${GAIE_SHA256:-f410dfca474608c02903087b47f1ac081706dfb6dfe7f83d00a7cc7e00c4ad0d}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFERENCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISAGG="${INFERENCE_ROOT}/vllm/disagg-pd"
LLMD="${INFERENCE_ROOT}/vllm/disagg-pd-llmd"
AGG="${INFERENCE_ROOT}/vllm/agg-baseline"
SGLANG_DISAGG="${INFERENCE_ROOT}/sglang/disagg-pd"
SGLANG_AGG="${INFERENCE_ROOT}/sglang/agg-baseline"
SCORER="${INFERENCE_ROOT}/_shared/scorer"
LOAD="${INFERENCE_ROOT}/_shared/load-replay"
DASHBOARD="${INFERENCE_ROOT}/_shared/dashboards/vllm-pd.json"
WORK_DIR="$(mktemp -d)"
RENDERED_DIR="${WORK_DIR}/rendered"
mkdir -p "${RENDERED_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT
# The unittest run below must not leave __pycache__ in the tree.
export PYTHONDONTWRITEBYTECODE=1

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
#
# Exact paths from the interface contract. A README per component is
# AGENTS.md section 3's "every component is self-contained" rule.

required_files=(
  "README.md"
  "vllm/disagg-pd/Chart.yaml"
  "vllm/disagg-pd/values.yaml"
  "vllm/disagg-pd/README.md"
  "vllm/disagg-pd-llmd/Chart.yaml"
  "vllm/disagg-pd-llmd/Chart.lock"
  "vllm/disagg-pd-llmd/values.yaml"
  "vllm/disagg-pd-llmd/README.md"
  "vllm/agg-baseline/Chart.yaml"
  "vllm/agg-baseline/values.yaml"
  "vllm/agg-baseline/README.md"
  "sglang/disagg-pd/Chart.yaml"
  "sglang/disagg-pd/values.yaml"
  "sglang/disagg-pd/README.md"
  "sglang/agg-baseline/Chart.yaml"
  "sglang/agg-baseline/values.yaml"
  "sglang/agg-baseline/README.md"
  "_shared/scorer/score.py"
  "_shared/scorer/test_score.py"
  "_shared/load-replay/run-load.sh"
  "_shared/load-replay/load-job.yaml"
  "_shared/dashboards/vllm-pd.json"
)
missing=()
for f in "${required_files[@]}"; do
  [[ -f "${INFERENCE_ROOT}/${f}" ]] || missing+=("${f}")
done
if [[ "${#missing[@]}" -eq 0 ]]; then
  pass "required files present (${#required_files[@]})"
else
  fail "required files missing under examples/inference/: ${missing[*]}"
fi

if [[ -f "${LOAD}/run-load.sh" && ! -x "${LOAD}/run-load.sh" ]]; then
  fail "_shared/load-replay/run-load.sh is not executable"
fi

# The goodput panel's feed must be a concrete mechanism documented in a
# README (the contract: Grafana cannot read a one-shot JSON file).
if grep -rqiE 'pushgateway|textfile' --include=README.md "${INFERENCE_ROOT}" 2>/dev/null; then
  pass "a README under examples/inference documents the goodput metric feed (pushgateway or textfile collector)"
else
  fail "no README under examples/inference documents how the scorer's goodput reaches Grafana (pushgateway or textfile collector)"
fi

# ------------------------------------------------- 2. shellcheck, bash -n

shell_scripts=()
while IFS= read -r s; do shell_scripts+=("${s}"); done < <(find "${INFERENCE_ROOT}" -name '*.sh' | sort)
if [[ "${#shell_scripts[@]}" -eq 0 ]]; then
  fail "no shell scripts found under examples/inference/"
else
  for s in "${shell_scripts[@]}"; do
    run_check "bash -n ${s#"${INFERENCE_ROOT}"/}" bash -n "${s}"
    run_check "shellcheck ${s#"${INFERENCE_ROOT}"/}" "${SHELLCHECK}" -x "${s}"
  done
fi

# -------------------------------------------------- 3. score.py and tests

python_files=()
while IFS= read -r p; do python_files+=("${p}"); done < <(find "${INFERENCE_ROOT}" -name '*.py' -not -path '*/__pycache__/*' | sort)
for p in "${python_files[@]}"; do
  run_check "py_compile ${p#"${INFERENCE_ROOT}"/}" "${PYTHON}" -c 'import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True, cfile=sys.argv[2])' "${p}" "${WORK_DIR}/pycompile.pyc"
done
if [[ "${#python_files[@]}" -gt 0 ]]; then
  run_check "ruff ${RUFF_VERSION} check" "${UV}" run --no-project -q --with "ruff==${RUFF_VERSION}" \
    ruff check --no-cache --select E,F,W,B --ignore E501 "${python_files[@]}"
fi
if [[ -f "${SCORER}/score.py" ]]; then
  # Stdlib + at most one common dependency (contract): anything else
  # imported at top level is a dependency the reader would have to install.
  run_check "score.py imports only the stdlib and at most numpy" "${PYTHON}" - "${SCORER}/score.py" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
mods = set()
for n in ast.walk(tree):
    if isinstance(n, ast.Import):
        mods |= {a.name.split(".")[0] for a in n.names}
    elif isinstance(n, ast.ImportFrom) and n.module and n.level == 0:
        mods.add(n.module.split(".")[0])
# sys.stdlib_module_names needs Python 3.10+; this runner's python3 is 3.9,
# where that attribute does not exist and getattr's () fallback would make
# every single import look non-stdlib. Fall back to a fixed set of modules
# that are stdlib in every CPython 3.x this chart's score.py is expected to
# run under, rather than silently accepting anything.
FALLBACK_STDLIB = {
    "argparse", "dataclasses", "json", "math", "sys", "typing", "os", "re",
    "io", "itertools", "functools", "collections", "statistics", "time",
    "datetime", "pathlib", "textwrap", "enum", "abc", "copy", "csv",
}
stdlib = set(getattr(sys, "stdlib_module_names", ())) or FALLBACK_STDLIB
extra = sorted(m for m in mods if m not in stdlib and m != "__future__")
if extra and extra != ["numpy"]:
    print(f"non-stdlib imports: {extra}")
    sys.exit(1)
PY
fi
run_check "score.py unit tests (unittest, stdlib only)" \
  "${PYTHON}" -m unittest discover -s "${SCORER}" -p 'test_*.py' -v

# ------------------------------------------- 4. helm lint, helm template

for chart in "${DISAGG}" "${AGG}" "${LLMD}" "${SGLANG_DISAGG}" "${SGLANG_AGG}"; do
  rel="${chart#"${INFERENCE_ROOT}"/}"
  [[ -f "${chart}/Chart.yaml" ]] || continue
  # A chart with a Chart.lock depends on another chart (disagg-pd-llmd on
  # llm-d's router chart): fetch exactly the locked version first.
  if [[ -f "${chart}/Chart.lock" ]]; then
    run_check "helm dependency build ${rel} (the versions in Chart.lock)" \
      "${HELM}" dependency build "${chart}"
  fi
  run_check "helm lint ${rel}" "${HELM}" lint "${chart}"
  # The output filename must be unique across every chart in this loop, not
  # just basename(chart): vllm/disagg-pd and sglang/disagg-pd both have
  # basename "disagg-pd", and a plain basename-only filename silently
  # overwrote one chart's rendered manifest with the other's, so
  # kubeconform below validated only the last one written for each
  # colliding name (confirmed: a run with both present rendered to only
  # as many files as there are distinct basenames, not distinct charts).
  rendered_name="${rel//\//-}"
  run_check "helm template ${rel} (default values)" \
    bash -c "'${HELM}' template contract-test '${chart}' --namespace contract-test > '${RENDERED_DIR}/${rendered_name}.yaml'"
done

# ------------------------------------------------------- 5. kubeconform

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

# Schemas for the custom resources disagg-pd-llmd renders (HTTPRoute,
# InferencePool), from the same pinned CRD release manifests its README
# installs, so a misspelled or misplaced field fails here as it would at
# apply time. kubeconform tries the built-in schema location first and this
# one for kinds that location does not have.
CRD_SCHEMA_DIR="${WORK_DIR}/crd-schemas"
fetch_pinned() {
  local url="$1" want="$2" out="$3" got
  curl -fsSL -o "${out}" "${url}" || return 1
  got="$(sha256sum "${out}" | awk '{print $1}')"
  [[ "${got}" == "${want}" ]] || { echo "checksum mismatch for ${url}: got ${got}, want ${want}"; return 1; }
}
if [[ -f "${LLMD}/Chart.yaml" ]]; then
  require_bin curl CURL
  require_bin sha256sum SHA256SUM
  run_check "Gateway API ${GATEWAY_API_VERSION} standard CRDs (pinned sha256)" fetch_pinned \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    "${GATEWAY_API_SHA256}" "${WORK_DIR}/gateway-api-crds.yaml"
  run_check "Gateway API Inference Extension ${GAIE_VERSION} CRDs (pinned sha256)" fetch_pinned \
    "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml" \
    "${GAIE_SHA256}" "${WORK_DIR}/gaie-crds.yaml"
  run_check "CRD manifests -> kubeconform JSON schemas" \
    "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
    python3 "${SCRIPT_DIR}/crd_to_jsonschema.py" --out "${CRD_SCHEMA_DIR}" \
    "${WORK_DIR}/gateway-api-crds.yaml" "${WORK_DIR}/gaie-crds.yaml"
fi

kubeconform_targets=()
for r in "${RENDERED_DIR}"/*.yaml; do [[ -s "${r}" ]] && kubeconform_targets+=("${r}"); done
[[ -f "${LOAD}/load-job.yaml" ]] && kubeconform_targets+=("${LOAD}/load-job.yaml")
if [[ "${#kubeconform_targets[@]}" -gt 0 ]]; then
  run_check "kubeconform (${#kubeconform_targets[@]} file(s), k8s 1.37.0, strict)" \
    "${KUBECONFORM_BIN}" -strict -summary -kubernetes-version 1.37.0 \
    -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${K8S_SCHEMA_COMMIT}/{{ .NormalizedKubernetesVersion }}-standalone{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
    -schema-location "${CRD_SCHEMA_DIR}/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
    "${kubeconform_targets[@]}"
else
  fail "nothing to run kubeconform on (no chart rendered, no load-job.yaml)"
fi

if [[ -f "${LOAD}/load-job.yaml" ]]; then
  if grep -qE '^kind:[[:space:]]*Job[[:space:]]*$' "${LOAD}/load-job.yaml"; then
    pass "load-job.yaml declares a Kubernetes Job"
  else
    fail "load-job.yaml declares no 'kind: Job'"
  fi
  if grep -qE 'image:.*:latest([[:space:]"]|$)' "${LOAD}/load-job.yaml"; then
    fail "load-job.yaml uses a :latest image tag"
  else
    pass "load-job.yaml pins its image (no :latest)"
  fi
fi

# ------------------------------------- 6. placement/transport contract

if [[ -f "${DISAGG}/Chart.yaml" && -f "${AGG}/Chart.yaml" && -f "${LLMD}/Chart.yaml" ]]; then
  run_check "placement/transport values contract" \
    env HELM="${HELM}" UV="${UV}" PYTHON_YAML_VERSION="${PYTHON_YAML_VERSION}" \
    bash "${SCRIPT_DIR}/test_placement_transport.sh"
else
  fail "placement/transport values contract: a chart is missing"
fi

# --------------------------------------------------------- 7. dashboard

if [[ -f "${DASHBOARD}" ]]; then
  run_check "dashboard vllm-pd.json" "${PYTHON}" "${SCRIPT_DIR}/check_dashboard.py" "${DASHBOARD}"
fi

# ------------------------------------------------------ 8. load driver

if [[ -f "${LOAD}/run-load.sh" ]]; then
  if grep -q -- 'port-forward' "${LOAD}/run-load.sh" "${LOAD}/load-job.yaml" 2>/dev/null; then
    fail "the load driver uses kubectl port-forward (the contract: in-cluster DNS only)"
  else
    pass "the load driver never port-forwards"
  fi
  if grep -q -- '--max-send-lag-ms' "${LOAD}/run-load.sh"; then
    pass "run-load.sh takes --max-send-lag-ms"
  else
    fail "run-load.sh has no --max-send-lag-ms option"
  fi
  if grep -qE 'get pods?[^|]*-o[[:space:]]*json' "${LOAD}/run-load.sh"; then
    pass "run-load.sh snapshots 'kubectl get pods -o json'"
  else
    fail "run-load.sh never takes a 'kubectl get pods -o json' snapshot"
  fi
  # Either the driver freezes and disables GC itself, or the README in
  # load-replay/ documents which vLLM-native switch does it instead.
  if grep -rqF 'gc.freeze' "${LOAD}" && grep -rqF 'gc.disable' "${LOAD}"; then
    pass "the load driver freezes and disables GC before the timed portion (or documents the vLLM-native switch that does)"
  else
    fail "_shared/load-replay never mentions both gc.freeze and gc.disable (the driver must call them, or its README must name the vLLM-native equivalent)"
  fi
fi

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all static checks passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
