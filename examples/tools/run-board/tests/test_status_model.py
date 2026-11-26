import sys
from datetime import timedelta
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.plan import PlanItem, StatusSource  # noqa: E402
from lib.status_model import (  # noqa: E402
    RawStatus,
    StatusError,
    dependency_edge_state,
    derive_display_state,
    load_status,
    parse_status_doc,
    parse_utc,
)

BLOCK_START = parse_utc("2026-11-20T11:00:00Z")
SAMPLE_STATUS = Path(__file__).resolve().parents[1] / "sample" / "status.sample.json"


def _item(planned_start_minutes=60, planned_duration_minutes=60, item_id="x"):
    return PlanItem(
        id=item_id,
        name="X",
        lane="node-a",
        planned_start=timedelta(minutes=planned_start_minutes),
        planned_duration=timedelta(minutes=planned_duration_minutes),
        depends_on=(),
        stop_condition="",
        status_source=StatusSource(kind="manual", key="x"),
    )


def test_sample_status_loads():
    doc = load_status(str(SAMPLE_STATUS))
    assert doc.block_start == BLOCK_START
    assert "dra-mode-node-a" in doc.items
    assert len(doc.collection_errors) == 1


def test_missing_entry_is_unknown_not_not_started():
    item = _item()
    disp = derive_display_state(item, None, BLOCK_START, BLOCK_START, grace_minutes=15)
    assert disp.base == "unknown"


def test_explicit_unknown_state_is_unknown():
    item = _item()
    raw = RawStatus(state="unknown", actual_start=None, actual_end=None, updated_at=None, note="")
    disp = derive_display_state(item, raw, BLOCK_START, BLOCK_START, grace_minutes=15)
    assert disp.base == "unknown"


def test_pending_before_planned_start_is_not_started():
    item = _item(planned_start_minutes=120)
    raw = RawStatus(state="pending", actual_start=None, actual_end=None, updated_at=None, note="")
    now = BLOCK_START + timedelta(minutes=60)
    disp = derive_display_state(item, raw, BLOCK_START, now, grace_minutes=15)
    assert disp.base == "not-started"
    assert disp.late is False


def test_pending_past_planned_start_plus_grace_is_overdue():
    item = _item(planned_start_minutes=60)
    raw = RawStatus(state="pending", actual_start=None, actual_end=None, updated_at=None, note="")
    now = BLOCK_START + timedelta(minutes=80)  # 20 min past start, grace is 15
    disp = derive_display_state(item, raw, BLOCK_START, now, grace_minutes=15)
    assert disp.base == "overdue-not-started"
    assert disp.late is True


def test_pending_within_grace_is_not_overdue():
    item = _item(planned_start_minutes=60)
    raw = RawStatus(state="pending", actual_start=None, actual_end=None, updated_at=None, note="")
    now = BLOCK_START + timedelta(minutes=70)  # 10 min past start, grace is 15
    disp = derive_display_state(item, raw, BLOCK_START, now, grace_minutes=15)
    assert disp.base == "not-started"


def test_running_started_late_is_flagged():
    item = _item(planned_start_minutes=60, planned_duration_minutes=120)
    raw = RawStatus(
        state="running",
        actual_start=BLOCK_START + timedelta(minutes=90),  # 30 min late, grace 15
        actual_end=None,
        updated_at=None,
        note="",
    )
    now = BLOCK_START + timedelta(minutes=100)
    disp = derive_display_state(item, raw, BLOCK_START, now, grace_minutes=15)
    assert disp.base == "running"
    assert disp.late is True
    assert disp.overrunning is False


def test_running_overrunning_is_flagged():
    item = _item(planned_start_minutes=0, planned_duration_minutes=60)
    raw = RawStatus(
        state="running", actual_start=BLOCK_START, actual_end=None, updated_at=None, note="",
    )
    now = BLOCK_START + timedelta(minutes=90)  # 30 min over a 60-min plan, grace 15
    disp = derive_display_state(item, raw, BLOCK_START, now, grace_minutes=15)
    assert disp.overrunning is True


def test_running_on_time_is_not_flagged():
    item = _item(planned_start_minutes=0, planned_duration_minutes=60)
    raw = RawStatus(state="running", actual_start=BLOCK_START, actual_end=None, updated_at=None, note="")
    now = BLOCK_START + timedelta(minutes=30)
    disp = derive_display_state(item, raw, BLOCK_START, now, grace_minutes=15)
    assert disp.late is False
    assert disp.overrunning is False


def test_done_late_finish_is_flagged():
    item = _item(planned_start_minutes=0, planned_duration_minutes=60)
    raw = RawStatus(
        state="done",
        actual_start=BLOCK_START,
        actual_end=BLOCK_START + timedelta(minutes=100),  # planned end at 60, grace 15
        updated_at=None,
        note="",
    )
    disp = derive_display_state(item, raw, BLOCK_START, BLOCK_START + timedelta(minutes=120), grace_minutes=15)
    assert disp.base == "done"
    assert disp.late is True


def test_done_on_time_is_not_flagged():
    item = _item(planned_start_minutes=0, planned_duration_minutes=60)
    raw = RawStatus(
        state="done", actual_start=BLOCK_START, actual_end=BLOCK_START + timedelta(minutes=55),
        updated_at=None, note="",
    )
    disp = derive_display_state(item, raw, BLOCK_START, BLOCK_START + timedelta(minutes=120), grace_minutes=15)
    assert disp.late is False


def test_failed_is_failed_regardless_of_timing():
    item = _item()
    raw = RawStatus(state="failed", actual_start=BLOCK_START, actual_end=BLOCK_START, updated_at=None, note="")
    disp = derive_display_state(item, raw, BLOCK_START, BLOCK_START, grace_minutes=15)
    assert disp.base == "failed"


def test_dependency_edge_states():
    from lib.status_model import DisplayState

    assert dependency_edge_state(DisplayState("done", False, False)) == "done"
    assert dependency_edge_state(DisplayState("running", False, False)) == "unmet"
    assert dependency_edge_state(DisplayState("failed", False, False)) == "broken"
    assert dependency_edge_state(DisplayState("unknown", False, False)) == "unknown"


def test_collected_before_block_start_rejected():
    with pytest.raises(StatusError, match="before block_start"):
        parse_status_doc(
            {
                "block_start": "2026-11-20T11:00:00Z",
                "collected_at": "2026-11-20T10:00:00Z",
                "items": {},
            }
        )


def test_naive_timestamp_rejected():
    with pytest.raises(StatusError):
        parse_utc("2026-11-20T11:00:00")  # no 'Z' or offset


def test_malformed_timestamp_is_a_status_error_not_a_bare_value_error():
    # datetime.fromisoformat's own ValueError must be wrapped, not left to escape as an
    # unlabelled exception that the callers' "except StatusError" blocks would miss.
    with pytest.raises(StatusError):
        parse_utc("17:05Z")
    with pytest.raises(StatusError):
        parse_utc("not-a-timestamp-at-all")


def test_non_string_timestamp_is_a_status_error():
    with pytest.raises(StatusError):
        parse_utc(12345)


def test_unknown_raw_state_rejected():
    with pytest.raises(StatusError, match="must be one of"):
        parse_status_doc(
            {
                "block_start": "2026-11-20T11:00:00Z",
                "collected_at": "2026-11-20T11:05:00Z",
                "items": {"x": {"state": "totally-made-up"}},
            }
        )


def test_syntactically_invalid_json_is_a_status_error_not_a_json_decode_error(tmp_path):
    # A real json.JSONDecodeError must not escape load_status — every caller's
    # "except StatusError" guard needs this to be the one error type.
    path = tmp_path / "status.json"
    path.write_text('{"block_start": "2026-11-20T11:00:00Z", "collected_at": "2026-11-20T11:05:00Z",}')
    with pytest.raises(StatusError):
        load_status(str(path))

def test_ci_verify_deliberate_failure():
    """ci-verify (throwaway, reverted before merge): must fail on purpose."""
    assert False, "deliberate failure for CI red-check verification"
