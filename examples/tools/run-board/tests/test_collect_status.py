import json
import sys
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import collect_status  # noqa: E402
from lib.plan import PlanItem, StatusSource  # noqa: E402
from datetime import timedelta  # noqa: E402


def _item(kind, **src_kwargs):
    return PlanItem(
        id="x", name="X", lane="l",
        planned_start=timedelta(0), planned_duration=timedelta(hours=1),
        depends_on=(), stop_condition="",
        status_source=StatusSource(kind=kind, **src_kwargs),
    )


def test_manual_kind_reads_from_manual_status_dict():
    item = _item("manual", key="phase-a")
    entry, error = collect_status._collect_one(
        item, {"phase-a": {"state": "done", "actual_start": "a", "actual_end": "b"}}
    )
    assert error is None
    assert entry["state"] == "done"


def test_manual_kind_missing_key_is_a_collection_error_not_a_crash():
    item = _item("manual", key="does-not-exist")
    entry, error = collect_status._collect_one(item, {})
    assert entry is None
    assert error is not None
    assert "does-not-exist" in error


def test_job_kind_calls_readonly_exec_with_safe_argv_and_maps_result():
    item = _item("job", namespace="run-board-sample", name="tier0-baseline-node-a")
    fake_job_json = json.dumps({"status": {"startTime": "2026-11-20T17:30:00Z", "conditions": []}})
    with mock.patch.object(collect_status, "run_readonly", return_value=fake_job_json) as run:
        entry, error = collect_status._collect_one(item, {})
    assert error is None
    assert entry["state"] == "running"
    argv = run.call_args[0][0]
    # the exact argv shape, spelled out, so a future refactor can't silently widen it:
    assert argv == ["kubectl", "get", "job", "tier0-baseline-node-a", "-n", "run-board-sample", "-o", "json"]


def test_job_kind_collection_failure_becomes_a_reported_error_not_a_crash():
    item = _item("job", namespace="ns", name="n")
    with mock.patch.object(collect_status, "run_readonly", side_effect=RuntimeError("boom")):
        entry, error = collect_status._collect_one(item, {})
    assert entry is None
    assert "boom" in error


def test_kueue_workload_kind_calls_readonly_exec_with_safe_argv():
    item = _item("kueue_workload", namespace="ns", name="n")
    fake = json.dumps({"status": {"conditions": []}})
    with mock.patch.object(collect_status, "run_readonly", return_value=fake) as run:
        entry, error = collect_status._collect_one(item, {})
    assert error is None
    argv = run.call_args[0][0]
    assert argv == ["kubectl", "get", "workloads.kueue.x-k8s.io", "n", "-n", "ns", "-o", "json"]


def test_main_writes_status_json_with_manual_items_and_errors(tmp_path):
    plan_path = tmp_path / "plan.yaml"
    plan_path.write_text(
        """
items:
  - id: a
    name: A
    lane: l
    planned_start: "T+00:00"
    planned_duration: "PT1H"
    status_source: {kind: manual, key: a}
  - id: b
    name: B
    lane: l
    planned_start: "T+00:00"
    planned_duration: "PT1H"
    status_source: {kind: manual, key: missing}
"""
    )
    manual_path = tmp_path / "manual-status.json"
    manual_path.write_text(json.dumps({"a": {"state": "done"}}))
    out_path = tmp_path / "status.json"

    argv = [
        "collect_status.py", str(plan_path),
        "--block-start", "2026-11-20T11:00:00Z",
        "--manual-status", str(manual_path),
        "-o", str(out_path),
    ]
    with mock.patch.object(sys, "argv", argv):
        rc = collect_status.main()
    assert rc == 0

    doc = json.loads(out_path.read_text())
    assert doc["items"]["a"]["state"] == "done"
    assert doc["items"]["b"]["state"] == "unknown"
    assert doc["collection_errors"], "the missing manual entry for b must be reported"
