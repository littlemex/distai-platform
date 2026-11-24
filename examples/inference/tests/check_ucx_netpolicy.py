"""NetworkPolicy + env var contract check for the NIXL UCX dynamic-port fix, across all
four prefill/decode disaggregation charts (vllm/disagg-pd, vllm/disagg-pd-llmd,
sglang/disagg-pd, sglang/disagg-pd-llmd).

NIXL's UCX backend (confirmed against ai-dynamo/nixl @52df750's src/plugins/ucx/config.cpp
and openucx/ucx @bcf0a63's src/uct/tcp/tcp_iface.c) opens a TCP listener for the actual KV
connection on a port transport.ucx.tcpPortRange fixes to a narrow, declared range
(UCX_TCP_PORT_RANGE). The contract this script checks, from `helm template` output alone (no
AWS credentials, no cluster), for every chart and for BOTH the prefill and the decode role:

  1. with the engine transport pinned to UCX (vllm: transport.backend=UCX; sglang:
     transport.backend=NIXL, transport.sglangNixlBackend=UCX), every engine container of
     BOTH roles carries UCX_TCP_PORT_RANGE equal to the chart's own declared
     transport.ucx.tcpPortRange (read from `helm show values`, not hardcoded here, so this
     check tracks the shipped default rather than a copy of it), and EACH role's own
     rendered NetworkPolicy (not just "some" NetworkPolicy among several) carries a matching
     port/endPort pair, on an ingress rule whose "from" selector names the PEER role
     specifically (never empty, never the same role, never an unrelated component);
  2. with the engine transport pinned to its own default (vllm: LIBFABRIC; sglang:
     NIXL+LIBFABRIC, and separately MOONCAKE) -- no engine container carries
     UCX_TCP_PORT_RANGE, and no rendered NetworkPolicy contains an endPort field at all.
     This fix adds a port range only for NIXL's UCX backend: LIBFABRIC's own KV bytes move
     over the EFA userspace, bypassing the kernel's TCP/IP stack entirely (confirmed on real
     hardware), so there is nothing for a NetworkPolicy port range to open there. MOONCAKE
     never goes through NIXL's UCX backend at all (so this fix correctly adds no range for
     it either), but whether MOONCAKE's own mooncakeProtocol=tcp has an equivalent
     dynamic-port gap of its own was not examined by this fix (see each sglang chart's
     README, "Known issues") -- this check only asserts that this fix adds nothing for
     MOONCAKE, not that MOONCAKE needs nothing;
  3. a malformed or out-of-bounds transport.ucx.tcpPortRange (no dash, non-numeric, a
     leading zero, first >= last, first < 1, last > 65535, or a span over 4096 ports) makes
     `helm template` fail under the UCX combination, not render something wrong silently.

disagg-pd-llmd's own networkPolicy.enabled defaults to false (unlike disagg-pd's true); this
script sets networkPolicy.enabled=true explicitly on every render so the same checks apply
uniformly to all four charts.

Usage: check_ucx_netpolicy.py --helm HELM --vllm-disagg-pd DIR --vllm-disagg-pd-llmd DIR
       --sglang-disagg-pd DIR --sglang-disagg-pd-llmd DIR
Prints PASS/FAIL per check; exits 1 if any failed.
"""

import argparse
import subprocess
import sys

import yaml

ROLES = ("prefill", "decode")
PEER = {"prefill": "decode", "decode": "prefill"}

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
        # --set-string, not --set: Helm's strvals parser coerces a bare numeric-looking
        # token like "20000" to an int64, so --set transport.ucx.tcpPortRange=20000 fails
        # on a generic "wrong type for value; expected string; got int64" from regexMatch,
        # not on this chart's own validation message (confirmed: Helm v3.22.1, read the
        # exact error). Every value this script passes is a string in values.yaml (chart
        # defaults, read via YAML, are never bare ints here either), so --set-string is
        # always correct, not just for the ambiguous numeric case.
        cmd += ["--set-string", s]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return None, proc.stderr.strip()
    return [d for d in yaml.safe_load_all(proc.stdout) if isinstance(d, dict)], ""


def helm_template_raw(helm, chart, sets):
    """Like helm_template, but with plain --set (not --set-string): only for the one case
    that needs Helm's own strvals structural syntax (transport.ucx=null, to delete a key
    entirely), where forcing a string would set the literal string "null" instead."""
    cmd = [helm, "template", "ucx-netpolicy-test", chart, "--namespace", "ucx-netpolicy-test"]
    for s in sets:
        cmd += ["--set", s]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return None, proc.stderr.strip()
    return [d for d in yaml.safe_load_all(proc.stdout) if isinstance(d, dict)], ""


def helm_template_fails(helm, chart, sets):
    docs, err = helm_template(helm, chart, sets)
    return docs is None, err


def helm_show_values(helm, chart):
    proc = subprocess.run([helm, "show", "values", chart], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return yaml.safe_load(proc.stdout) or {}


def workloads(docs):
    return [d for d in docs if d.get("kind") in ("Deployment", "StatefulSet")]


def networkpolicies(docs):
    return [d for d in docs if d.get("kind") == "NetworkPolicy"]


def pod_spec(w):
    return ((w.get("spec") or {}).get("template") or {}).get("spec") or {}


def pod_labels(w):
    return (((w.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {}


def role_of(w):
    """The role (prefill/decode) a workload belongs to, from its own pod template's
    app.kubernetes.io/component label (set by every role's Deployment regardless of
    placement.sameNodeMeasurement, unlike the nodeSelector value)."""
    return pod_labels(w).get("app.kubernetes.io/component")


def role_workloads(docs, role):
    return [w for w in workloads(docs) if role_of(w) == role]


def all_envs(w):
    """Every (container_name, env_name, env_value_or_None) triple across every container
    and init container of a workload."""
    spec = pod_spec(w)
    out = []
    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
        for e in c.get("env") or []:
            out.append((c.get("name"), e.get("name"), e.get("value")))
    return out


def netpol_for_role(docs, role):
    """The NetworkPolicy object(s) whose own podSelector names this role specifically
    (component == role), the chart's own convention for "this role's own ingress rules"."""
    out = []
    for np in networkpolicies(docs):
        sel = ((np.get("spec") or {}).get("podSelector") or {}).get("matchLabels") or {}
        if sel.get("app.kubernetes.io/component") == role:
            out.append(np)
    return out


def ingress_rules_from_peer(np, peer_role):
    """Ingress rules of one NetworkPolicy whose "from" is scoped to exactly the peer role:
    every from-entry has a podSelector as its ONLY key (no sibling namespaceSelector, which
    would widen the match to every namespace, and no ipBlock), with matchLabels naming both
    app.kubernetes.io/component == peer_role and app.kubernetes.io/instance (not empty, not
    the same role, not an unrelated component, not every namespace)."""
    out = []
    for rule in ((np.get("spec") or {}).get("ingress") or []):
        froms = rule.get("from") or []
        if not froms:
            continue
        if all(
            isinstance(f, dict)
            and set(f.keys()) == {"podSelector"}
            and isinstance(f["podSelector"], dict)
            and set(f["podSelector"].keys()) == {"matchLabels"}
            and (f["podSelector"]["matchLabels"] or {}).get("app.kubernetes.io/component") == peer_role
            and (f["podSelector"]["matchLabels"] or {}).get("app.kubernetes.io/instance")
            for f in froms
        ):
            out.append(rule)
    return out


def range_rendered_from_peer(docs, role, first, last):
    """True only if THIS role's own NetworkPolicy carries a port/endPort pair matching
    (first, last) on a rule scoped to exactly the peer role (not some other NetworkPolicy,
    not an unscoped rule, not a rule naming the wrong role)."""
    nps = netpol_for_role(docs, role)
    if not nps:
        return None  # this role's own NetworkPolicy was not even rendered
    for np in nps:
        for rule in ingress_rules_from_peer(np, PEER[role]):
            for p in rule.get("ports") or []:
                if p.get("port") == first and p.get("endPort") == last:
                    return True
    return False


def has_end_port_anywhere(docs):
    for np in networkpolicies(docs):
        for rule in (np.get("spec") or {}).get("ingress") or []:
            for p in rule.get("ports") or []:
                if "endPort" in p:
                    return True
    return False


def has_range_rendered_anywhere(docs, first, last):
    for np in networkpolicies(docs):
        for rule in (np.get("spec") or {}).get("ingress") or []:
            for p in rule.get("ports") or []:
                if p.get("port") == first and p.get("endPort") == last:
                    return True
    return False


def env_var_present(docs, role, name):
    """Collects every distinct value any container of this role's own workload(s) sets
    for the given env var name, across every container and init container. Returns
    (at_least_one_container_sets_it, the_set_of_distinct_values); (None, None) if the
    role's workload was not found at all. A container that never sets this env var simply
    does not contribute to the set -- this does not assert *every* container sets it, only
    that at least one does and none disagrees with another on the value."""
    ws = role_workloads(docs, role)
    if not ws:
        return None, None
    values = set()
    for w in ws:
        for _, env_name, env_value in all_envs(w):
            if env_name == name:
                values.add(env_value)
    return (len(values) > 0), values


def check_chart(helm, name, chart, ucx_sets, default_sets, extra_default_cases=()):
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

    # ---- 1. the chart's own pinned default transport: no env var, no endPort anywhere.
    for case_label, sets in (("default", default_sets),) + tuple(extra_default_cases):
        libdocs, err = helm_template(helm, chart, ["networkPolicy.enabled=true"] + sets)
        if not check(f"{name}: helm template, {case_label} transport (networkPolicy.enabled=true, {'/'.join(sets)})",
                     libdocs is not None, err):
            continue
        check(f"{name}: {case_label} transport renders at least one NetworkPolicy",
              len(networkpolicies(libdocs)) > 0)
        # The reason differs by case: LIBFABRIC's KV bytes bypass the kernel's TCP/IP stack
        # (confirmed), so there is nothing for a port range to open; MOONCAKE never goes
        # through NIXL's UCX backend at all (this fix adds no range for it either way), but
        # whether MOONCAKE's own mooncakeProtocol=tcp has an equivalent dynamic-port gap of
        # its own was not examined by this fix (see README, "Known issues") -- the assertion
        # here is only "this fix renders no endPort", not a claim that MOONCAKE needs none.
        check(f"{name}: {case_label} transport renders no endPort anywhere "
              "(this fix adds a range only for NIXL's UCX backend)",
              not has_end_port_anywhere(libdocs))
        for role in ROLES:
            present, vals = env_var_present(libdocs, role, "UCX_TCP_PORT_RANGE")
            check(f"{name}: {case_label} transport renders no UCX_TCP_PORT_RANGE on {role} "
                  "({role}'s own workload must actually be found, not merely absent from the check)",
                  present is False, repr((present, vals)))

    # ---- 2. UCX selected: both roles' own env var and own NetworkPolicy carry the range,
    # scoped to the peer role specifically.
    udocs, err = helm_template(helm, chart, ["networkPolicy.enabled=true"] + ucx_sets)
    if not check(f"{name}: helm template, {'/'.join(ucx_sets)} (networkPolicy.enabled=true)",
                 udocs is not None, err):
        return
    for role in ROLES:
        present, vals = env_var_present(udocs, role, "UCX_TCP_PORT_RANGE")
        check(f"{name}: UCX backend's own {role} workload(s) carry UCX_TCP_PORT_RANGE={port_range!r} "
              "on at least one container, with no container disagreeing on the value",
              present is True and vals == {port_range}, repr(vals))
        rendered = range_rendered_from_peer(udocs, role, first, last)
        check(f"{name}: {role}'s own NetworkPolicy renders an ingress port range {first}-{last} "
              f"matching transport.ucx.tcpPortRange, scoped to exactly the peer role ({PEER[role]})",
              rendered is True, repr(rendered))

    # ---- 2b. a positive control: a non-default range must actually be the one rendered,
    # not a copy of the chart's own default hardcoded somewhere in the template.
    custom_first, custom_last = 21000, 21063
    cdocs, err = helm_template(helm, chart, ["networkPolicy.enabled=true"] + ucx_sets +
                                [f"transport.ucx.tcpPortRange={custom_first}-{custom_last}"])
    if check(f"{name}: helm template, UCX with a non-default transport.ucx.tcpPortRange="
             f"{custom_first}-{custom_last}", cdocs is not None, err):
        for role in ROLES:
            present, vals = env_var_present(cdocs, role, "UCX_TCP_PORT_RANGE")
            check(f"{name}: a non-default tcpPortRange is honored on {role}'s own env var "
                  "(not a hardcoded default)", present is True and vals == {f"{custom_first}-{custom_last}"},
                  repr(vals))
            rendered = range_rendered_from_peer(cdocs, role, custom_first, custom_last)
            check(f"{name}: a non-default tcpPortRange is honored on {role}'s own NetworkPolicy "
                  "(not a hardcoded default)", rendered is True, repr(rendered))
        check(f"{name}: a non-default tcpPortRange does NOT also render the chart's own default "
              f"{first}-{last} anywhere", not has_range_rendered_anywhere(cdocs, first, last))

    # ---- 2c. the 4096-port width cap boundary: exactly 4096 ports passes, 4097 fails.
    ok_fails, ok_err = helm_template_fails(helm, chart, ucx_sets + ["transport.ucx.tcpPortRange=20000-24095"])
    check(f"{name}: transport.ucx.tcpPortRange=20000-24095 (exactly 4096 ports) does NOT fail",
          not ok_fails, ok_err)
    bad_fails, bad_err = helm_template_fails(helm, chart, ucx_sets + ["transport.ucx.tcpPortRange=20000-24096"])
    check(f"{name}: transport.ucx.tcpPortRange=20000-24096 (4097 ports) fails on the width cap",
          bad_fails and "tcpPortRange" in (bad_err or ""), bad_err or "rendered without error")

    # ---- 2d. UCX with networkPolicy.enabled=false: the env var still renders (it does not
    # depend on networkPolicy.enabled at all), but zero NetworkPolicy objects render at all
    # (nothing to open the range in; this is the exact combination vllm/disagg-pd-llmd's own
    # README states for its own networkPolicy.enabled=false default).
    offdocs, err = helm_template(helm, chart, ["networkPolicy.enabled=false"] + ucx_sets)
    if check(f"{name}: helm template, UCX with networkPolicy.enabled=false", offdocs is not None, err):
        check(f"{name}: UCX with networkPolicy.enabled=false renders zero NetworkPolicy objects",
              len(networkpolicies(offdocs)) == 0)
        for role in ROLES:
            present, vals = env_var_present(offdocs, role, "UCX_TCP_PORT_RANGE")
            check(f"{name}: UCX with networkPolicy.enabled=false still sets UCX_TCP_PORT_RANGE on {role} "
                  "(the env var does not depend on networkPolicy.enabled)",
                  present is True and vals == {port_range}, repr(vals))

    # ---- 3. malformed / out-of-bounds values fail to render under the UCX combination,
    # specifically on this chart's own validation message (not some unrelated type error).
    bad_values = ["20000", "a-b", "020000-020063", "20063-20000", "20000-20000",
                  "0-10", "1-70000", "20000-30000"]
    for bad in bad_values:
        fails, err = helm_template_fails(helm, chart, ucx_sets + [f"transport.ucx.tcpPortRange={bad}"])
        check(f"{name}: transport.ucx.tcpPortRange={bad!r} makes helm template fail "
              "on this chart's own tcpPortRange validation message",
              fails and "tcpPortRange" in (err or ""), err or "rendered without error")

    # ---- 4. a non-UCX render with transport.ucx entirely absent (simulating helm upgrade
    # --reuse-values from a pre-fix release, where the old stored config has no "ucx" key at
    # all and the chart's own default never gets a chance to fill it in) must still succeed,
    # and must not render any UCX_TCP_PORT_RANGE or endPort.
    nodocs, err = helm_template_raw(helm, chart, default_sets + ["networkPolicy.enabled=true",
                                                                  "transport.ucx=null"])
    if check(f"{name}: default transport with transport.ucx entirely absent (simulated "
             "--reuse-values from a pre-fix release) still renders", nodocs is not None, err):
        check(f"{name}: transport.ucx absent + default transport renders no endPort anywhere",
              not has_end_port_anywhere(nodocs))
        for role in ROLES:
            present, vals = env_var_present(nodocs, role, "UCX_TCP_PORT_RANGE")
            check(f"{name}: transport.ucx absent + default transport renders no UCX_TCP_PORT_RANGE on {role}",
                  present is False, repr((present, vals)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--helm", default="helm")
    ap.add_argument("--vllm-disagg-pd", required=True)
    ap.add_argument("--vllm-disagg-pd-llmd", required=True)
    ap.add_argument("--sglang-disagg-pd", required=True)
    ap.add_argument("--sglang-disagg-pd-llmd", required=True)
    a = ap.parse_args()

    check_chart(a.helm, "vllm/disagg-pd", a.vllm_disagg_pd,
                ["transport.backend=UCX"], ["transport.backend=LIBFABRIC"])
    check_chart(a.helm, "vllm/disagg-pd-llmd", a.vllm_disagg_pd_llmd,
                ["transport.backend=UCX"], ["transport.backend=LIBFABRIC"])
    check_chart(a.helm, "sglang/disagg-pd", a.sglang_disagg_pd,
                ["transport.backend=NIXL", "transport.sglangNixlBackend=UCX"],
                ["transport.backend=NIXL", "transport.sglangNixlBackend=LIBFABRIC"],
                extra_default_cases=[("MOONCAKE", ["transport.backend=MOONCAKE"])])
    check_chart(a.helm, "sglang/disagg-pd-llmd", a.sglang_disagg_pd_llmd,
                ["transport.backend=NIXL", "transport.sglangNixlBackend=UCX"],
                ["transport.backend=NIXL", "transport.sglangNixlBackend=LIBFABRIC"],
                extra_default_cases=[("MOONCAKE", ["transport.backend=MOONCAKE"])])

    print()
    if not failures:
        print("RESULT PASS: all UCX NetworkPolicy checks passed")
        return 0
    print(f"RESULT FAIL: {len(failures)} check(s) failed")
    return 1


if __name__ == "__main__":
    sys.exit(main())
