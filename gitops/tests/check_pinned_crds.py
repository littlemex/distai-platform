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
    repo_url = addon_doc["repoURL"]
    # #28: not every registry chart is OCI. accel-nvidia-device-plugin's
    # repoURL is a classic Helm chart repo (index.yaml at
    # https://nvidia.github.io/k8s-device-plugin), which `helm template`
    # reaches with `--repo <url> <chart-name>`, never an `oci://` ref --
    # prefixing "oci://" onto an already-"https://" URL produced an
    # unparseable "oci://https://..." reference (found while extending
    # this script for #28). Every other pinned addon.yaml in this repo so
    # far (karpenter*, kueue, the other three accel-* add-ons) uses an OCI
    # registry host with no scheme of its own, so this branch leaves their
    # behavior unchanged.
    if repo_url.startswith("http://") or repo_url.startswith("https://"):
        ref = f"{repo_url}#{chart}"  # descriptive only, for the FAIL message below; not a real helm ref
        cmd = ["helm", "template", f"{chart}-pinned-crd-check", chart, "--repo", repo_url, "--version", version]
    else:
        ref = f"oci://{repo_url}/{chart}"
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


def main(repo_root, rendered_dir):
    failures = 0
    served = {}
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
            skip_crds = bool(doc.get("skipCrds"))
            suffix = " (skipCrds: its own crds/-folder CRDs are not applied)" if skip_crds else ""
            print(f"INFO {label} ({chart}:{doc['version']}) ships {len(crds)} CustomResourceDefinition kind(s){suffix}")

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
