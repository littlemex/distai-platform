import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from datetime import timedelta  # noqa: E402

import json
from unittest import mock

from lib.plan import Plan, PlanItem, StatusSource, load_plan  # noqa: E402
from lib.status_model import RawStatus, StatusDoc, load_status, parse_utc  # noqa: E402
import render_board  # noqa: E402
from render_board import render  # noqa: E402

SAMPLE_DIR = Path(__file__).resolve().parents[1] / "sample"


def _render_sample() -> str:
    plan = load_plan(str(SAMPLE_DIR / "plan.yaml"))
    status = load_status(str(SAMPLE_DIR / "status.sample.json"))
    return render(plan, status)


def test_svg_body_is_well_formed_xml():
    # html.parser.HTMLParser is deliberately lenient and does not raise on malformed
    # markup, so it cannot actually catch a broken tag — this parses the inner <svg>...
    # </svg> block (which the page's own CSS/JS never touch) as strict XML instead,
    # which DOES fail on an unescaped '&', a mismatched tag, or any other real break.
    out = _render_sample()
    svg_text = out[out.index("<svg "):out.index("</svg>") + len("</svg>")]
    ET.fromstring(svg_text)  # raises ET.ParseError on malformed XML


def test_every_plan_item_name_appears():
    plan = load_plan(str(SAMPLE_DIR / "plan.yaml"))
    out = _render_sample()
    for item in plan.items:
        assert item.name in out, f"{item.id} name missing from rendered HTML"


def test_done_item_gets_done_class_and_unknown_item_gets_unknown_class():
    # Matching 'class="state-done' (the actual <g class="..."> opening tag) rather than
    # the bare substring "state-done": the inline <style> block also contains that bare
    # substring in its own CSS selectors, so a bare-substring check would still pass even
    # if no item ever actually got that class on an element.
    out = _render_sample()
    assert 'class="state-done' in out
    assert 'class="state-unknown' in out
    assert 'class="state-running' in out


def test_late_item_gets_late_modifier():
    # tier0-baseline-node-b finishes 25 minutes past its planned end (grace is 15
    # minutes) — "late" for a done item is about the finish time, not the start time.
    out = _render_sample()
    assert 'class="state-done mod-late' in out
    # The badge text as an actual rendered element, not just present somewhere on the
    # page — the legend text alone also contains the bare substring "[late]", so a
    # bare "in out" check here would pass even if no item ever got the badge.
    assert '<tspan class="badge badge-late"> [late]</tspan>' in out


def test_failed_item_gets_failed_class():
    # node-health-suite-check is the sample's one failed item (on time, no [late] badge).
    out = _render_sample()
    assert 'class="state-failed' in out


def test_overdue_not_started_item_gets_its_own_class_distinct_from_unknown():
    # efa-loopback-check is pending with a planned_start well before the snapshot.
    out = _render_sample()
    assert 'class="state-overdue-not-started' in out
    # The legend swatch colors for "overdue-not-started" and "unknown" must differ —
    # both being the same amber would make them indistinguishable at a glance, even
    # though they mean different things (a known fact vs. a missing one).
    from render_board import LEGEND_STATE_COLORS

    assert LEGEND_STATE_COLORS["overdue-not-started"] != LEGEND_STATE_COLORS["unknown"]
    # Same check against the actual chart CSS, not just the legend's own color table:
    # the two states must use two different CSS custom properties, with two different
    # literal values, not the same --unknown-text token reused for both.
    assert "--overdue-text:#b8550a" in out
    assert "--unknown-text:#8d6605" in out
    assert "stroke: var(--overdue-text)" in out


def test_overdue_not_started_item_does_not_get_a_redundant_late_badge():
    # Its own state text already says "Not started (overdue)" — a second [late] badge,
    # in a different color token than the row's own orange, would be redundant and a
    # color mismatch, not new information.
    out = _render_sample()
    overdue_row = re.search(r'<text class="note"[^>]*>Not started \(overdue\)(.*?)</text>', out)
    assert overdue_row is not None
    assert "[late]" not in overdue_row.group(1)


def test_overrunning_item_gets_overrun_badge_and_pattern():
    # node-replacement-drill has been running for 55 minutes against a 20-minute plan
    # (grace 15 minutes) — overrunning, but not late (it started on time).
    out = _render_sample()
    assert 'class="state-running mod-overrunning' in out
    assert '<tspan class="badge badge-late"> [overrunning]</tspan>' in out


def test_manual_badge_and_unknown_dependency_edge_are_rendered():
    out = _render_sample()
    # Same reasoning as the late-badge test above: the legend also contains the bare
    # substring "[manual", so this checks the actual rendered tspan, not just the page.
    assert '<tspan class="badge badge-manual"> [manual 16:55Z]</tspan>' in out
    # dra-mode-node-b is unknown (a collection error); any item depending on it must get
    # a distinct 'unknown' edge, not the same 'unmet' edge as a dependency that is merely
    # still running.
    assert 'class="dep-unknown"' in out


def test_stop_condition_is_shown_as_a_tooltip():
    plan = load_plan(str(SAMPLE_DIR / "plan.yaml"))
    out = _render_sample()
    item_with_stop_condition = next(i for i in plan.items if i.stop_condition and i.stop_condition != "n/a")
    assert f"<title>{item_with_stop_condition.stop_condition}</title>" in out


def test_collection_error_is_shown_as_a_banner_not_hidden():
    out = _render_sample()
    assert "Collection was incomplete" in out
    assert "dra-mode-node-b" in out


def test_no_external_urls_in_output():
    out = _render_sample()
    # No http(s):// anywhere — this is the single-file, no-CDN, air-gap guarantee.
    assert not re.search(r"https?://", out), "output must not reference any external URL"


def test_content_security_policy_present():
    out = _render_sample()
    assert "Content-Security-Policy" in out
    assert "default-src 'none'" in out


def test_free_text_fields_are_escaped():
    """Plan/status free text that reaches the page (name, lane, stop_condition) must
    never be interpretable as HTML — otherwise a plan.yaml or status.json authored by
    someone else (or a buggy collector) could inject script into the rendered board.
    (status.json's own `note` field is collected but never rendered anywhere on the
    page today — nothing to escape there yet.)"""
    plan = load_plan(str(SAMPLE_DIR / "plan.yaml"))
    status = load_status(str(SAMPLE_DIR / "status.sample.json"))

    # Mutate one item's name in-memory to something hostile and confirm it comes out escaped.
    import dataclasses

    hostile = '<img src=x onerror=alert(1)>'
    items = list(plan.items)
    items[0] = dataclasses.replace(items[0], name=hostile)
    hostile_plan = dataclasses.replace(plan, items=tuple(items))

    out = render(hostile_plan, status)
    assert "<img" not in out
    assert "&lt;img" in out


def test_collected_at_embedded_for_the_staleness_script():
    out = _render_sample()
    assert 'data-collected-at="2026-11-20T21:00:00Z"' in out


def test_dependency_edges_rendered_for_every_depends_on():
    plan = load_plan(str(SAMPLE_DIR / "plan.yaml"))
    out = _render_sample()
    expected_edges = sum(len(item.depends_on) for item in plan.items)
    actual_edges = out.count('class="dep-')
    assert actual_edges == expected_edges


def _one_item_plan_and_status(state: str, collected_hours_after_planned_end: float, actual_start_hours_after_planned_start=None):
    block_start = parse_utc("2026-01-01T00:00:00Z")
    item = PlanItem(
        id="x", name="X", lane="l",
        planned_start=timedelta(hours=1), planned_duration=timedelta(hours=1),
        depends_on=(), stop_condition="", status_source=StatusSource(kind="manual", key="x"),
    )
    plan = Plan(grace_minutes=15, items=(item,))
    actual_start = None
    if actual_start_hours_after_planned_start is not None:
        actual_start = block_start + item.planned_start + timedelta(hours=actual_start_hours_after_planned_start)
    raw = RawStatus(state=state, actual_start=actual_start, actual_end=None, updated_at=None, note="")
    collected_at = block_start + item.planned_start + item.planned_duration + timedelta(hours=collected_hours_after_planned_end)
    status = StatusDoc(block_start=block_start, collected_at=collected_at, items={"x": raw}, collection_errors=())
    return plan, status


def _bar_widths(out: str) -> tuple[float, float]:
    planned_width = float(re.search(r'<rect class="bar-planned"[^>]*width="([\d.]+)"', out).group(1))
    actual_width = float(re.search(r'<rect class="bar-actual"[^>]*width="([\d.]+)"', out).group(1))
    return planned_width, actual_width


def test_finished_item_with_no_actual_end_spans_the_planned_window_not_the_snapshot():
    """A 'done'/'failed' entry with no actual_end on record means 'finished, exact end
    unknown' — not 'still running'. Its bar must be the same width as its own planned
    bar. Rendering with the snapshot many hours after the planned end makes the bug this
    guards against (stretching the bar out to the snapshot line) obviously different in
    width from the fix, rather than coincidentally close. Covers both the no-actual_start
    case (start defaults to the planned start) and the actual_start-present case."""
    for state in ("done", "failed"):
        for actual_start_offset in (None, 0, 5):
            plan, status = _one_item_plan_and_status(
                state, collected_hours_after_planned_end=10, actual_start_hours_after_planned_start=actual_start_offset
            )
            out = render(plan, status)
            planned_width, actual_width = _bar_widths(out)
            assert abs(planned_width - actual_width) < 0.5, (
                f"state={state} actual_start_offset={actual_start_offset}: "
                f"planned={planned_width} actual={actual_width}"
            )


def test_finished_item_started_after_its_own_planned_end_does_not_become_a_zero_width_sliver():
    """A done/failed item whose actual_start is already past its own planned end (it
    started very late) must still draw a real bar — start_dt + planned_duration — not
    snap its end back to the planned end (which would be before start_dt, collapsing to
    the 2px-minimum sliver this guards against)."""
    plan, status = _one_item_plan_and_status(
        "done", collected_hours_after_planned_end=10, actual_start_hours_after_planned_start=3,
    )
    out = render(plan, status)
    planned_width, actual_width = _bar_widths(out)
    assert abs(planned_width - actual_width) < 0.5


def test_running_item_with_no_actual_end_does_still_extend_to_the_snapshot():
    """The contrast case for the tests above: a genuinely still-running item legitimately
    has no actual_end, and its bar must extend all the way to the snapshot line (it really
    is still going) rather than being clipped to the planned window like a finished item."""
    plan, status = _one_item_plan_and_status("running", collected_hours_after_planned_end=10)
    out = render(plan, status)
    planned_width, actual_width = _bar_widths(out)
    assert actual_width > planned_width * 2


def test_bar_planned_is_pointer_events_enabled_so_its_tooltip_is_reachable():
    # SVG does not hit-test an unfilled shape's interior by default; without this, an
    # overdue/not-started item's <title> tooltip would only trigger on its thin outline.
    out = _render_sample()
    assert "pointer-events: all;" in out


def test_main_rejects_a_malformed_status_timestamp_with_a_labelled_error_not_a_traceback(tmp_path):
    status_path = tmp_path / "status.json"
    status_path.write_text(
        json.dumps(
            {
                "block_start": "2026-11-20T11:00:00Z",
                "collected_at": "2026-11-20T12:00:00Z",
                "items": {"phase-a-bare-ec2-experiment": {"state": "done", "actual_start": "17:05Z"}},
            }
        )
    )
    argv = ["render_board.py", str(SAMPLE_DIR / "plan.yaml"), str(status_path), "-o", str(tmp_path / "out.html")]
    with mock.patch.object(sys, "argv", argv):
        rc = render_board.main()
    assert rc == 2
    assert not (tmp_path / "out.html").exists()
