import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.k8s_mapping import map_job_status, map_kueue_workload_status  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _load(name):
    with open(FIXTURES / name) as f:
        return json.load(f)


def test_job_running():
    mapped = map_job_status(_load("job_running.json"))
    assert mapped == {"state": "running", "actual_start": "2026-11-20T17:30:00Z", "actual_end": None}


def test_job_done():
    mapped = map_job_status(_load("job_done.json"))
    assert mapped["state"] == "done"
    assert mapped["actual_start"] == "2026-11-20T17:30:00Z"
    assert mapped["actual_end"] == "2026-11-20T19:20:00Z"


def test_job_failed_uses_condition_timestamp_not_completion_time():
    mapped = map_job_status(_load("job_failed.json"))
    assert mapped["state"] == "failed"
    # A failed Job never gets completionTime set; the Failed condition's own
    # lastTransitionTime is the only real end-time signal.
    assert mapped["actual_end"] == "2026-11-20T18:05:00Z"


def test_job_with_empty_status_is_unknown_not_pending():
    mapped = map_job_status(_load("job_pending_empty_status.json"))
    assert mapped["state"] == "unknown"


def test_job_never_started_but_has_status_block_is_pending():
    mapped = map_job_status({"status": {"conditions": []}})
    assert mapped["state"] == "pending"


def test_kueue_workload_admitted_is_running():
    mapped = map_kueue_workload_status(_load("workload_admitted.json"))
    assert mapped["state"] == "running"
    assert mapped["actual_start"] == "2026-11-20T20:45:00Z"


def test_kueue_workload_finished_success_is_done():
    mapped = map_kueue_workload_status(_load("workload_finished_success.json"))
    assert mapped["state"] == "done"
    assert mapped["actual_start"] == "2026-11-20T20:45:00Z"
    assert mapped["actual_end"] == "2026-11-20T22:30:00Z"


def test_kueue_workload_finished_failure_reason_is_failed():
    doc = {
        "status": {
            "conditions": [
                {"type": "Admitted", "status": "True", "lastTransitionTime": "t1"},
                {"type": "Finished", "status": "True", "lastTransitionTime": "t2", "reason": "Failed"},
            ]
        }
    }
    mapped = map_kueue_workload_status(doc)
    assert mapped["state"] == "failed"


def test_kueue_workload_finished_with_unrecognized_reason_is_unknown_not_done():
    # This is the fail-open bug this mapping must not have: any reason other than the
    # two the allowlist explicitly recognizes must render as "unknown", never silently
    # as "done".
    doc = {
        "status": {
            "conditions": [
                {"type": "Admitted", "status": "True", "lastTransitionTime": "t1"},
                {"type": "Finished", "status": "True", "lastTransitionTime": "t2", "reason": "SomeFutureReasonValue"},
            ]
        }
    }
    mapped = map_kueue_workload_status(doc)
    assert mapped["state"] == "unknown"


def test_kueue_workload_finished_with_no_reason_is_unknown_not_done():
    doc = {
        "status": {
            "conditions": [
                {"type": "Admitted", "status": "True", "lastTransitionTime": "t1"},
                {"type": "Finished", "status": "True", "lastTransitionTime": "t2"},
            ]
        }
    }
    mapped = map_kueue_workload_status(doc)
    assert mapped["state"] == "unknown"


def test_kueue_workload_no_status_is_unknown():
    assert map_kueue_workload_status({})["state"] == "unknown"


def test_kueue_workload_not_yet_admitted_is_pending():
    doc = {"status": {"conditions": [{"type": "QuotaReserved", "status": "True", "lastTransitionTime": "t0"}]}}
    assert map_kueue_workload_status(doc)["state"] == "pending"
