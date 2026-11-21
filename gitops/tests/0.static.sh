#!/usr/bin/env bash
# Static checks for the gitops/ delivery layer (issue #25): no AWS
# credentials needed, no cluster needed.
#
#   1. required files and directories exist, scoped to this PR's first-PR
#      content (decision 9: no accelerators/, no teams/*);
#   2. shellcheck and `bash -n` on every *.sh under gitops/;
#   3. yamllint on every literal (non-templated) tracked YAML file;
#   4. the structural contract of every addon.yaml / cells parameter file,
#      the three ApplicationSets and the root Application, against decisions
#      1, 2, 3, 4, 6 and 8 of the issue (check_gitops_contract.py); every
#      gitops/addons/ entry is tier core and every gitops/addon-catalog/
#      entry platform-optional or workload, with the directory naming
#      rules of issue #41 Decision 2 (check_addon_tiers.py); every
#      cells/*/addons/*.yaml marker against its catalog entry, issue #41
#      Decision 3's checks (0)-(4) (check_addon_catalog_sync.py; its
#      overridableKeys sub-check runs `helm dependency build` on a
#      temporary copy of each wrapper chart, so it needs network access to
#      that chart's upstream repository);
#   5. `helm lint` and `helm template` of charts/capacity-pool and
#      charts/smoke, each against one real cells/*/{capacity-pool,smoke}/*.yaml
#      parameter file's own `values:`; of charts/optional-pool against
#      addons/optional-pool/addon.yaml's own `values:`; and of
#      charts/dcgm-exporter (after `helm dependency build`) against the
#      cells/*/addons/*.yaml marker that points at it;
#   6. kubeconform of the rendered chart output, the three ApplicationSets
#      and the root Application, against pinned upstream + CRD-catalog schemas;
#   7. every pinned add-on's own exact chart version (never a generic,
#      multi-version schema catalog) is `helm template`-d fresh and its
#      real CustomResourceDefinitions extracted, to check that the
#      rendered charts/{capacity-pool,smoke,optional-pool,dcgm-exporter}
#      output only uses an apiVersion that pinned chart version actually
#      serves
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
  "charts/capacity-pool/Chart.yaml"
  "charts/smoke/Chart.yaml"
  "appsets/addons-optional.ApplicationSet.yaml"
  "addons/optional-pool/addon.yaml"
  "charts/optional-pool/Chart.yaml"
  "charts/dcgm-exporter/Chart.yaml"
  "addon-catalog/dcgm-exporter/addon.yaml"
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
    find "${GITOPS_ROOT}/addon-catalog" -mindepth 2 -maxdepth 2 -name 'addon.yaml'
    find "${GITOPS_ROOT}/cells" -path '*/capacity-pool/*.yaml' -o -path '*/smoke/*.yaml' -o -path '*/teams/*.yaml' -o -path '*/addons/*.yaml'
    find "${GITOPS_ROOT}/appsets" -name '*.yaml'
    find "${GITOPS_ROOT}/bootstrap" -name '*.yaml'
    find "${GITOPS_ROOT}/charts" -maxdepth 2 -name 'Chart.yaml' -o -maxdepth 2 -name 'values.yaml'
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

run_check "add-on tiers and naming (check_addon_tiers.py)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_addon_tiers.py" "${REPO_ROOT}"

# HELM is passed explicitly: the overridableKeys sub-check calls helm
# itself (on a temporary copy of each wrapper chart, never this checkout).
run_check "add-on catalog vs. cell markers (check_addon_catalog_sync.py)" \
  env HELM="${HELM}" "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_addon_catalog_sync.py" "${REPO_ROOT}"

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

if [[ "${#cell_capacity_pool_files[@]}" -ge 1 ]]; then
  run_check "helm lint charts/capacity-pool" "${HELM}" lint "${GITOPS_ROOT}/charts/capacity-pool"
  CP_VALUES="${WORK_DIR}/capacity-pool-values.yaml"
  extract_values "${cell_capacity_pool_files[0]}" "${CP_VALUES}"
  run_check "helm template charts/capacity-pool (values from $(basename "${cell_capacity_pool_files[0]}"))" \
    bash -c "'${HELM}' template capacity-pool-e2e '${GITOPS_ROOT}/charts/capacity-pool' -f '${CP_VALUES}' > '${RENDERED_DIR}/capacity-pool.yaml'"
fi
if [[ "${#cell_smoke_files[@]}" -ge 1 ]]; then
  run_check "helm lint charts/smoke" "${HELM}" lint "${GITOPS_ROOT}/charts/smoke"
  SMOKE_VALUES="${WORK_DIR}/smoke-values.yaml"
  extract_values "${cell_smoke_files[0]}" "${SMOKE_VALUES}"
  run_check "helm template charts/smoke (values from $(basename "${cell_smoke_files[0]}"))" \
    bash -c "'${HELM}' template smoke-e2e '${GITOPS_ROOT}/charts/smoke' -f '${SMOKE_VALUES}' > '${RENDERED_DIR}/smoke.yaml'"
fi

# charts/optional-pool is delivered by platform.ApplicationSet.yaml from
# addons/optional-pool/addon.yaml (issue #41: a core add-on with a local
# dir, not a registry chart), so that file's own values:/valuesFrom: are
# its real, checked-in input -- the same extract_values() technique as the
# cells parameter files above.
OPTIONAL_POOL_ADDON="${GITOPS_ROOT}/addons/optional-pool/addon.yaml"
if [[ -f "${OPTIONAL_POOL_ADDON}" ]]; then
  run_check "helm lint charts/optional-pool" "${HELM}" lint "${GITOPS_ROOT}/charts/optional-pool"
  OPTIONAL_POOL_VALUES="${WORK_DIR}/optional-pool-values.yaml"
  extract_values "${OPTIONAL_POOL_ADDON}" "${OPTIONAL_POOL_VALUES}"
  run_check "helm template charts/optional-pool (values from addons/optional-pool/addon.yaml)" \
    bash -c "'${HELM}' template optional-pool-e2e '${GITOPS_ROOT}/charts/optional-pool' -f '${OPTIONAL_POOL_VALUES}' > '${RENDERED_DIR}/optional-pool.yaml'"
fi

# charts/dcgm-exporter wraps an upstream chart as a Helm dependency (issue
# #41 Decision 3), so it cannot be linted or rendered until that
# dependency is fetched. `helm dependency build` writes the fetched
# tarball into gitops/charts/dcgm-exporter/charts/ of this checkout (that
# directory is .gitignore'd, never committed): harmless on an ephemeral CI
# runner, but on a developer checkout it leaves that tarball behind after
# this script exits -- this step is not side-effect-free there.
# check_addon_catalog_sync.py does its own dependency build on a temporary
# copy instead, so it never depends on this one having run.
# The values come from the cells/*/addons/*.yaml marker that points at
# this chart, the same way capacity-pool/smoke above take theirs from a
# real parameter file; with no such marker, the chart's defaults alone.
DCGM_CHART="${GITOPS_ROOT}/charts/dcgm-exporter"
if [[ -f "${DCGM_CHART}/Chart.yaml" ]]; then
  mapfile -t dcgm_markers < <(grep -lE '^dir:[[:space:]]*"?gitops/charts/dcgm-exporter/?"?[[:space:]]*$' "${GITOPS_ROOT}"/cells/*/addons/*.yaml 2>/dev/null | sort)
  DCGM_VALUES="${WORK_DIR}/dcgm-exporter-values.yaml"
  DCGM_NAMESPACE="default"
  if [[ "${#dcgm_markers[@]}" -ge 1 ]]; then
    extract_values "${dcgm_markers[0]}" "${DCGM_VALUES}"
    DCGM_NAMESPACE="$(sed -n 's/^namespace:[[:space:]]*//p' "${dcgm_markers[0]}" | tr -d '"' | head -n1)"
    DCGM_VALUES_FROM="$(basename "${dcgm_markers[0]}")"
  else
    printf '{}\n' >"${DCGM_VALUES}"
    DCGM_VALUES_FROM="chart defaults, no cells/*/addons/ marker points at it"
  fi
  run_check "helm dependency build charts/dcgm-exporter" "${HELM}" dependency build "${DCGM_CHART}"
  run_check "helm lint charts/dcgm-exporter" "${HELM}" lint "${DCGM_CHART}"
  run_check "helm template charts/dcgm-exporter (values from ${DCGM_VALUES_FROM})" \
    bash -c "'${HELM}' template dcgm-exporter-e2e '${DCGM_CHART}' --namespace '${DCGM_NAMESPACE:-default}' -f '${DCGM_VALUES}' > '${RENDERED_DIR}/dcgm-exporter.yaml'"
fi

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
[[ -f "${GITOPS_ROOT}/appsets/addons-optional.ApplicationSet.yaml" ]] && kubeconform_targets+=("${GITOPS_ROOT}/appsets/addons-optional.ApplicationSet.yaml")
[[ -f "${RENDERED_DIR}/capacity-pool.yaml" ]] && kubeconform_targets+=("${RENDERED_DIR}/capacity-pool.yaml")
[[ -f "${RENDERED_DIR}/smoke.yaml" ]] && kubeconform_targets+=("${RENDERED_DIR}/smoke.yaml")
[[ -f "${RENDERED_DIR}/optional-pool.yaml" ]] && kubeconform_targets+=("${RENDERED_DIR}/optional-pool.yaml")
[[ -f "${RENDERED_DIR}/dcgm-exporter.yaml" ]] && kubeconform_targets+=("${RENDERED_DIR}/dcgm-exporter.yaml")

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
# It reads every file in RENDERED_DIR, so charts/optional-pool's NodePool/
# EC2NodeClass are checked against karpenter-crd's pinned CRDs here too,
# with no change to the script; charts/dcgm-exporter renders no kind any
# pinned add-on's CRD covers. The wrapper chart's own dependency pin
# (Chart.yaml dependencies[].version) is not a CRD question and is not
# checked here.
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
