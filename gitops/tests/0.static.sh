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
# mapfile/readarray needs bash >=4 (gitops/tests/README.md's own
# Prerequisites) -- never run this on macOS's shipped bash 3.2.

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
# Accumulates every failure and keeps going -- right for independent,
# stateless static checks, where one bad chart should not hide a problem
# in an unrelated one (#63, filed as #61 item 4; see 1.e2e.sh's own
# fail() for the opposite, stop-immediately contract this repository's
# stateful e2e scripts use under a different name, and why it is a
# different name here on purpose).
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

# At least one platform-optional catalog entry (issue #41 Decision 2(b))
# must exist for this PR's own mechanism to have anything to check below
# -- named nowhere here, so a future catalog entry for a non-NVIDIA
# component (a Neuron metrics agent, for example) needs no copied block
# (AGENTS.md section 0/5: no GPU-only assumption in a shared mechanism).
mapfile -t catalog_entries < <(find "${GITOPS_ROOT}/addon-catalog" -mindepth 2 -maxdepth 2 -name 'addon.yaml' 2>/dev/null | sort)
if [[ "${#catalog_entries[@]}" -ge 1 ]]; then
  echo "PASS at least one gitops/addon-catalog/*/addon.yaml exists (${#catalog_entries[@]} found)"
else
  echo "FAIL no gitops/addon-catalog/*/addon.yaml found"
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

# DA-24/DA-43/C-53: a checker that has only ever been run against a
# passing repository is not evidence it would fail on a broken one.
# --selftest builds its own mutated, throwaway fixtures (never this
# checkout) and asserts each mutation fails only the rule it broke, run
# before the real check below so a broken checker fails loudly here
# rather than silently passing everything downstream.
run_check "add-on tiers and naming self-test (check_addon_tiers.py --selftest)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_addon_tiers.py" --selftest

run_check "add-on tiers and naming (check_addon_tiers.py)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_addon_tiers.py" "${REPO_ROOT}"

run_check "add-on catalog vs. cell markers self-test (check_addon_catalog_sync.py --selftest)" \
  env HELM="${HELM}" "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_addon_catalog_sync.py" --selftest

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
  # Issue #41 Decision 4 Finding 1's option (a) (values.enabled: false,
  # the maintainer-undecided alternative to this chart's own default)
  # renders nothing at all -- exercised here since e2e only ever runs
  # with the default (true); a chart that silently rendered an object
  # anyway when disabled would mean a cell cannot actually pick option
  # (a), the exact switch this PR's own open question relies on.
  DISABLED_VALUES="${WORK_DIR}/optional-pool-disabled-values.yaml"
  cat "${OPTIONAL_POOL_VALUES}" | sed 's/^enabled: .*/enabled: false/' >"${DISABLED_VALUES}"
  grep -q '^enabled: false$' "${DISABLED_VALUES}" || echo 'enabled: false' >>"${DISABLED_VALUES}"
  DISABLED_RENDERED="${WORK_DIR}/optional-pool-disabled.yaml"
  "${HELM}" template optional-pool-disabled-e2e "${GITOPS_ROOT}/charts/optional-pool" -f "${DISABLED_VALUES}" >"${DISABLED_RENDERED}" 2>"${WORK_DIR}/optional-pool-disabled.err"
  # -s tests size > 0, which a file holding only "helm template"'s own
  # single trailing newline still satisfies (1 byte) -- not what "renders
  # nothing" means here. Command substitution strips trailing newlines,
  # so comparing that against an empty string is the actual "no content
  # at all" check.
  if [[ -n "$(cat "${DISABLED_RENDERED}")" ]]; then
    echo "FAIL charts/optional-pool with enabled: false renders a non-empty manifest (option (a) would not actually disable it)"
    failures=$((failures + 1))
  else
    echo "PASS charts/optional-pool with enabled: false renders nothing"
  fi
fi

# Every gitops/addon-catalog/<name>/addon.yaml's own dir chart is linted
# and rendered the same way, by name derived from the catalog entry
# itself -- not a per-component copied block (AGENTS.md section 0/5). A
# chart with a Helm `dependencies:` entry (issue #41 Decision 3's wrapper
# shape) needs `helm dependency build` first; that writes the fetched
# tarball into <chart>/charts/ of this checkout (.gitignore'd, never
# committed): harmless on an ephemeral CI runner, but on a developer
# checkout it leaves that tarball behind after this script exits.
# check_addon_catalog_sync.py does its own dependency build on a temporary
# copy instead, so it never depends on this one having run. Values come
# from the first cells/*/addons/*.yaml marker whose own fromCatalog names
# this entry, the same way capacity-pool/smoke above take theirs from a
# real parameter file; with no such marker, the chart's defaults alone.
for catalog_entry in "${catalog_entries[@]}"; do
  entry_name="$(basename "$(dirname "${catalog_entry}")")"
  entry_dir_rel="$(sed -n 's/^dir:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${catalog_entry}" | head -n1)"
  [[ -n "${entry_dir_rel}" ]] || { echo "INFO ${entry_name}: no 'dir' in catalog entry (not platform-optional, or malformed -- check_addon_catalog_sync.py reports the latter), skipping render"; continue; }
  ENTRY_CHART="${REPO_ROOT}/${entry_dir_rel}"
  [[ -f "${ENTRY_CHART}/Chart.yaml" ]] || { echo "FAIL ${entry_name}: dir ${entry_dir_rel} has no Chart.yaml"; failures=$((failures + 1)); continue; }
  if grep -q '^dependencies:' "${ENTRY_CHART}/Chart.yaml" 2>/dev/null; then
    run_check "helm dependency build charts/${entry_name}" "${HELM}" dependency build "${ENTRY_CHART}"
  fi
  mapfile -t entry_markers < <(grep -lE "^fromCatalog:[[:space:]]*\"?${entry_name}\"?[[:space:]]*\$" "${GITOPS_ROOT}"/cells/*/addons/*.yaml 2>/dev/null | sort)
  ENTRY_VALUES="${WORK_DIR}/${entry_name}-values.yaml"
  ENTRY_NAMESPACE="default"
  if [[ "${#entry_markers[@]}" -ge 1 ]]; then
    extract_values "${entry_markers[0]}" "${ENTRY_VALUES}"
    ENTRY_NAMESPACE="$(sed -n 's/^namespace:[[:space:]]*//p' "${entry_markers[0]}" | tr -d '"' | head -n1)"
    ENTRY_VALUES_FROM="$(basename "${entry_markers[0]}")"
  else
    printf '{}\n' >"${ENTRY_VALUES}"
    ENTRY_VALUES_FROM="chart defaults, no cells/*/addons/ marker points at it"
  fi
  run_check "helm lint charts/${entry_name}" "${HELM}" lint "${ENTRY_CHART}"
  run_check "helm template charts/${entry_name} (values from ${ENTRY_VALUES_FROM})" \
    bash -c "'${HELM}' template '${entry_name}-e2e' '${ENTRY_CHART}' --namespace '${ENTRY_NAMESPACE:-default}' -f '${ENTRY_VALUES}' > '${RENDERED_DIR}/${entry_name}.yaml'"
done

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

# The two ApplicationSets and the root Application, plus every *.yaml this
# script itself rendered into RENDERED_DIR above - a glob, not an
# enumerate-by-name list of the charts this PR happens to ship (#63, filed
# as #55 item 2): a hand-typed list here is exactly the same hardcoded-set
# problem check_gitops_contract.py's own addon_dirs already hit once a
# sibling branch added its own chart and its own entry here independently
# (RENDERED_DIR is this script's own dedicated temp directory - nothing
# else ever writes into it, so the glob cannot pick up anything this
# script did not itself render).
kubeconform_targets=("${GITOPS_ROOT}/appsets/platform.ApplicationSet.yaml" "${GITOPS_ROOT}/appsets/cells.ApplicationSet.yaml" "${GITOPS_ROOT}/bootstrap/root-application.yaml")
# addons-optional.ApplicationSet.yaml is a source file under appsets/, not
# something this script renders into RENDERED_DIR, so the glob below
# cannot pick it up on its own -- it still needs naming here, same as the
# other two ApplicationSets/root Application above.
[[ -f "${GITOPS_ROOT}/appsets/addons-optional.ApplicationSet.yaml" ]] && kubeconform_targets+=("${GITOPS_ROOT}/appsets/addons-optional.ApplicationSet.yaml")
# Every chart this script rendered into RENDERED_DIR above -- including
# capacity-pool/smoke and every gitops/addon-catalog/*/ entry -- is
# already covered by the glob below; no addon-catalog-specific loop is
# needed on top of it (#63/#55 item 2's own point: a hardcoded or
# re-derived-but-still-enumerated list here drifts the moment a sibling
# branch adds its own chart, exactly what this merge itself would have
# done by naming each one twice).
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
# It reads every file in RENDERED_DIR, so charts/optional-pool's NodePool/
# EC2NodeClass are checked against karpenter-crd's pinned CRDs here too,
# with no change to the script; charts/dcgm-exporter renders no kind any
# pinned add-on's CRD covers. The wrapper chart's own dependency pin
# (Chart.yaml dependencies[].version) is not a CRD question and is not
# checked here.
run_check "pinned-chart-version CRDs (check_pinned_crds.py)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_pinned_crds.py" "${REPO_ROOT}" "${RENDERED_DIR}"

# -------------------------------------- 8. AppProject whitelist cross-check
#
# #63, filed as "SA1" item 1: gitops/bootstrap/appproject-whitelist.yaml
# (the platform AppProject's own clusterResourceWhitelist/
# namespaceResourceWhitelist) is a hand-maintained list, not derived live
# at bootstrap time. check_appproject_whitelist.py is what keeps it honest:
# it helm-templates every gitops/addons/*/addon.yaml and gitops/
# addon-catalog/*/addon.yaml fresh (needs network access to each add-on's
# own registry, like check_pinned_crds.py above) and fails if any rendered
# (group, kind) pair is missing from that file - the drift this script
# exists to catch before it reaches a real cluster as a refused sync.
run_check "platform AppProject whitelist (check_appproject_whitelist.py)" \
  "${UV}" run --no-project -q --with "pyyaml==${PYTHON_YAML_VERSION}" \
  python3 "${SCRIPT_DIR}/check_appproject_whitelist.py" "${REPO_ROOT}"

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "RESULT PASS: all static checks passed"
else
  echo "RESULT FAIL: ${failures} check(s) failed"
  exit 1
fi
