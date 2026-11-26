#!/usr/bin/env bash
# Static checks for examples/tools/gpu-healthcheck (issue #30). No AWS
# credentials, no cluster, no GPU. Run via the EC2 runner, never the Mac:
#   runner/run.sh --ref <branch> -- bash examples/tools/gpu-healthcheck/tests/0.static.sh
# Deliberately no `set -e`: this script's whole job is to run every check and
# report every result, never to stop silently at the first failing one. Every
# check below captures its own exit status into the `check` helper instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILED=0

check() {
    local desc="$1" ok="$2"
    if [[ "${ok}" == "0" ]]; then
        echo "PASS: ${desc}"
    else
        echo "FAIL: ${desc}"
        FAILED=1
    fi
}

echo "=== shellcheck ==="
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${BASE_DIR}/run.sh" "${BASE_DIR}/tools/render-profiles.sh"
    check "shellcheck: run.sh, tools/render-profiles.sh" "$?"
else
    echo "SKIP: shellcheck not installed"
fi

echo "=== vendor tree byte-identical to SHA256SUMS (no stray edits) ==="
# A real content check, not a shebang proxy: vendor/update-vendor.sh writes
# SHA256SUMS from the exact tree it just copied from upstream, so any later
# hand-edit to a file under vendor/awsome-distributed-ai/ -- anywhere in the
# file, not only line 1 -- changes its hash and fails this check. A real
# re-pin (update-vendor.sh against a newer commit) regenerates SHA256SUMS in
# the same commit as the content change, so this check never fails for a
# deliberate, reviewed re-pin.
if command -v sha256sum >/dev/null 2>&1; then
    SHA_CHECK_CMD=(sha256sum -c SHA256SUMS)
else
    SHA_CHECK_CMD=(shasum -a 256 -c SHA256SUMS)
fi
if (cd "${BASE_DIR}/vendor" && "${SHA_CHECK_CMD[@]}" >/tmp/gpu-healthcheck-sha256sums.out 2>&1); then
    check "vendor/ matches SHA256SUMS" "0"
else
    cat /tmp/gpu-healthcheck-sha256sums.out
    check "vendor/ matches SHA256SUMS" "1"
fi

# `sha256sum -c` only checks the files SHA256SUMS already lists; it says
# nothing about a file added under awsome-distributed-ai/ that was never
# vendored through update-vendor.sh. Catch that case by count: the two
# numbers must match exactly.
TREE_FILE_COUNT=$(find "${BASE_DIR}/vendor/awsome-distributed-ai" -type f | wc -l | tr -d ' ')
SUMS_LINE_COUNT=$(wc -l < "${BASE_DIR}/vendor/SHA256SUMS" | tr -d ' ')
[[ "${TREE_FILE_COUNT}" == "${SUMS_LINE_COUNT}" ]]
check "vendor/awsome-distributed-ai/ file count (${TREE_FILE_COUNT}) matches SHA256SUMS line count (${SUMS_LINE_COUNT})" "$?"

for f in VENDORED_COMMIT SHA256SUMS update-vendor.sh; do
    [[ -f "${BASE_DIR}/vendor/${f}" ]]
    check "vendor/${f} exists" "$?"
done
[[ -f "${BASE_DIR}/vendor/awsome-distributed-ai/LICENSE" ]]
check "vendor/awsome-distributed-ai/LICENSE exists" "$?"
[[ ! -d "${BASE_DIR}/vendor/awsome-distributed-ai/slurm" ]]
check "vendor/awsome-distributed-ai/slurm/ dropped (Kubernetes-only adoption)" "$?"

echo "=== render-profiles.sh: deterministic, g6e rows present, no silent EFA_COUNT drift ==="
OUT1="$("${BASE_DIR}/tools/render-profiles.sh")"
OUT2="$("${BASE_DIR}/tools/render-profiles.sh")"
[[ "${OUT1}" == "${OUT2}" ]]
check "render-profiles.sh is deterministic (same output twice)" "$?"

g6e12=$(echo "${OUT1}" | awk -F'|' '$1=="g6e.12xlarge"')
g6e48=$(echo "${OUT1}" | awk -F'|' '$1=="g6e.48xlarge"')
[[ "${g6e12}" == "g6e.12xlarge|4|1|false|efa" ]]
check "g6e.12xlarge profile row == g6e.12xlarge|4|1|false|efa (sourced from #50's fixture)" "$?"
[[ "${g6e48}" == "g6e.48xlarge|8|4|false|efa" ]]
check "g6e.48xlarge profile row == g6e.48xlarge|8|4|false|efa (sourced from #50's fixture)" "$?"

echo "=== render-profiles.sh cross-checked against issue #50's own fixtures and GROUND_TRUTH ==="
# Two independent cross-checks, not one: GROUND_TRUTH's own tuple is
# (MaximumNetworkCards, MaximumEfaInterfaces) -- documented order, but every
# onboarded E==C row (including p4d.24xlarge, added below) happens to be
# symmetric, so reading the tuple alone can never structurally prove which
# element is which. The describe.json fixture's own EfaInfo.MaximumEfaInterfaces
# field is named, not positional, and settles that independently of
# GROUND_TRUTH's tuple order.
python3 - "${BASE_DIR}/../../../gitops/tests/check_nic_layout.py" "${BASE_DIR}/../../../gitops/charts/capacity-pool/tools/fixtures" <<'PYEOF'
import json
import os
import re
import sys

ck_path, fixtures_dir = sys.argv[1:]
src = open(ck_path, encoding="utf-8").read()
m = re.search(r"GROUND_TRUTH: dict\[str, tuple\[int, int\]\] = \{(.*?)\n\}", src, re.S)
assert m, "could not find GROUND_TRUTH table in check_nic_layout.py"
pairs = re.findall(r'"([\w.\-]+)":\s*\((\d+),\s*(\d+)\)', m.group(1))
gt = {t: int(e) for t, _, e in pairs}  # second tuple element = E (documented order)

expect = {"g6e.12xlarge": 1, "g6e.48xlarge": 4, "p4d.24xlarge": 4}
for t, e in expect.items():
    assert t in gt, f"{t} missing from check_nic_layout.py GROUND_TRUTH"
    assert gt[t] == e, f"{t}: GROUND_TRUTH EFA count {gt[t]} != overlay {e}"

    describe_path = os.path.join(fixtures_dir, f"{t}.describe.json")
    assert os.path.isfile(describe_path), f"no describe.json fixture for {t}"
    describe = json.load(open(describe_path, encoding="utf-8"))
    fixture_efa = describe["EfaInfo"]["MaximumEfaInterfaces"]
    assert fixture_efa == e, f"{t}: describe.json EfaInfo.MaximumEfaInterfaces {fixture_efa} != overlay {e}"

print("GROUND_TRUTH + describe.json cross-check OK:", expect)
PYEOF
check "g6e-overlay.conf EFA counts match gitops/tests/check_nic_layout.py GROUND_TRUTH and the describe.json fixtures' own named field" "$?"

echo "=== --inject-bad-efa-count actually changes exactly one row, by +1 ==="
BAD="$("${BASE_DIR}/tools/render-profiles.sh" --inject-bad-efa-count g6e.12xlarge)"
bad_line=$(echo "${BAD}" | awk -F'|' '$1=="g6e.12xlarge"')
[[ "${bad_line}" == "g6e.12xlarge|4|2|false|efa" ]]
check "inject-bad-efa-count bumps g6e.12xlarge EFA_COUNT 1 -> 2" "$?"
other_line=$(echo "${BAD}" | awk -F'|' '$1=="g6e.48xlarge"')
[[ "${other_line}" == "g6e.48xlarge|8|4|false|efa" ]]
check "inject-bad-efa-count leaves every other row unchanged" "$?"

echo "=== job templates: render with dummy tokens, each variant is valid YAML ==="
python3 - "${BASE_DIR}/manifests/job-preflight.yaml.tmpl" <<'PYEOF'
import sys

# PyYAML is required, not optional: an earlier version of this check fell
# back to a weaker kubectl-dry-run path when PyYAML was missing, and that
# path's own subprocess.run(check=False) never actually failed the check
# either -- the net effect was "pass regardless of the YAML's own validity"
# on any runner without PyYAML, despite a comment claiming it would be
# skipped, not silently passed. Failing loudly here is the honest version of
# that claim.
import yaml

path = sys.argv[1]
raw = open(path, encoding="utf-8").read()

def render(raw, with_queue):
    text = raw
    if with_queue:
        text = text.replace("# KUEUE-ONLY", "")
        text = text.replace("__QUEUE_NAME__", "smoke")
    else:
        text = "\n".join(l for l in text.splitlines() if "# KUEUE-ONLY" not in l)
    for tok, val in {
        "__RUN_ID__": "1234567890",
        "__NAMESPACE__": "gpu-healthcheck",
        "__INSTANCE_TYPE__": "g6e.12xlarge",
        "__BASE_IMAGE__": "nvcr.io/nvidia/cloud-native/dcgm:3.3.7-1-ubuntu22.04",
    }.items():
        text = text.replace(tok, val)
    text = "\n".join(l for l in text.splitlines() if not l.startswith("#"))
    return text

for with_queue in (True, False):
    rendered = render(raw, with_queue)
    assert "__" not in rendered, f"unsubstituted token left (with_queue={with_queue})"
    docs = list(yaml.safe_load_all(rendered))
    assert docs and docs[0] is not None, f"empty YAML doc (with_queue={with_queue})"
print("job-preflight.yaml.tmpl renders to valid YAML with and without Kueue")
PYEOF
check "job-preflight.yaml.tmpl renders to syntactically valid YAML (both Kueue/no-Kueue variants)" "$?"

echo "=== $([[ ${FAILED} -eq 0 ]] && echo ALL PASS || echo SOME FAILED) ==="
exit "${FAILED}"
