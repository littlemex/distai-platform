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
    out = _render_sample()
    assert "state-done" in out
    assert "state-unknown" in out
    assert "state-running" in out


def test_late_item_gets_late_modifier():
    # tier0-baseline-node-b starts 20 minutes late against a 15-minute grace.
    out = _render_sample()
    assert "mod-late" in out


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
    """Plan/status free text (name, note, stop_condition-derived labels) must never be
    interpretable as HTML — otherwise a plan.yaml or status.json authored by someone
    else (or a buggy collector) could inject script into the rendered board."""
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
