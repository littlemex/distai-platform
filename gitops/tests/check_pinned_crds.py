#!/usr/bin/env python3
"""Validate gitops/charts output against the exact CRDs the pinned add-on
charts ship -- not a generic, multi-version schema catalog.

Root cause this closes (found on a real cluster, 2026-11-19):
0.static.sh's kubeconform step validated manifests against
datreeio/CRDs-catalog, a catalog that carries a JSON schema for every
historical version of a CRD (kueue.x-k8s.io/v1beta1 *and* v1beta2, for
example). gitops/charts/{capacity-pool,smoke}'s templates hardcoded
kueue.x-k8s.io/v1beta1; kubeconform validated that happily, because the
catalog's v1beta1 schema exists -- even though Kueue 0.20.6 (the version
addons/kueue/addon.yaml actually pins) serves only v1beta2 on a real
cluster. The catalog answers "is this a valid shape for some version of
this CRD", never "is this the version the chart we pinned actually
ships".

What this script does instead: for every gitops/addons/<name>/addon.yaml
naming a registry chart, `helm template` that exact pinned chart version
(network access to the OCI registry required -- the same registries
0.static.sh's own helm lint/template steps and Argo CD itself reach),
respecting `skipCrds` the same way Argo CD's generated Application does
(`helm template --skip-crds` only ever affects a chart's special
top-level `crds/` folder, never a CRD defined as an ordinary template --
confirmed against Argo CD's own Helm user guide, the same source
gitops/addons/karpenter/addon.yaml's own comment cites). Every
CustomResourceDefinition that chart version actually ships, with its own
`served: true` versions, becomes the one source of truth this script
checks gitops/charts' already-rendered output against (the same
RENDERED_DIR 0.static.sh's own kubeconform step already produced -- this
script renders nothing a second time).

Usage: check_pinned_crds.py <repo_root> <rendered_dir>
"""
import glob
import os
import subprocess
import sys
import tempfile

import yaml


def load_docs(path):
    with open(path, encoding="utf-8") as f:
        return [d for d in yaml.safe_load_all(f) if d]


def set_path(d, dotted_key, value):
    parts = dotted_key.split(".")
    cur = d
    for p in parts[:-1]:
        cur = cur.setdefault(p, {})
    cur[parts[-1]] = value


def placeholder_values(addon_doc):
    """Same technique 0.static.sh's own extract_values() uses: an addon.yaml's
    `valuesFrom` entries are resolved only by Argo CD's templatePatch, from a
    live cluster's Cluster generator params / registration Secret
    annotations -- neither exists here. Filling each entry's own `helmKey`
    path with an inert placeholder is enough to get a chart whose templates
    `required()`-guard a cell-specific value (karpenter's settings.clusterName)
    past that guard, so its real CRD content (if any; karpenter itself ships
    none once --skip-crds is honored) still renders instead of this script
    reporting every such chart as broken."""
    values = dict(addon_doc.get("values") or {})
    for entry in addon_doc.get("valuesFrom", []) or []:
        set_path(values, entry["helmKey"], "pinned-crd-check-placeholder")
    return values


def helm_template_chart(addon_doc, workdir, namespace=None):
    """namespace is optional and defaults to None (Helm's own "default", the
    same as every call site before this parameter existed): this function's
    original purpose is CRD extraction, and a CustomResourceDefinition is
    cluster-scoped, so no caller before check_appproject_whitelist.py (#63)
    ever needed one. That script reuses this same renderer to also check
    *namespaced* objects' metadata.namespace against the AppProject's real
    destinations -- Helm only renders whatever `.Release.Namespace` resolves
    to into a template, and never knows what addon.yaml's own declared
    namespace is unless told; passing one through (`--namespace`) is that
    telling, not a new render path."""
    chart = addon_doc["chart"]
    version = str(addon_doc["version"])
    skip_crds = bool(addon_doc.get("skipCrds"))
    ref = f"oci://{addon_doc['repoURL']}/{chart}"
    cmd = ["helm", "template", f"{chart}-pinned-crd-check", ref, "--version", version]
    if namespace:
        cmd += ["--namespace", namespace, "--create-namespace"]
    if skip_crds:
        cmd.append("--skip-crds")
    values = placeholder_values(addon_doc)
    values_path = None
    if values:
        values_path = os.path.join(workdir, f"{chart}-values.yaml")
        with open(values_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(values, f)
        cmd += ["-f", values_path]
    proc = subprocess.run(cmd, cwd=workdir, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        print(f"FAIL helm template {ref}:{version} (for CRD extraction): {proc.stderr.strip()}")
        return None
    return proc.stdout


def extract_served_versions(rendered_text):
    """{(group, kind): {served version name, ...}}, one CRD extraction unit."""
    out = {}
    for doc in yaml.safe_load_all(rendered_text):
        if not doc or doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc.get("spec", {}) or {}
        group = spec.get("group")
        kind = (spec.get("names") or {}).get("kind")
        versions = {v["name"] for v in spec.get("versions", []) if v.get("served", True)}
        if group and kind and versions:
            out.setdefault((group, kind), set()).update(versions)
    return out


def helm_template_dir_chart(addon_doc, repo_root, workdir):
    """Same idea as helm_template_chart, for a local dir:-sourced chart
    (gitops/addon-catalog/<name>/addon.yaml) instead of a registry one --
    dcgm-exporter's own wrapper around an upstream `dependencies:` entry
    is the one that needs this (#63, independent security-axis review
    pass, filed as "SA3" item 2). `helm dependency build` resolves that
    dependency into charts/ first, the same step gitops/tests/0.static.sh's
    own helm lint/template steps already run for this chart."""
    chart_ref = os.path.join(repo_root, addon_doc["dir"])
    subprocess.run(["helm", "dependency", "build", chart_ref], capture_output=True, text=True, timeout=120)
    name = addon_doc.get("addon", os.path.basename(chart_ref))
    cmd = ["helm", "template", f"{name}-pinned-crd-check", chart_ref]
    namespace = addon_doc.get("namespace")
    if namespace:
        cmd += ["-n", namespace, "--create-namespace"]
    values = placeholder_values(addon_doc)
    values_path = None
    if values:
        values_path = os.path.join(workdir, f"{name}-values.yaml")
        with open(values_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(values, f)
        cmd += ["-f", values_path]
    proc = subprocess.run(cmd, cwd=workdir, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        print(f"FAIL helm template {addon_doc['dir']} (for securityContext check): {proc.stderr.strip()}")
        return None
    return proc.stdout


def container_security_contexts(ds_spec):
    """Every container's own rendered securityContext in a DaemonSet's pod
    template (init and regular; a dropped-privilege override on one and not
    the other would otherwise go unnoticed)."""
    pod_spec = (ds_spec.get("template") or {}).get("spec") or {}
    containers = list(pod_spec.get("initContainers") or []) + list(pod_spec.get("containers") or [])
    return [(c.get("name", "?"), c.get("securityContext") or {}) for c in containers]


def check_security_context_rendered(rendered_text, expected):
    """A fixed, named securityContext policy, checked against the exact
    pinned chart's own rendered output (#63, filed as "SA3" item 2) -
    dcgm-exporter's own hardening (allowPrivilegeEscalation: false,
    capabilities add SYS_ADMIN/drop ALL, runAsNonRoot: false, runAsUser:
    0), kept here rather than read back from addon.yaml's own values on
    purpose: reading the expectation from the same file being checked
    would pass trivially the moment that file's own override is weakened
    or dropped. Returns (True, "") or (False, reason). No DaemonSet in
    the chart's output at all is reported as a reason, not a silent pass
    -- that would otherwise look identical to "override lost"."""
    found_any_daemonset = False
    mismatches = []
    for doc in yaml.safe_load_all(rendered_text):
        if not doc or doc.get("kind") != "DaemonSet":
            continue
        found_any_daemonset = True
        for name, actual in container_security_contexts(doc.get("spec") or {}):
            for key, want in expected.items():
                got = actual.get(key)
                # A False expectation also matches the key being absent
                # entirely (dcgm-exporter's own pinned chart renders no
                # "privileged" key at all, not a literal "privileged:
                # false" - confirmed by rendering it): Kubernetes' own
                # documented default for every boolean SecurityContext
                # field this check compares is False, so "absent" and
                # "false" are the same fact on the cluster. A True
                # expectation, or any non-boolean one, still requires an
                # exact match.
                if want is False and got is None:
                    continue
                if got != want:
                    mismatches.append(f"container {name!r}: {key}={got!r}, expected {want!r}")
    if not found_any_daemonset:
        return False, "the rendered chart has no DaemonSet at all to carry a securityContext"
    if mismatches:
        return False, "; ".join(mismatches)
    return True, ""


# Addon label -> expected securityContext (#63, filed as "SA3" item 2).
# dcgm-exporter's own entry has no values.securityContext override of its
# own (gitops/addon-catalog/dcgm-exporter/addon.yaml sets no such key) --
# this is the pinned upstream chart's own rendered default instead,
# confirmed by rendering it, kept here rather than read back from that
# chart for the same reason explained above check_security_context_
# rendered's own call sites. privileged: False is included deliberately
# (Fable 5.2 review of a sibling branch, #63): check_security_context_
# rendered() only compares keys present here, so leaving this key out
# would let a privileged: true regression on this container pass
# silently -- confirmed the rendered container carries no "privileged"
# key today (the implicit Kubernetes default, False) before adding it.
SECURITY_CONTEXT_EXPECTATIONS = {
    "dcgm-exporter": {
        "privileged": False,
        "allowPrivilegeEscalation": False,
        "capabilities": {"add": ["SYS_ADMIN"], "drop": ["ALL"]},
        "runAsNonRoot": False,
        "runAsUser": 0,
    },
}


def main(repo_root, rendered_dir):
    failures = 0
    served = {}
    # Every addon.yaml/addon-catalog label this run actually found, versus
    # every label whose SECURITY_CONTEXT_EXPECTATIONS entry was actually
    # exercised below (Fable 5.2 review, #63): the "if label in
    # SECURITY_CONTEXT_EXPECTATIONS" guard below makes a renamed or
    # misspelled label a silent no-op rather than a failure. A label this
    # run never saw at all (not this checkout's own) is not a failure.
    labels_seen = set()
    security_context_checked = set()
    addon_files = sorted(glob.glob(os.path.join(repo_root, "gitops", "addons", "*", "addon.yaml")))
    with tempfile.TemporaryDirectory() as workdir:
        for addon_path in addon_files:
            with open(addon_path, encoding="utf-8") as f:
                doc = yaml.safe_load(f) or {}
            chart = doc.get("chart")
            if not chart:
                # A local-dir add-on (`dir:` instead of `chart:`) ships no
                # registry chart to pull; none exist in this PR, but a
                # future one might, and it is simply out of this script's
                # scope (its CRDs, if any, would be checked in tree).
                continue
            rendered = helm_template_chart(doc, workdir)
            if rendered is None:
                failures += 1
                continue
            crds = extract_served_versions(rendered)
            for key, versions in crds.items():
                served.setdefault(key, set()).update(versions)
            label = doc.get("addon", chart)
            labels_seen.add(label)
            skip_crds = bool(doc.get("skipCrds"))
            suffix = " (skipCrds: its own crds/-folder CRDs are not applied)" if skip_crds else ""
            print(f"INFO {label} ({chart}:{doc['version']}) ships {len(crds)} CustomResourceDefinition kind(s){suffix}")

    # Local dir:-sourced addon-catalog charts (dcgm-exporter, #63 filed
    # as "SA3" item 2): these ship no CRD of their own, so they sit
    # outside the registry-chart loop above, but a securityContext
    # expectation in SECURITY_CONTEXT_EXPECTATIONS still applies to them.
    catalog_files = sorted(glob.glob(os.path.join(repo_root, "gitops", "addon-catalog", "*", "addon.yaml")))
    with tempfile.TemporaryDirectory() as catalog_workdir:
        for addon_path in catalog_files:
            with open(addon_path, encoding="utf-8") as f:
                doc = yaml.safe_load(f) or {}
            label = doc.get("addon", os.path.basename(os.path.dirname(addon_path)))
            labels_seen.add(label)
            if "dir" not in doc or label not in SECURITY_CONTEXT_EXPECTATIONS:
                continue
            rendered = helm_template_dir_chart(doc, repo_root, catalog_workdir)
            if rendered is None:
                failures += 1
                continue
            security_context_checked.add(label)
            ok, reason = check_security_context_rendered(rendered, SECURITY_CONTEXT_EXPECTATIONS[label])
            if ok:
                print(f"PASS {label}: the rendered chart's own container(s) carry the hardened securityContext")
            else:
                print(f"FAIL {label}: the rendered chart's own container(s) do not carry the hardened securityContext ({reason})")
                failures += 1

    if failures:
        return 1

    if not served:
        print("INFO no pinned add-on in this PR ships a CRD; nothing for gitops/charts output to be checked against")
        return 0

    checked = 0
    rendered_files = sorted(glob.glob(os.path.join(rendered_dir, "*.yaml")))
    for rendered_file in rendered_files:
        rel = os.path.basename(rendered_file)
        for doc in load_docs(rendered_file):
            kind = doc.get("kind", "")
            if not kind or kind == "CustomResourceDefinition":
                continue
            api_version = doc.get("apiVersion", "")
            group, _, version = api_version.partition("/")
            if not version:
                continue  # a core/v1 kind: not any add-on's own CRD
            key = (group, kind)
            if key not in served:
                continue  # not a kind any pinned add-on's CRD covers
            checked += 1
            name = (doc.get("metadata") or {}).get("name", "?")
            served_versions = served[key]
            if version in served_versions:
                print(f"PASS {rel}: {kind} {name} ({api_version}) is served by the pinned chart")
            else:
                print(
                    f"FAIL {rel}: {kind} {name} uses {api_version}, but the pinned chart "
                    f"for {group}/{kind} only serves: {', '.join(sorted(served_versions))}"
                )
                failures += 1

    print(f"INFO checked {checked} manifest(s) against {len(served)} pinned CustomResourceDefinition kind(s)")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
