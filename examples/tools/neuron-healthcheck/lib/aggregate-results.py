#!/usr/bin/env python3
"""Aggregate this tool's per-check result files into one summary.json.

Reads RESULTS_DIR/check-*.json (the schema lib/common.sh documents) and
writes RESULTS_DIR/summary.json with one entry per expected check and an
overall status:

- FAIL if any check is FAIL, if any result file is unreadable or carries a
  status other than PASS/WARN/FAIL, or if an expected check wrote no
  result at all (reported as NOT_RUN: the container stops at the first
  failing check, and a check that never ran is not a pass).
- WARN if no check failed and at least one is WARN.
- PASS otherwise.

Usage:
    aggregate-results.py --results-dir DIR

Exit status: 0 for PASS or WARN, 1 for FAIL.
"""
from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
import sys

EXPECTED_CHECKS = ["0-neuron-ls", "1-neff-compile-load", "2-efa-enumeration"]
KNOWN_STATUSES = ("PASS", "WARN", "FAIL")


def load(results_dir: str) -> dict[str, dict]:
    by_check: dict[str, dict] = {}
    for path in sorted(glob.glob(os.path.join(results_dir, "check-*.json"))):
        name = os.path.basename(path)[len("check-"):-len(".json")]
        try:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
            if not isinstance(doc, dict):
                raise ValueError("not a JSON object")
        except (OSError, ValueError) as exc:
            doc = {"check": name, "status": "ERROR", "message": f"unreadable result file {os.path.basename(path)}: {exc}"}
        by_check[str(doc.get("check") or name)] = doc
    return by_check


def summarize(by_check: dict[str, dict], expected: list[str]) -> dict:
    checks = []
    for name in expected + sorted(set(by_check) - set(expected)):
        doc = by_check.get(name)
        if doc is None:
            checks.append({"check": name, "status": "NOT_RUN", "message": "no result file -- an earlier check failed, or this check never ran"})
            continue
        status = doc.get("status")
        message = str(doc.get("message", ""))
        if status not in KNOWN_STATUSES:
            message = f"unrecognized status {status!r}: {message}"
            status = "ERROR"
        checks.append({"check": name, "status": status, "message": message})

    statuses = {c["status"] for c in checks}
    if statuses - {"PASS", "WARN"}:
        overall = "FAIL"
    elif "WARN" in statuses:
        overall = "WARN"
    else:
        overall = "PASS"

    first = next(iter(by_check.values()), {})
    return {
        "overall_status": overall,
        "node": first.get("node", ""),
        "instance_type": first.get("instance_type", ""),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "checks": checks,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results-dir", default=os.environ.get("RESULTS_DIR", ""))
    args = parser.parse_args()
    if not args.results_dir:
        print("aggregate-results.py: --results-dir (or RESULTS_DIR) is required", file=sys.stderr)
        return 1

    summary = summarize(load(args.results_dir), EXPECTED_CHECKS)
    os.makedirs(args.results_dir, exist_ok=True)
    with open(os.path.join(args.results_dir, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")

    print(f"overall: {summary['overall_status']}")
    for c in summary["checks"]:
        print(f"  {c['status']:<7} {c['check']}: {c['message']}")
    return 0 if summary["overall_status"] in ("PASS", "WARN") else 1


if __name__ == "__main__":
    sys.exit(main())
