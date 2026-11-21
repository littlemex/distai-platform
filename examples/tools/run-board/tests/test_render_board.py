import html.parser
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.plan import load_plan  # noqa: E402
from lib.status_model import load_status  # noqa: E402
from render_board import render  # noqa: E402

SAMPLE_DIR = Path(__file__).resolve().parents[1] / "sample"


class _StrictParser(html.parser.HTMLParser):
    """Just needs to not blow up — a cheap proxy for "this is well-formed enough"."""

    def error(self, message):  # pragma: no cover - HTMLParser in py3 doesn't call this
        raise AssertionError(message)


def _render_sample() -> str:
    plan = load_plan(str(SAMPLE_DIR / "plan.yaml"))
    status = load_status(str(SAMPLE_DIR / "status.sample.json"))
    return render(plan, status)


def test_renders_without_raising_and_parses():
    out = _render_sample()
    parser = _StrictParser()
    parser.feed(out)  # raises on malformed markup via .error() above only for py2-style parsers;
    # the real check is just that .feed() completes without a Python exception.


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
