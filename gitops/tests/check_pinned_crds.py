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
import re
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
    # Both NVIDIA charts (accel-nvidia-device-plugin, accel-nvidia-dra)
    # template a validation guard refusing the implicit "default"
    # namespace ("Running in the 'default' namespace is not recommended"),
    # found running this script for #28 -- the render fails outright
    # without a namespace, not merely mislabels one. Combined with #63's
    # own need (an addon's namespaced objects must carry their *real*
    # namespace, not Helm's "default" fallback, for check_appproject_
    # whitelist.py's own comparison), both callers below now pass this
    # addon's own namespace: field through as the `namespace` parameter,
    # rather than this function re-deriving it a second way.
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


def helm_template_dir_chart(addon_doc, repo_root, workdir):
    """Same idea as helm_template_chart, for a local dir:-sourced chart
    (gitops/addon-catalog/<name>/addon.yaml) instead of a registry one --
    dcgm-exporter's own wrapper around an upstream `dependencies:` entry
    is the one that needs this today (#63, filed as "SA3" item 2). `helm
    dependency build` resolves that dependency into charts/ first, the
    same step gitops/tests/0.static.sh's own helm lint/template steps
    already run for this chart."""
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


# A fixed, named securityContext policy per addon label (#63, independent
# security-axis review pass, filed as "SA3" item 2 - this table used to be
# a single hardcoded dict for the two accel-efa-device-plugin-* addons
# only; dcgm-exporter's own hardening was not mechanically checked at all
# until this entry was added). Each entry is the exact values dcgm-exporter/
# addon.yaml or the two EFA addon.yaml files set themselves, kept here
# (never read back from those same files) for the reason explained above
# check_security_context_rendered's own call sites.
SECURITY_CONTEXT_EXPECTATIONS = {
    "accel-efa-device-plugin-nvidia": {
        "privileged": False,
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
    },
    "accel-efa-device-plugin-neuron": {
        "privileged": False,
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
    },
    "dcgm-exporter": {
        "allowPrivilegeEscalation": False,
        "capabilities": {"add": ["SYS_ADMIN"], "drop": ["ALL"]},
        "runAsNonRoot": False,
        "runAsUser": 0,
    },
}

METHOD_LABEL_RE = re.compile(r"^distai\.dev/[\w-]+-method$")


def find_method_label(values):
    """#28: search an addon.yaml's own `values` block (recursively; a method
    label lives at a different nesting depth per chart -- top-level
    nodeSelector for both NVIDIA charts, devicePlugin.nodeSelector /
    draDriver.nodeSelector for Neuron) for the one key matching
    distai.dev/<vendor>-method. Returns (key, value) or None."""
    if isinstance(values, dict):
        for k, v in values.items():
            if isinstance(k, str) and METHOD_LABEL_RE.match(k) and isinstance(v, str):
                return (k, v)
            found = find_method_label(v)
            if found:
                return found
    elif isinstance(values, list):
        for item in values:
            found = find_method_label(item)
            if found:
                return found
    return None


def daemonset_carries_label(ds_spec, key, value):
    """True if this DaemonSet's pod template selects nodes by key=value,
    either through a plain nodeSelector or a required nodeAffinity
    matchExpressions term (both chart families in this PR use one or the
    other, confirmed against the pinned chart versions' own values.yaml)."""
    pod_spec = ((ds_spec.get("template") or {}).get("spec") or {})
    if (pod_spec.get("nodeSelector") or {}).get(key) == value:
        return True
    terms = (
        ((pod_spec.get("affinity") or {}).get("nodeAffinity") or {})
        .get("requiredDuringSchedulingIgnoredDuringExecution", {})
        .get("nodeSelectorTerms", [])
    )
    for term in terms:
        for expr in term.get("matchExpressions", []):
            if expr.get("key") == key and value in (expr.get("values") or []):
                return True
    return False


def check_method_label_rendered(label, rendered_text, key, value):
    """#28, Blocking finding from the Fable 5.2 review of this PR: a
    values key that is not a real field in the pinned chart is silently
    ignored by Helm, not an error -- confirmed by the review, and the
    reason this script (which already has the exact pinned chart's own
    real rendered output) checks the label actually reached a DaemonSet's
    pod template, rather than trusting that setting it in addon.yaml's
    values was enough. Returns True/False/None (None: no DaemonSet in
    this chart's output at all, which is itself worth flagging)."""
    found_any_daemonset = False
    for doc in yaml.safe_load_all(rendered_text):
        if not doc or doc.get("kind") != "DaemonSet":
            continue
        found_any_daemonset = True
        if daemonset_carries_label(doc.get("spec") or {}, key, value):
            return True
    return None if not found_any_daemonset else False


def container_security_contexts(ds_spec):
    """Every container's own rendered securityContext in a DaemonSet's pod
    template (init and regular; a dropped-privilege override on one and not
    the other would otherwise go unnoticed)."""
    pod_spec = (ds_spec.get("template") or {}).get("spec") or {}
    containers = list(pod_spec.get("initContainers") or []) + list(pod_spec.get("containers") or [])
    return [(c.get("name", "?"), c.get("securityContext") or {}) for c in containers]


def check_security_context_rendered(rendered_text, expected):
    """accel-efa-device-plugin-{nvidia,neuron} (Fable 5.2 review round 2, finding
    N6): an addon.yaml's own `values.securityContext` override is, like a method
    label, a real Helm value that is silently ignored if the key or nesting is
    wrong -- the same failure mode #19/#28's own review already found once for
    `nodeSelector`. This asserts the *exact pinned chart's* own rendered
    DaemonSet actually carries the override on every one of its containers, not
    merely that `addon.yaml` declares it. Returns (True, "") or (False, reason).
    No DaemonSet in the chart's output at all is reported as a reason, not a
    silent pass -- that would otherwise look identical to "override lost"."""
    found_any_daemonset = False
    mismatches = []
    for doc in yaml.safe_load_all(rendered_text):
        if not doc or doc.get("kind") != "DaemonSet":
            continue
        found_any_daemonset = True
        for name, actual in container_security_contexts(doc.get("spec") or {}):
            for key, want in expected.items():
                got = actual.get(key)
                if got != want:
                    mismatches.append(f"container {name!r}: {key}={got!r}, expected {want!r}")
    if not found_any_daemonset:
        return False, "the rendered chart has no DaemonSet at all to carry a securityContext"
    if mismatches:
        return False, "; ".join(mismatches)
    return True, ""


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
            rendered = helm_template_chart(doc, workdir, namespace=doc.get("namespace"))
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

            # #28: every accel-* advertiser (never accel-device-classes,
            # which is a dir-only addon with no chart and no method label
            # of its own) must have its declared method label actually
            # reach a DaemonSet in the rendered output of the exact
            # pinned chart version -- not merely present in addon.yaml's
            # own values block, which Helm would silently accept and
            # ignore if the key were wrong (the review finding this
            # closes).
            if label.startswith("accel-"):
                method = find_method_label(doc.get("values") or {})
                if not method:
                    print(f"FAIL {label}: no distai.dev/*-method key found anywhere in its values block")
                    failures += 1
                else:
                    mkey, mvalue = method
                    result = check_method_label_rendered(label, rendered, mkey, mvalue)
                    if result is True:
                        print(f"PASS {label}: a DaemonSet in the rendered chart selects nodes by {mkey}={mvalue}")
                    elif result is False:
                        print(
                            f"FAIL {label}: no DaemonSet in the rendered chart selects nodes by {mkey}={mvalue} "
                            f"(the values key holding it may not be a real field of {chart}:{doc['version']})"
                        )
                        failures += 1
                    else:
                        print(f"FAIL {label}: the rendered chart has no DaemonSet at all to carry {mkey}={mvalue}")
                        failures += 1

            # accel-efa-device-plugin-{nvidia,neuron} (Fable 5.2 review round 2,
            # finding N6): the same "a values override can be silently ignored"
            # failure mode as the method-label check above, for the
            # securityContext hardening these add-ons ship instead of the
            # pinned chart's own default. This is a fixed, named policy per
            # addon -- SECURITY_CONTEXT_EXPECTATIONS below, never read back
            # from addon.yaml's own values -- on purpose: reading the
            # expectation from the same file being checked would pass
            # trivially the moment addon.yaml's own override is weakened or
            # dropped (confirmed by a deliberately-broken copy during this
            # check's own development: an earlier, condition-on-addon.yaml's-
            # own-value version of this check silently skipped a
            # `privileged: true` regression instead of failing it).
            if label in SECURITY_CONTEXT_EXPECTATIONS:
                ok, reason = check_security_context_rendered(rendered, SECURITY_CONTEXT_EXPECTATIONS[label])
                if ok:
                    print(f"PASS {label}: the rendered chart's own container(s) carry the hardened securityContext")
                else:
                    print(f"FAIL {label}: the rendered chart's own container(s) do not carry the hardened securityContext ({reason})")
                    failures += 1

                # Fable 5.2 review round 4: a method label alone is not enough --
                # confirmed on real hardware that this chart's own Pod crash-loops
                # on an EFA-capable instance type with zero physical EFA interfaces,
                # which a method-labeled pool can have (gitops/cells/dp-a19-gpu-r3,
                # dp-a19-trn-r3, #28). The fix is capacity-pool's own
                # distai.dev/efa-attached="true" label (set only when
                # pool.networkInterfaces is non-empty) ANDed into both releases' own
                # nodeSelector; this asserts that AND actually reaches the rendered
                # DaemonSet, the same silent-Helm-value risk the method-label check
                # above already guards against.
                efa_result = check_method_label_rendered(label, rendered, "distai.dev/efa-attached", "true")
                if efa_result is True:
                    print(f"PASS {label}: a DaemonSet in the rendered chart also requires distai.dev/efa-attached=true")
                else:
                    print(
                        f"FAIL {label}: no DaemonSet in the rendered chart requires distai.dev/efa-attached=true "
                        "(a method label alone would schedule this Pod on an EFA-less node and crash-loop there, "
                        "confirmed on real hardware)"
                    )
                    failures += 1

    # Local dir:-sourced addon-catalog charts (dcgm-exporter today, #63
    # filed as "SA3" item 2): these ship no CRD of their own, so they sit
    # outside the registry-chart loop above, but a securityContext
    # expectation in SECURITY_CONTEXT_EXPECTATIONS still applies to them
    # the same way.
    catalog_files = sorted(glob.glob(os.path.join(repo_root, "gitops", "addon-catalog", "*", "addon.yaml")))
    with tempfile.TemporaryDirectory() as catalog_workdir:
        for addon_path in catalog_files:
            with open(addon_path, encoding="utf-8") as f:
                doc = yaml.safe_load(f) or {}
            label = doc.get("addon", os.path.basename(os.path.dirname(addon_path)))
            if "dir" not in doc or label not in SECURITY_CONTEXT_EXPECTATIONS:
                continue
            rendered = helm_template_dir_chart(doc, repo_root, catalog_workdir)
            if rendered is None:
                failures += 1
                continue
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
