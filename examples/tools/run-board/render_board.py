#!/usr/bin/env python3
"""render_board.py — pure function: (plan.yaml, status.json) -> one self-contained board.html.

No network access, no cluster/AWS access, no file writes other than the one
output file. Deterministic: the same two inputs always produce byte-identical
output (it never reads the wall clock — `collected_at` from status.json is the
only notion of "now" used to decide what is late or overdue).

Visual language follows this repo's own AWS-Cloudscape token snapshot
(see ../../../.claude/rules/aws-design-kit-for-ui.md): link blue #006ce0, pill
buttons, success/info/error tokens. The "unknown" amber and the hatch/pattern
fills for delayed/failed/unknown are this tool's own addition (Cloudscape has
no tiling-pattern convention) so that state is never color-only.

Usage:
    python3 render_board.py plan.yaml status.json -o board.html
"""
from __future__ import annotations

import argparse
import html
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.plan import Plan, load_plan
from lib.status_model import (
    RawStatus,
    StatusDoc,
    derive_display_state,
    dependency_edge_state,
    load_status,
)

# --- layout constants --------------------------------------------------------

LABEL_COL_W = 300
ROW_H = 34
ROW_GAP = 6
LANE_HEADER_H = 22  # its own strip, so a lane label never overlaps the first item's text
CHART_LEFT = LABEL_COL_W + 20
CHART_RIGHT_MARGIN = 40
PX_PER_MINUTE = 2.2  # clamped below for very long or very short plans
TOP_AXIS_H = 50

# Flat, explicit per-state colors for the legend swatches. The chart itself gets its
# color from CSS classes (lib above), but the legend draws tiny standalone boxes that
# are not inside a `.state-X` ancestor, so relying on the same descendant-combinator
# CSS rules there would silently render them blank — these are spelled out once, here,
# so the legend can never again go blank for that reason.
LEGEND_STATE_COLORS = {
    "not-started": ("#ffffff", "#c6c6cd"),
    "overdue-not-started": ("#fffbf0", "#8d6605"),
    "running": ("#f0fbff", "#006ce0"),
    "done": ("#effff1", "#00802f"),
    "failed": ("#fff5f5", "#db0000"),
    "unknown": ("#fffbf0", "#8d6605"),
}

# State -> (fill css class). "late"/"overrunning" add a modifier class on top.
BASE_STATE_LABEL = {
    "unknown": "Unknown (collection incomplete)",
    "not-started": "Not started (on schedule)",
    "overdue-not-started": "Not started (overdue)",
    "running": "Running",
    "done": "Done",
    "failed": "Failed",
}

CSS = """
:root {
  --ink:#0f141a; --ink2:#424650; --bg:#f6f6f9; --card:#ffffff;
  --line:#c6c6cd; --line2:#ebebf0; --link:#006ce0;
  --info-bg:#f0fbff; --info-text:#006ce0;
  --success-bg:#effff1; --success-text:#00802f;
  --error-bg:#fff5f5; --error-text:#db0000;
  /* amber "unknown" token: not in the Cloudscape snapshot this repo vendors,
     added here only because a distinct 5th state needs a distinct hue. */
  --unknown-bg:#fffbf0; --unknown-text:#8d6605;
  --r-button:20px; --r-input:8px; --r-container:16px;
  --font-base:'Open Sans','Helvetica Neue',Roboto,Arial,sans-serif;
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 24px; background: var(--bg); color: var(--ink);
  font-family: var(--font-base);
}
h1 { font-size: 20px; margin: 0 0 4px; }
.subtitle { color: var(--ink2); font-size: 13px; margin: 0 0 16px; }
.banner {
  display: none; border-radius: var(--r-input); padding: 10px 16px;
  background: var(--unknown-bg); color: var(--unknown-text); font-size: 13px;
  margin-bottom: 12px; border: 1px solid var(--unknown-text);
}
.banner.show { display: block; }
.card {
  background: var(--card); border: 1px solid var(--line);
  border-radius: var(--r-container); padding: 16px; overflow-x: auto;
}
.legend { display: flex; flex-wrap: wrap; gap: 14px; margin: 12px 0 20px; font-size: 12px; color: var(--ink2); }
.legend-item { display: flex; align-items: center; gap: 6px; }
.legend-swatch { width: 16px; height: 12px; border-radius: 3px; border: 1px solid var(--line); }
.lane-label { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; fill: var(--ink2); }
.item-label { font-size: 12px; fill: var(--ink); }
.axis-text { font-size: 11px; fill: var(--ink2); }
.axis-line { stroke: var(--line2); stroke-width: 1; }
.now-line { stroke: var(--link); stroke-width: 1.5; stroke-dasharray: 4 3; }
.bar-planned { fill: none; stroke: var(--line); stroke-width: 1.5; }
.bar-actual { stroke-width: 0; }
.state-not-started .bar-actual, .state-overdue-not-started .bar-actual { fill: none; }
.state-not-started .bar-planned { stroke-dasharray: 3 3; }
.state-overdue-not-started .bar-planned { stroke: var(--unknown-text); stroke-dasharray: 3 3; }
.state-running .bar-actual { fill: var(--info-bg); stroke: var(--info-text); stroke-width: 1.5; }
.state-done .bar-actual { fill: var(--success-bg); stroke: var(--success-text); stroke-width: 1.5; }
.state-failed .bar-actual { fill: url(#hatch-failed); stroke: var(--error-text); stroke-width: 1.5; }
.state-unknown .bar-actual { fill: url(#hatch-unknown); stroke: var(--unknown-text); stroke-width: 1.5; stroke-dasharray: 2 2; }
.mod-late .bar-actual { fill: url(#hatch-late); }
.mod-overrunning .bar-actual { fill: url(#hatch-overrun); }
.badge {
  font-size: 10px; padding: 1px 7px; border-radius: var(--r-button);
  margin-left: 6px; font-weight: 600;
}
.badge-manual { background: var(--line2); color: var(--ink2); }
.badge-late { background: var(--unknown-bg); color: var(--unknown-text); }
.dep-done { stroke: var(--success-text); stroke-width: 1.2; }
.dep-unmet { stroke: var(--ink2); stroke-width: 1; stroke-dasharray: 2 2; }
.dep-broken { stroke: var(--error-text); stroke-width: 1.5; }
.footnote { color: var(--ink2); font-size: 11px; margin-top: 10px; }
.note { font-size: 11px; fill: var(--ink2); }
"""

JS = """
(function () {
  // The one place this tool reads the real wall clock: a view-time staleness
  // warning only. It never changes anything that was drawn — the chart itself
  // is rendered once, deterministically, from status.json's own collected_at.
  var collectedAt = new Date(document.body.getAttribute('data-collected-at'));
  var staleAfterMinutes = 30;
  var ageMinutes = (Date.now() - collectedAt.getTime()) / 60000;
  if (ageMinutes > staleAfterMinutes) {
    var b = document.getElementById('stale-banner');
    if (b) {
      b.classList.add('show');
      b.textContent = 'This snapshot is ' + Math.round(ageMinutes) + ' minutes old (collected at '
        + document.body.getAttribute('data-collected-at') + ' UTC). It is not live — re-run '
        + 'collect_status.py and re-render to refresh it.';
    }
  }
})();
"""


def _minutes(td) -> float:
    return td.total_seconds() / 60.0


def _fmt_hhmm_offset(total_minutes: float) -> str:
    sign = "-" if total_minutes < 0 else "+"
    total_minutes = abs(total_minutes)
    h, m = divmod(int(round(total_minutes)), 60)
    return f"T{sign}{h:02d}:{m:02d}"


def render(plan: Plan, status: StatusDoc) -> str:
    items_by_id = plan.by_id()

    # Timeline extent: from block_start to the latest of (every planned end,
    # every actual end/now-if-running, collected_at), plus a small margin.
    latest_minutes = 0.0
    for item in plan.items:
        latest_minutes = max(latest_minutes, _minutes(item.planned_start + item.planned_duration))
        raw = status.items.get(item.id)
        if raw and raw.actual_end:
            latest_minutes = max(latest_minutes, _minutes(raw.actual_end - status.block_start))
    latest_minutes = max(latest_minutes, _minutes(status.collected_at - status.block_start))
    latest_minutes += 30  # margin so the last bar/now-line isn't flush against the edge

    px_per_minute = PX_PER_MINUTE
    chart_w = latest_minutes * px_per_minute
    if chart_w > 2600:
        px_per_minute = 2600 / latest_minutes
        chart_w = 2600
    if chart_w < 600:
        px_per_minute = 600 / latest_minutes if latest_minutes else PX_PER_MINUTE
        chart_w = 600

    total_w = CHART_LEFT + chart_w + CHART_RIGHT_MARGIN
    # Order: group by lane (first appearance order), then by planned_start within a lane.
    lanes: list[str] = []
    for item in plan.items:
        if item.lane not in lanes:
            lanes.append(item.lane)
    ordered = sorted(plan.items, key=lambda it: (lanes.index(it.lane), _minutes(it.planned_start)))

    total_h = TOP_AXIS_H + len(lanes) * LANE_HEADER_H + len(ordered) * (ROW_H + ROW_GAP) + 30

    svg_parts: list[str] = []
    svg_parts.append(
        f'<svg viewBox="0 0 {total_w:.0f} {total_h:.0f}" width="{total_w:.0f}" height="{total_h:.0f}" '
        'role="img" aria-label="Plan versus actual board">'
    )
    svg_parts.append(_defs())

    # Hour gridlines + axis labels, every 60 minutes.
    hour = 0.0
    while hour <= latest_minutes:
        x = CHART_LEFT + hour * px_per_minute
        svg_parts.append(f'<line class="axis-line" x1="{x:.1f}" y1="{TOP_AXIS_H - 10}" x2="{x:.1f}" y2="{total_h - 10:.0f}" />')
        svg_parts.append(f'<text class="axis-text" x="{x:.1f}" y="{TOP_AXIS_H - 18}" text-anchor="middle">{_fmt_hhmm_offset(hour)}</text>')
        hour += 60

    # "now" line at collected_at.
    now_x = CHART_LEFT + _minutes(status.collected_at - status.block_start) * px_per_minute
    svg_parts.append(f'<line class="now-line" x1="{now_x:.1f}" y1="{TOP_AXIS_H - 10}" x2="{now_x:.1f}" y2="{total_h - 10:.0f}" />')
    svg_parts.append(f'<text class="axis-text" x="{now_x:.1f}" y="{TOP_AXIS_H - 32}" text-anchor="middle">snapshot</text>')

    row_y: dict[str, float] = {}
    current_lane = None
    y = TOP_AXIS_H
    for item in ordered:
        if item.lane != current_lane:
            svg_parts.append(f'<text class="lane-label" x="8" y="{y + 15:.0f}">{html.escape(item.lane)}</text>')
            current_lane = item.lane
            y += LANE_HEADER_H
        row_y[item.id] = y
        y += ROW_H + ROW_GAP

    # Dependency arrows first, so bars draw on top of them.
    for item in ordered:
        disp = derive_display_state(item, status.items.get(item.id), status.block_start, status.collected_at, plan.grace_minutes)
        for dep_id in item.depends_on:
            dep_item = items_by_id[dep_id]
            dep_disp = derive_display_state(dep_item, status.items.get(dep_id), status.block_start, status.collected_at, plan.grace_minutes)
            edge = dependency_edge_state(dep_item, dep_disp)
            dep_end_x = CHART_LEFT + _minutes(dep_item.planned_start + dep_item.planned_duration) * px_per_minute
            dep_y = row_y[dep_id] + ROW_H / 2
            this_start_x = CHART_LEFT + _minutes(item.planned_start) * px_per_minute
            this_y = row_y[item.id] + ROW_H / 2
            svg_parts.append(
                f'<path class="dep-{edge}" fill="none" '
                f'd="M {dep_end_x:.1f} {dep_y:.1f} C {dep_end_x + 20:.1f} {dep_y:.1f}, '
                f'{this_start_x - 20:.1f} {this_y:.1f}, {this_start_x:.1f} {this_y:.1f}" />'
            )

    for item in ordered:
        raw = status.items.get(item.id)
        disp = derive_display_state(item, raw, status.block_start, status.collected_at, plan.grace_minutes)
        y = row_y[item.id]
        state_classes = f"state-{disp.base}"
        if disp.late:
            state_classes += " mod-late"
        if disp.overrunning:
            state_classes += " mod-overrunning"

        px = CHART_LEFT + _minutes(item.planned_start) * px_per_minute
        pw = max(2.0, _minutes(item.planned_duration) * px_per_minute)
        svg_parts.append(f'<g class="{state_classes}">')
        svg_parts.append(f'<rect class="bar-planned" x="{px:.1f}" y="{y + 3:.1f}" width="{pw:.1f}" height="{ROW_H - 6}" rx="6" />')

        if raw and raw.actual_start and disp.base in ("running", "done", "failed"):
            ax = CHART_LEFT + _minutes(raw.actual_start - status.block_start) * px_per_minute
            end_dt = raw.actual_end if raw.actual_end else status.collected_at
            aw = max(2.0, _minutes(end_dt - raw.actual_start) * px_per_minute)
            svg_parts.append(f'<rect class="bar-actual" x="{ax:.1f}" y="{y + 7:.1f}" width="{aw:.1f}" height="{ROW_H - 14}" rx="4" />')
        elif disp.base == "unknown":
            svg_parts.append(f'<rect class="bar-actual" x="{px:.1f}" y="{y + 7:.1f}" width="{pw:.1f}" height="{ROW_H - 14}" rx="4" />')
        svg_parts.append("</g>")

        label = html.escape(item.name)
        badges = ""
        if item.status_source.kind == "manual":
            badges += '<tspan class="badge badge-manual"> manual</tspan>'
        if disp.late or disp.base == "overdue-not-started":
            badges += '<tspan class="badge badge-late"> late</tspan>'
        svg_parts.append(f'<text class="item-label" x="12" y="{y + ROW_H / 2 + 4:.0f}">{label}</text>')
        state_text = html.escape(BASE_STATE_LABEL[disp.base])
        svg_parts.append(f'<text class="note" x="12" y="{y + ROW_H / 2 + 16:.0f}">{state_text}</text>')

    svg_parts.append("</svg>")
    svg = "\n".join(svg_parts)

    legend_items = [
        ("not-started", "Not started"),
        ("overdue-not-started", "Overdue, not started"),
        ("running", "Running"),
        ("done", "Done"),
        ("failed", "Failed"),
        ("unknown", "Unknown / collection error"),
    ]
    legend_html = "".join(
        f'<div class="legend-item"><span class="legend-swatch" '
        f'style="background:{LEGEND_STATE_COLORS[s][0]};border-color:{LEGEND_STATE_COLORS[s][1]}">'
        f'</span>{html.escape(label)}</div>'
        for s, label in legend_items
    )

    errors_html = ""
    if status.collection_errors:
        error_lines = "".join(f"<li>{html.escape(e)}</li>" for e in status.collection_errors)
        errors_html = (
            '<div class="banner show">Collection was incomplete for '
            f'{len(status.collection_errors)} item(s) — shown as "Unknown", not as "not started":'
            f'<ul>{error_lines}</ul></div>'
        )

    collected_at_text = status.collected_at.strftime("%Y-%m-%dT%H:%M:%SZ")
    block_start_text = status.block_start.strftime("%Y-%m-%dT%H:%M:%SZ")

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self'" />
<title>run-board (toy) — plan vs actual</title>
<style>{CSS}</style>
</head>
<body data-collected-at="{collected_at_text}">
<h1>run-board (toy) — plan vs actual</h1>
<p class="subtitle">
  Not production monitoring. Outline bars = planned. Filled bars = actual, from a single
  point-in-time snapshot. Block start {block_start_text} UTC. Snapshot collected at
  {collected_at_text} UTC — the dashed blue line marks that moment on the axis below.
</p>
<div id="stale-banner" class="banner"></div>
{errors_html}
<div class="card">
{svg}
</div>
<div class="legend">{legend_html}</div>
<p class="footnote">
  Dependency arrows: solid green = dependency done, dashed grey = dependency not yet done,
  red = dependency failed. Stop conditions (free text in plan.yaml) are informational only —
  this tool never evaluates them, so their absence from this page is not a signal that they
  were not hit.
</p>
<script>{JS}</script>
</body>
</html>
"""


def _defs() -> str:
    # Pattern fills so failed/unknown/late states are distinguishable without color
    # (grayscale-safe), on top of the color difference.
    return """
<defs>
  <pattern id="hatch-failed" width="6" height="6" patternTransform="rotate(45)" patternUnits="userSpaceOnUse">
    <rect width="6" height="6" fill="#fff5f5" />
    <line x1="0" y1="0" x2="0" y2="6" stroke="#db0000" stroke-width="2" />
  </pattern>
  <pattern id="hatch-unknown" width="5" height="5" patternUnits="userSpaceOnUse">
    <rect width="5" height="5" fill="#fffbf0" />
    <circle cx="2.5" cy="2.5" r="1" fill="#8d6605" />
  </pattern>
  <pattern id="hatch-late" width="6" height="6" patternTransform="rotate(135)" patternUnits="userSpaceOnUse">
    <rect width="6" height="6" fill="#fff0cc" />
    <line x1="0" y1="0" x2="0" y2="6" stroke="#8d6605" stroke-width="1.5" />
  </pattern>
  <pattern id="hatch-overrun" width="4" height="4" patternUnits="userSpaceOnUse">
    <rect width="4" height="4" fill="#fff5f5" />
    <line x1="0" y1="0" x2="4" y2="4" stroke="#db0000" stroke-width="1" />
    <line x1="4" y1="0" x2="0" y2="4" stroke="#db0000" stroke-width="1" />
  </pattern>
</defs>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("plan", help="path to plan.yaml")
    ap.add_argument("status", help="path to status.json")
    ap.add_argument("-o", "--out", required=True, help="path to write board.html")
    args = ap.parse_args()

    plan = load_plan(args.plan)
    status = load_status(args.status)
    html_out = render(plan, status)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(html_out)
    print(f"[render_board] wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
