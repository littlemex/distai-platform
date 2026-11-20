"""Values/template contract checks for examples/inference/vllm/{disagg-pd,agg-baseline}.

Derived from the interface contract's "Placement and transport" section and
acceptance criterion 1; needs `helm` and PyYAML, no cluster. Called by
test_placement_transport.sh, which supplies PyYAML through `uv`.

Nothing here depends on a Deployment, Service, or container name the chart
happens to choose. A role Deployment is identified primarily by its
nodeSelector carrying the role key (default `distai.dev/pd-role`) with the
value `prefill` or `decode`; when placement.sameNodeMeasurement overrides
both roles onto one shared value, role identity falls back to the pod
template's own `app.kubernetes.io/component` label instead (see
`roles_by`). The vLLM container of a role is the container requesting
`nvidia.com/gpu` (every container of the pod if none does).

Usage: check_placement_transport.py --helm HELM --disagg CHART_DIR --agg CHART_DIR --work-dir DIR
Prints PASS/FAIL per check; exits 1 if any failed.
"""

import argparse
import json
import os
import subprocess
import sys

import yaml

ROLE_KEY = "distai.dev/pd-role"
OVERRIDE_KEY = "example.test/pd-role-override"
ROLES = ("prefill", "decode")
HOSTNAME = "kubernetes.io/hostname"
ZONE = "topology.kubernetes.io/zone"
WORKLOAD_KINDS = ("Deployment", "StatefulSet")

failures = []


def check(label, ok, detail=""):
    if ok:
        print(f"PASS {label}")
    else:
        print(f"FAIL {label}{': ' + detail if detail else ''}")
        failures.append(label)
    return ok


# ------------------------------------------------------------- rendering

class Renderer:
    def __init__(self, helm, work_dir):
        self.helm = helm
        self.work_dir = work_dir
        self.n = 0

    def render(self, chart, sets=(), values=None):
        cmd = [self.helm, "template", "contract-test", chart, "--namespace", "contract-test"]
        if values is not None:
            self.n += 1
            path = os.path.join(self.work_dir, f"override-{self.n}.yaml")
            with open(path, "w", encoding="utf-8") as f:
                yaml.safe_dump(values, f)
            cmd += ["-f", path]
        for s in sets:
            cmd += ["--set", s]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            return None, proc.stderr.strip()
        return [d for d in yaml.safe_load_all(proc.stdout) if isinstance(d, dict)], ""

    def show_values(self, chart):
        proc = subprocess.run([self.helm, "show", "values", chart], capture_output=True, text=True)
        if proc.returncode != 0:
            return None
        return yaml.safe_load(proc.stdout) or {}


# ------------------------------------------------------------ inspection

def workloads(docs):
    return [d for d in docs if d.get("kind") in WORKLOAD_KINDS]


def pod_spec(w):
    return ((w.get("spec") or {}).get("template") or {}).get("spec") or {}


def pod_labels(w):
    return (((w.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {}


def name_of(d):
    return f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"


def roles_by(docs, key):
    """Identifies a role by its nodeSelector[key] value (prefill/decode) when
    that value is still role-specific. When placement.sameNodeMeasurement
    overrides both roles to the same shared nodeSelector value, that key no
    longer distinguishes them, so this falls back to the pod template's own
    app.kubernetes.io/component label (which the chart always sets to the
    role name, independent of any placement value)."""
    out = {r: [] for r in ROLES}
    for w in workloads(docs):
        v = (pod_spec(w).get("nodeSelector") or {}).get(key)
        if v not in out:
            v = pod_labels(w).get("app.kubernetes.io/component")
        if v in out:
            out[v].append(w)
    return out


def selector_matches(sel, labels):
    """Kubernetes LabelSelector semantics. An empty/absent selector matches nothing here
    (in an affinity term, a null labelSelector selects no pods)."""
    if not sel:
        return False
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in sel.get("matchExpressions") or []:
        k, op, vals = e.get("key"), e.get("operator"), e.get("values") or []
        if op == "In" and labels.get(k) not in vals:
            return False
        if op == "NotIn" and k in labels and labels[k] in vals:
            return False
        if op == "Exists" and k not in labels:
            return False
        if op == "DoesNotExist" and k in labels:
            return False
    return bool(sel.get("matchLabels") or sel.get("matchExpressions"))


def anti_terms(spec):
    """Returns (required_terms, preferred_terms) of podAntiAffinity."""
    paa = ((spec.get("affinity") or {}).get("podAntiAffinity")) or {}
    req = paa.get("requiredDuringSchedulingIgnoredDuringExecution") or []
    pref = [p.get("podAffinityTerm") or {} for p in paa.get("preferredDuringSchedulingIgnoredDuringExecution") or []]
    return req, pref


def affinity_terms(spec):
    """Returns (required_terms, preferred_terms) of podAffinity (not anti-affinity)."""
    pa = ((spec.get("affinity") or {}).get("podAffinity")) or {}
    req = pa.get("requiredDuringSchedulingIgnoredDuringExecution") or []
    pref = [p.get("podAffinityTerm") or {} for p in pa.get("preferredDuringSchedulingIgnoredDuringExecution") or []]
    return req, pref


def term_hits(term, labels, topology_key=HOSTNAME):
    return term.get("topologyKey") == topology_key and selector_matches(term.get("labelSelector"), labels)


def gpu_containers(spec):
    cs = spec.get("containers") or []
    gpu = [c for c in cs if "nvidia.com/gpu" in (((c.get("resources") or {}).get("limits")) or {})]
    return gpu or cs


def env_of(c):
    return {e.get("name"): e.get("value") for e in c.get("env") or []}


def configmap_text(docs):
    return " ".join(json.dumps(d.get("data") or {}) for d in docs if d.get("kind") == "ConfigMap")


def container_text(c):
    return json.dumps({"command": c.get("command"), "args": c.get("args"), "env": c.get("env")})


def find_paths(tree, needle, prefix=()):
    """Paths in a values tree where `needle` is a scalar value or a map key.
    Returns [(path_tuple, 'scalar'|'mapkey')]."""
    found = []
    if isinstance(tree, dict):
        for k, v in tree.items():
            if k == needle:
                found.append((prefix, "mapkey"))
            if v == needle:
                found.append((prefix + (k,), "scalar"))
            found += find_paths(v, needle, prefix + (k,))
    elif isinstance(tree, list):
        # A key inside a list cannot be overridden by a values file without
        # replacing the whole list; treat it as not an override point.
        pass
    return found


def get_path(tree, path):
    cur = tree
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return None, False
        cur = cur[p]
    return cur, True


def nest(path, leaf):
    d = leaf
    for p in reversed(path):
        d = {p: d}
    return d


def deep_merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            deep_merge(a[k], v)
        else:
            a[k] = v
    return a


# ---------------------------------------------------------------- checks

def check_roles_present(label, docs, key=ROLE_KEY):
    roles = roles_by(docs, key)
    ok = all(roles[r] for r in ROLES)
    check(f"{label}: a prefill and a decode workload, each with nodeSelector {key}=<role>", ok,
          "found " + ", ".join(f"{r}={[name_of(w) for w in roles[r]]}" for r in ROLES))
    return roles if ok else None


def check_anti_affinity_present(label, roles):
    # Rendered on decode only (never on both roles -- a required term on both
    # could leave neither schedulable, each waiting on a peer that is itself
    # waiting), matching prefill's own label.
    for w in roles["decode"]:
        req, _ = anti_terms(pod_spec(w))
        other_ok = all(any(term_hits(t, pod_labels(o)) for t in req) for o in roles["prefill"])
        check(f"{label}: {name_of(w)} (decode) has a required podAntiAffinity term, topologyKey {HOSTNAME}, "
              f"selecting the prefill pods' labels", other_ok,
              f"required terms={json.dumps(req)} prefill pod labels={[pod_labels(o) for o in roles['prefill']]}")
        own_hit = any(term_hits(t, pod_labels(w)) for t in req)
        check(f"{label}: {name_of(w)} (decode)'s anti-affinity does not also select its own role's pods "
              "(it must match the *other* role, so several replicas of one role can still share a node)",
              not own_hit, f"required terms={json.dumps(req)} own labels={pod_labels(w)}")
    for w in roles["prefill"]:
        req, pref = anti_terms(pod_spec(w))
        check(f"{label}: {name_of(w)} (prefill) carries no podAntiAffinity term of its own "
              "(only decode carries the rule, so prefill always schedules unconstrained)",
              not (req or pref), json.dumps(req + pref))
    labels = {r: [pod_labels(w) for w in roles[r]] for r in ROLES}
    distinct = all(p != d for p in labels["prefill"] for d in labels["decode"])
    check(f"{label}: prefill and decode pod templates carry different labels", distinct, json.dumps(labels))


def check_anti_affinity_absent(label, roles):
    for r in ROLES:
        other = ROLES[1 - ROLES.index(r)]
        for w in roles[r]:
            req, pref = anti_terms(pod_spec(w))
            hits = [t for t in req + pref for o in roles[other] if term_hits(t, pod_labels(o))]
            check(f"{label}: {name_of(w)} ({r}) has no podAntiAffinity term (required or preferred) "
                  f"against the {other} pods -- dropped, not weakened", not hits, json.dumps(hits))


def check_zone_affinity_present(label, roles):
    # EFA traffic cannot cross an Availability Zone (AWS EFA docs). Without
    # this, the hostname anti-affinity alone lets Karpenter satisfy decode's
    # placement with a node in a different zone from prefill's, which has no
    # EFA path between the two pods at all. Required podAffinity (not
    # anti-affinity) on topology.kubernetes.io/zone, toward prefill's labels,
    # alongside (not instead of) the hostname anti-affinity.
    for w in roles["decode"]:
        req, _ = affinity_terms(pod_spec(w))
        other_ok = all(
            any(term_hits(t, pod_labels(o), topology_key=ZONE) for t in req) for o in roles["prefill"]
        )
        check(f"{label}: {name_of(w)} (decode) has a required podAffinity term, topologyKey {ZONE}, "
              f"selecting the prefill pods' labels", other_ok,
              f"required terms={json.dumps(req)} prefill pod labels={[pod_labels(o) for o in roles['prefill']]}")


def check_zone_affinity_absent(label, roles):
    for w in roles["decode"]:
        req, pref = affinity_terms(pod_spec(w))
        hits = [t for t in req + pref if t.get("topologyKey") == ZONE]
        check(f"{label}: {name_of(w)} (decode) has no podAffinity term on topologyKey {ZONE} "
              "(no EFA device requested, so same-zone placement is not required)", not hits, json.dumps(hits))


def check_affinity_present(label, roles):
    # The same-node measurement cell: decode carries a required podAffinity
    # (not anti-affinity) toward prefill, so it is actively pulled onto
    # prefill's own node rather than merely left free to land there.
    for w in roles["decode"]:
        req, _ = affinity_terms(pod_spec(w))
        other_ok = all(any(term_hits(t, pod_labels(o)) for t in req) for o in roles["prefill"])
        check(f"{label}: {name_of(w)} (decode) has a required podAffinity term, topologyKey {HOSTNAME}, "
              f"selecting the prefill pods' labels", other_ok,
              f"required terms={json.dumps(req)} prefill pod labels={[pod_labels(o) for o in roles['prefill']]}")


def env_check(label, roles, name, predicate, describe):
    for r in ROLES:
        for w in roles[r]:
            for c in gpu_containers(pod_spec(w)):
                env = env_of(c)
                present = name in env
                check(f"{label}: {name_of(w)} container {c.get('name')} {describe}",
                      predicate(present, env.get(name)),
                      f"{name}={'<unset>' if not present else repr(env.get(name))}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--helm", default="helm")
    ap.add_argument("--disagg", required=True)
    ap.add_argument("--agg", required=True)
    ap.add_argument("--work-dir", required=True)
    a = ap.parse_args()
    R = Renderer(a.helm, a.work_dir)

    # ---------------------------------------------- default values file
    values = R.show_values(a.disagg)
    if not check("disagg-pd: helm show values", values is not None):
        return 1

    def val(path):
        v, ok = get_path(values, path)
        return v if ok else "<missing>"

    check("disagg-pd values: placement.sameNodeMeasurement defaults to false",
          val(("placement", "sameNodeMeasurement")) is False, repr(val(("placement", "sameNodeMeasurement"))))
    check("disagg-pd values: placement.enforceAntiAffinity defaults to true",
          val(("placement", "enforceAntiAffinity")) is True, repr(val(("placement", "enforceAntiAffinity"))))
    check("disagg-pd values: transport.forceEfaSameNode defaults to false",
          val(("transport", "forceEfaSameNode")) is False, repr(val(("transport", "forceEfaSameNode"))))
    check("disagg-pd values: transport.backend defaults to LIBFABRIC",
          val(("transport", "backend")) == "LIBFABRIC", repr(val(("transport", "backend"))))

    # ----------------------------------------------- default rendering
    docs, err = R.render(a.disagg)
    if not check("disagg-pd: helm template with default values", docs is not None, err):
        return 1
    roles = check_roles_present("default", docs)
    if roles:
        check_anti_affinity_present("default", roles)
        check_zone_affinity_present("default", roles)
        env_check("default", roles, "FI_EFA_ENABLE_SHM_TRANSFER",
                  lambda present, v: (not present) or v != "0",
                  "does not force FI_EFA_ENABLE_SHM_TRANSFER=0 (forceEfaSameNode=false)")
        env_check("default", roles, "FI_PROVIDER", lambda p, v: v == "efa",
                  "sets FI_PROVIDER=efa (backend LIBFABRIC)")
        env_check("default", roles, "FI_EFA_USE_DEVICE_RDMA", lambda p, v: v == "1",
                  "sets FI_EFA_USE_DEVICE_RDMA=1 (backend LIBFABRIC)")
        cm = configmap_text(docs)
        for r in ROLES:
            for w in roles[r]:
                text = " ".join(container_text(c) for c in gpu_containers(pod_spec(w))) + " " + cm
                check(f"default: {name_of(w)} ({r}) configures NixlConnector with the LIBFABRIC backend",
                      "NixlConnector" in text and "LIBFABRIC" in text)
        for r in ROLES:
            for w in roles[r]:
                strategy = (w.get("spec") or {}).get("strategy")
                check(f"default: {name_of(w)} ({r}) has no strategy override (RollingUpdate, Kubernetes' own default)",
                      strategy is None, repr(strategy))

    # ----------------------------------- role key has a values override
    key_paths = find_paths(values, ROLE_KEY)
    if check(f"disagg-pd values: the role key {ROLE_KEY} is a values override point, not hardcoded",
             bool(key_paths), f"{ROLE_KEY} does not appear as a value or map key anywhere in values.yaml"):
        override = {}
        for path, how in key_paths:
            if how == "scalar":
                deep_merge(override, nest(path, OVERRIDE_KEY))
            else:
                orig, _ = get_path(values, path)
                deep_merge(override, nest(path, {ROLE_KEY: None, OVERRIDE_KEY: orig[ROLE_KEY]}))
        odocs, err = R.render(a.disagg, values=override)
        if check(f"key override: helm template with the role key set to {OVERRIDE_KEY}", odocs is not None, err):
            oroles = check_roles_present("key override", odocs, OVERRIDE_KEY)
            stale = [name_of(w) for w in workloads(odocs) if ROLE_KEY in (pod_spec(w).get("nodeSelector") or {})]
            check(f"key override: no workload still selects nodes on {ROLE_KEY}", not stale, str(stale))
            if oroles:
                check_anti_affinity_present("key override", oroles)

    # ------------------- sameNodeMeasurement=true (fault-injection shape)
    # Both roles target the shared pool value; decode still carries the
    # required anti-affinity (enforceAntiAffinity stays at its true default)
    # -- this is the configuration the real-cluster e2e caps to one node to
    # prove the backstop itself works, not the YAML contract alone.
    sdocs, err = R.render(a.disagg, sets=["placement.sameNodeMeasurement=true"])
    if check("sameNodeMeasurement=true: helm template", sdocs is not None, err):
        sroles = check_roles_present("sameNodeMeasurement=true", sdocs, key=ROLE_KEY)
        if sroles:
            shared_ok = all(
                (pod_spec(w).get("nodeSelector") or {}).get(ROLE_KEY) == "shared"
                for r in ROLES for w in sroles[r]
            )
            check("sameNodeMeasurement=true: both roles' nodeSelector targets placement.sharedPoolValue (shared)",
                  shared_ok, json.dumps({r: [pod_spec(w).get("nodeSelector") for w in sroles[r]] for r in ROLES}))
            check_anti_affinity_present("sameNodeMeasurement=true, enforceAntiAffinity=true (default)", sroles)
            for r in ROLES:
                for w in sroles[r]:
                    strategy = (w.get("spec") or {}).get("strategy")
                    check(f"sameNodeMeasurement=true: {name_of(w)} ({r}) sets strategy.type=Recreate "
                          "(the shared pool has no spare GPU/EFA for a RollingUpdate surge pod)",
                          strategy == {"type": "Recreate"}, repr(strategy))

    # ----- sameNodeMeasurement=true, enforceAntiAffinity=false (same-node
    # transport measurement shape): decode carries required affinity toward
    # prefill instead of anti-affinity against it.
    adocs, err = R.render(a.disagg, sets=[
        "placement.sameNodeMeasurement=true", "placement.enforceAntiAffinity=false",
    ])
    if check("sameNodeMeasurement=true,enforceAntiAffinity=false: helm template", adocs is not None, err):
        aroles = check_roles_present("sameNodeMeasurement=true,enforceAntiAffinity=false", adocs)
        if aroles:
            check_affinity_present("sameNodeMeasurement=true,enforceAntiAffinity=false", aroles)
            check_anti_affinity_absent("sameNodeMeasurement=true,enforceAntiAffinity=false "
                                        "(no anti-affinity left once affinity replaces it)", aroles)

    # ----- no EFA device requested at all (UCX backend, efaDevices=0 on
    # both roles): the zone-affinity requirement must not render, since
    # nothing about this placement needs EFA's same-zone restriction.
    udocs, err = R.render(a.disagg, sets=[
        "transport.backend=UCX", "prefill.efaDevices=0", "decode.efaDevices=0",
    ])
    if check("transport.backend=UCX,efaDevices=0: helm template", udocs is not None, err):
        uroles = check_roles_present("transport.backend=UCX,efaDevices=0", udocs)
        if uroles:
            check_anti_affinity_present("transport.backend=UCX,efaDevices=0", uroles)
            check_zone_affinity_absent("transport.backend=UCX,efaDevices=0", uroles)

    # ------ forceEfaSameNode=true alone (no sameNodeMeasurement): must fail
    _, err = R.render(a.disagg, sets=["transport.forceEfaSameNode=true"])
    check("forceEfaSameNode=true without sameNodeMeasurement=true: helm template fails "
          "(forcing the same-host EFA path has no meaning on a cross-node run)",
          err is not None and "sameNodeMeasurement" in (err or ""), err)

    # --- forceEfaSameNode=true combined with sameNodeMeasurement=true: the
    # actual same-node transport measurement cell.
    fdocs, err = R.render(a.disagg, sets=[
        "placement.sameNodeMeasurement=true", "placement.enforceAntiAffinity=false",
        "transport.forceEfaSameNode=true",
    ])
    if check("sameNodeMeasurement=true,forceEfaSameNode=true: helm template", fdocs is not None, err):
        froles = check_roles_present("sameNodeMeasurement=true,forceEfaSameNode=true", fdocs)
        if froles:
            env_check("sameNodeMeasurement=true,forceEfaSameNode=true", froles, "FI_EFA_ENABLE_SHM_TRANSFER",
                      lambda p, v: v == "0", "sets FI_EFA_ENABLE_SHM_TRANSFER=0")
            check_affinity_present("sameNodeMeasurement=true,forceEfaSameNode=true (placement unchanged)", froles)

    # forceEfaSameNode=false, same-node mode: explicit =1, not unset.
    ndocs, err = R.render(a.disagg, sets=[
        "placement.sameNodeMeasurement=true", "placement.enforceAntiAffinity=false",
        "transport.forceEfaSameNode=false",
    ])
    if check("sameNodeMeasurement=true,forceEfaSameNode=false: helm template", ndocs is not None, err):
        nroles = check_roles_present("sameNodeMeasurement=true,forceEfaSameNode=false", ndocs)
        if nroles:
            env_check("sameNodeMeasurement=true,forceEfaSameNode=false", nroles, "FI_EFA_ENABLE_SHM_TRANSFER",
                      lambda p, v: p and v == "1", "sets FI_EFA_ENABLE_SHM_TRANSFER=1 explicitly (library default, stated)")

    # ------------------------------------------------- backend=UCX
    udocs, err = R.render(a.disagg, sets=["transport.backend=UCX"])
    if check("transport.backend=UCX: helm template", udocs is not None, err):
        uroles = check_roles_present("transport.backend=UCX", udocs)
        if uroles:
            cm = configmap_text(udocs)
            for r in ROLES:
                for w in uroles[r]:
                    cs = gpu_containers(pod_spec(w))
                    # KV_TRANSFER_CONFIG, the field that actually carries the
                    # backend name, lives in each container's own env list,
                    # not in command/args (the entrypoint script reads it
                    # from the environment at runtime) -- check container_text,
                    # which includes env, not just command/args.
                    text = json.dumps([container_text(c) for c in cs]) + " " + cm
                    check(f"transport.backend=UCX: {name_of(w)} ({r})'s connector config follows the value "
                          "(names UCX, no longer LIBFABRIC)", "UCX" in text and "LIBFABRIC" not in text)

    # --------------------------- RFC Decision 4: ratio knobs are values
    knobs = [("prefill", "replicas", 2), ("decode", "replicas", 3),
             ("prefill", "gpusPerEngine", 1), ("decode", "gpusPerEngine", 4)]
    missing = [".".join(k[:2]) for k in knobs if get_path(values, k[:2])[1] is False]
    if check("disagg-pd values: prefill/decode replicas and gpusPerEngine are values (RFC Decision 4)",
             not missing, f"missing: {missing}"):
        kdocs, err = R.render(a.disagg, sets=[f"{r}.{k}={v}" for r, k, v in knobs])
        if check("ratio knobs: helm template with prefill 2x1 GPU, decode 3x4 GPU", kdocs is not None, err):
            kroles = check_roles_present("ratio knobs", kdocs)
            if kroles:
                for r, want_rep, want_gpu in (("prefill", 2, 1), ("decode", 3, 4)):
                    reps = sum(int((w.get("spec") or {}).get("replicas", 1)) for w in kroles[r])
                    check(f"ratio knobs: {r} replicas = {want_rep}", reps == want_rep, f"got {reps}")
                    gpus = [str((((c.get("resources") or {}).get("limits")) or {}).get("nvidia.com/gpu"))
                            for w in kroles[r] for c in gpu_containers(pod_spec(w))]
                    check(f"ratio knobs: {r} container requests nvidia.com/gpu = {want_gpu}",
                          gpus and all(g == str(want_gpu) for g in gpus), f"got {gpus}")

    # -------------------------------------------------- agg-baseline
    adocs, err = R.render(a.agg)
    if check("agg-baseline: helm template with default values", adocs is not None, err):
        aw = workloads(adocs)
        check("agg-baseline: exactly one vLLM workload", len(aw) == 1, str([name_of(w) for w in aw]))
        # The command script always carries the literal "--kv-transfer-config"
        # text (it is a shell conditional on KV_TRANSFER_CONFIG's own value,
        # present whether or not kvCacheTier is gpu-only) - the actual
        # contract is that the env var's own *value* is empty by default,
        # not that the flag name never renders anywhere.
        kv_envs = set()
        for w in aw:
            for c in gpu_containers(pod_spec(w)):
                for e in c.get("env") or []:
                    if e["name"] == "KV_TRANSFER_CONFIG":
                        kv_envs.add(e.get("value", "<valueFrom>"))
        check("agg-baseline: no KV connector configured by default (KV_TRANSFER_CONFIG is empty)",
              kv_envs == {""}, repr(kv_envs))
        aroles = roles_by(adocs, ROLE_KEY)
        check("agg-baseline: no workload is pinned to a prefill/decode role node",
              not any(aroles[r] for r in ROLES))

    # ------------------------------------------- kvCacheTier (skeleton)
    _, err = R.render(a.disagg, sets=["kvCacheTier.mode=remote"])
    check("disagg-pd: kvCacheTier.mode=remote without an endpoint: helm template fails",
          err is not None and "kvCacheTier.lmcache.remote.endpoint" in (err or ""), err)
    _, err = R.render(a.agg, sets=["kvCacheTier.mode=remote"])
    check("agg-baseline: kvCacheTier.mode=remote without an endpoint: helm template fails",
          err is not None and "kvCacheTier.lmcache.remote.endpoint" in (err or ""), err)

    ldocs, err = R.render(a.disagg, sets=["kvCacheTier.mode=local"])
    if check("disagg-pd: kvCacheTier.mode=local: helm template", ldocs is not None, err):
        lroles = check_roles_present("disagg-pd kvCacheTier.mode=local", ldocs)
        if lroles:
            cm = configmap_text(ldocs)
            for r in ROLES:
                for w in lroles[r]:
                    text = " ".join(container_text(c) for c in gpu_containers(pod_spec(w))) + " " + cm
                    check(f"disagg-pd kvCacheTier.mode=local: {name_of(w)} ({r}) stacks "
                          "MultiConnector(NixlConnector, LMCacheConnector), keeping NixlConnector",
                          "MultiConnector" in text and "NixlConnector" in text and "LMCacheConnector" in text)

    rdocs, err = R.render(a.disagg, sets=[
        "kvCacheTier.mode=remote", "kvCacheTier.lmcache.remote.endpoint=cache.example.internal:6379",
    ])
    if check("disagg-pd: kvCacheTier.mode=remote with an endpoint: helm template", rdocs is not None, err):
        rroles = check_roles_present("disagg-pd kvCacheTier.mode=remote", rdocs)
        if rroles:
            cm = configmap_text(rdocs)
            for r in ROLES:
                for w in rroles[r]:
                    text = " ".join(container_text(c) for c in gpu_containers(pod_spec(w))) + " " + cm
                    check(f"disagg-pd kvCacheTier.mode=remote: {name_of(w)} ({r}) carries the remote endpoint",
                          "cache.example.internal" in text)

    radocs, err = R.render(a.agg, sets=[
        "kvCacheTier.mode=remote", "kvCacheTier.lmcache.remote.endpoint=cache.example.internal:6379",
    ])
    if check("agg-baseline: kvCacheTier.mode=remote with an endpoint: helm template", radocs is not None, err):
        aw2 = workloads(radocs)
        text = " ".join(json.dumps(w) for w in aw2) + " " + configmap_text(radocs)
        check("agg-baseline kvCacheTier.mode=remote: LMCacheConnector alone, no MultiConnector "
              "(there is no NixlConnector here to stack it with)",
              "LMCacheConnector" in text and "MultiConnector" not in text and "cache.example.internal" in text)

    # ----------------------------- exposure and pinning (AGENTS.md section 6)
    for chart_label, rendered in (("disagg-pd", docs), ("agg-baseline", adocs)):
        if rendered is None:
            continue
        svcs = [d for d in rendered if d.get("kind") == "Service"]
        exposed = [name_of(s) for s in svcs if (s.get("spec") or {}).get("type", "ClusterIP") != "ClusterIP"]
        check(f"{chart_label}: every Service is ClusterIP by default (nothing reachable from outside the cluster)",
              not exposed, str(exposed))
        ingresses = [name_of(d) for d in rendered if d.get("kind") in ("Ingress", "Gateway", "HTTPRoute")]
        check(f"{chart_label}: no Ingress/Gateway/HTTPRoute by default", not ingresses, str(ingresses))
        images = [c.get("image", "") for w in workloads(rendered)
                  for c in (pod_spec(w).get("containers") or []) + (pod_spec(w).get("initContainers") or [])]
        unpinned = [i for i in images if "@sha256:" not in i
                    and (":" not in i.rsplit("/", 1)[-1] or i.endswith(":latest"))]
        check(f"{chart_label}: every image is pinned by tag or digest, none :latest", images and not unpinned,
              f"unpinned: {unpinned}" if images else "no images rendered")

    print()
    if failures:
        print(f"RESULT FAIL: {len(failures)} placement/transport check(s) failed")
        return 1
    print("RESULT PASS: all placement/transport checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
