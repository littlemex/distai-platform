#!/usr/bin/env python3
"""collect_status.py — the only script in run-board that touches a cluster or AWS.

Read-only, by construction (see lib/readonly_exec.py's allowlist): `kubectl get`
and `aws ec2 describe-*` only. Never writes to the cluster or to AWS. Builds
status.json from a small, explicit allowlist of fields (see lib/k8s_mapping.py)
— never the full kubectl/aws JSON, so account IDs, image URIs, node IPs and
free-text condition messages never end up on disk or in the rendered HTML.

Usage:
    python3 collect_status.py plan.yaml --block-start 2026-11-20T11:00:00Z \
        --manual-status manual-status.json -o status.json

`--manual-status` is a small, human-maintained JSON file for plan items whose
status_source.kind is "manual" (e.g. a phase run by someone else's own
tooling, reported back as a flag rather than observed as a Kubernetes object).
Its shape: {"<key>": {"state": "...", "actual_start": "...", "actual_end": "...",
"updated_at": "...", "note": "..."}}.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.k8s_mapping import map_job_status, map_kueue_workload_status
from lib.plan import load_plan, PlanError
from lib.readonly_exec import run_readonly, DisallowedCommandError


def _now_utc_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _collect_one(item, manual_status: dict) -> tuple[dict | None, str | None]:
    """Return (status_entry_or_None, error_or_None) for a single plan item."""
    src = item.status_source
    try:
        if src.kind == "manual":
            entry = manual_status.get(src.key)
            if entry is None:
                return None, f"{item.id}: no manual status entry for key {src.key!r}"
            return {
                "state": entry.get("state", "unknown"),
                "actual_start": entry.get("actual_start"),
                "actual_end": entry.get("actual_end"),
                "updated_at": entry.get("updated_at"),
                "note": entry.get("note", "manual"),
            }, None

        if src.kind == "job":
            out = run_readonly(["kubectl", "get", "job", src.name, "-n", src.namespace, "-o", "json"])
            mapped = map_job_status(json.loads(out))
            mapped["note"] = f"job/{src.name}"
            return mapped, None

        if src.kind == "kueue_workload":
            out = run_readonly([
                "kubectl", "get", "workloads.kueue.x-k8s.io", src.name, "-n", src.namespace, "-o", "json",
            ])
            mapped = map_kueue_workload_status(json.loads(out))
            mapped["note"] = f"workload/{src.name}"
            return mapped, None

        return None, f"{item.id}: unhandled status_source.kind {src.kind!r}"
    except DisallowedCommandError as e:
        return None, f"{item.id}: refused to run a non-allowlisted command: {e}"
    except Exception as e:  # noqa: BLE001 — one item's collection failure must not abort the run
        return None, f"{item.id}: collection failed: {type(e).__name__}: {e}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("plan", help="path to plan.yaml")
    ap.add_argument("--block-start", required=True, help="UTC ISO-8601, e.g. 2026-11-20T11:00:00Z")
    ap.add_argument("--manual-status", default=None, help="path to a manual-status.json file")
    ap.add_argument("-o", "--out", required=True, help="path to write status.json")
    args = ap.parse_args()

    try:
        plan = load_plan(args.plan)
    except PlanError as e:
        print(f"[collect_status] invalid plan: {e}", file=sys.stderr)
        return 2

    manual_status = {}
    if args.manual_status:
        with open(args.manual_status, "r", encoding="utf-8") as f:
            manual_status = json.load(f)

    items = {}
    errors = []
    for item in plan.items:
        entry, error = _collect_one(item, manual_status)
        if entry is not None:
            items[item.id] = entry
        if error is not None:
            errors.append(error)
            items.setdefault(item.id, {"state": "unknown", "note": "collection error"})

    doc = {
        "block_start": args.block_start,
        "collected_at": _now_utc_iso(),
        "items": items,
        "collection_errors": errors,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")

    if errors:
        print(f"[collect_status] wrote {args.out} with {len(errors)} collection error(s):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
