"""Values/template contract checks for examples/inference/vllm/neuron/{disagg-pd,agg-baseline}.

The Neuron (Trainium) counterparts of vllm/disagg-pd and vllm/agg-baseline
(Issue #80) keep the GPU charts' top-level values shape (placement.*,
transport.*, kvCacheTier.*, prefill.*/decode.*) with these differences, all
checked here from `helm template` output alone:

  - prefill/decode.gpusPerEngine is renamed neuronCoresPerEngine (agg-baseline:
    engine.neuronCoresPerEngine), and there is no mps/gpuMemoryUtilization;
  - accelerator.resourceName defaults to aws.amazon.com/neuron, requested as
    whole devices -- ceil(neuronCoresPerEngine / accelerator.coresPerDevice),
    never a raw core count, because the device plugin advertises whole
    Neuron chips, not individual NeuronCores (gitops/addons/
    accel-neuron-device-plugin/addon.yaml). neuronCoresPerEngine itself still
    reaches vLLM's --tensor-parallel-size unchanged, raw;
  - transport.efaResourceName still defaults to vpc.amazonaws.com/efa;
  - prefill.compileCacheVolume/decode.compileCacheVolume (agg-baseline:
    engine.compileCacheVolume), each default emptyDir: {}, is mounted at
    exactly the path VLLM_CACHE_ROOT names. disagg-pd sets this per role,
    not once under engine.*: prefill and decode run on separate nodes, and
    a single shared value pointing both at the same PersistentVolumeClaim
    name would be a multi-attach failure waiting to happen;
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
    affinity_terms,
    anti_terms,
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


def devices_for(cores, per_device):
    """Whole Neuron devices (chips) a request for `cores` NeuronCores needs.

    The device plugin advertises aws.amazon.com/neuron as whole devices, not
    individual NeuronCores (confirmed against this platform's own
    gitops/addons/accel-neuron-device-plugin/addon.yaml: "Light-tier pods
    request aws.amazon.com/neuron, never neuroncore" because Karpenter's own
    capacity estimate for the per-core resource is wrong on trn2.3xlarge).
    neuronCoresPerEngine is a NeuronCore count (vLLM's --tensor-parallel-size);
    the resource request is ceil(cores / coresPerDevice) -- a request for
    fewer cores than one device still holds the whole device, with the rest
    of its cores idle.
    """
    return -(-int(cores) // int(per_device))


def check_neuron_request(label, w, want_cores, per_device):
    cs = neuron_containers(pod_spec(w))
    want_devices = devices_for(want_cores, per_device)
    got = [str(((c.get("resources") or {}).get("limits") or {}).get(NEURON)) for c in cs]
    check(f"{label}: {name_of(w)} has a container with resources.limits[{NEURON}] = {want_devices} "
          f"(ceil({want_cores} neuronCoresPerEngine / {per_device} accelerator.coresPerDevice))",
          bool(got) and all(g == str(want_devices) for g in got), f"got {got or 'no Neuron request'}")
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
    whose volume is `want_volume` as configured (the caller passes the
    role's own compileCacheVolume: engine.* for agg-baseline, or that
    role's own prefill.*/decode.* for disagg-pd)."""
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
        check(f"{label}: {name_of(w)} the volume at {root} ({vname}) is the configured "
              f"compileCacheVolume ({json.dumps(want_volume)})", vols.get(vname) == want_volume,
              f"volume {vname!r} = {json.dumps(vols.get(vname, '<not in pod volumes>'))}")
        check(f"{label}: {name_of(w)} mount at {root} is writable (the compile cache is written on a cold start)",
              not mounts[0].get("readOnly"), json.dumps(mounts[0]))


# ---------------------------------------------------------------- checks

DISAGG_PRESENT = [
    ("accelerator", "resourceName"), ("accelerator", "coresPerDevice"),
    ("placement", "nodeSelectorKey"), ("placement", "sameNodeMeasurement"),
    ("placement", "sharedPoolValue"), ("placement", "enforceAntiAffinity"),
    ("transport", "backend"), ("transport", "efaResourceName"), ("transport", "ucx", "tcpPortRange"),
    ("transport", "kvRoleMode"),
    ("kvCacheTier", "mode"),
    ("engine", "cacheVolume"),
] + [(r, k) for r in ROLES for k in (
    "replicas", "neuronCoresPerEngine", "efaDevices", "nodeSelectorValue",
    "extraNodeSelector", "resources", "extraArgs", "extraEnv", "compileCacheVolume")]
DISAGG_ABSENT = [(r, k) for r in ROLES for k in ("gpusPerEngine", "mps", "gpuMemoryUtilization")] \
    + [("engine", "compileCacheVolume")]

AGG_PRESENT = [
    ("accelerator", "resourceName"), ("accelerator", "coresPerDevice"), ("kvCacheTier", "mode"),
    ("engine", "neuronCoresPerEngine"), ("engine", "cacheVolume"), ("engine", "compileCacheVolume"),
]
AGG_ABSENT = [("engine", k) for k in ("gpusPerEngine", "mps", "gpuMemoryUtilization")]

def device_crossing_override(default_cores, per_device):
    """A neuronCoresPerEngine value whose own device count (ceil(x /
    per_device)) differs from the default's. A value that is merely a
    different core count is not enough: at the default of 1 core (device
    count 1), the next plausible core count can still land on the same
    device count (e.g. 2 cores is still 1 device at per_device=4) -- a
    chart that hardcoded "1 device" regardless of cores would pass that
    check too. Adding a full per_device crosses the boundary unconditionally.
    """
    return int(default_cores) + int(per_device)


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
    check(f"{rel} values: transport.kvRoleMode defaults to kv_both",
          val("transport", "kvRoleMode") == "kv_both", repr(val("transport", "kvRoleMode")))
    for r in ROLES:
        check(f"{rel} values: {r}.compileCacheVolume defaults to emptyDir: {{}}",
              val(r, "compileCacheVolume") == {"emptyDir": {}}, json.dumps(val(r, "compileCacheVolume")))

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
                    cs = check_neuron_request(f"{rel} default ({r})", w, val(r, "neuronCoresPerEngine"),
                                               val("accelerator", "coresPerDevice"))
                    check_compile_cache(f"{rel} default ({r})", w, cs, val(r, "compileCacheVolume"))
                    efa = val(r, "efaDevices")
                    got_efa = [str(((c.get("resources") or {}).get("limits") or {}).get(EFA)) for c in cs]
                    check(f"{rel} default: {name_of(w)} ({r}) requests resources.limits[{EFA}] = {efa} "
                          f"({r}.efaDevices)", bool(got_efa) and all(g == str(efa) for g in got_efa), f"got {got_efa}")
                    # Engine containers only -- not configmap_text(docs): this
                    # chart's own proxy ConfigMap embeds proxy.py verbatim,
                    # whose docstring literally contains "NixlConnector",
                    # which would make this check pass even if no engine
                    # container actually configured the connector.
                    text = " ".join(container_text(c) for c in cs)
                    check(f"{rel} default: {name_of(w)} ({r}) configures a NixlConnector "
                          "(NixlConnector or NeuronNixlConnector) with the LIBFABRIC backend",
                          "NixlConnector" in text and "LIBFABRIC" in text)
                    # The exact Neuron-specific facts the PR cites from the
                    # plugin's own source: kv_buffer_device must be "cuda"
                    # (vllm_neuron.vllm.platform.get_nixl_supported_devices
                    # lists only that value for Neuron) and the compile
                    # cache is off unless VLLM_NEURON_BACKEND is set
                    # explicitly, even on the plugin's own default route.
                    # Parse KV_TRANSFER_CONFIG's own value as JSON rather
                    # than substring-matching the doubly-escaped text, so
                    # this does not depend on how many times the value got
                    # re-serialized on the way into container_text.
                    envd = env_of(cs[0]) if cs else {}
                    kv_cfg = {}
                    try:
                        kv_cfg = json.loads(envd.get("KV_TRANSFER_CONFIG", "{}"))
                    except json.JSONDecodeError:
                        pass
                    check(f"{rel} default: {name_of(w)} ({r}) KV_TRANSFER_CONFIG sets "
                          'kv_buffer_device to "cuda" (the only value the plugin accepts for Neuron)',
                          kv_cfg.get("kv_buffer_device") == "cuda", json.dumps(kv_cfg))
                    check(f"{rel} default: {name_of(w)} ({r}) KV_TRANSFER_CONFIG sets "
                          'kv_role to "kv_both" at transport.kvRoleMode\'s own default '
                          "(not kv_producer/kv_consumer, which only the producer_consumer "
                          "scenario below should render)",
                          kv_cfg.get("kv_role") == "kv_both", json.dumps(kv_cfg))
                    check(f"{rel} default: {name_of(w)} ({r}) sets VLLM_NEURON_BACKEND=neuron_native "
                          "(the precompile cache is off otherwise)",
                          envd.get("VLLM_NEURON_BACKEND") == "neuron_native", json.dumps(envd))
                    # Libfabric/EFA env vars, same names and meaning as the
                    # NVIDIA chart (these are libfabric-level, not
                    # accelerator-specific).
                    check(f"{rel} default: {name_of(w)} ({r}) sets FI_PROVIDER=efa",
                          envd.get("FI_PROVIDER") == "efa", json.dumps(envd))
                    check(f"{rel} default: {name_of(w)} ({r}) sets FI_EFA_USE_DEVICE_RDMA=1",
                          envd.get("FI_EFA_USE_DEVICE_RDMA") == "1", json.dumps(envd))
                    check(f"{rel} default: {name_of(w)} ({r}) sets FI_EFA_ENABLE_SHM_TRANSFER "
                          "(0 or 1, from transport.forceEfaSameNode; default is forceEfaSameNode=false -> \"1\")",
                          envd.get("FI_EFA_ENABLE_SHM_TRANSFER") == "1", json.dumps(envd))
            check_decode_anti_affinity(f"{rel} default", roles)
            # At the default (enforceAntiAffinity=true, both roles request
            # EFA), decode must also carry a required podAffinity zone term
            # matching prefill's labels -- EFA cannot cross a zone. #92
            # tracks that this is dropped when enforceAntiAffinity=false;
            # not re-checked here, only the default's own guarantee.
            for w in roles["decode"]:
                zreq, _ = affinity_terms(pod_spec(w))
                zone_terms = [t for t in zreq if t.get("topologyKey") == "topology.kubernetes.io/zone"]
                ok = bool(zone_terms) and all(
                    any(term_hits(t, pod_labels(o), topology_key="topology.kubernetes.io/zone")
                        for t in zone_terms) for o in roles["prefill"])
                check(f"{rel} default: {name_of(w)} (decode) has a required podAffinity term, "
                      "topologyKey topology.kubernetes.io/zone, selecting the prefill pods' labels",
                      ok, f"podAffinity required terms={json.dumps(zreq)}")

    # --------------------------------------- transport.kvRoleMode override
    # Proves kvRoleMode=producer_consumer is a real, wired values-only
    # switch (kv_producer on prefill, kv_consumer on decode), not merely
    # documented: a template that always rendered kv_both regardless of
    # this value would fail this scenario.
    want_role = {"prefill": "kv_producer", "decode": "kv_consumer"}
    rdocs, err = R.render(chart, sets=["transport.kvRoleMode=producer_consumer"])
    if check(f"{rel} transport.kvRoleMode=producer_consumer: helm template", rdocs is not None, err):
        scenarios["kvRoleMode=producer_consumer"] = rdocs
        rroles = check_roles_present(f"{rel} transport.kvRoleMode=producer_consumer", rdocs, key, sel_values)
        if rroles:
            for r in ROLES:
                for w in rroles[r]:
                    envd = env_of(neuron_containers(pod_spec(w))[0]) if neuron_containers(pod_spec(w)) else {}
                    kv_cfg = {}
                    try:
                        kv_cfg = json.loads(envd.get("KV_TRANSFER_CONFIG", "{}"))
                    except json.JSONDecodeError:
                        pass
                    check(f"{rel} transport.kvRoleMode=producer_consumer: {name_of(w)} ({r}) "
                          f"KV_TRANSFER_CONFIG sets kv_role to {want_role[r]!r}",
                          kv_cfg.get("kv_role") == want_role[r], json.dumps(kv_cfg))
    _, err = R.render(chart, sets=["transport.kvRoleMode=bogus"])
    check(f"{rel} transport.kvRoleMode=bogus: helm template fails naming transport.kvRoleMode",
          err is not None and "kvRoleMode" in (err or ""), err or "rendered")

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

    # ------------------------- forceEfaSameNode=true: FI_EFA_ENABLE_SHM_TRANSFER=0
    # The default-scenario assertion above only proves the env var is "1" at
    # transport.forceEfaSameNode's own default (false) -- a template that
    # hardcoded "1" would pass that alone. This scenario flips the value and
    # proves the env var actually follows it.
    fdocs, err = R.render(chart, sets=["placement.sameNodeMeasurement=true", "transport.forceEfaSameNode=true"])
    if check(f"{rel} forceEfaSameNode=true: helm template", fdocs is not None, err):
        scenarios["forceEfaSameNode=true"] = fdocs
        froles = check_roles_present(f"{rel} forceEfaSameNode=true", fdocs, key, sel_values)
        if froles:
            for r in ROLES:
                for w in froles[r]:
                    envd = env_of(neuron_containers(pod_spec(w))[0]) if neuron_containers(pod_spec(w)) else {}
                    check(f"{rel} forceEfaSameNode=true: {name_of(w)} ({r}) sets "
                          "FI_EFA_ENABLE_SHM_TRANSFER=0 (not hardcoded 1)",
                          envd.get("FI_EFA_ENABLE_SHM_TRANSFER") == "0", json.dumps(envd))

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
    per_device = val("accelerator", "coresPerDevice")
    default_cores_by_role = {r: val(r, "neuronCoresPerEngine") for r in ROLES}
    # device_crossing_override per role, offset by one extra per_device for
    # decode so the two roles' override values differ from each other too
    # (prefill and decode must stay independently wired, not accidentally
    # sharing one computed value) -- see device_crossing_override's own
    # docstring for why a merely-different core count alone does not
    # prove the device math scales.
    want = {
        "prefill": device_crossing_override(default_cores_by_role["prefill"], per_device),
        "decode": device_crossing_override(default_cores_by_role["decode"], per_device) + int(per_device),
    }
    kdocs, err = R.render(chart, sets=[f"{r}.neuronCoresPerEngine={want[r]}" for r in ROLES])
    label = f"{rel} neuronCoresPerEngine prefill={want['prefill']},decode={want['decode']}"
    if check(f"{label}: helm template", kdocs is not None, err):
        scenarios["neuronCoresPerEngine override"] = kdocs
        kroles = check_roles_present(label, kdocs, key, sel_values)
        droles = roles_by(docs, key, sel_values) if docs is not None else {r: [] for r in ROLES}
        if kroles:
            for r in ROLES:
                default_cores = default_cores_by_role[r]
                default_names = tp_env_names([c for w in droles[r] for c in neuron_containers(pod_spec(w))],
                                             default_cores)
                for w in kroles[r]:
                    cs = check_neuron_request(f"{label} ({r})", w, want[r], per_device)
                    got = [str(((c.get("resources") or {}).get("limits") or {}).get(NEURON)) for c in cs]
                    check(f"{label} ({r}): device count actually changed from the default "
                          f"({devices_for(default_cores, per_device)} device(s) at {default_cores} cores) "
                          f"to {devices_for(want[r], per_device)} device(s)",
                          devices_for(want[r], per_device) != devices_for(default_cores, per_device), json.dumps(got))
                    # An env var carries the core count when it equals the
                    # configured value both at the default and under the
                    # override -- the same name, following the value.
                    names = tp_env_names(cs, want[r]) & default_names
                    check(f"{label}: {name_of(w)} ({r}) has an env var that follows {r}.neuronCoresPerEngine "
                          f"({default_cores} by default, {want[r]} here)", bool(names),
                          f"env equal to {want[r]} here: {sorted(tp_env_names(cs, want[r]))}; "
                          f"env equal to {default_cores} at the default: {sorted(default_names)}")
                    check_tp_wired(f"{label} ({r})", w, cs, names, want[r])
            check(f"{label}: prefill and decode override values differ "
                  "(each role's own value, not one shared computed value)",
                  want["prefill"] != want["decode"], json.dumps(want))

    # ------------------------------------- accelerator.coresPerDevice override
    # Proves per_device is actually read from the value, not hardcoded 4: at
    # neuronCoresPerEngine=3, the default coresPerDevice (4) rounds to 1
    # device, while coresPerDevice=2 rounds the SAME core count to 2 devices.
    # A template that hardcoded per_device=4 would pass every other scenario
    # in this file (all of them leave coresPerDevice at its default) but
    # fail this one.
    pdocs, err = R.render(chart, sets=[f"{r}.neuronCoresPerEngine=3" for r in ROLES])
    cdocs, err2 = R.render(chart, sets=[f"{r}.neuronCoresPerEngine=3" for r in ROLES] +
                           ["accelerator.coresPerDevice=2"])
    if check(f"{rel} accelerator.coresPerDevice=2: helm template (both cores=3 renders)",
             pdocs is not None and cdocs is not None, err or err2):
        scenarios["coresPerDevice override (default)"] = pdocs
        scenarios["coresPerDevice override (=2)"] = cdocs
        proles = check_roles_present(f"{rel} coresPerDevice={per_device} (default), cores=3", pdocs, key, sel_values)
        croles = check_roles_present(f"{rel} coresPerDevice=2, cores=3", cdocs, key, sel_values)
        if proles and croles:
            for r in ROLES:
                for w in proles[r]:
                    check_neuron_request(f"{rel} coresPerDevice={per_device} (default), cores=3 ({r})",
                                          w, 3, per_device)
                for w in croles[r]:
                    check_neuron_request(f"{rel} coresPerDevice=2, cores=3 ({r})", w, 3, 2)

    # ------------------------------ compileCacheVolume override, per role
    # A PVC in place of the emptyDir default, with a DIFFERENT claim name
    # per role: proves (a) the mount at VLLM_CACHE_ROOT is wired from each
    # role's own value, not a coincidental emptyDir, and (b) the two roles'
    # values are independent, not the same shared field -- a prefill and a
    # decode Pod on two different nodes must never be pointed at the same
    # PersistentVolumeClaim name by this chart's own defaults (Decision 3
    # puts them on separate nodes; a shared RWO claim name would be a
    # multi-attach failure waiting to happen). Helm deep-merges a
    # values-file map into the chart's default map, so each override nulls
    # emptyDir explicitly (Helm's documented way to drop a default key);
    # without that the volume would carry both sources.
    pvc_by_role = {r: {"persistentVolumeClaim": {"claimName": f"neuron-compile-cache-{r}"}} for r in ROLES}
    cdocs, err = R.render(chart, values={
        r: {"compileCacheVolume": {"emptyDir": None, **pvc_by_role[r]}} for r in ROLES
    })
    if check(f"{rel} compileCacheVolume=PVC (per role, different claim names): helm template",
             cdocs is not None, err):
        scenarios["compileCacheVolume=PVC"] = cdocs
        croles = check_roles_present(f"{rel} compileCacheVolume=PVC", cdocs, key, sel_values)
        if croles:
            for r in ROLES:
                for w in croles[r]:
                    check_compile_cache(f"{rel} compileCacheVolume=PVC ({r})", w,
                                        neuron_containers(pod_spec(w)), pvc_by_role[r])
            check(f"{rel} compileCacheVolume=PVC: prefill and decode do not share a claim name",
                  pvc_by_role["prefill"] != pvc_by_role["decode"], json.dumps(pvc_by_role))

    # ------------------------------------- kvCacheTier.mode=local render
    # Only a render-only smoke check: proves the MultiConnector branch
    # (templates/engines.yaml) does not crash and that the NIXL entry
    # inside it is renamed to NeuronNixlConnector with its module path
    # (the plugin's top-level-NixlConnector rewrite only looks at the
    # top-level kv_connector, so inside MultiConnector this chart's own
    # template has to do that renaming itself). Does not confirm anything
    # about LMCacheMPConnector itself on Neuron -- unverified either way,
    # stated in values.yaml and the README, not resolved here.
    ldocs, err = R.render(chart, sets=[
        "kvCacheTier.mode=local",
        "kvCacheTier.lmcache.mpServerEndpoint=10.0.1.23:5555",
    ])
    if check(f"{rel} kvCacheTier.mode=local: helm template", ldocs is not None, err):
        scenarios["kvCacheTier.mode=local"] = ldocs
        lroles = check_roles_present(f"{rel} kvCacheTier.mode=local", ldocs, key, sel_values)
        if lroles:
            for r in ROLES:
                for w in lroles[r]:
                    cs = neuron_containers(pod_spec(w))
                    text = " ".join(container_text(c) for c in cs)
                    check(f"{rel} kvCacheTier.mode=local: {name_of(w)} ({r}) renders "
                          "MultiConnector with a NeuronNixlConnector entry (not a bare NixlConnector, "
                          "since the plugin's own top-level rewrite does not reach inside MultiConnector)",
                          "MultiConnector" in text and "NeuronNixlConnector" in text
                          and "vllm_neuron.vllm.kv_connector.neuron_nixl_connector" in text, text[:800])

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
            cs = check_neuron_request(f"{rel} default", w, val("engine", "neuronCoresPerEngine"),
                                       val("accelerator", "coresPerDevice"))
            check_compile_cache(f"{rel} default", w, cs, val("engine", "compileCacheVolume"))
            # Unlike disagg-pd, this chart renders no kv-transfer-config at
            # all at the default kvCacheTier.mode=gpu-only (one aggregated
            # process, no cross-process KV transfer, so no kv_buffer_device
            # to assert here) -- confirmed against templates/engine.yaml's
            # own comment. VLLM_NEURON_BACKEND still applies: the compile
            # cache is a property of this engine regardless of KV transfer.
            envd = env_of(cs[0]) if cs else {}
            check(f"{rel} default: {name_of(w)} sets VLLM_NEURON_BACKEND=neuron_native",
                  envd.get("VLLM_NEURON_BACKEND") == "neuron_native", json.dumps(envd))
            check(f"{rel} default: {name_of(w)} renders KV_TRANSFER_CONFIG empty "
                  "at the default kvCacheTier.mode=gpu-only (one aggregated process; the env var "
                  "itself is always rendered, the entrypoint's own [ -z \"$KV_TRANSFER_CONFIG\" ] "
                  "check is what skips --kv-transfer-config, not an absent env entry)",
                  not envd.get("KV_TRANSFER_CONFIG"), json.dumps(envd))

    per_device = val("accelerator", "coresPerDevice")
    default_cores = val("engine", "neuronCoresPerEngine")
    # device_crossing_override: at the default of 1 core (1 device at
    # coresPerDevice=4), a merely-different core count can still round to
    # the same device count, which would let a chart that hardcoded
    # "1 device" pass. This value crosses a device boundary
    # unconditionally, so the override actually proves ceil() scales.
    want = device_crossing_override(default_cores, per_device)
    kdocs, err = R.render(chart, sets=[f"engine.neuronCoresPerEngine={want}"])
    if check(f"{rel} engine.neuronCoresPerEngine={want}: helm template", kdocs is not None, err):
        scenarios["neuronCoresPerEngine override"] = kdocs
        for w in workloads(kdocs):
            cs = check_neuron_request(f"{rel} engine.neuronCoresPerEngine={want}", w, want, per_device)
            check_tp_wired(f"{rel} engine.neuronCoresPerEngine={want}", w, cs, tp_env_names(cs, want), want)
            got = [str(((c.get("resources") or {}).get("limits") or {}).get(NEURON)) for c in cs]
            check(f"{rel} engine.neuronCoresPerEngine={want}: device count actually changed from the "
                  f"default ({devices_for(default_cores, per_device)} device(s) at {default_cores} cores) "
                  f"to {devices_for(want, per_device)} device(s)",
                  devices_for(want, per_device) != devices_for(default_cores, per_device), json.dumps(got))

    # ------------------------------------- accelerator.coresPerDevice override
    # Same proof as disagg-pd: at neuronCoresPerEngine=3, coresPerDevice=4
    # (default) rounds to 1 device, coresPerDevice=2 rounds the SAME core
    # count to 2 -- proves per_device is read from the value, not hardcoded.
    apdocs, err = R.render(chart, sets=["engine.neuronCoresPerEngine=3"])
    acdocs, err2 = R.render(chart, sets=["engine.neuronCoresPerEngine=3", "accelerator.coresPerDevice=2"])
    if check(f"{rel} accelerator.coresPerDevice=2: helm template (both cores=3 renders)",
             apdocs is not None and acdocs is not None, err or err2):
        scenarios["coresPerDevice override (default)"] = apdocs
        scenarios["coresPerDevice override (=2)"] = acdocs
        for w in workloads(apdocs):
            check_neuron_request(f"{rel} coresPerDevice={per_device} (default), cores=3", w, 3, per_device)
        for w in workloads(acdocs):
            check_neuron_request(f"{rel} coresPerDevice=2, cores=3", w, 3, 2)

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
