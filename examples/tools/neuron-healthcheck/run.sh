#!/usr/bin/env bash
# Run this tool's three Neuron node checks (neuron-ls device/NeuronCore
# count, NEFF compile+load on the real device, EFA PCI enumeration) as one
# Kubernetes Job on a real cluster, before a Neuron verification run
# (issue #97). See README.md for the design and the instance-profile table.
#
# This does not deliver anything to a cell (examples/ is not gitops/, see
# ../../../AGENTS.md section 3): it is a script you run by hand, the same
# shape as ../gpu-healthcheck/run.sh.
#
# Required environment (export before running; the current kubeconfig
# context must already point at the target cluster -- this script never
# changes it):
#   INSTANCE_TYPE   the Neuron node's instance type, must have exactly one
#                   row in profiles/instance-profiles.conf (rendered by
#                   tools/render-profile.sh). This script refuses to start
#                   otherwise: a pre-flight with no expectation to compare
#                   against must not read as "nothing to check, so PASS".
# Optional environment:
#   NAMESPACE        (neuron-healthcheck)
#   QUEUE_NAME        Kueue LocalQueue to bind the Job to. Empty (default):
#                     the Job runs unsuspended immediately, no Kueue
#                     involvement -- use this when Kueue is not installed
#                     on the target cluster.
#   BASE_IMAGE        (the AWS Neuron PyTorch inference DLC on the SDK 2.31
#                     line, pinned by tag and digest -- see README.md
#                     "Base image")
#   RUN_ID            (date +%s), must be unique per concurrent run on one
#                     cluster (ConfigMap/Job names carry it)
#   INJECT_BAD_DEVICE_COUNT  "1": render instance-profiles.conf with
#                     INSTANCE_TYPE's own DEVICE_COUNT off by +1, for this
#                     tool's own deliberate-failure Test Plan step only.
#                     Never set for a real pre-flight.
#   KUBECTL           (kubectl)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL:-kubectl}"

DEFAULT_BASE_IMAGE="public.ecr.aws/neuron/pytorch-inference-neuronx:2.9.0-neuronx-py312-sdk2.31.1-ubuntu24.04@sha256:de98dc02a68765df5688d301134debbd677ccdc4fbd6873af34fafafcc3462ec"

: "${INSTANCE_TYPE:?export INSTANCE_TYPE}"
NAMESPACE="${NAMESPACE:-neuron-healthcheck}"
QUEUE_NAME="${QUEUE_NAME:-}"
BASE_IMAGE="${BASE_IMAGE:-${DEFAULT_BASE_IMAGE}}"
RUN_ID="${RUN_ID:-$(date +%s)}"
INJECT_BAD_DEVICE_COUNT="${INJECT_BAD_DEVICE_COUNT:-0}"

# These values are substituted into the manifest with sed and become
# Kubernetes object names, so refuse anything that is not a DNS-1123 label
# before it can break the substitution or the object name.
for pair in "RUN_ID=${RUN_ID}" "NAMESPACE=${NAMESPACE}" "QUEUE_NAME=${QUEUE_NAME}"; do
    val="${pair#*=}"
    [[ -z "${val}" && "${pair%%=*}" == "QUEUE_NAME" ]] && continue
    if [[ ! "${val}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        echo "[run.sh] FATAL: ${pair%%=*}='${val}' is not a DNS-1123 label (lowercase letters, digits, '-')" >&2
        exit 1
    fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "[run.sh] namespace=${NAMESPACE} instance_type=${INSTANCE_TYPE} run_id=${RUN_ID} queue=${QUEUE_NAME:-<none>} inject_bad_device_count=${INJECT_BAD_DEVICE_COUNT}"

if [[ "${INJECT_BAD_DEVICE_COUNT}" == "1" ]]; then
    "${SCRIPT_DIR}/tools/render-profile.sh" --inject-bad-device-count "${INSTANCE_TYPE}" > "${WORK}/instance-profiles.conf"
else
    "${SCRIPT_DIR}/tools/render-profile.sh" > "${WORK}/instance-profiles.conf"
fi

# Fail here, not with a silent PASS later: a typo'd INSTANCE_TYPE, or a real
# type this tool has not onboarded yet, must not read as "nothing to check,
# so PASS".
ROW_COUNT=$(awk -F'|' -v t="${INSTANCE_TYPE}" '$1==t' "${WORK}/instance-profiles.conf" | wc -l | tr -d ' ')
if [[ "${ROW_COUNT}" != "1" ]]; then
    echo "[run.sh] FATAL: instance-profiles.conf has ${ROW_COUNT} row(s) for INSTANCE_TYPE=${INSTANCE_TYPE} (need exactly 1) -- refusing to run a pre-flight with no real expectation to check against. See profiles/instance-profiles.conf." >&2
    exit 1
fi
if [[ "${INJECT_BAD_DEVICE_COUNT}" == "1" ]]; then
    grep -q "TEST ONLY: DEVICE_COUNT bumped by +1 for --inject-bad-device-count (${INSTANCE_TYPE})" "${WORK}/instance-profiles.conf" || {
        echo "[run.sh] FATAL: INJECT_BAD_DEVICE_COUNT=1 was set but render-profile.sh did not actually inject anything for ${INSTANCE_TYPE} -- this would silently run a normal PASS-path check while claiming to test the FAIL path." >&2
        exit 1
    }
fi

ROW="$(awk -F'|' -v t="${INSTANCE_TYPE}" '$1==t' "${WORK}/instance-profiles.conf")"
IFS='|' read -r _ EXPECTED_DEVICE_COUNT EXPECTED_NEURONCORE_COUNT EXPECTED_EFA_COUNT EXTRA <<<"${ROW}"
for v in "${EXPECTED_DEVICE_COUNT}" "${EXPECTED_NEURONCORE_COUNT}" "${EXPECTED_EFA_COUNT}"; do
    # No leading zero (0 itself excepted): this value is sed-substituted into
    # the Job's own environment and later compared with bash's arithmetic
    # `-ne`/`-gt` in lib/checks/*.sh, which reads a leading-zero operand as
    # octal ("08" errors, "010" silently reads as 8) -- see lib/common.sh's
    # require_int for the same rule on the Job-side copy of this check.
    if [[ ! "${v}" =~ ^(0|[1-9][0-9]*)$ ]] || [[ -n "${EXTRA:-}" ]]; then
        echo "[run.sh] FATAL: malformed row for ${INSTANCE_TYPE} in instance-profiles.conf: '${ROW}' (want INSTANCE_TYPE|DEVICE_COUNT|NEURONCORE_COUNT|EFA_COUNT, all counts non-negative integers with no leading zero)" >&2
        exit 1
    fi
done
if [[ "${EXPECTED_DEVICE_COUNT}" -lt 1 ]] || [[ "${EXPECTED_NEURONCORE_COUNT}" -lt 1 ]]; then
    echo "[run.sh] FATAL: malformed row for ${INSTANCE_TYPE} in instance-profiles.conf: '${ROW}' (DEVICE_COUNT and NEURONCORE_COUNT must be at least 1 -- a Neuron node with zero devices or zero cores is not a real expectation to check against; EFA_COUNT may be 0 for a type with no EFA)" >&2
    exit 1
fi
echo "[run.sh] expected: devices=${EXPECTED_DEVICE_COUNT} nc_count=${EXPECTED_NEURONCORE_COUNT} efa=${EXPECTED_EFA_COUNT}"

# Refuse a reused RUN_ID before creating anything (namespace included):
# a Job's template is immutable after creation, so re-applying it would not
# actually run anything new, and the poll loop below would read the OLD
# Job's Complete/Failed condition at once -- a stale verdict printed as if
# it were fresh.
JOB_NAME="neuron-healthcheck-preflight-${RUN_ID}"
if "${KUBECTL}" get job -n "${NAMESPACE}" "${JOB_NAME}" >/dev/null 2>&1; then
    echo "[run.sh] FATAL: job/${JOB_NAME} already exists in ns/${NAMESPACE} -- re-applying it would not actually run anything new and would report its OLD result. Pick a different RUN_ID, or delete it first: kubectl delete job -n ${NAMESPACE} ${JOB_NAME}" >&2
    exit 1
fi

"${KUBECTL}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL}" apply -f - >/dev/null

LIB="${SCRIPT_DIR}/lib"
RENDERED="${WORK}/rendered.yaml"

{
    # Two ConfigMaps, one per mounted directory: lib/ (shared helper and
    # aggregator) and lib/checks/ (the three checks). Files are listed one
    # by one -- `--from-file=<dir>` skips subdirectories, and naming each
    # file keeps a stray file in lib/ from riding along into the Job.
    "${KUBECTL}" create configmap "neuron-healthcheck-lib-root-${RUN_ID}" -n "${NAMESPACE}" \
        --from-file="${LIB}/common.sh" \
        --from-file="${LIB}/aggregate-results.py" \
        --dry-run=client -o yaml
    echo "---"
    "${KUBECTL}" create configmap "neuron-healthcheck-lib-checks-${RUN_ID}" -n "${NAMESPACE}" \
        --from-file="${LIB}/checks/0-neuron-ls-check.sh" \
        --from-file="${LIB}/checks/1-neff-compile-load-check.py" \
        --from-file="${LIB}/checks/2-efa-enumeration-check.sh" \
        --dry-run=client -o yaml
    echo "---"
} > "${RENDERED}"

job_tmpl="${WORK}/job.yaml"
cp "${SCRIPT_DIR}/manifests/job-preflight.yaml.tmpl" "${job_tmpl}"
if [[ -n "${QUEUE_NAME}" ]]; then
    sed -i.bak "s/# KUEUE-ONLY//; s/__QUEUE_NAME__/${QUEUE_NAME}/g" "${job_tmpl}"
else
    sed -i.bak "/# KUEUE-ONLY/d" "${job_tmpl}"
fi
sed -i.bak \
    -e "s/__RUN_ID__/${RUN_ID}/g" \
    -e "s/__NAMESPACE__/${NAMESPACE}/g" \
    -e "s/__INSTANCE_TYPE__/${INSTANCE_TYPE}/g" \
    -e "s#__BASE_IMAGE__#${BASE_IMAGE}#g" \
    -e "s/__EXPECTED_DEVICE_COUNT__/${EXPECTED_DEVICE_COUNT}/g" \
    -e "s/__EXPECTED_NEURONCORE_COUNT__/${EXPECTED_NEURONCORE_COUNT}/g" \
    -e "s/__EXPECTED_EFA_COUNT__/${EXPECTED_EFA_COUNT}/g" \
    "${job_tmpl}"
grep -q '^#' "${job_tmpl}" && sed -i.bak '/^#/d' "${job_tmpl}"
cat "${job_tmpl}" >> "${RENDERED}"

"${KUBECTL}" apply -f "${RENDERED}"

echo "[run.sh] waiting for Job/${JOB_NAME} in ns/${NAMESPACE} to reach Complete or Failed (up to 20m)..."
# Poll status.conditions for either Complete or Failed, not a single
# `kubectl wait --for=condition=complete`: a Job with backoffLimit: 0 that
# fails reaches Failed, which that wait form never returns for, so a real
# check failure would otherwise read as a 20-minute hang instead of a
# prompt report.
DEADLINE=$(( $(date +%s) + 1200 ))
JOB_COND=""
TIMED_OUT=1
while [[ $(date +%s) -lt "${DEADLINE}" ]]; do
    JOB_COND=$("${KUBECTL}" get job -n "${NAMESPACE}" "${JOB_NAME}" \
        -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
    case "${JOB_COND}" in
        *Complete*) JOB_RESULT=PASS; TIMED_OUT=0; break ;;
        *Failed*) JOB_RESULT=FAIL; TIMED_OUT=0; break ;;
    esac
    sleep 10
done
JOB_RESULT="${JOB_RESULT:-FAIL}"
# Keyed on whether the loop actually broke out early (TIMED_OUT), not on
# whether JOB_COND happens to be non-empty: a Kueue-suspended Job that was
# never admitted carries a real, non-empty condition (Suspended=True) the
# whole time, which is exactly the "not admitted" case this warning names.
[[ "${TIMED_OUT}" == "0" ]] || echo "[run.sh] WARNING: Job neither Complete nor Failed after 20m (condition=${JOB_COND:-<none>}; not admitted, stuck Pending, still pulling the image, or still running) -- treating as FAIL" >&2

POD=$("${KUBECTL}" get pods -n "${NAMESPACE}" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
NODE=$("${KUBECTL}" get pods -n "${NAMESPACE}" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
echo "[run.sh] result=${JOB_RESULT} job_condition=${JOB_COND:-<none>} job=${JOB_NAME} pod=${POD:-<none>} node=${NODE:-<none>}"
if [[ -n "${POD}" ]]; then
    "${KUBECTL}" logs -n "${NAMESPACE}" "${POD}" || true
else
    "${KUBECTL}" describe job -n "${NAMESPACE}" "${JOB_NAME}" || true
fi

# The two ConfigMaps this run created have no ownerReference to the Job
# (the Job's UID is not known until after they are rendered in the same
# apply) and ttlSecondsAfterFinished only cleans up the Job itself, so they
# would otherwise accumulate across runs. Delete them explicitly, success
# or failure.
"${KUBECTL}" delete configmap -n "${NAMESPACE}" \
    "neuron-healthcheck-lib-root-${RUN_ID}" \
    "neuron-healthcheck-lib-checks-${RUN_ID}" \
    --ignore-not-found >/dev/null

echo "[run.sh] RESULT: ${JOB_RESULT}"
[[ "${JOB_RESULT}" == "PASS" ]]
