#!/usr/bin/env python3
"""Turn a score.py summary into Prometheus text exposition format.

Grafana cannot read a one-shot JSON file, so the summary is pushed to a
Prometheus Pushgateway, which the cluster's collector scrapes like any other
target. This script only prints the text; the push itself is one ``curl``
(see examples/inference/_shared/README.md). The run, the layout and the SLO
the score was computed against go in the Pushgateway grouping key of that
push, which turns them into labels. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

LABEL = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")

GAUGES = (
    ("joint_attainment_share", "Share of planned requests meeting TTFT and longest-gap limits jointly."),
    ("goodput_per_gpu", "Jointly attaining requests per GPU-second, drain included."),
    ("planned_requests", "Requests the load generator was asked to send."),
    ("failed_requests", "Requests that returned an error."),
    ("no_tokens_generated", "Successful requests with no inter-token gap observed."),
)


def escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--summary", required=True, help="score.py output JSON")
    p.add_argument(
        "--label",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="extra label added to every sample (repeatable)",
    )
    args = p.parse_args(argv)
    labels = {}
    for item in args.label:
        name, sep, value = item.partition("=")
        if not sep or not LABEL.match(name):
            print(f"to_prom.py: bad --label {item!r}", file=sys.stderr)
            return 1
        labels[name] = value
    try:
        with open(args.summary, encoding="utf-8") as f:
            summary = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"to_prom.py: cannot read {args.summary}: {e}", file=sys.stderr)
        return 1
    if not isinstance(summary, dict):
        print(f"to_prom.py: {args.summary} is not a score.py summary", file=sys.stderr)
        return 1
    rendered = ",".join(f'{k}="{escape(v)}"' for k, v in sorted(labels.items()))
    rendered = f"{{{rendered}}}" if rendered else ""
    for key, help_text in GAUGES:
        value = summary.get(key)
        if value is None:
            continue
        name = f"distai_pd_{key}"
        print(f"# HELP {name} {help_text}")
        print(f"# TYPE {name} gauge")
        print(f"{name}{rendered} {float(value)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
