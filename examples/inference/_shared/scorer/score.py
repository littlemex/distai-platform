#!/usr/bin/env python3
"""Score a saved vLLM benchmark run against an explicit joint SLO.

Reads the per-request detail that ``vllm bench serve --save-result
--save-detailed`` writes and computes, without re-running any load:

* per-request longest inter-token gap (``max(itls)``),
* joint SLO attainment: the share of *planned* requests that succeeded with
  TTFT within ``--ttft-ms`` AND longest gap within ``--tpot-or-gap-ms``,
* goodput per GPU over the full interval, drain included.

The input is the one JSON object vLLM writes: per-request parallel arrays
(index i is request i) ``ttfts`` and ``itls`` (seconds), ``errors`` (empty
string means success), ``start_times``, ``latencies`` and ``queue_times``
(seconds). ``ttfts``, ``itls``, ``errors`` and ``start_times`` are only
written with ``--save-detailed``.

Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from typing import Any


class InputError(Exception):
    """The records file cannot be scored; the message names the problem."""


@dataclass
class Record:
    success: bool
    ttft_s: float
    itls_s: list[float]
    start_s: float
    latency_s: float
    queue_s: float


def _num(value: Any, what: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InputError(f"{what} is not a number: {value!r}")
    if not math.isfinite(value):
        raise InputError(f"{what} is not finite: {value!r}")
    return float(value)


def _num_list(value: Any, what: str) -> list[float]:
    if not isinstance(value, list):
        raise InputError(f"{what} is not a list")
    return [_num(v, f"{what}[{i}]") for i, v in enumerate(value)]


REQUIRED = ("ttfts", "itls", "errors", "start_times", "latencies", "queue_times")


def load_records(path: str) -> list[Record]:
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except OSError as e:
        raise InputError(f"cannot read {path}: {e.strerror}") from e
    except json.JSONDecodeError as e:
        raise InputError(f"{path} is not valid JSON: {e.msg} at line {e.lineno}") from e
    if not isinstance(doc, dict):
        raise InputError(f"{path} is not a JSON object of per-request arrays")
    missing = [k for k in REQUIRED if k not in doc]
    if missing:
        raise InputError(
            "per-request arrays missing: "
            + ", ".join(missing)
            + " (was the run saved with --save-detailed?)"
        )
    if not isinstance(doc["ttfts"], list):
        raise InputError("ttfts is not a list")
    n = len(doc["ttfts"])
    for key in REQUIRED:
        if not isinstance(doc[key], list) or len(doc[key]) != n:
            raise InputError(f"{key} does not have one entry per request ({n})")
    records = []
    for i in range(n):
        error = doc["errors"][i]
        if not isinstance(error, str):
            raise InputError(f"errors[{i}] is not a string")
        records.append(
            Record(
                success=error == "",
                ttft_s=_num(doc["ttfts"][i], f"ttfts[{i}]"),
                itls_s=_num_list(doc["itls"][i], f"itls[{i}]"),
                start_s=_num(doc["start_times"][i], f"start_times[{i}]"),
                latency_s=_num(doc["latencies"][i], f"latencies[{i}]"),
                queue_s=_num(doc["queue_times"][i], f"queue_times[{i}]"),
            )
        )
    return records


def interval_seconds(records: list[Record]) -> float | None:
    """From the first request's arrival to the last successful completion.

    A request's arrival is its send time minus its client-side queue time;
    the end is the latest send plus latency over successful requests, so the
    drain after the last send is included. None when nothing succeeded.
    """
    ends = [r.start_s + r.latency_s for r in records if r.success]
    if not ends:
        return None
    return max(ends) - min(r.start_s - r.queue_s for r in records)


def percentile(sorted_values: list[float], q: float) -> float | None:
    """Linear-interpolated percentile (the numpy default) of sorted values."""
    if not sorted_values:
        return None
    pos = (len(sorted_values) - 1) * q / 100.0
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return sorted_values[lo]
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (pos - lo)


def summarize(values: list[float]) -> dict[str, float | None]:
    ordered = sorted(values)
    return {f"p{q}": percentile(ordered, q) for q in (50, 90, 99)}


def score(
    records: list[Record],
    planned: int,
    gpu_count: int,
    ttft_ms: float,
    gap_ms: float,
) -> dict[str, Any]:
    if len(records) > planned:
        raise InputError(
            f"{len(records)} records but --planned-requests is {planned}; "
            "the planned count must be what the load generator was asked to send"
        )
    failed = 0
    no_tokens = 0
    successful = 0
    attained = 0
    ttfts_ms: list[float] = []
    gaps_ms: list[float] = []
    for r in records:
        if not r.success:
            failed += 1
            continue
        successful += 1
        if not r.itls_s:
            # No inter-token gap was observed, so the gap limit cannot be
            # shown to hold: counted separately, never scored as a gap of 0.
            no_tokens += 1
            continue
        ttft = r.ttft_s * 1000.0
        gap = max(r.itls_s) * 1000.0
        ttfts_ms.append(ttft)
        gaps_ms.append(gap)
        if ttft <= ttft_ms and gap <= gap_ms:
            attained += 1
    interval = interval_seconds(records)
    if interval is not None and interval <= 0:
        raise InputError(f"run interval is not positive: {interval}")
    return {
        "planned_requests": planned,
        "successful_requests": successful,
        "failed_requests": failed,
        "no_tokens_generated": no_tokens,
        "joint_attainment_share": attained / planned,
        # No successful request means no jointly attaining request: 0, not undefined.
        "goodput_per_gpu": attained / (gpu_count * interval) if interval else 0.0,
        "ttft_ms": summarize(ttfts_ms),
        "longest_gap_ms": summarize(gaps_ms),
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--records", required=True, help="vLLM --save-detailed result JSON")
    p.add_argument(
        "--planned-requests",
        type=int,
        required=True,
        help="how many requests the load generator was asked to send (the denominator)",
    )
    p.add_argument("--gpu-count", type=int, required=True, help="GPUs serving the run")
    p.add_argument("--ttft-ms", type=float, required=True, help="TTFT limit in ms")
    p.add_argument(
        "--tpot-or-gap-ms",
        type=float,
        required=True,
        help="limit on each request's longest inter-token gap, in ms",
    )
    p.add_argument("--out", required=True, help="where to write the summary JSON")
    args = p.parse_args(argv)
    if args.planned_requests <= 0:
        p.error("--planned-requests must be positive")
    if args.gpu_count <= 0:
        p.error("--gpu-count must be positive")
    if not (args.ttft_ms > 0 and math.isfinite(args.ttft_ms)):
        p.error("--ttft-ms must be a positive number")
    if not (args.tpot_or_gap_ms > 0 and math.isfinite(args.tpot_or_gap_ms)):
        p.error("--tpot-or-gap-ms must be a positive number")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        records = load_records(args.records)
        result = score(
            records,
            args.planned_requests,
            args.gpu_count,
            args.ttft_ms,
            args.tpot_or_gap_ms,
        )
    except InputError as e:
        print(f"score.py: {e}", file=sys.stderr)
        return 1
    try:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2)
            f.write("\n")
    except OSError as e:
        print(f"score.py: cannot write {args.out}: {e.strerror}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
