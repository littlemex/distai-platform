#!/usr/bin/env bash
# Static checks for the gitops/ delivery layer (issue #25): no AWS
# credentials needed, no cluster needed.
#
#   1. required files and directories exist, scoped to this PR's first-PR
#      content (decision 9: no accelerators/, no teams/*);
#   2. shellcheck and `bash -n` on every *.sh under gitops/;
#   3. yamllint on every literal (non-templated) tracked YAML file;
#   4. the structural contract of every addon.yaml / cells parameter file,
#      both ApplicationSets and the root Application, against decisions
#      1, 2, 3, 4, 6 and 8 of the issue (check_gitops_contract.py);
#   5. `helm lint` and `helm template` of charts/capacity-pool and
#      charts/smoke, each against one real cells/*/{capacity-pool,smoke}/*.yaml
#      parameter file's own `values:`; charts/accel-device-classes (#28)
#      against its own chart defaults, since nothing in it varies per cell;
#   5b. issue #27's values shapes, from tests/fixtures/<chart>/*.yaml:
#      `helm lint` and `helm template` of each fixture; seven fixtures
#      that must be refused (a reserved pool with no reservation tags, an
#      unknown pool.capacityType, a capacity-type entry inside
#      pool.requirements, an invalid instanceMatchCriteria, an invalid
#      taint effect, a duplicate taint key+effect, an empty tag value)
#      fail `helm template`; and the rendered objects' own fields checked
#      by check_chart_renders.py, including the unchanged `on-demand`
#      default pool and default smoke queue, whose fields must be
#      identical to this chart's pre-#27 shape at the field level (not a
#      byte-level comparison: a checked-in golden file breaks on an
#      unrelated base-branch rebase or a different Helm version, neither
#      of which is a field regression, with no way to tell the two apart
#      from a byte diff alone; the field-level check below asserts what
#      the acceptance criterion actually cares about instead);
#   6. kubeconform of the rendered chart output (including every 5b
#      fixture), both ApplicationSets and the root Application, against
#      pinned upstream + CRD-catalog schemas;
#   7. every pinned add-on's own exact chart version (never a generic,
#      multi-version schema catalog) is `helm template`-d fresh and its
#      real CustomResourceDefinitions extracted, to check that the
#      rendered charts/{capacity-pool,smoke} output only uses an
#      apiVersion that pinned chart version actually serves
#      (check_pinned_crds.py; needs network access to each add-on's own
#      OCI registry, the same one Argo CD itself pulls from).
#
# Every check prints PASS or FAIL. Exits non-zero if any failed.
#
# Required: none (uses whatever NAME-independent fixtures are checked in).
# Optional environment:
#   HELM (helm), UV (uv), PYTHON_YAML_VERSION (6.0.2), YAMLLINT_VERSION (1.38.0),
#   KUBECONFORM_VERSION (0.8.0), K8S_SCHEMA_COMMIT, CRD_CATALOG_COMMIT
#   (both default to the commits pinned below; override only to re-pin).
set -euo pipefail

HELM="${HELM:-helm}"
UV="${UV:-uv}"
PYTHON_YAML_VERSION="${PYTHON_YAML_VERSION:-6.0.2}"
YAMLLINT_VERSION="${YAMLLINT_VERSION:-1.38.0}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.8.0}"
# yannh/kubernetes-json-schema@master, resolved 2026-11-19: the directory
# layout for Kubernetes 1.37.0's standard schemas.
K8S_SCHEMA_COMMIT="${K8S_SCHEMA_COMMIT:-11639286f15b208b6c7f1f93bc2c1a70f42cfbcb}"
# datreeio/CRDs-catalog@main, resolved 2026-11-19: Argo CD (Application,
# ApplicationSet, AppProject), Karpenter (NodePool, EC2NodeClass) and Kueue
# (ClusterQueue, ResourceFlavor, LocalQueue) schemas this PR's charts and
# manifests need and no other source bundles.
CRD_CATALOG_COMMIT="${CRD_CATALOG_COMMIT:-784ec895547a36e548e6810b41f27baade3a0890}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${GITOPS_ROOT}/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

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
  command -v "$1" >/dev/null 2>&1 || {
    echo "FAIL $1 not found (set $2 to its path)"
    exit 1
  }
}

require_bin "${HELM}" HELM
require_bin "${UV}" UV
require_bin curl CURL
require_bin sha256sum SHA256SUM
require_bin shellcheck SHELLCHECK

# ---------------------------------------------------- 1. required files

required_files=(
  "bootstrap/bootstrap.sh"
  "bootstrap/root-application.yaml"
  "appsets/platform.ApplicationSet.yaml"
  "appsets/cells.ApplicationSet.yaml"
  "addons/karpenter-crd/addon.yaml"
  "addons/karpenter/addon.yaml"
  "addons/kueue/addon.yaml"
  "addons/accel-nvidia-device-plugin/addon.yaml"
  "addons/accel-nvidia-dra/addon.yaml"
  "addons/accel-neuron-device-plugin/addon.yaml"
  "addons/accel-neuron-dra/addon.yaml"
  "addons/accel-device-classes/addon.yaml"
  "charts/capacity-pool/Chart.yaml"
  "charts/accel-device-classes/Chart.yaml"
  "charts/smoke/Chart.yaml"
)
missing=()
for f in "${required_files[@]}"; do
  [[ -f "${GITOPS_ROOT}/${f}" ]] || missing+=("${f}")
done
if [[ "${#missing[@]}" -eq 0 ]]; then
  echo "PASS required files present"
else
  echo "FAIL required files missing: ${missing[*]}"
  failures=$((failures + 1))
fi

mapfile -t cell_capacity_pool_files < <(find "${GITOPS_ROOT}/cells" -path '*/capacity-pool/*.yaml' 2>/dev/null | sort)
mapfile -t cell_smoke_files < <(find "${GITOPS_ROOT}/cells" -path '*/smoke/*.yaml' 2>/dev/null | sort)
if [[ "${#cell_capacity_pool_files[@]}" -ge 1 ]]; then
  echo "PASS at least one cells/*/capacity-pool/*.yaml exists"
else
  echo "FAIL no cells/*/capacity-pool/*.yaml found"
  failures=$((failures + 1))
fi
if [[ "${#cell_smoke_files[@]}" -ge 1 ]]; then
  echo "PASS at least one cells/*/smoke/*.yaml exists"
else
  echo "FAIL no cells/*/smoke/*.yaml found"
  failures=$((failures + 1))
fi

# ------------------------------------------------- 2. shellcheck, bash -n

mapfile -t shell_scripts < <(find "${GITOPS_ROOT}" -name '*.sh' | sort)
if [[ "${#shell_scripts[@]}" -eq 0 ]]; then
  echo "FAIL no shell scripts found under gitops/ (expected at least bootstrap/bootstrap.sh)"
  failures=$((failures + 1))
else
  for s in "${shell_scripts[@]}"; do
    run_check "bash -n $(basename "${s}")" bash -n "${s}"
  done
  run_check "shellcheck every *.sh under gitops/" shellcheck -x "${shell_scripts[@]}"
fi

# ---------------------------------------------------------- 3. yamllint

mapfile -t literal_yaml_files < <(
  {
    find "${GITOPS_ROOT}/addons" -name 'addon.yaml'
    find "${GITOPS_ROOT}/cells" -path '*/capacity-pool/*.yaml' -o -path '*/smoke/*.yaml' -o -path '*/teams/*.yaml'
    find "${GITOPS_ROOT}/appsets" -name '*.yaml'
    find "${GITOPS_ROOT}/bootstrap" -name '*.yaml'
    find "${GITOPS_ROOT}/charts" -maxdepth 2 -name 'Chart.yaml' -o -maxdepth 2 -name 'values.yaml'
    find "${SCRIPT_DIR}/fixtures" -name '*.yaml'
  } 2>/dev/null | sort -u
)
if [[ "${#literal_yaml_files[@]}" -eq 0 ]]; then
  echo "FAIL no literal YAML files found to lint"
  failures=$((failures + 1))
else
  # yamllint>=1.38.0 requires Python>=3.10 (its own packaging metadata);
  # the runner image's own system Python (AL2023's dnf-provided 3.9) does
  # not satisfy that, so `uv run` must ask for a newer interpreter
  # explicitly - uv then downloads and caches a standalone build itself,
  # the same way it resolves any other `--with` dependency, rather than
  # failing resolution against whichever Python happened to be on PATH.
  run_check "yamllint ${#literal_yaml_files[@]} file(s)" \
    "${UV}" run --no-project -q --python 3.12 --with "yamllint==${YAMLLINT_VERSION}" \
    yamllint -c "${SCRIPT_DIR}/.yamllint.yaml" --strict "${literal_yaml_files[@]}"
fi

# ---------------------------------------------- 4. gitops contract checks

run_check "gitops contract (check_gitops_contract.py)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_gitops_contract.py" "${REPO_ROOT}"

# -------------------------------------- 4b. issue #27's contract checks
#
# The tracked tree ships no reserved pool and no cell with two queues, so
# the reserved/duplicate-addon checks added for issue #27 never run against
# real content above (confirmed: a dead check still prints PASS on an empty
# input). Each case below copies the real repo into a throwaway directory,
# adds exactly one cell parameter file exercising one rule, and runs
# check_gitops_contract.py against the copy -- never against the tracked
# tree, so nothing here is committed.

contract_copy_with() {
  # contract_copy_with DEST REL_PATH CONTENT: copies REPO_ROOT into DEST,
  # writes CONTENT to DEST/REL_PATH (parent directories created).
  local dest="$1" rel="$2" content="$3"
  rm -rf "${dest}"
  mkdir -p "${dest}"
  cp -r "${REPO_ROOT}/gitops" "${dest}/gitops"
  mkdir -p "$(dirname "${dest}/${rel}")"
  printf '%s' "${content}" >"${dest}/${rel}"
}
run_contract_check_on() {
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
    python3 "${SCRIPT_DIR}/check_gitops_contract.py" "$1"
}

RESERVED_OK_DIR="${WORK_DIR}/contract-reserved-ok"
contract_copy_with "${RESERVED_OK_DIR}" "gitops/cells/contract-check/capacity-pool/cpu-rsv.yaml" \
'addon: capacity-pool-cpu-rsv
wave: capacity
dir: gitops/charts/capacity-pool
namespace: kube-system
values:
  pool:
    name: cpu-rsv
    capacityType: reserved
  reservation:
    tags:
      distai-platform-contract-check: "1"
'
if run_contract_check_on "${RESERVED_OK_DIR}" >"${WORK_DIR}/contract-reserved-ok.log" 2>&1; then
  if grep -q "values.pool.capacityType is one of" "${WORK_DIR}/contract-reserved-ok.log" \
    && grep -q "sets a non-empty values.reservation.tags" "${WORK_DIR}/contract-reserved-ok.log" \
    && grep -q "instanceMatchCriteria is 'targeted'" "${WORK_DIR}/contract-reserved-ok.log"; then
    echo "PASS check_gitops_contract.py's reserved-pool checks ran and passed against a valid -rsv cell file"
  else
    echo "FAIL check_gitops_contract.py passed but did not print the issue #27 reserved-pool checks (still dead code)"
    failures=$((failures + 1))
  fi
else
  echo "FAIL check_gitops_contract.py rejected a valid reserved pool: $(cat "${WORK_DIR}/contract-reserved-ok.log")"
  failures=$((failures + 1))
fi

contract_bad_cases=(
  "empty-tags|values:\n  pool:\n    name: cpu-rsv\n    capacityType: reserved\n  reservation:\n    tags: {}\n|sets a non-empty values.reservation.tags"
  "open-match|values:\n  pool:\n    name: cpu-rsv\n    capacityType: reserved\n  reservation:\n    tags: {k: v}\n    instanceMatchCriteria: open\n|instanceMatchCriteria is .targeted."
  "bad-enum|values:\n  pool:\n    name: cpu-rsv\n    capacityType: spot\n|values.pool.capacityType is one of"
)
for case in "${contract_bad_cases[@]}"; do
  IFS='|' read -r case_name case_values case_pattern <<<"${case}"
  dest="${WORK_DIR}/contract-${case_name}"
  contract_copy_with "${dest}" "gitops/cells/contract-check/capacity-pool/cpu-rsv.yaml" \
    "$(printf 'addon: capacity-pool-cpu-rsv\nwave: capacity\ndir: gitops/charts/capacity-pool\nnamespace: kube-system\n%b' "${case_values}")"
  if run_contract_check_on "${dest}" >"${WORK_DIR}/contract-${case_name}.log" 2>&1; then
    echo "FAIL check_gitops_contract.py passed a cell file that must fail (${case_name})"
    failures=$((failures + 1))
  elif grep -qE "^FAIL gitops/cells/contract-check/capacity-pool/cpu-rsv\.yaml.*${case_pattern}" "${WORK_DIR}/contract-${case_name}.log"; then
    echo "PASS check_gitops_contract.py rejected the ${case_name} cell file on the expected check"
  else
    echo "FAIL check_gitops_contract.py rejected the ${case_name} cell file, but not on the expected check (pattern: ${case_pattern}): $(cat "${WORK_DIR}/contract-${case_name}.log")"
    failures=$((failures + 1))
  fi
done

DUP_ADDON_DIR="${WORK_DIR}/contract-dup-addon"
contract_copy_with "${DUP_ADDON_DIR}" "gitops/cells/example-cell/smoke/second.yaml" \
'addon: smoke
wave: capacity
dir: gitops/charts/smoke
namespace: distai-smoke
values:
  clusterQueue:
    resourceFlavor: cpu
'
if run_contract_check_on "${DUP_ADDON_DIR}" >"${WORK_DIR}/contract-dup-addon.log" 2>&1; then
  echo "FAIL check_gitops_contract.py passed two parameter files with the same addon value in one cell"
  failures=$((failures + 1))
elif grep -q "unique addon values" "${WORK_DIR}/contract-dup-addon.log"; then
  echo "PASS check_gitops_contract.py rejected two parameter files with the same addon value in one cell"
else
  echo "FAIL check_gitops_contract.py rejected the duplicate-addon cell, but not on the expected check: $(cat "${WORK_DIR}/contract-dup-addon.log")"
  failures=$((failures + 1))
fi

# ----------------------------------------------- 5. helm lint and template

RENDERED_DIR="${WORK_DIR}/rendered"
mkdir -p "${RENDERED_DIR}"

# A real cells/*/capacity-pool/*.yaml and cells/*/smoke/*.yaml parameter
# file's own `values:` block is the only place this PR's actual, checked-in
# input to each chart lives (decision 2: "static values: for anything not
# cell-specific"); extracting it keeps this test from inventing a second,
# untracked set of example values that could drift from what a real cell
# renders. A parameter file's `valuesFrom:` entries (decision 2) are
# resolved only by cells.ApplicationSet.yaml's templatePatch, from the
# Cluster generator's own params or the registration Secret's annotations
# - neither exists outside a real cluster, so this check cannot supply the
# real value. It fills each entry's own `helmKey` path with an inert
# placeholder instead of leaving it unset, so `helm template` still
# exercises the chart's structure (its `required()` guards, selectors and
# so on) rather than this check silently skipping every chart that happens
# to need a cell-specific input.
extract_values() {
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" python3 - "$1" "$2" <<'PY'
import sys
import yaml
path, out = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    doc = yaml.safe_load(f)
doc = doc or {}
values = doc.get("values", {}) or {}

def set_path(d, dotted_key, value):
    parts = dotted_key.split(".")
    cur = d
    for p in parts[:-1]:
        cur = cur.setdefault(p, {})
    cur[parts[-1]] = value

for entry in doc.get("valuesFrom", []) or []:
    set_path(values, entry["helmKey"], "static-check-placeholder")

with open(out, "w", encoding="utf-8") as f:
    yaml.safe_dump(values, f)
PY
}

# #28: loop over every cells/*/capacity-pool/*.yaml and cells/*/smoke/*.yaml
# parameter file, not only the first in sorted order -- issue #28 added a
# second and third pair (dp-a19-gpu, dp-a19-trn) whose own values
# (pool.labels, a widened pool.requirements) are exactly the content a
# single-file check would never render or kubeconform. Each file's own
# cell/pool name keeps its rendered output from colliding with another's
# in RENDERED_DIR.
if [[ "${#cell_capacity_pool_files[@]}" -ge 1 ]]; then
  run_check "helm lint charts/capacity-pool" "${HELM}" lint "${GITOPS_ROOT}/charts/capacity-pool"
  for cp_file in "${cell_capacity_pool_files[@]}"; do
    cp_label="$(basename "$(dirname "$(dirname "${cp_file}")")")-$(basename "${cp_file}" .yaml)"
    CP_VALUES="${WORK_DIR}/capacity-pool-values-${cp_label}.yaml"
    extract_values "${cp_file}" "${CP_VALUES}"
    run_check "helm template charts/capacity-pool (values from ${cp_label}/$(basename "${cp_file}"))" \
      bash -c "'${HELM}' template capacity-pool-e2e '${GITOPS_ROOT}/charts/capacity-pool' -f '${CP_VALUES}' > '${RENDERED_DIR}/capacity-pool-${cp_label}.yaml'"
  done
fi
if [[ "${#cell_smoke_files[@]}" -ge 1 ]]; then
  run_check "helm lint charts/smoke" "${HELM}" lint "${GITOPS_ROOT}/charts/smoke"
  for smoke_file in "${cell_smoke_files[@]}"; do
    smoke_label="$(basename "$(dirname "$(dirname "${smoke_file}")")")-$(basename "${smoke_file}" .yaml)"
    SMOKE_VALUES="${WORK_DIR}/smoke-values-${smoke_label}.yaml"
    extract_values "${smoke_file}" "${SMOKE_VALUES}"
    run_check "helm template charts/smoke (values from ${smoke_label}/$(basename "${smoke_file}"))" \
      bash -c "'${HELM}' template smoke-e2e '${GITOPS_ROOT}/charts/smoke' -f '${SMOKE_VALUES}' > '${RENDERED_DIR}/smoke-${smoke_label}.yaml'"
  done
fi

# charts/accel-device-classes (#28) has no cell-specific values (one
# cluster-scoped DeviceClass, nothing varies per cell) and no
# cells/*/*.yaml parameter file to extract values from -- helm lint/
# template run against the chart's own defaults only.
if [[ -f "${GITOPS_ROOT}/charts/accel-device-classes/Chart.yaml" ]]; then
  run_check "helm lint charts/accel-device-classes" "${HELM}" lint "${GITOPS_ROOT}/charts/accel-device-classes"
  run_check "helm template charts/accel-device-classes" \
    bash -c "'${HELM}' template accel-device-classes-e2e '${GITOPS_ROOT}/charts/accel-device-classes' > '${RENDERED_DIR}/accel-device-classes.yaml'"
fi

# --------------------------------- 5b. issue #27 values shapes (fixtures)
#
# tests/fixtures/<chart>/<name>.yaml are plain Helm values files, one per
# values shape issue #27 adds (pool.capacityType on-demand/reserved/flex,
# reservation.*, accelerator.*, tenancy.teamTaint, clusterQueue.memQuota).
# Each is linted and rendered to RENDERED_DIR/fixture-<chart>-<name>.yaml,
# so section 6's kubeconform and section 7's pinned-CRD check see every new
# shape too, then check_chart_renders.py checks the rendered fields.

FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

# Fixtures `helm template` must refuse. Each differs from a fixture that
# renders (reserved.yaml, flex.yaml) in exactly the one value under test,
# so a failure can only come from that value.
expect_render_failure=(
  "capacity-pool/reserved-no-tags"
  "capacity-pool/unknown-capacity-type"
  "capacity-pool/capacity-type-in-requirements"
  "capacity-pool/invalid-instance-match-criteria"
  "capacity-pool/invalid-taint-effect"
  "capacity-pool/duplicate-taint"
  "capacity-pool/empty-tag-value"
)
must_fail() {
  local key="$1" f
  for f in "${expect_render_failure[@]}"; do
    [[ "${f}" == "${key}" ]] && return 0
  done
  return 1
}

for chart in capacity-pool smoke; do
  mapfile -t chart_fixtures < <(find "${FIXTURES_DIR}/${chart}" -name '*.yaml' 2>/dev/null | sort)
  if [[ "${#chart_fixtures[@]}" -eq 0 ]]; then
    echo "FAIL no fixtures found under tests/fixtures/${chart}/"
    failures=$((failures + 1))
    continue
  fi
  for fixture in "${chart_fixtures[@]}"; do
    name="$(basename "${fixture}" .yaml)"
    if must_fail "${chart}/${name}"; then
      if "${HELM}" template "fixture-${name}" "${GITOPS_ROOT}/charts/${chart}" -f "${fixture}" \
        >"${WORK_DIR}/must-fail-${chart}-${name}.out" 2>"${WORK_DIR}/must-fail-${chart}-${name}.err"; then
        echo "FAIL helm template charts/${chart} -f fixtures/${chart}/${name}.yaml rendered, but must be refused"
        failures=$((failures + 1))
      else
        echo "PASS helm template charts/${chart} -f fixtures/${chart}/${name}.yaml is refused: $(tr '\n' ' ' <"${WORK_DIR}/must-fail-${chart}-${name}.err")"
      fi
      continue
    fi
    run_check "helm lint charts/${chart} (fixtures/${chart}/${name}.yaml)" \
      "${HELM}" lint "${GITOPS_ROOT}/charts/${chart}" -f "${fixture}"
    run_check "helm template charts/${chart} (fixtures/${chart}/${name}.yaml)" \
      bash -c "'${HELM}' template 'fixture-${name}' '${GITOPS_ROOT}/charts/${chart}' -f '${fixture}' > '${RENDERED_DIR}/fixture-${chart}-${name}.yaml'"
  done
done

run_check "chart render fields (check_chart_renders.py)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_chart_renders.py" "${FIXTURES_DIR}" "${RENDERED_DIR}"

# ------------------------------------------------------- 6. kubeconform

KUBECONFORM_BIN="${WORK_DIR}/kubeconform"
if command -v kubeconform >/dev/null 2>&1; then
  KUBECONFORM_BIN="$(command -v kubeconform)"
else
  # kubeconform is a single static binary with no package manager entry
  # on most machines this runs on; download and checksum-verify it here
  # rather than assuming it is preinstalled.
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

KUBECONFORM_ARGS=(
  -kubernetes-version 1.37.0
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${K8S_SCHEMA_COMMIT}/{{ .NormalizedKubernetesVersion }}-standalone{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json"
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRD_CATALOG_COMMIT}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  -summary
)

kubeconform_targets=("${GITOPS_ROOT}/appsets/platform.ApplicationSet.yaml" "${GITOPS_ROOT}/appsets/cells.ApplicationSet.yaml" "${GITOPS_ROOT}/bootstrap/root-application.yaml")
# #28: every rendered output under RENDERED_DIR, not a fixed list of
# names -- the capacity-pool/smoke loop above now writes one file per
# cell, and #27's own fixture loop writes one file per fixture.
while IFS= read -r -d '' rendered_file; do
  kubeconform_targets+=("${rendered_file}")
done < <(find "${RENDERED_DIR}" -maxdepth 1 -name '*.yaml' -print0 | sort -z)

run_check "kubeconform (${#kubeconform_targets[@]} file(s), k8s 1.37.0 + pinned CRD schemas)" \
  "${KUBECONFORM_BIN}" "${KUBECONFORM_ARGS[@]}" "${kubeconform_targets[@]}"

# -------------------------------------- 7. pinned-chart-version CRD check
#
# kubeconform above validates against a generic, multi-version schema
# catalog: it answers "is this a valid shape for *some* version of this
# CRD", never "is this the version the chart version we actually pinned
# serves". check_pinned_crds.py helm-templates each addons/*/addon.yaml's
# own exact pinned chart version fresh and checks gitops/charts' already-
# rendered output (this section's own RENDERED_DIR) against the real
# CRDs that version ships -- the gap that let gitops/charts/{capacity-pool,
# smoke}'s templates hardcode kueue.x-k8s.io/v1beta1 straight through this
# script while Kueue 0.20.6 (the pinned version) serves only v1beta2.
run_check "pinned-chart-version CRDs (check_pinned_crds.py)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_pinned_crds.py" "${REPO_ROOT}" "${RENDERED_DIR}"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all static checks passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
