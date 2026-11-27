#!/usr/bin/env bash
# Run the vendored awsome-distributed-ai lightweight GPU/EFA health-check
# suite (checks 0-3) as one Kubernetes Job on a real cluster, before a GPU
# verification run (issue #30). See README.md for the design and the
# instance-profile table.
#
# This does not deliver anything to a cell (examples/ is not gitops/, see
# ../../../AGENTS.md section 3): it is a script you run by hand, the same
# shape as ../run-board.
#
# Required environment (export before running; the current kubeconfig
# context must already point at the target cluster -- this script never
# changes it):
#   INSTANCE_TYPE   the GPU node's instance type, must have exactly one row
#                   in vendor/awsome-distributed-ai/instance-profiles.conf
#                   or profiles/g6e-overlay.conf (tools/render-profiles.sh
#                   merges both). This script refuses to start otherwise --
#                   upstream's own lib/common.sh load_instance_profile()
#                   treats a missing row as EXPECTED_GPU_COUNT=
#                   EXPECTED_EFA_COUNT=0 and only logs a warning, which this
#                   script does not accept as "nothing to check, so PASS".
# Optional environment:
#   NAMESPACE        (gpu-healthcheck)
#   QUEUE_NAME        Kueue LocalQueue to bind the Job to. Empty (default):
#                     the Job runs unsuspended immediately, no Kueue
#                     involvement -- use this when Kueue is not installed
#                     on the target cluster.
#   BASE_IMAGE        (nvcr.io/nvidia/cloud-native/dcgm:3.3.7-1-ubuntu22.04,
#                     the same public, pre-built image upstream's own
#                     kubernetes/Dockerfile uses as its FROM; pin by digest
#                     once confirmed for the account/region you run this
#                     from -- see README.md "Pinning the base image")
#   RUN_ID            (date +%s), must be unique per concurrent run on one
#                     cluster (ConfigMap/Job names carry it)
#   INJECT_BAD_EFA_COUNT  "1": render the merged instance-profiles.conf with
#                     INSTANCE_TYPE's own EFA_COUNT off by +1, for this
#                     tool's own deliberate-failure Test Plan step only.
#                     Never set for a real pre-flight.
#   SUITE_ARGS        Passed to gpu-healthcheck.sh verbatim (default
#                     "--suite lightweight", checks 0-3, the pre-flight's
#                     own scope). "--suite intensive --exclusive" runs
#                     checks 4-6 instead (DCGM L4, NCCL allreduce, EFA
#                     loopback) -- the two suites are separate selections,
#                     not additive: upstream's own gpu-healthcheck.sh
#                     --suite lightweight|intensive and its own
#                     "Checks 4-6" description for intensive (vendor/
#                     awsome-distributed-ai/gpu-healthcheck.sh) confirm
#                     this, and a real run with --suite intensive
#                     --exclusive reported 3/3 checks, not 7/7. Run this
#                     script twice, once with each suite, for both.
#                     Without --exclusive, upstream itself refuses to
#                     start the intensive suite at all ("Intensive suite
#                     requires --exclusive flag to confirm exclusive node
#                     access", same vendored file) -- confirmed by
#                     reading that line, not by running without the flag.
#   KUBECTL           (kubectl)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL:-kubectl}"

: "${INSTANCE_TYPE:?export INSTANCE_TYPE}"
NAMESPACE="${NAMESPACE:-gpu-healthcheck}"
QUEUE_NAME="${QUEUE_NAME:-}"
BASE_IMAGE="${BASE_IMAGE:-nvcr.io/nvidia/cloud-native/dcgm:3.3.7-1-ubuntu22.04}"
RUN_ID="${RUN_ID:-$(date +%s)}"
# The arguments gpu-healthcheck.sh itself is invoked with, verbatim
# (upstream's own --suite/--check/--exclusive/--dry-run flags). Default
# "--suite lightweight" substitutes the identical literal the previous
# hardcoded invocation used, in the same position, so the command this
# script runs for a caller that does not set this is unchanged; the
# rendered Job's own log banner line changed text (from "running
# lightweight suite (checks 0-3)" to "running suite: --suite
# lightweight"), stated here rather than left implicit. "--suite
# intensive --exclusive" runs checks 4-6 instead of 0-3, not in
# addition to them -- see this variable's own usage-comment entry above
# for the exact confirmation and citation.
SUITE_ARGS="${SUITE_ARGS:---suite lightweight}"
INJECT_BAD_EFA_COUNT="${INJECT_BAD_EFA_COUNT:-0}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "[run.sh] namespace=${NAMESPACE} instance_type=${INSTANCE_TYPE} run_id=${RUN_ID} queue=${QUEUE_NAME:-<none>} inject_bad_efa_count=${INJECT_BAD_EFA_COUNT}"

if [[ "${INJECT_BAD_EFA_COUNT}" == "1" ]]; then
    "${SCRIPT_DIR}/tools/render-profiles.sh" --inject-bad-efa-count "${INSTANCE_TYPE}" > "${WORK}/instance-profiles.conf"
else
    "${SCRIPT_DIR}/tools/render-profiles.sh" > "${WORK}/instance-profiles.conf"
fi

# Fail here, not with a silent PASS later: upstream's own load_instance_profile()
# treats a missing row as EXPECTED_GPU_COUNT=EXPECTED_EFA_COUNT=0 and logs a
# warning only -- which this tool's own exit code does not surface at all. A
# typo'd INSTANCE_TYPE, or a real type this tool has not onboarded yet, must
# not read as "nothing to check, so PASS".
ROW_COUNT=$(awk -F'|' -v t="${INSTANCE_TYPE}" '$1==t' "${WORK}/instance-profiles.conf" | wc -l | tr -d ' ')
if [[ "${ROW_COUNT}" != "1" ]]; then
    echo "[run.sh] FATAL: instance-profiles.conf has ${ROW_COUNT} row(s) for INSTANCE_TYPE=${INSTANCE_TYPE} (need exactly 1) -- refusing to run a pre-flight with no real expectation to check against. See profiles/g6e-overlay.conf and vendor/awsome-distributed-ai/instance-profiles.conf." >&2
    exit 1
fi
if [[ "${INJECT_BAD_EFA_COUNT}" == "1" ]]; then
    grep -q "TEST ONLY: EFA_COUNT bumped by +1 for --inject-bad-efa-count (${INSTANCE_TYPE})" "${WORK}/instance-profiles.conf" || {
        echo "[run.sh] FATAL: INJECT_BAD_EFA_COUNT=1 was set but render-profiles.sh did not actually inject anything for ${INSTANCE_TYPE} -- this would silently run a normal PASS-path check while claiming to test the FAIL path." >&2
        exit 1
    }
fi

"${KUBECTL}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL}" apply -f - >/dev/null

# Refuse a reused RUN_ID outright, rather than let `kubectl apply` on an
# already-finished Job's own spec silently no-op: a Job's template is
# immutable after creation, so re-applying it would not actually run
# anything new, and the poll loop below would read the OLD Job's Complete/
# Failed condition at once -- a stale verdict printed as if it were fresh.
JOB_NAME="gpu-healthcheck-preflight-${RUN_ID}"
if "${KUBECTL}" get job -n "${NAMESPACE}" "${JOB_NAME}" >/dev/null 2>&1; then
    echo "[run.sh] FATAL: job/${JOB_NAME} already exists in ns/${NAMESPACE} -- re-applying it would not actually run anything new and would report its OLD result. Pick a different RUN_ID, or delete it first: kubectl delete job -n ${NAMESPACE} ${JOB_NAME}" >&2
    exit 1
fi

VENDOR="${SCRIPT_DIR}/vendor/awsome-distributed-ai"
RENDERED="${WORK}/rendered.yaml"

{
    # One ConfigMap holds both gpu-healthcheck.sh and the merged
    # instance-profiles.conf (not two, and not a separate file subPath
    # mount for the profile): fewer independently-mounted volumes under the
    # same directory, and no subPath mount of a single file into a
    # directory another ConfigMap volume already owns.
    "${KUBECTL}" create configmap "gpu-healthcheck-vendor-root-${RUN_ID}" -n "${NAMESPACE}" \
        --from-file="${VENDOR}/gpu-healthcheck.sh" \
        --from-file="instance-profiles.conf=${WORK}/instance-profiles.conf" \
        --dry-run=client -o yaml
    echo "---"
    "${KUBECTL}" create configmap "gpu-healthcheck-vendor-checks-${RUN_ID}" -n "${NAMESPACE}" \
        --from-file="${VENDOR}/checks" \
        --dry-run=client -o yaml
    echo "---"
    "${KUBECTL}" create configmap "gpu-healthcheck-vendor-lib-${RUN_ID}" -n "${NAMESPACE}" \
        --from-file="${VENDOR}/lib" \
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
    -e "s#__SUITE_ARGS__#${SUITE_ARGS}#g" \
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
# whole time, which is exactly the "not admitted" case this warning exists
# to name -- checking only "-n JOB_COND" would silently say nothing for it.
[[ "${TIMED_OUT}" == "0" ]] || echo "[run.sh] WARNING: Job neither Complete nor Failed after 20m (condition=${JOB_COND:-<none>}; not admitted, stuck Pending, or still running) -- treating as FAIL" >&2

POD=$("${KUBECTL}" get pods -n "${NAMESPACE}" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
NODE=$("${KUBECTL}" get pods -n "${NAMESPACE}" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
echo "[run.sh] result=${JOB_RESULT} job_condition=${JOB_COND:-<none>} job=${JOB_NAME} pod=${POD:-<none>} node=${NODE:-<none>}"
if [[ -n "${POD}" ]]; then
    "${KUBECTL}" logs -n "${NAMESPACE}" "${POD}" || true
else
    "${KUBECTL}" describe job -n "${NAMESPACE}" "${JOB_NAME}" || true
fi

# The three ConfigMaps this run created have no ownerReference to the Job
# (the Job's UID is not known until after they are rendered in the same
# apply) and ttlSecondsAfterFinished only cleans up the Job itself, so they
# would otherwise accumulate across runs. Delete them explicitly, success
# or failure, rather than leave that for a human to notice later.
"${KUBECTL}" delete configmap -n "${NAMESPACE}" \
    "gpu-healthcheck-vendor-root-${RUN_ID}" \
    "gpu-healthcheck-vendor-checks-${RUN_ID}" \
    "gpu-healthcheck-vendor-lib-${RUN_ID}" \
    --ignore-not-found >/dev/null

echo "[run.sh] RESULT: ${JOB_RESULT}"
[[ "${JOB_RESULT}" == "PASS" ]]
