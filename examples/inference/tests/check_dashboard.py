"""Static checks for examples/inference/_shared/dashboards/vllm-pd.json (stdlib only).

Asserts, against the interface contract: valid Grafana 11.x dashboard JSON
(schemaVersion 39..41, the range Grafana 11.0..11.6 writes), and a panel
query for every metric the contract names, plus the joint-SLO goodput
panel. Datasources must be referenced through a variable, never a literal
UID of one environment's Grafana.

Usage: check_dashboard.py PATH. Prints PASS/FAIL per check; exits 1 if any failed.
"""

import json
import sys

REQUIRED_METRICS = [
    "vllm:time_to_first_token_seconds_bucket",
    # vLLM's real /metrics output (confirmed against a running v0.34.0
    # engine; "vllm:time_per_output_token_seconds_bucket" and
    # "vllm:gpu_cache_usage_perc", named in an earlier draft of this
    # contract, do not exist):
    "vllm:inter_token_latency_seconds_bucket",
    "vllm:request_time_per_output_token_seconds_bucket",
    "vllm:e2e_request_latency_seconds_bucket",
    "vllm:num_requests_running",
    "vllm:num_requests_waiting",
    "vllm:kv_cache_usage_perc",
    "node_amazonefa_tx_bytes_total",
    "node_amazonefa_rdma_write_bytes_total",
    "node_amazonefa_rdma_write_recv_bytes_total",
]
QUANTILE_METRICS = [
    "vllm:time_to_first_token_seconds_bucket",
    "vllm:request_time_per_output_token_seconds_bucket",
]

failures = []


def check(label, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {label}{'' if ok or not detail else ': ' + detail}")
    if not ok:
        failures.append(label)


def walk_panels(panels):
    for p in panels or []:
        yield p
        yield from walk_panels(p.get("panels"))


def walk(obj):
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk(v)


def main(path):
    try:
        with open(path, encoding="utf-8") as f:
            dash = json.load(f)
    except (OSError, ValueError) as e:
        check(f"{path} is valid JSON", False, str(e))
        return 1
    check(f"{path} is valid JSON", True)
    if "dashboard" in dash and isinstance(dash["dashboard"], dict):
        dash = dash["dashboard"]

    sv = dash.get("schemaVersion")
    check("schemaVersion is a Grafana 11.x value (39..41)", isinstance(sv, int) and 39 <= sv <= 41, repr(sv))

    panels = list(walk_panels(dash.get("panels")))
    check("dashboard has panels", bool(panels))
    exprs = []
    for p in panels:
        for t in p.get("targets") or []:
            e = t.get("expr") or t.get("expression") or ""
            exprs.append((p.get("title") or "", e))
    all_expr = "\n".join(e for _, e in exprs)

    for m in REQUIRED_METRICS:
        check(f"a panel queries {m}", m in all_expr)
    for m in QUANTILE_METRICS:
        for q in ("0.5", "0.9", "0.99"):
            ok = any("histogram_quantile" in e and m in e and (f"({q}," in e.replace(" ", "")) for _, e in exprs)
            check(f"histogram_quantile({q}, ...{m}...) is plotted", ok)
    for role in ("prefill", "decode"):
        ok = any("up{" in e and "component" in e and role in e for _, e in exprs)
        check(f"a per-role replica panel uses up{{component=...{role}...}}", ok)

    known = set(REQUIRED_METRICS) | {"up{"}
    goodput = [(t, e) for t, e in exprs if "goodput" in t.lower() and e.strip()]
    check("a goodput panel (title contains 'goodput') has a non-empty query", bool(goodput))
    check("the goodput panel queries a metric of its own, not one of the vLLM/EFA metrics above",
          any(not any(k in e for k in known) for _, e in goodput), str(goodput))

    literal = []
    for o in walk(dash):
        ds = o.get("datasource")
        uid = ds.get("uid") if isinstance(ds, dict) else ds if isinstance(ds, str) else None
        if uid and not str(uid).startswith("$") and uid not in ("-- Grafana --", "-- Mixed --", "-- Dashboard --", "grafana"):
            literal.append(uid)
    check("datasources are referenced through a variable (no environment-specific UID)", not literal,
          str(sorted(set(literal))))

    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_dashboard.py PATH", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
