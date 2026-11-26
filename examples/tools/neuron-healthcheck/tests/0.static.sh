#!/usr/bin/env bash
# Static checks for examples/tools/neuron-healthcheck (issue #97). No AWS
# credentials, no cluster, no Neuron device, no torch/torch_neuronx. Run via
# the EC2 runner, never the Mac:
#   runner/run.sh --ref <branch> -- bash examples/tools/neuron-healthcheck/tests/0.static.sh
# Needs bash, awk, python3 with PyYAML (required, see the template check
# below); shellcheck is used when installed.
#
# These checks are written against the issue's own design (the file layout,
# the instance-profiles.conf format INSTANCE_TYPE|DEVICE_COUNT|NEURONCORE_COUNT|EFA_COUNT,
# the run.sh environment contract and the --inject-bad-device-count flag),
# not against any particular implementation's internals.
#
# Deliberately no `set -e`: this script's whole job is to run every check and
# report every result, never to stop silently at the first failing one. Every
# check below captures its own exit status into the `check` helper instead.
# The `[[ ... ]]` / `check "..." "$?"` pairs below pass the condition's own
# status on purpose, so SC2319 does not apply to this file.
# shellcheck disable=SC2319
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BASE_DIR}/../../.." && pwd)"
FAILED=0

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

check() {
    local desc="$1" ok="$2"
    if [[ "${ok}" == "0" ]]; then
        echo "PASS: ${desc}"
    else
        echo "FAIL: ${desc}"
        FAILED=1
    fi
}

# Data rows of a profile file or rendered profile: comments and blank lines
# dropped, trailing whitespace and CR stripped.
data_rows() {
    sed -e 's/[[:space:]]*$//' | awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/'
}

echo "=== file layout (issue #97 design comment) ==="
for f in \
    README.md \
    run.sh \
    profiles/instance-profiles.conf \
    lib/common.sh \
    lib/checks/0-neuron-ls-check.sh \
    lib/checks/1-neff-compile-load-check.py \
    lib/checks/2-efa-enumeration-check.sh \
    lib/aggregate-results.py \
    manifests/00-namespace.yaml \
    manifests/job-preflight.yaml.tmpl \
    tools/render-profile.sh \
    tests/0.static.sh; do
    [[ -f "${BASE_DIR}/${f}" ]]
    check "${f} exists" "$?"
done
for f in run.sh tools/render-profile.sh; do
    [[ -x "${BASE_DIR}/${f}" ]]
    check "${f} is executable" "$?"
done

echo "=== shell scripts: bash -n and shellcheck ==="
SH_FILES=()
while IFS= read -r f; do SH_FILES+=("${f}"); done < <(find "${BASE_DIR}" -type f -name '*.sh' | LC_ALL=C sort)
[[ "${#SH_FILES[@]}" -gt 0 ]]
check "found shell scripts under the tool (${#SH_FILES[@]})" "$?"
for f in "${SH_FILES[@]}"; do
    bash -n "${f}"
    check "bash -n ${f#"${BASE_DIR}"/}" "$?"
done
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${SH_FILES[@]}"; do
        # -x: follow `source "${SCRIPT_DIR}/../common.sh"` in lib/checks/*.sh.
        # The sourced file's own `# shellcheck source=../common.sh` directive
        # names the right relative path, but shellcheck only resolves and
        # checks a sourced file with -x; without it, SC1091 ("not following")
        # fires on an actual, resolvable path and would fail this check on
        # correct code.
        shellcheck -x "${f}"
        check "shellcheck -x ${f#"${BASE_DIR}"/}" "$?"
    done
else
    echo "SKIP: shellcheck not installed"
fi

echo "=== Python files compile (no torch/torch_neuronx needed) ==="
# py_compile parses and byte-compiles without executing any import, so it
# runs on a host with no Neuron packages. cfile points into ${WORK} so no
# __pycache__ is written into the tree.
for f in lib/checks/1-neff-compile-load-check.py lib/aggregate-results.py; do
    python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
        "${BASE_DIR}/${f}" "${WORK}/$(basename "${f}").pyc"
    check "py_compile ${f}" "$?"
done

echo "=== profiles/instance-profiles.conf: measured trn2.3xlarge row ==="
PROFILE="${BASE_DIR}/profiles/instance-profiles.conf"
PROFILE_ROWS="$(data_rows 2>/dev/null < "${PROFILE}")"
# Every data row has the four documented fields:
#   INSTANCE_TYPE|DEVICE_COUNT|NEURONCORE_COUNT|EFA_COUNT
# with the three counts as non-negative integers.
BAD_ROWS="$(echo "${PROFILE_ROWS}" | awk -F'|' 'NF && !(NF==4 && $1!="" && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ && $4~/^[0-9]+$/)')"
[[ -n "${PROFILE_ROWS}" && -z "${BAD_ROWS}" ]]
check "every data row is INSTANCE_TYPE|DEVICE_COUNT|NEURONCORE_COUNT|EFA_COUNT with integer counts${BAD_ROWS:+ (bad: ${BAD_ROWS})}" "$?"
DUP_TYPES="$(echo "${PROFILE_ROWS}" | awk -F'|' 'NF{print $1}' | sort | uniq -d)"
[[ -z "${DUP_TYPES}" ]]
check "no instance type has more than one row${DUP_TYPES:+ (duplicated: ${DUP_TYPES})}" "$?"

TRN2_ROWS="$(echo "${PROFILE_ROWS}" | awk -F'|' '$1=="trn2.3xlarge"')"
TRN2_COUNT="$(echo "${TRN2_ROWS}" | awk 'NF' | wc -l | tr -d ' ')"
[[ "${TRN2_COUNT}" == "1" ]]
check "exactly one trn2.3xlarge row (found ${TRN2_COUNT})" "$?"
# Measured values, not placeholders:
#   DEVICE_COUNT=1, NEURONCORE_COUNT=4: issue #19 E4a/E4b, a real trn2.3xlarge
#     (device plugin advertised aws.amazon.com/neuron: 1 and
#     aws.amazon.com/neuroncore: 4; neuron-ls showed device 0 with 4 cores).
#     Karpenter's own instance-type data says neuroncore: 8 for this type,
#     which the same measurement shows is wrong (see also the comment above
#     the Trainium accelerators step in gitops/tests/1.e2e.sh).
#   EFA_COUNT=1: gitops/charts/capacity-pool/tools/fixtures/trn2.3xlarge.describe.json,
#     EfaInfo.MaximumEfaInterfaces=1 (_source.capturedUtc 2026-11-25),
#     cross-checked against two sources in the next section.
[[ "${TRN2_ROWS}" == "trn2.3xlarge|1|4|1" ]]
check "trn2.3xlarge row == trn2.3xlarge|1|4|1 (got: ${TRN2_ROWS:-<none>})" "$?"

echo "=== trn2.3xlarge EFA_COUNT cross-checked against GROUND_TRUTH and the describe.json fixture ==="
# Two independent cross-checks, not one: GROUND_TRUTH's own tuple is
# (MaximumNetworkCards, MaximumEfaInterfaces) -- documented order, but the
# trn2.3xlarge entry is symmetric (1, 1), so reading the tuple alone cannot
# structurally prove which element is which. The describe.json fixture's own
# EfaInfo.MaximumEfaInterfaces field is named, not positional, and settles
# that independently of GROUND_TRUTH's tuple order.
python3 - "${PROFILE}" "${REPO_ROOT}/gitops/tests/check_nic_layout.py" \
    "${REPO_ROOT}/gitops/charts/capacity-pool/tools/fixtures/trn2.3xlarge.describe.json" <<'PYEOF'
import json
import re
import sys

profile_path, ck_path, describe_path = sys.argv[1:]

profile_efa = None
for line in open(profile_path, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    fields = line.split("|")
    if fields[0] == "trn2.3xlarge":
        profile_efa = int(fields[3])
assert profile_efa is not None, "no trn2.3xlarge row in instance-profiles.conf"

src = open(ck_path, encoding="utf-8").read()
m = re.search(r"GROUND_TRUTH: dict\[str, tuple\[int, int\]\] = \{(.*?)\n\}", src, re.S)
assert m, "could not find GROUND_TRUTH table in check_nic_layout.py"
pairs = {t: (int(c), int(e)) for t, c, e in re.findall(r'"([\w.\-]+)":\s*\((\d+),\s*(\d+)\)', m.group(1))}
assert "trn2.3xlarge" in pairs, "trn2.3xlarge missing from check_nic_layout.py GROUND_TRUTH"
assert pairs["trn2.3xlarge"] == (1, 1), f"GROUND_TRUTH[trn2.3xlarge] = {pairs['trn2.3xlarge']} != (1, 1)"
gt_efa = pairs["trn2.3xlarge"][1]  # second tuple element = E (documented order)
assert gt_efa == profile_efa, f"GROUND_TRUTH EFA count {gt_efa} != profile EFA_COUNT {profile_efa}"

describe = json.load(open(describe_path, encoding="utf-8"))
assert describe.get("_source", {}).get("instanceType") == "trn2.3xlarge", "describe.json _source.instanceType is not trn2.3xlarge"
fixture_efa = describe["EfaInfo"]["MaximumEfaInterfaces"]
assert fixture_efa == 1, f"describe.json EfaInfo.MaximumEfaInterfaces {fixture_efa} != 1"
assert fixture_efa == profile_efa, f"describe.json EfaInfo.MaximumEfaInterfaces {fixture_efa} != profile EFA_COUNT {profile_efa}"

print("GROUND_TRUTH (1, 1) + describe.json EfaInfo.MaximumEfaInterfaces=1 match profile EFA_COUNT", profile_efa)
PYEOF
check "trn2.3xlarge EFA_COUNT matches gitops/tests/check_nic_layout.py GROUND_TRUTH and the describe.json fixture's own named field" "$?"

echo "=== tools/render-profile.sh: deterministic, matches the checked-in profile ==="
RENDER="${BASE_DIR}/tools/render-profile.sh"
OUT1="$("${RENDER}" 2>"${WORK}/render1.err")"
RC1=$?
OUT2="$("${RENDER}" 2>"${WORK}/render2.err")"
RC2=$?
[[ "${RC1}" == "0" && "${RC2}" == "0" ]] || cat "${WORK}/render1.err" "${WORK}/render2.err"
[[ "${RC1}" == "0" && "${RC2}" == "0" ]]
check "render-profile.sh with no arguments exits 0 (twice)" "$?"
[[ -n "${OUT1}" && "${OUT1}" == "${OUT2}" ]]
check "render-profile.sh is deterministic (same non-empty output twice)" "$?"
RENDERED_ROWS="$(echo "${OUT1}" | data_rows)"
[[ "${RENDERED_ROWS}" == "${PROFILE_ROWS}" ]]
check "render-profile.sh with no arguments renders exactly the data rows of profiles/instance-profiles.conf" "$?"

echo "=== --inject-bad-device-count changes exactly one field of exactly one row, by +1 ==="
BAD="$("${RENDER}" --inject-bad-device-count trn2.3xlarge 2>"${WORK}/inject.err")"
RC=$?
[[ "${RC}" == "0" ]] || cat "${WORK}/inject.err"
[[ "${RC}" == "0" ]]
check "render-profile.sh --inject-bad-device-count trn2.3xlarge exits 0" "$?"
BAD_ROWS_ALL="$(echo "${BAD}" | data_rows)"
bad_line="$(echo "${BAD_ROWS_ALL}" | awk -F'|' '$1=="trn2.3xlarge"')"
[[ "${bad_line}" == "trn2.3xlarge|2|4|1" ]]
check "inject-bad-device-count bumps trn2.3xlarge DEVICE_COUNT 1 -> 2, NEURONCORE_COUNT and EFA_COUNT unchanged (got: ${bad_line:-<none>})" "$?"
OTHERS_BEFORE="$(echo "${RENDERED_ROWS}" | awk -F'|' '$1!="trn2.3xlarge"')"
OTHERS_AFTER="$(echo "${BAD_ROWS_ALL}" | awk -F'|' '$1!="trn2.3xlarge"')"
[[ "${OTHERS_BEFORE}" == "${OTHERS_AFTER}" ]]
check "inject-bad-device-count leaves every other row unchanged" "$?"
[[ "$(echo "${BAD_ROWS_ALL}" | wc -l | tr -d ' ')" == "$(echo "${RENDERED_ROWS}" | wc -l | tr -d ' ')" ]]
check "inject-bad-device-count adds or drops no data row" "$?"

"${RENDER}" --inject-bad-device-count some-nonexistent-type >/dev/null 2>&1
RC=$?
# -x guard: a missing script exits 127, which must not count as "refused".
[[ -x "${RENDER}" && "${RC}" != "0" ]]
check "inject-bad-device-count refuses an instance type with no row (exit ${RC}, want non-zero)" "$?"

echo "=== run.sh: refuses to start without a real expectation, before touching a cluster ==="
# A kubectl on PATH that records every call and fails. run.sh must reject a
# missing or unknown INSTANCE_TYPE before it creates anything on a cluster.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/kubectl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${WORK}/kubectl.calls"
exit 97
EOF
chmod +x "${WORK}/bin/kubectl"
run_guarded() {
    rm -f "${WORK}/kubectl.calls"
    env -u INSTANCE_TYPE -u QUEUE_NAME -u INJECT_BAD_DEVICE_COUNT -u KUBECTL \
        PATH="${WORK}/bin:${PATH}" KUBECONFIG=/dev/null "$@" "${BASE_DIR}/run.sh" >"${WORK}/run.out" 2>&1
}
run_guarded
RC=$?
# -x guard: a missing run.sh exits 127, which must not count as "refused".
[[ -x "${BASE_DIR}/run.sh" && "${RC}" != "0" && ! -s "${WORK}/kubectl.calls" ]]
check "run.sh with INSTANCE_TYPE unset exits non-zero (exit ${RC}) without calling kubectl" "$?"
run_guarded INSTANCE_TYPE=some-nonexistent-type
RC=$?
[[ -x "${BASE_DIR}/run.sh" && "${RC}" != "0" && ! -s "${WORK}/kubectl.calls" ]]
check "run.sh with an INSTANCE_TYPE that has no profile row exits non-zero (exit ${RC}) without calling kubectl" "$?"

# BASE_IMAGE default: a pinned public Neuron DLC tag, never :latest. Written
# to tolerate either a single-line "BASE_IMAGE:-public.ecr.aws/..." default
# (the gpu-healthcheck/run.sh style) or a one-level indirection through a
# named constant (run.sh's own DEFAULT_BASE_IMAGE="public.ecr.aws/...", then
# BASE_IMAGE="${BASE_IMAGE:-${DEFAULT_BASE_IMAGE}}") -- both satisfy the same
# acceptance criterion (a pinned tag, not :latest); which indirection style
# is used is an implementation choice, not part of the contract.
grep -Eq 'public\.ecr\.aws/neuron/pytorch-inference-neuronx:[^"[:space:]]+' "${BASE_DIR}/run.sh" \
    && ! grep -Eq 'public\.ecr\.aws/neuron/pytorch-inference-neuronx:latest' "${BASE_DIR}/run.sh"
check "run.sh's own BASE_IMAGE default names a pinned public.ecr.aws/neuron/pytorch-inference-neuronx tag (not :latest)" "$?"
for v in INSTANCE_TYPE NAMESPACE QUEUE_NAME BASE_IMAGE RUN_ID INJECT_BAD_DEVICE_COUNT; do
    grep -q "${v}" "${BASE_DIR}/run.sh"
    check "run.sh reads ${v}" "$?"
done
grep -Eq 'NAMESPACE:-neuron-healthcheck\}' "${BASE_DIR}/run.sh"
check "run.sh NAMESPACE defaults to neuron-healthcheck" "$?"

echo "=== manifests: render with dummy tokens, valid YAML, no accelerator request, neuron toleration ==="
# The Python block prints one "RESULT <0|1> <description>" line per check and
# never stops early; each line goes through the same `check` helper. A
# crash (including a missing PyYAML) prints no RESULT line for the checks it
# did not reach and is reported as its own FAIL below.
python3 - "${BASE_DIR}/manifests/job-preflight.yaml.tmpl" "${BASE_DIR}/manifests/00-namespace.yaml" \
    > "${WORK}/manifests.out" <<'PYEOF'
import re
import sys

# PyYAML is required, not optional: a fallback that skips this check when
# PyYAML is missing would read as "pass regardless of the YAML's own
# validity" on any runner without it. Failing loudly here is the honest
# version of that check.
import yaml

tmpl_path, ns_path = sys.argv[1:]
raw = open(tmpl_path, encoding="utf-8").read()


def result(ok, desc, detail=""):
    print(f"RESULT {0 if ok else 1} {desc}{'' if ok or not detail else f' ({detail})'}", flush=True)


# A placeholder token is __UPPER_CASE__; this deliberately does not match
# Python dunders such as __name__ that an inline script may legitimately carry.
TOKEN = re.compile(r"__[A-Z][A-Z0-9_]*__")
DUMMY = {
    "__RUN_ID__": "1234567890",
    "__NAMESPACE__": "neuron-healthcheck",
    "__INSTANCE_TYPE__": "trn2.3xlarge",
    "__BASE_IMAGE__": "public.ecr.aws/neuron/pytorch-inference-neuronx:0.0.0-static-test",
    # run.sh also substitutes the profile row's own three expected counts
    # into the container's environment (not named in the issue's design
    # comment, which only lists the four tokens above; run.sh reads them from
    # profiles/instance-profiles.conf at render time, no new input of its
    # own). Dummy values here only need to be valid non-negative integers.
    "__EXPECTED_DEVICE_COUNT__": "1",
    "__EXPECTED_NEURONCORE_COUNT__": "4",
    "__EXPECTED_EFA_COUNT__": "1",
}
# Standard compute resources are unprefixed (cpu, memory, ephemeral-storage,
# hugepages-*); every device-plugin resource is a domain-prefixed extended
# resource. Issue #97's design: the pre-flight requests no device-plugin
# resource at all, so it never holds a slot the workload it guards needs.
NAMED_ACCEL = {"nvidia.com/gpu", "aws.amazon.com/neuron", "aws.amazon.com/neuroncore",
               "aws.amazon.com/neurondevice", "vpc.amazonaws.com/efa"}

result("# KUEUE-ONLY" in raw, "template has '# KUEUE-ONLY' lines")
result("__QUEUE_NAME__" in raw, "template carries the __QUEUE_NAME__ token")
for tok in DUMMY:
    result(tok in raw, f"template uses {tok}")


def render(text, with_queue):
    if with_queue:
        text = text.replace("# KUEUE-ONLY", "").replace("__QUEUE_NAME__", "smoke")
    else:
        text = "\n".join(l for l in text.splitlines() if "# KUEUE-ONLY" not in l)
    for tok, val in DUMMY.items():
        text = text.replace(tok, val)
    return "\n".join(l for l in text.splitlines() if not l.startswith("#"))


def walk(node, key):
    """Yield every value stored under `key` anywhere in a parsed document."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key:
                yield v
            yield from walk(v, key)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item, key)


for with_queue in (True, False):
    tag = "Kueue variant" if with_queue else "no-Kueue variant"
    rendered = render(raw, with_queue)
    left = sorted(set(TOKEN.findall(rendered)))
    result(not left, f"{tag}: no __TOKEN__ left after substitution", f"left: {left}")
    try:
        docs = [d for d in yaml.safe_load_all(rendered) if d is not None]
    except yaml.YAMLError as e:
        result(False, f"{tag}: valid YAML", str(e).replace("\n", " "))
        continue
    result(bool(docs), f"{tag}: valid YAML with at least one non-empty document")
    jobs = [d for d in docs if isinstance(d, dict) and d.get("kind") == "Job"]
    result(len(jobs) == 1, f"{tag}: exactly one Job document", f"found {len(jobs)}")
    if len(jobs) != 1:
        continue
    job = jobs[0]
    meta = job.get("metadata") or {}
    spec = job.get("spec") or {}
    pod = ((spec.get("template") or {}).get("spec")) or {}

    accel = []
    for res in walk(docs, "resources"):
        if not isinstance(res, dict):
            continue
        for section in ("requests", "limits"):
            for name in res.get(section) or {}:
                if name in NAMED_ACCEL or "/" in str(name):
                    accel.append(f"{section}.{name}")
        if res.get("claims"):
            accel.append("claims (DRA)")
    if pod.get("resourceClaims"):
        accel.append("pod resourceClaims (DRA)")
    result(not accel, f"{tag}: no container requests nvidia.com/gpu, aws.amazon.com/neuron* or any other device-plugin/DRA resource", f"found: {accel}")

    tols = pod.get("tolerations") or []
    result(any(isinstance(t, dict) and t.get("key") == "aws.amazon.com/neuron" for t in tols),
           f"{tag}: pod template tolerates aws.amazon.com/neuron", f"tolerations: {tols}")

    sel = pod.get("nodeSelector") or {}
    result(sel.get("node.kubernetes.io/instance-type") == DUMMY["__INSTANCE_TYPE__"],
           f"{tag}: nodeSelector node.kubernetes.io/instance-type comes from __INSTANCE_TYPE__", f"nodeSelector: {sel}")
    result(meta.get("namespace") == DUMMY["__NAMESPACE__"],
           f"{tag}: Job metadata.namespace comes from __NAMESPACE__", f"got: {meta.get('namespace')!r}")

    queue = (meta.get("labels") or {}).get("kueue.x-k8s.io/queue-name")
    if with_queue:
        result(queue == "smoke", f"{tag}: Job label kueue.x-k8s.io/queue-name comes from __QUEUE_NAME__", f"got: {queue!r}")
    else:
        result(queue is None, f"{tag}: Job carries no kueue.x-k8s.io/queue-name label", f"got: {queue!r}")
        result(spec.get("suspend") is not True, f"{tag}: Job is not suspended (nothing would admit it)")

ns_raw = open(ns_path, encoding="utf-8").read().replace("__NAMESPACE__", DUMMY["__NAMESPACE__"])
try:
    ns_docs = [d for d in yaml.safe_load_all(ns_raw) if d is not None]
    result(any(isinstance(d, dict) and d.get("kind") == "Namespace" for d in ns_docs),
           "manifests/00-namespace.yaml is valid YAML with a Namespace document")
except yaml.YAMLError as e:
    result(False, "manifests/00-namespace.yaml is valid YAML", str(e).replace("\n", " "))
print("DONE", flush=True)
PYEOF
PY_RC=$?
while IFS= read -r line; do
    case "${line}" in
        "RESULT "*)
            rest="${line#RESULT }"
            check "${rest#* }" "${rest%% *}"
            ;;
    esac
done < "${WORK}/manifests.out"
grep -qx DONE "${WORK}/manifests.out" && [[ "${PY_RC}" == "0" ]]
check "manifest checks ran to completion (python3 exit ${PY_RC}; PyYAML is required)" "$?"

echo "=== check 0 (neuron-ls): fault injection with a stub binary, no real device needed ==="
CHECK_BIN="${WORK}/checkbin"
mkdir -p "${CHECK_BIN}"
RESULTS0="${WORK}/check0-results"

write_neuron_ls_stub() {
    printf '%s\n' "$1" > "${CHECK_BIN}/neuron-ls.out"
    {
        echo '#!/usr/bin/env bash'
        echo "cat '${CHECK_BIN}/neuron-ls.out'"
    } > "${CHECK_BIN}/neuron-ls"
    chmod +x "${CHECK_BIN}/neuron-ls"
}

run_check0() {
    rm -rf "${RESULTS0}"
    mkdir -p "${RESULTS0}"
    EXPECTED_DEVICE_COUNT="$1" EXPECTED_NEURONCORE_COUNT="$2" RESULTS_DIR="${RESULTS0}" \
        PATH="${CHECK_BIN}:${PATH}" bash "${BASE_DIR}/lib/checks/0-neuron-ls-check.sh" >"${WORK}/check0.out" 2>&1
    echo "$?"
}

write_neuron_ls_stub '[{"neuron_device": 0, "nc_count": 4}]'
RC="$(run_check0 1 4)"
[[ "${RC}" == "0" ]]
check "check 0 PASSes against a stub neuron-ls reporting the expected device/core count" "$?"
grep -q '"status": "PASS"' "${RESULTS0}/check-0-neuron-ls.json" 2>/dev/null
check "check 0's own result file reports PASS" "$?"

RC="$(run_check0 1 8)"
[[ "${RC}" == "1" ]]
check "check 0 FAILs when the stub's nc_count (4) does not match EXPECTED_NEURONCORE_COUNT (8)" "$?"
grep -q "NeuronCore count mismatch" "${WORK}/check0.out"
check "check 0's own FAIL message names the NeuronCore mismatch, not a generic error" "$?"

RC="$(run_check0 2 4)"
[[ "${RC}" == "1" ]]
check "check 0 FAILs when the stub's device count (1) does not match EXPECTED_DEVICE_COUNT (2)" "$?"
grep -q "Neuron device count mismatch" "${WORK}/check0.out"
check "check 0's own FAIL message names the device-count mismatch, not a generic error" "$?"

printf '#!/usr/bin/env bash\necho "not valid json at all"\n' > "${CHECK_BIN}/neuron-ls"
chmod +x "${CHECK_BIN}/neuron-ls"
RC="$(run_check0 1 4)"
[[ "${RC}" == "1" ]]
check "check 0 FAILs cleanly, not a crash, when neuron-ls prints something that is not JSON" "$?"
grep -q "could not parse" "${WORK}/check0.out"
check "check 0's own FAIL message names a parse failure, never a silent pass" "$?"

rm -f "${CHECK_BIN}/neuron-ls"
RC="$(run_check0 1 4)"
[[ "${RC}" == "1" ]]
check "check 0 FAILs when neuron-ls is missing from PATH entirely" "$?"
grep -q "not found on PATH" "${WORK}/check0.out"
check "check 0's own FAIL message names the missing binary" "$?"

RC="$(EXPECTED_DEVICE_COUNT=0 EXPECTED_NEURONCORE_COUNT=4 RESULTS_DIR="${RESULTS0}" bash "${BASE_DIR}/lib/checks/0-neuron-ls-check.sh" >"${WORK}/check0.out" 2>&1; echo "$?")"
[[ "${RC}" == "1" ]]
check "check 0 refuses EXPECTED_DEVICE_COUNT=0 as not a real expectation to check against" "$?"

echo "=== check 2 (EFA enumeration): fault injection with a stub lspci, no real device needed ==="
RESULTS2="${WORK}/check2-results"

run_check2() {
    rm -rf "${RESULTS2}"
    mkdir -p "${RESULTS2}"
    EXPECTED_EFA_COUNT="$1" RESULTS_DIR="${RESULTS2}" \
        PATH="${CHECK_BIN}:${PATH}" bash "${BASE_DIR}/lib/checks/2-efa-enumeration-check.sh" >"${WORK}/check2.out" 2>&1
    echo "$?"
}
printf '#!/usr/bin/env bash\necho "32:00.0 Ethernet controller [0200]: Amazon.com, Inc. Elastic Fabric Adapter (EFA) [1d0f:efa2]"\n' > "${CHECK_BIN}/lspci"
chmod +x "${CHECK_BIN}/lspci"
RC="$(run_check2 1)"
[[ "${RC}" == "0" ]]
check "check 2 exits 0 against a stub lspci reporting the expected EFA count (PASS, or WARN if this static-check host's own /sys/module/efa is absent, which it checks for real)" "$?"

RC="$(run_check2 2)"
[[ "${RC}" == "1" ]]
check "check 2 FAILs when the stub's EFA count (1) does not match EXPECTED_EFA_COUNT (2)" "$?"
grep -q "EFA PCI device count mismatch" "${WORK}/check2.out"
check "check 2's own FAIL message names the EFA count mismatch, not a generic error" "$?"

echo "=== check 1 (NEFF compile+load): this host has no Neuron Runtime or device, by construction ==="
# Not a stub: this static-check host (the EC2 runner, never the Mac) has
# neither torch_neuronx nor a Neuron device, so check 1 fails for real here
# -- the same way it would on any host without Trainium hardware. This is
# genuine coverage of check 1's own FAIL path (DA-54), not a simulation.
RESULTS1="${WORK}/check1-results"
mkdir -p "${RESULTS1}"
RESULTS_DIR="${RESULTS1}" python3 "${BASE_DIR}/lib/checks/1-neff-compile-load-check.py" --target trn2 >"${WORK}/check1.out" 2>&1
RC=$?
[[ "${RC}" == "1" ]]
check "check 1 FAILs on a host with no Neuron Runtime/device (this static-check host itself)" "$?"
grep -qE "FAIL: 1-neff-compile-load" "${WORK}/check1.out"
check "check 1 prints its own FAIL line, not a silent or uncaught exit" "$?"
[[ -f "${RESULTS1}/check-1-neff-compile-load.json" ]]
check "check 1 writes its own result file even on failure" "$?"
grep -q '"status": "FAIL"' "${RESULTS1}/check-1-neff-compile-load.json" 2>/dev/null
check "check 1's own result file reports FAIL" "$?"

echo "=== lib/aggregate-results.py: NOT_RUN, WARN and unrecognized-status handling ==="
AGG_DIR="${WORK}/agg"
mkdir -p "${AGG_DIR}"
rm -f "${AGG_DIR}"/*.json
cat > "${AGG_DIR}/check-0-neuron-ls.json" <<'EOF'
{"check": "0-neuron-ls", "status": "PASS", "message": "ok"}
EOF
python3 "${BASE_DIR}/lib/aggregate-results.py" --results-dir "${AGG_DIR}" >/dev/null
RC=$?
[[ "${RC}" == "1" ]]
check "aggregate-results.py exits non-zero when checks 1 and 2 never wrote a result (NOT_RUN counts as FAIL, not PASS)" "$?"
python3 -c "
import json
d = json.load(open('${AGG_DIR}/summary.json'))
by = {c['check']: c['status'] for c in d['checks']}
assert d['overall_status'] == 'FAIL', d['overall_status']
assert by.get('1-neff-compile-load') == 'NOT_RUN', by
assert by.get('2-efa-enumeration') == 'NOT_RUN', by
"
check "summary.json marks the two checks that wrote no result file as NOT_RUN, by name" "$?"

cat > "${AGG_DIR}/check-1-neff-compile-load.json" <<'EOF'
{"check": "1-neff-compile-load", "status": "WARN", "message": "warn"}
EOF
cat > "${AGG_DIR}/check-2-efa-enumeration.json" <<'EOF'
{"check": "2-efa-enumeration", "status": "PASS", "message": "ok"}
EOF
python3 "${BASE_DIR}/lib/aggregate-results.py" --results-dir "${AGG_DIR}" >/dev/null
RC=$?
[[ "${RC}" == "0" ]]
check "aggregate-results.py exits 0 (WARN, not FAIL) when no check failed and one is WARN" "$?"
python3 -c "
import json
d = json.load(open('${AGG_DIR}/summary.json'))
assert d['overall_status'] == 'WARN', d['overall_status']
"
check "summary.json overall_status is WARN, not PASS, when any check is WARN" "$?"

cat > "${AGG_DIR}/check-0-neuron-ls.json" <<'EOF'
{"check": "0-neuron-ls", "status": "not-a-real-status", "message": "x"}
EOF
python3 "${BASE_DIR}/lib/aggregate-results.py" --results-dir "${AGG_DIR}" >/dev/null
RC=$?
[[ "${RC}" == "1" ]]
check "aggregate-results.py exits non-zero on an unrecognized status (treated as ERROR, never silently PASS)" "$?"

echo "=== $([[ ${FAILED} -eq 0 ]] && echo ALL PASS || echo SOME FAILED) ==="
exit "${FAILED}"
