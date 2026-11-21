"""Pure mappings from a `kubectl get ... -o json` document to a raw lifecycle state.

Split out from `collect_status.py` so the actual decision logic — "is this Job
done, failed, or still running?" — is tested against fixture JSON
(`tests/fixtures/*.json`), not only indirectly through a live cluster call.

Only a small, allowlisted set of fields is ever read out of these documents and
carried forward (see `collect_status.py`): never the full object, which can
contain account IDs, image URIs, node IPs or free-text condition messages that
must not end up in a committed `status.json` or the rendered HTML.
"""
from __future__ import annotations


def map_job_status(job: dict) -> dict:
    """Map a Batch Job's `-o json` document to {state, actual_start, actual_end}.

    - running: has a startTime, no terminal condition yet.
    - done: a condition of type "Complete" with status "True" (completionTime
      is set only on success, matching the Job API's own contract).
    - failed: a condition of type "Failed" with status "True" — its own
      timestamp is used (not completionTime, which is not set on failure).
    - unknown: no status block at all (should not normally happen for a real
      Job, but a just-created one briefly has an empty status).
    """
    status = job.get("status", {})
    conditions = status.get("conditions", []) or []
    by_type = {c.get("type"): c for c in conditions if isinstance(c, dict)}

    failed = by_type.get("Failed")
    if failed and failed.get("status") == "True":
        return {
            "state": "failed",
            "actual_start": status.get("startTime"),
            "actual_end": failed.get("lastTransitionTime"),
        }

    complete = by_type.get("Complete")
    if complete and complete.get("status") == "True":
        return {
            "state": "done",
            "actual_start": status.get("startTime"),
            "actual_end": status.get("completionTime") or complete.get("lastTransitionTime"),
        }

    if status.get("startTime"):
        return {"state": "running", "actual_start": status.get("startTime"), "actual_end": None}

    if "status" not in job:
        return {"state": "unknown", "actual_start": None, "actual_end": None}

    return {"state": "pending", "actual_start": None, "actual_end": None}


def map_kueue_workload_status(workload: dict) -> dict:
    """Map a `workloads.kueue.x-k8s.io` `-o json` document to a raw state.

    Kueue's own Workload conditions: "Admitted" (True once scheduled; its
    `lastTransitionTime` is the real "actual start" for queueing purposes —
    the thing a run-board cares about is when the work actually got a slot,
    not when it was merely submitted), "Finished" (True on either success or
    failure).

    Finished=True does not by itself say which: this deliberately does NOT
    fail open to "done" by treating anything without an obvious failure
    keyword as success. Some Kueue releases have used the same `reason`
    value for both outcomes, which a keyword-guess mapping would render as
    "done" for a Workload that actually failed. Instead, only
    `reason == "Succeeded"` is mapped to done and only
    `reason == "Failed"` to failed; anything else — an unrecognized reason, a
    different Kueue minor version's own wording, a missing reason — maps to
    "unknown" rather than guessing. If this repo later pins a specific Kueue
    version, this allowlist should be checked against that version's actual
    `Reason` values and extended deliberately, not loosened by default.
    """
    status = workload.get("status", {})
    conditions = status.get("conditions", []) or []
    by_type = {c.get("type"): c for c in conditions if isinstance(c, dict)}

    finished = by_type.get("Finished")
    admitted = by_type.get("Admitted")

    if finished and finished.get("status") == "True":
        reason = finished.get("reason") or ""
        actual_start = admitted.get("lastTransitionTime") if admitted else None
        actual_end = finished.get("lastTransitionTime")
        if reason == "Succeeded":
            return {"state": "done", "actual_start": actual_start, "actual_end": actual_end}
        if reason == "Failed":
            return {"state": "failed", "actual_start": actual_start, "actual_end": actual_end}
        return {"state": "unknown", "actual_start": actual_start, "actual_end": actual_end}

    if admitted and admitted.get("status") == "True":
        return {"state": "running", "actual_start": admitted.get("lastTransitionTime"), "actual_end": None}

    if "status" not in workload:
        return {"state": "unknown", "actual_start": None, "actual_end": None}

    return {"state": "pending", "actual_start": None, "actual_end": None}
