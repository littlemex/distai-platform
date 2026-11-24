"""NetworkPolicy contract check for the NIXL UCX dynamic-port fix, across all four
prefill/decode disaggregation charts (vllm/disagg-pd, vllm/disagg-pd-llmd,
sglang/disagg-pd, sglang/disagg-pd-llmd).

NIXL's UCX backend (confirmed against ai-dynamo/nixl's src/plugins/ucx/config.cpp
and openucx/ucx's src/uct/tcp/tcp_iface.c) opens a TCP listener for the actual KV
connection on a port transport.ucx.tcpPortRange fixes to a narrow, declared range
(UCX_TCP_PORT_RANGE). The contract this script checks, from `helm template` output
alone (no AWS credentials, no cluster):

  1. with the engine transport selecting UCX (vllm: transport.backend=UCX; sglang:
     transport.backend=NIXL, transport.sglangNixlBackend=UCX), every rendered
     NetworkPolicy's ingress rules include a port/endPort pair matching the
     chart's own declared transport.ucx.tcpPortRange (read from `helm show
     values`, not hardcoded here, so this check tracks the shipped default
     rather than a copy of it), and that rule's "from" is scoped to a
     podSelector (never an unscoped/cluster-wide rule);
  2. with the engine transport selecting LIBFABRIC (vllm) or
     sglangNixlBackend=LIBFABRIC (sglang) -- the chart's own default -- no
     rendered NetworkPolicy contains an endPort field at all: LIBFABRIC's KV
     bytes and its own handshake move over the EFA userspace, bypassing the
     kernel's TCP/IP stack entirely, so there is nothing for a NetworkPolicy
     port range to open.

disagg-pd-llmd's own networkPolicy.enabled defaults to false (unlike disagg-pd's
true); this script sets networkPolicy.enabled=true explicitly on every render so
the same two checks apply uniformly to all four charts.

Usage: check_ucx_netpolicy.py --helm HELM --vllm-disagg-pd DIR --vllm-disagg-pd-llmd DIR
       --sglang-disagg-pd DIR --sglang-disagg-pd-llmd DIR
Prints PASS/FAIL per check; exits 1 if any failed.
"""

import argparse
import subprocess
import sys

import yaml

failures = []


def check(label, ok, detail=""):
    if ok:
        print(f"PASS {label}")
    else:
        print(f"FAIL {label}{': ' + detail if detail else ''}")
        failures.append(label)
    return ok


def helm_template(helm, chart, sets):
    cmd = [helm, "template", "ucx-netpolicy-test", chart, "--namespace", "ucx-netpolicy-test"]
    for s in sets:
        cmd += ["--set", s]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return None, proc.stderr.strip()
    return [d for d in yaml.safe_load_all(proc.stdout) if isinstance(d, dict)], ""


def helm_show_values(helm, chart):
    proc = subprocess.run([helm, "show", "values", chart], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return yaml.safe_load(proc.stdout) or {}


def networkpolicies(docs):
    return [d for d in docs if d.get("kind") == "NetworkPolicy"]


def ingress_ports(netpols):
    """Every ports entry across every ingress rule of every given NetworkPolicy,
    paired with whether that rule's "from" is scoped to at least one podSelector
    (never empty/omitted, which would mean "all sources")."""
    out = []
    for np in netpols:
        for rule in ((np.get("spec") or {}).get("ingress") or []):
            scoped = bool(rule.get("from")) and all(
                isinstance(f, dict) and f.get("podSelector") is not None for f in rule["from"]
            )
            for p in rule.get("ports") or []:
                out.append((p, scoped))
    return out


def has_end_port_anywhere(docs):
    return any("endPort" in p for p, _ in ingress_ports(networkpolicies(docs)))


def ucx_range_rendered(docs, first, last):
    """At least one ingress ports entry is exactly {port: first, endPort: last}
    (ignoring an optional explicit protocol field), on a from-scoped rule."""
    for p, scoped in ingress_ports(networkpolicies(docs)):
        if p.get("port") == first and p.get("endPort") == last:
            return scoped
    return None  # not rendered at all


def check_chart(helm, name, chart, ucx_sets):
    values = helm_show_values(helm, chart)
    if not check(f"{name}: helm show values", values is not None):
        return
    port_range = (values.get("transport") or {}).get("ucx", {}).get("tcpPortRange")
    if not check(f"{name}: transport.ucx.tcpPortRange is set in values.yaml", bool(port_range),
                 repr(port_range)):
        return
    parts = port_range.split("-")
    if not check(f"{name}: transport.ucx.tcpPortRange is \"<first>-<last>\"", len(parts) == 2,
                 repr(port_range)):
        return
    first, last = int(parts[0]), int(parts[1])

    # ---- 1. LIBFABRIC (the chart's own default): no endPort anywhere.
    libdocs, err = helm_template(helm, chart, ["networkPolicy.enabled=true"])
    if check(f"{name}: helm template, default transport (networkPolicy.enabled=true)",
             libdocs is not None, err):
        check(f"{name}: default transport renders at least one NetworkPolicy",
              len(networkpolicies(libdocs)) > 0)
        check(f"{name}: default transport (LIBFABRIC) renders no endPort anywhere "
              "(its KV bytes bypass the kernel's TCP/IP stack; nothing for a port range to open)",
              not has_end_port_anywhere(libdocs))

    # ---- 2. UCX selected: the declared range is rendered, from a scoped peer.
    udocs, err = helm_template(helm, chart, ["networkPolicy.enabled=true"] + ucx_sets)
    if check(f"{name}: helm template, {'/'.join(ucx_sets)} (networkPolicy.enabled=true)",
             udocs is not None, err):
        scoped = ucx_range_rendered(udocs, first, last)
        check(f"{name}: UCX backend renders an ingress port range {first}-{last} "
              "matching transport.ucx.tcpPortRange", scoped is not None)
        if scoped is not None:
            check(f"{name}: that port range's ingress rule is scoped to a podSelector "
                  "(peer role only, never an unscoped/cluster-wide rule)", scoped)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--helm", default="helm")
    ap.add_argument("--vllm-disagg-pd", required=True)
    ap.add_argument("--vllm-disagg-pd-llmd", required=True)
    ap.add_argument("--sglang-disagg-pd", required=True)
    ap.add_argument("--sglang-disagg-pd-llmd", required=True)
    a = ap.parse_args()

    check_chart(a.helm, "vllm/disagg-pd", a.vllm_disagg_pd, ["transport.backend=UCX"])
    check_chart(a.helm, "vllm/disagg-pd-llmd", a.vllm_disagg_pd_llmd, ["transport.backend=UCX"])
    check_chart(a.helm, "sglang/disagg-pd", a.sglang_disagg_pd,
                ["transport.backend=NIXL", "transport.sglangNixlBackend=UCX"])
    check_chart(a.helm, "sglang/disagg-pd-llmd", a.sglang_disagg_pd_llmd,
                ["transport.backend=NIXL", "transport.sglangNixlBackend=UCX"])

    print()
    if not failures:
        print("RESULT PASS: all UCX NetworkPolicy checks passed")
        return 0
    print(f"RESULT FAIL: {len(failures)} check(s) failed")
    return 1


if __name__ == "__main__":
    sys.exit(main())
