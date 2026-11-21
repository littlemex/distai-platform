"""Pure status model: load status.json, and derive a display state for each item.

`collect_status.py` writes only raw facts (lifecycle state + timestamps) into
status.json. This module turns those raw facts plus the plan's own planned
start/duration into a *derived* display state (on-time, late, overrunning,
overdue-not-started, unknown, ...). The derivation is a pure function of
(plan item, raw status entry, block_start, collected_at, grace) — it never reads
the wall clock, so re-rendering the same status.json always produces the same
picture (`render_board.py` is deterministic and testable with a fixed fixture).

Keeping this out of the collector also means the one piece of logic most likely
to have an off-by-one (is this late? by how much?) is tested directly, with
fixture timestamps, rather than only indirectly through a full collector run.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

RAW_STATES = {"unknown", "pending", "running", "done", "failed"}


class StatusError(ValueError):
    """status.json is malformed."""


def parse_utc(text: str) -> datetime:
    """Parse an ISO-8601 UTC timestamp like '2026-11-20T11:00:00Z'.

    Every malformed-input path raises StatusError, not a bare ValueError/TypeError —
    callers (render_board.py's and collect_status.py's own `except StatusError` blocks)
    rely on that to turn a hand-edited typo into a labelled error instead of an
    unlabelled traceback.
    """
    if not isinstance(text, str):
        raise StatusError(f"timestamp must be a string, got {text!r}")
    candidate = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        dt = datetime.fromisoformat(candidate)
    except ValueError as e:
        raise StatusError(f"timestamp {text!r} is not a valid ISO-8601 timestamp: {e}") from e
    if dt.tzinfo is None:
        raise StatusError(f"timestamp {text!r} has no timezone; all timestamps must be UTC")
    return dt.astimezone(timezone.utc)


@dataclass(frozen=True)
class RawStatus:
    state: str  # one of RAW_STATES
    actual_start: datetime | None
    actual_end: datetime | None
    updated_at: datetime | None  # expected for kind=manual entries (shown next to the badge), not enforced
    note: str  # allowlisted, human-written short text only — never raw k8s/AWS output


@dataclass(frozen=True)
class StatusDoc:
    block_start: datetime
    collected_at: datetime
    items: dict  # id -> RawStatus
    collection_errors: tuple[str, ...]


def load_status(path: str) -> StatusDoc:
    with open(path, "r", encoding="utf-8") as f:
        raw = json.load(f)
    return parse_status_doc(raw)


def parse_status_doc(raw: dict) -> StatusDoc:
    if not isinstance(raw, dict):
        raise StatusError("status.json must be an object at the top level")
    for required in ("block_start", "collected_at", "items"):
        if required not in raw:
            raise StatusError(f"status.json is missing required field {required!r}")

    block_start = parse_utc(raw["block_start"])
    collected_at = parse_utc(raw["collected_at"])
    if collected_at < block_start:
        raise StatusError("collected_at is before block_start — that cannot be a real snapshot")

    items = {}
    raw_items = raw["items"]
    if not isinstance(raw_items, dict):
        raise StatusError("status.json 'items' must be an object keyed by plan item id")
    for item_id, entry in raw_items.items():
        if not isinstance(entry, dict) or "state" not in entry:
            raise StatusError(f"status entry {item_id!r} must be an object with a 'state'")
        state = entry["state"]
        if state not in RAW_STATES:
            raise StatusError(f"status entry {item_id!r}: state={state!r} must be one of {sorted(RAW_STATES)}")
        actual_start = parse_utc(entry["actual_start"]) if entry.get("actual_start") else None
        actual_end = parse_utc(entry["actual_end"]) if entry.get("actual_end") else None
        updated_at = parse_utc(entry["updated_at"]) if entry.get("updated_at") else None
        note = entry.get("note", "")
        if not isinstance(note, str):
            raise StatusError(f"status entry {item_id!r}: 'note' must be a string")
        items[item_id] = RawStatus(
            state=state, actual_start=actual_start, actual_end=actual_end,
            updated_at=updated_at, note=note,
        )

    collection_errors = tuple(raw.get("collection_errors", []))
    return StatusDoc(
        block_start=block_start, collected_at=collected_at, items=items,
        collection_errors=collection_errors,
    )


# --- Derived display state -------------------------------------------------

@dataclass(frozen=True)
class DisplayState:
    base: str  # unknown | not-started | overdue-not-started | running | done | failed
    late: bool  # started later than planned, or finished later than planned
    overrunning: bool  # a running item has already exceeded planned_duration


def derive_display_state(
    item,  # lib.plan.PlanItem
    raw: RawStatus | None,
    block_start: datetime,
    collected_at: datetime,
    grace_minutes: int,
) -> DisplayState:
    """Map (plan item, raw status) to what the board should actually draw.

    `raw is None` means the collector never produced an entry for this id at
    all (e.g. a typo in status_source, or the whole collection run errored out
    before reaching it) — that is `unknown`, the same as an explicit
    state="unknown", never silently drawn as "not started".
    """
    grace = timedelta(minutes=grace_minutes)
    planned_start_abs = block_start + item.planned_start
    planned_end_abs = planned_start_abs + item.planned_duration

    if raw is None or raw.state == "unknown":
        return DisplayState(base="unknown", late=False, overrunning=False)

    if raw.state == "failed":
        late = bool(raw.actual_start and raw.actual_start > planned_start_abs + grace)
        return DisplayState(base="failed", late=late, overrunning=False)

    if raw.state == "pending":
        if collected_at > planned_start_abs + grace:
            return DisplayState(base="overdue-not-started", late=True, overrunning=False)
        return DisplayState(base="not-started", late=False, overrunning=False)

    if raw.state == "running":
        late = bool(raw.actual_start and raw.actual_start > planned_start_abs + grace)
        overrunning = (collected_at - (raw.actual_start or planned_start_abs)) > item.planned_duration + grace
        return DisplayState(base="running", late=late, overrunning=overrunning)

    if raw.state == "done":
        late = bool(raw.actual_end and raw.actual_end > planned_end_abs + grace)
        return DisplayState(base="done", late=late, overrunning=False)

    # Unreachable given RAW_STATES, kept explicit rather than falling through silently.
    raise StatusError(f"unhandled raw state {raw.state!r}")


def dependency_edge_state(dep_display: DisplayState) -> str:
    """How to draw the arrow from a dependency to a dependent: 'done' | 'unmet' | 'broken' | 'unknown'.

    'broken' means the dependency itself failed — an arrow drawn as if the
    order were merely "not yet satisfied" would understate the problem.
    'unknown' means the dependency's own state could not be collected at all —
    drawing it the same as 'unmet' (a dependency we positively know is not
    done yet) would claim more certainty than this tool actually has: an
    "unmet" dependency might in fact already be done, just not observed.
    """
    if dep_display.base == "unknown":
        return "unknown"
    if dep_display.base == "failed":
        return "broken"
    if dep_display.base == "done":
        return "done"
    return "unmet"
