import sys
import textwrap
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.plan import PlanError, load_plan, parse_duration, parse_offset  # noqa: E402

SAMPLE_PLAN = Path(__file__).resolve().parents[1] / "sample" / "plan.yaml"


def test_sample_plan_loads():
    plan = load_plan(str(SAMPLE_PLAN))
    assert plan.grace_minutes == 15
    ids = [item.id for item in plan.items]
    assert ids[0] == "phase-a-bare-ec2-experiment"
    assert "closing-tail" in ids
    assert len(ids) == len(set(ids)), "ids must be unique"


def test_sample_plan_dependencies_resolve():
    plan = load_plan(str(SAMPLE_PLAN))
    by_id = plan.by_id()
    for item in plan.items:
        for dep in item.depends_on:
            assert dep in by_id


def test_parse_offset_and_duration():
    assert parse_offset("T+06:30").total_seconds() == 6 * 3600 + 30 * 60
    assert parse_duration("PT2H15M").total_seconds() == 2 * 3600 + 15 * 60
    assert parse_duration("PT45M").total_seconds() == 45 * 60
    assert parse_duration("PT6H").total_seconds() == 6 * 3600


@pytest.mark.parametrize("bad", ["06:30", "T06:30", "T+6:3", "T+:30", ""])
def test_parse_offset_rejects_garbage(bad):
    with pytest.raises(PlanError):
        parse_offset(bad)


def test_parse_offset_accepts_single_digit_hour():
    # The hour component is \d+, not \d{2}: "T+6:30" is a legitimate short form
    # of "T+06:30", not garbage — kept as its own explicit, documented case so
    # a future tightening of the regex doesn't silently break single-digit
    # hour offsets without a test noticing.
    assert parse_offset("T+6:30").total_seconds() == 6 * 3600 + 30 * 60


@pytest.mark.parametrize("bad", ["2H", "PT", "PTxH", ""])
def test_parse_duration_rejects_garbage(bad):
    with pytest.raises(PlanError):
        parse_duration(bad)


def _write_plan(tmp_path, body: str) -> str:
    p = tmp_path / "plan.yaml"
    p.write_text(textwrap.dedent(body))
    return str(p)


def test_duplicate_id_rejected(tmp_path):
    path = _write_plan(
        tmp_path,
        """
        items:
          - id: a
            name: A
            lane: l
            planned_start: "T+00:00"
            planned_duration: "PT1H"
            status_source: {kind: manual, key: a}
          - id: a
            name: A again
            lane: l
            planned_start: "T+01:00"
            planned_duration: "PT1H"
            status_source: {kind: manual, key: a2}
        """,
    )
    with pytest.raises(PlanError, match="duplicate"):
        load_plan(path)


def test_unknown_dependency_rejected(tmp_path):
    path = _write_plan(
        tmp_path,
        """
        items:
          - id: a
            name: A
            lane: l
            planned_start: "T+00:00"
            planned_duration: "PT1H"
            depends_on: [does-not-exist]
            status_source: {kind: manual, key: a}
        """,
    )
    with pytest.raises(PlanError, match="unknown id"):
        load_plan(path)


def test_self_dependency_rejected(tmp_path):
    path = _write_plan(
        tmp_path,
        """
        items:
          - id: a
            name: A
            lane: l
            planned_start: "T+00:00"
            planned_duration: "PT1H"
            depends_on: [a]
            status_source: {kind: manual, key: a}
        """,
    )
    with pytest.raises(PlanError, match="itself"):
        load_plan(path)


@pytest.mark.parametrize(
    "bad_namespace",
    ["Has-Capital", "-leading-dash", "trailing-dash-", "has a space", "../etc/passwd", "ns;rm -rf /"],
)
def test_status_source_rejects_unsafe_namespace(tmp_path, bad_namespace):
    """These values will later be spliced into a kubectl argv list — they must fail to parse
    rather than reach a subprocess call. This is the plan.yaml side of the injection guard
    whose subprocess side is tested in test_readonly_exec.py."""
    path = _write_plan(
        tmp_path,
        f"""
        items:
          - id: a
            name: A
            lane: l
            planned_start: "T+00:00"
            planned_duration: "PT1H"
            status_source: {{kind: job, namespace: "{bad_namespace}", name: ok-name}}
        """,
    )
    with pytest.raises(PlanError):
        load_plan(path)


def test_empty_items_rejected(tmp_path):
    path = _write_plan(tmp_path, "items: []\n")
    with pytest.raises(PlanError, match="non-empty"):
        load_plan(path)
