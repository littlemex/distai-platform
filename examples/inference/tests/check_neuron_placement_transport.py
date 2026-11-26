"""Values/template contract checks for examples/inference/vllm/neuron/{disagg-pd,agg-baseline}.

The Neuron (Trainium) counterparts of vllm/disagg-pd and vllm/agg-baseline
(Issue #80) keep the GPU charts' top-level values shape (placement.*,
transport.*, kvCacheTier.*, prefill.*/decode.*) with these differences, all
checked here from `helm template` output alone:

  - prefill/decode.gpusPerEngine is renamed neuronCoresPerEngine (agg-baseline:
    engine.neuronCoresPerEngine), and there is no mps/gpuMemoryUtilization;
  - accelerator.resourceName defaults to aws.amazon.com/neuron, and each
    role's vLLM container requests exactly neuronCoresPerEngine of it, which
    also reaches vLLM's --tensor-parallel-size;
  - transport.efaResourceName still defaults to vpc.amazonaws.com/efa;
  - engine.compileCacheVolume (default emptyDir: {}) is mounted at exactly the
    path VLLM_CACHE_ROOT names;
  - NEURON_VISIBLE_DEVICES is never set (the vLLM Neuron plugin documents it
    for bare-metal host-level numbering only; under the Kubernetes device
    plugin it must stay unset).

The placement contract (decode-only required anti-affinity against prefill,
the two nodeSelectorValues, sameNodeMeasurement retargeting both roles to
sharedPoolValue) and the UCX port-range guard are the same contract
check_placement_transport.py holds the GPU chart to; the pure helpers are
imported from it rather than copied.

A chart directory that does not exist, a chart that does not render, or a
values key the contract names that is missing is reported as a FAIL line
naming the path or key -- never skipped, never a traceback.

Nothing here depends on a Deployment, Service, or container name the chart
happens to choose. A role workload is identified by its nodeSelector value on
placement.nodeSelectorKey (both read from `helm show values`); when
sameNodeMeasurement puts both roles on one shared value, by a pod template
label whose value is the role name. The vLLM container of a role is the
container requesting the Neuron resource.

Usage: check_neuron_placement_transport.py --helm HELM --disagg CHART_DIR --agg CHART_DIR --work-dir DIR
Prints PASS/FAIL per check; exits 1 if any failed.
"""

import argparse
import json
import os
import re
import subprocess
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from check_placement_transport import (  # noqa: E402
    HOSTNAME,
    Renderer,
    anti_terms,
    configmap_text,
    container_text,
    env_of,
    get_path,
    name_of,
    pod_labels,
    pod_spec,
    term_hits,
    workloads,
)

NEURON = "aws.amazon.com/neuron"
EFA = "vpc.amazonaws.com/efa"
FORBIDDEN_ENV = "NEURON_VISIBLE_DEVICES"
ROLES = ("prefill", "decode")

failures = []


def check(label, ok, detail=""):
    if ok:
        print(f"PASS {label}")
    else:
        print(f"FAIL {label}{': ' + str(detail) if detail else ''}")
        failures.append(label)
    return ok


# ------------------------------------------------------------- rendering

class NeuronRenderer(Renderer):
    """Renderer whose show_values keeps helm's own error text, so a missing
    chart surfaces as helm's "path ... not found" rather than a bare None."""

    def show_values(self, chart):
        proc = subprocess.run([self.helm, "show", "values", chart], capture_output=True, text=True)
        if proc.returncode != 0:
            return None, proc.stderr.strip()
        return yaml.safe_load(proc.stdout) or {}, ""


def chart_present(chart, rel):
    """The chart directory and its Chart.yaml exist; FAIL naming the path otherwise."""
    path = os.path.join(chart, "Chart.yaml")
    return check(f"{rel}: chart exists ({path})", os.path.isfile(path),
                 f"{path} not found -- the {rel} chart is not on this branch")


def require_keys(rel, values, present, absent):
    """Every path in `present` exists in values.yaml and none in `absent` does."""
    missing = [".".join(p) for p in present if not get_path(values, p)[1]]
    check(f"{rel} values: every key the contract names is present", not missing,
          f"missing values key(s): {missing}")
    stray = [".".join(p) for p in absent if get_path(values, p)[1]]
    check(f"{rel} values: no GPU-only key (gpusPerEngine, mps, gpuMemoryUtilization)", not stray,
          f"present but must not exist on a Neuron chart: {stray}")
    return not missing


# ------------------------------------------------------------ inspection

def neuron_containers(spec, resource=NEURON):
    """Containers requesting the Neuron resource. Unlike the GPU checker's
    gpu_containers this does not fall back to every container: a role with no
    Neuron request is itself a contract failure."""
    return [c for c in spec.get("containers") or []
            if resource in (((c.get("resources") or {}).get("limits")) or {})]


def roles_by(docs, key, values_by_role):
    """{role: [workload]} by nodeSelector[key] == that role's nodeSelectorValue;
    falls back to a pod template label whose value is the role name when the
    nodeSelector no longer tells the roles apart (sameNodeMeasurement)."""
    by_value = {v: r for r, v in values_by_role.items()}
    out = {r: [] for r in ROLES}
    for w in workloads(docs):
        r = by_value.get((pod_spec(w).get("nodeSelector") or {}).get(key))
        if r is None:
            hits = [v for v in pod_labels(w).values() if v in ROLES]
            r = hits[0] if len(set(hits)) == 1 else None
        if r is not None:
            out[r].append(w)
    return out


def check_roles_present(label, docs, key, values_by_role):
    roles = roles_by(docs, key, values_by_role)
    ok = all(roles[r] for r in ROLES)
    check(f"{label}: a prefill and a decode workload", ok,
          "found " + ", ".join(f"{r}={[name_of(w) for w in roles[r]]}" for r in ROLES))
    return roles if ok else None


def check_no_forbidden_env(label, docs):
    """NEURON_VISIBLE_DEVICES is set nowhere: no container or init container
    env entry, no ConfigMap key (an envFrom source), no assignment in a
    command/args script."""
    hits = []
    assign = re.compile(r"\b" + FORBIDDEN_ENV + r"=")
    for w in workloads(docs):
        spec = pod_spec(w)
        for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
            if any(e.get("name") == FORBIDDEN_ENV for e in c.get("env") or []):
                hits.append(f"{name_of(w)}/{c.get('name')} env")
            if assign.search(json.dumps({"command": c.get("command"), "args": c.get("args")})):
                hits.append(f"{name_of(w)}/{c.get('name')} command/args assigns it")
    for d in docs:
        if d.get("kind") == "ConfigMap" and FORBIDDEN_ENV in (d.get("data") or {}):
            hits.append(f"{name_of(d)} data key")
    check(f"{label}: {FORBIDDEN_ENV} is never set (left to the Neuron device plugin)", not hits, hits)


def check_neuron_request(label, w, want):
    cs = neuron_containers(pod_spec(w))
    got = [str(((c.get("resources") or {}).get("limits") or {}).get(NEURON)) for c in cs]
    check(f"{label}: {name_of(w)} has a container with resources.limits[{NEURON}] = {want} "
          "(neuronCoresPerEngine)", bool(got) and all(g == str(want) for g in got), f"got {got or 'no Neuron request'}")
    return cs


def tp_env_names(cs, cores):
    """Env var names whose value is the configured core count, on any of cs."""
    return {n for c in cs for n, v in env_of(c).items() if v == str(cores)}


def check_tp_wired(label, w, cs, names, cores):
    """--tensor-parallel-size is given the core count, either literally or via
    one of the env vars that carry it."""
    for c in cs:
        text = json.dumps({"command": c.get("command"), "args": c.get("args")})
        ok = "--tensor-parallel-size" in text and (
            any(f"${n}" in text or f"${{{n}}}" in text for n in names)
            or re.search(r"--tensor-parallel-size[\\\"', =]+" + str(cores) + r"\b", text) is not None)
        check(f"{label}: {name_of(w)} container {c.get('name')} passes neuronCoresPerEngine ({cores}) to "
              "--tensor-parallel-size", ok, f"env carrying {cores}: {sorted(names)}; command/args={text[:400]}")


def check_compile_cache(label, w, cs, want_volume):
    """VLLM_CACHE_ROOT equals, as a string, the mountPath of a volumeMount
    whose volume is engine.compileCacheVolume as configured."""
    spec = pod_spec(w)
    vols = {v.get("name"): {k: x for k, x in v.items() if k != "name"} for v in spec.get("volumes") or []}
    for c in cs:
        root = env_of(c).get("VLLM_CACHE_ROOT")
        if not check(f"{label}: {name_of(w)} container {c.get('name')} sets VLLM_CACHE_ROOT", bool(root),
                     f"VLLM_CACHE_ROOT={'<unset>' if root is None else repr(root)}"):
            continue
        mounts = [m for m in c.get("volumeMounts") or [] if m.get("mountPath") == root]
        if not check(f"{label}: {name_of(w)} container {c.get('name')} mounts a volume at exactly "
                     f"VLLM_CACHE_ROOT ({root})", len(mounts) == 1,
                     f"mountPaths={[m.get('mountPath') for m in c.get('volumeMounts') or []]}"):
            continue
        vname = mounts[0].get("name")
        check(f"{label}: {name_of(w)} the volume at {root} ({vname}) is engine.compileCacheVolume "
              f"({json.dumps(want_volume)})", vols.get(vname) == want_volume,
              f"volume {vname!r} = {json.dumps(vols.get(vname, '<not in pod volumes>'))}")
        check(f"{label}: {name_of(w)} mount at {root} is writable (the compile cache is written on a cold start)",
              not mounts[0].get("readOnly"), json.dumps(mounts[0]))


# ---------------------------------------------------------------- checks

DISAGG_PRESENT = [
    ("accelerator", "resourceName"),
    ("placement", "nodeSelectorKey"), ("placement", "sameNodeMeasurement"),
    ("placement", "sharedPoolValue"), ("placement", "enforceAntiAffinity"),
    ("transport", "backend"), ("transport", "efaResourceName"), ("transport", "ucx", "tcpPortRange"),
    ("kvCacheTier", "mode"),
    ("engine", "cacheVolume"), ("engine", "compileCacheVolume"),
] + [(r, k) for r in ROLES for k in (
    "replicas", "neuronCoresPerEngine", "efaDevices", "nodeSelectorValue",
    "extraNodeSelector", "resources", "extraArgs", "extraEnv")]
DISAGG_ABSENT = [(r, k) for r in ROLES for k in ("gpusPerEngine", "mps", "gpuMemoryUtilization")]

AGG_PRESENT = [
    ("accelerator", "resourceName"), ("kvCacheTier", "mode"),
    ("engine", "neuronCoresPerEngine"), ("engine", "cacheVolume"), ("engine", "compileCacheVolume"),
]
AGG_ABSENT = [("engine", k) for k in ("gpusPerEngine", "mps", "gpuMemoryUtilization")]

# Fixed core counts for the override render, chosen to fit a trn2.3xlarge
# (4 NeuronCores); replaced by another if a default already equals one.
CORE_CANDIDATES = (2, 4, 1)


def pick_override(default, avoid=()):
    return next(n for n in CORE_CANDIDATES if str(n) != str(default) and n not in avoid)


def check_disagg(R, chart):
    rel = "neuron/disagg-pd"
    if not chart_present(chart, rel):
        return
    values, err = R.show_values(chart)
    if not check(f"{rel}: helm show values", values is not None, err):
        return
    if not require_keys(rel, values, DISAGG_PRESENT, DISAGG_ABSENT):
        return

    def val(*path):
        v, ok = get_path(values, path)
        return v if ok else "<missing>"

    key = val("placement", "nodeSelectorKey")
    shared = val("placement", "sharedPoolValue")
    sel_values = {r: val(r, "nodeSelectorValue") for r in ROLES}
    check(f"{rel} values: accelerator.resourceName defaults to {NEURON}",
          val("accelerator", "resourceName") == NEURON, repr(val("accelerator", "resourceName")))
    check(f"{rel} values: transport.efaResourceName defaults to {EFA}",
          val("transport", "efaResourceName") == EFA, repr(val("transport", "efaResourceName")))
    check(f"{rel} values: transport.backend defaults to LIBFABRIC",
          val("transport", "backend") == "LIBFABRIC", repr(val("transport", "backend")))
    check(f"{rel} values: placement.nodeSelectorKey defaults to distai.dev/pd-role",
          key == "distai.dev/pd-role", repr(key))
    check(f"{rel} values: placement.sameNodeMeasurement defaults to false",
          val("placement", "sameNodeMeasurement") is False, repr(val("placement", "sameNodeMeasurement")))
    check(f"{rel} values: placement.enforceAntiAffinity defaults to true",
          val("placement", "enforceAntiAffinity") is True, repr(val("placement", "enforceAntiAffinity")))
    check(f"{rel} values: prefill and decode nodeSelectorValues differ",
          sel_values["prefill"] != sel_values["decode"], json.dumps(sel_values))
    check(f"{rel} values: engine.compileCacheVolume defaults to emptyDir: {{}}",
          val("engine", "compileCacheVolume") == {"emptyDir": {}}, json.dumps(val("engine", "compileCacheVolume")))

    scenarios = {}

    # ----------------------------------------------- default rendering
    docs, err = R.render(chart)
    if check(f"{rel} default: helm template", docs is not None, err):
        scenarios["default"] = docs
        roles = check_roles_present(f"{rel} default", docs, key, sel_values)
        if roles:
            for r in ROLES:
                for w in roles[r]:
                    got = (pod_spec(w).get("nodeSelector") or {}).get(key)
                    check(f"{rel} default: {name_of(w)} ({r}) nodeSelector {key}={sel_values[r]} "
                          f"({r}.nodeSelectorValue)", got == sel_values[r], repr(got))
                    cs = check_neuron_request(f"{rel} default ({r})", w, val(r, "neuronCoresPerEngine"))
                    check_compile_cache(f"{rel} default ({r})", w, cs, val("engine", "compileCacheVolume"))
                    efa = val(r, "efaDevices")
                    got_efa = [str(((c.get("resources") or {}).get("limits") or {}).get(EFA)) for c in cs]
                    check(f"{rel} default: {name_of(w)} ({r}) requests resources.limits[{EFA}] = {efa} "
                          f"({r}.efaDevices)", bool(got_efa) and all(g == str(efa) for g in got_efa), f"got {got_efa}")
                    text = " ".join(container_text(c) for c in cs) + " " + configmap_text(docs)
                    check(f"{rel} default: {name_of(w)} ({r}) configures a NixlConnector "
                          "(NixlConnector or NeuronNixlConnector) with the LIBFABRIC backend",
                          "NixlConnector" in text and "LIBFABRIC" in text)
            check_decode_anti_affinity(f"{rel} default", roles)

    # ------------------------------------------- sameNodeMeasurement=true
    sdocs, err = R.render(chart, sets=["placement.sameNodeMeasurement=true"])
    if check(f"{rel} sameNodeMeasurement=true: helm template", sdocs is not None, err):
        scenarios["sameNodeMeasurement=true"] = sdocs
        sroles = check_roles_present(f"{rel} sameNodeMeasurement=true", sdocs, key, sel_values)
        if sroles:
            got = {r: [(pod_spec(w).get("nodeSelector") or {}).get(key) for w in sroles[r]] for r in ROLES}
            check(f"{rel} sameNodeMeasurement=true: both roles' nodeSelector {key} is placement.sharedPoolValue "
                  f"({shared})", all(v == shared for r in ROLES for v in got[r]), json.dumps(got))
            check_decode_anti_affinity(f"{rel} sameNodeMeasurement=true, enforceAntiAffinity=true (default)", sroles)

    # ------------------------------------------- enforceAntiAffinity=false
    edocs, err = R.render(chart, sets=["placement.enforceAntiAffinity=false"])
    if check(f"{rel} enforceAntiAffinity=false: helm template", edocs is not None, err):
        scenarios["enforceAntiAffinity=false"] = edocs
        eroles = check_roles_present(f"{rel} enforceAntiAffinity=false", edocs, key, sel_values)
        if eroles:
            for r in ROLES:
                other = ROLES[1 - ROLES.index(r)]
                for w in eroles[r]:
                    req, pref = anti_terms(pod_spec(w))
                    hits = [t for t in req + pref for o in eroles[other] if term_hits(t, pod_labels(o))]
                    check(f"{rel} enforceAntiAffinity=false: {name_of(w)} ({r}) has no podAntiAffinity term "
                          f"against the {other} pods", not hits, json.dumps(hits))
                    got = (pod_spec(w).get("nodeSelector") or {}).get(key)
                    check(f"{rel} enforceAntiAffinity=false: {name_of(w)} ({r}) still selects {key}={sel_values[r]}",
                          got == sel_values[r], repr(got))

    # ----------------------------------- neuronCoresPerEngine override
    want = {}
    for r in ROLES:
        want[r] = pick_override(val(r, "neuronCoresPerEngine"), avoid=want.values())
    kdocs, err = R.render(chart, sets=[f"{r}.neuronCoresPerEngine={want[r]}" for r in ROLES])
    label = f"{rel} neuronCoresPerEngine prefill={want['prefill']},decode={want['decode']}"
    if check(f"{label}: helm template", kdocs is not None, err):
        scenarios["neuronCoresPerEngine override"] = kdocs
        kroles = check_roles_present(label, kdocs, key, sel_values)
        droles = roles_by(docs, key, sel_values) if docs is not None else {r: [] for r in ROLES}
        if kroles:
            for r in ROLES:
                default_cores = val(r, "neuronCoresPerEngine")
                default_names = tp_env_names([c for w in droles[r] for c in neuron_containers(pod_spec(w))],
                                             default_cores)
                for w in kroles[r]:
                    cs = check_neuron_request(f"{label} ({r})", w, want[r])
                    # An env var carries the core count when it equals the
                    # configured value both at the default and under the
                    # override -- the same name, following the value.
                    names = tp_env_names(cs, want[r]) & default_names
                    check(f"{label}: {name_of(w)} ({r}) has an env var that follows {r}.neuronCoresPerEngine "
                          f"({default_cores} by default, {want[r]} here)", bool(names),
                          f"env equal to {want[r]} here: {sorted(tp_env_names(cs, want[r]))}; "
                          f"env equal to {default_cores} at the default: {sorted(default_names)}")
                    check_tp_wired(f"{label} ({r})", w, cs, names, want[r])

    # -------------------------------------- engine.compileCacheVolume override
    # A PVC in place of the emptyDir default: proves the mount at
    # VLLM_CACHE_ROOT is wired from the value, not a coincidental emptyDir.
    # Helm deep-merges a values-file map into the chart's default map, so
    # the override nulls emptyDir explicitly (Helm's documented way to drop a
    # default key); without that the volume would carry both sources.
    pvc = {"persistentVolumeClaim": {"claimName": "neuron-compile-cache"}}
    cdocs, err = R.render(chart, values={"engine": {"compileCacheVolume": {"emptyDir": None, **pvc}}})
    if check(f"{rel} engine.compileCacheVolume=PVC: helm template", cdocs is not None, err):
        scenarios["compileCacheVolume=PVC"] = cdocs
        croles = check_roles_present(f"{rel} engine.compileCacheVolume=PVC", cdocs, key, sel_values)
        if croles:
            for r in ROLES:
                for w in croles[r]:
                    check_compile_cache(f"{rel} engine.compileCacheVolume=PVC ({r})", w,
                                        neuron_containers(pod_spec(w)), pvc)

    # --------------------------------------------------- UCX port range
    # Same guard as the GPU chart: a range wider than 4096 ports fails to
    # render; exactly 4096 still renders.
    _, err = R.render(chart, sets=["transport.backend=UCX", "transport.ucx.tcpPortRange=20000-24096"])
    check(f"{rel} transport.backend=UCX, tcpPortRange=20000-24096 (4097 ports): helm template fails "
          "naming transport.ucx.tcpPortRange", err is not None and "tcpPortRange" in (err or ""), err or "rendered")
    udocs, err = R.render(chart, sets=["transport.backend=UCX", "transport.ucx.tcpPortRange=20000-24095"])
    if check(f"{rel} transport.backend=UCX, tcpPortRange=20000-24095 (4096 ports): helm template", udocs is not None, err):
        scenarios["transport.backend=UCX"] = udocs

    for name, sdocs in scenarios.items():
        check_no_forbidden_env(f"{rel} {name}", sdocs)


def check_decode_anti_affinity(label, roles):
    # Decode only, never both roles (two required terms pointing at each
    # other can leave neither schedulable), matching prefill's own labels.
    for w in roles["decode"]:
        req, _ = anti_terms(pod_spec(w))
        ok = all(any(term_hits(t, pod_labels(o)) for t in req) for o in roles["prefill"])
        check(f"{label}: {name_of(w)} (decode) has a required podAntiAffinity term, topologyKey {HOSTNAME}, "
              "selecting the prefill pods' labels", ok,
              f"required terms={json.dumps(req)} prefill pod labels={[pod_labels(o) for o in roles['prefill']]}")
        check(f"{label}: {name_of(w)} (decode)'s anti-affinity does not select its own pods",
              not any(term_hits(t, pod_labels(w)) for t in req), json.dumps(req))
    for w in roles["prefill"]:
        req, pref = anti_terms(pod_spec(w))
        check(f"{label}: {name_of(w)} (prefill) carries no podAntiAffinity term of its own",
              not (req or pref), json.dumps(req + pref))


def check_agg(R, chart):
    rel = "neuron/agg-baseline"
    if not chart_present(chart, rel):
        return
    values, err = R.show_values(chart)
    if not check(f"{rel}: helm show values", values is not None, err):
        return
    if not require_keys(rel, values, AGG_PRESENT, AGG_ABSENT):
        return

    def val(*path):
        v, ok = get_path(values, path)
        return v if ok else "<missing>"

    check(f"{rel} values: accelerator.resourceName defaults to {NEURON}",
          val("accelerator", "resourceName") == NEURON, repr(val("accelerator", "resourceName")))
    check(f"{rel} values: engine.compileCacheVolume defaults to emptyDir: {{}}",
          val("engine", "compileCacheVolume") == {"emptyDir": {}}, json.dumps(val("engine", "compileCacheVolume")))

    scenarios = {}
    docs, err = R.render(chart)
    if check(f"{rel} default: helm template", docs is not None, err):
        scenarios["default"] = docs
        ws = workloads(docs)
        check(f"{rel} default: exactly one vLLM workload", len(ws) == 1, str([name_of(w) for w in ws]))
        for w in ws:
            cs = check_neuron_request(f"{rel} default", w, val("engine", "neuronCoresPerEngine"))
            check_compile_cache(f"{rel} default", w, cs, val("engine", "compileCacheVolume"))

    want = pick_override(val("engine", "neuronCoresPerEngine"))
    kdocs, err = R.render(chart, sets=[f"engine.neuronCoresPerEngine={want}"])
    if check(f"{rel} engine.neuronCoresPerEngine={want}: helm template", kdocs is not None, err):
        scenarios["neuronCoresPerEngine override"] = kdocs
        for w in workloads(kdocs):
            cs = check_neuron_request(f"{rel} engine.neuronCoresPerEngine={want}", w, want)
            check_tp_wired(f"{rel} engine.neuronCoresPerEngine={want}", w, cs, tp_env_names(cs, want), want)

    for name, sdocs in scenarios.items():
        check_no_forbidden_env(f"{rel} {name}", sdocs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--helm", default="helm")
    ap.add_argument("--disagg", required=True)
    ap.add_argument("--agg", required=True)
    ap.add_argument("--work-dir", required=True)
    a = ap.parse_args()
    R = NeuronRenderer(a.helm, a.work_dir)

    check_disagg(R, a.disagg)
    check_agg(R, a.agg)

    print()
    if failures:
        print(f"RESULT FAIL: {len(failures)} Neuron placement/transport check(s) failed")
        return 1
    print("RESULT PASS: all Neuron placement/transport checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
