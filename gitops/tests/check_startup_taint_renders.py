#!/usr/bin/env python3
"""Render the pinned charts behind #96's add-on changes (network access
required, same style as check_pinned_crds.py/check_appproject_whitelist.py)
and check the *rendered* output, not only each `addon.yaml`'s declared
`values:` (`check_startup_taint_keys.py`'s own job, and a one-time
`helm template` before/after diff run once by hand are not enough: a
chart bump can silently stop reading a values key, or a typo in a
`config.*` name can pass structurally while Vigil watches its own chart
default instead).

Checked, against each pinned chart version `addons/*/addon.yaml` actually
names (not a hand-typed copy of its values):

  - each of the four device-plugin add-ons' own `addon.yaml` values,
    rendered with and without them: the set of DaemonSet names is
    unchanged, and every DaemonSet's own tolerations gain exactly the one
    `distai.dev/startup-not-ready` entry `check_startup_taint_keys.py`
    also checks the add-on's declared values for -- nothing else differs,
    so nothing this add-on depended on (CriticalAddonsOnly, the
    vendor-specific taint, the SageMaker health-status toleration) was
    silently dropped by this override;
  - `vigil-controller`'s own rendered `ConfigMap` actually contains the
    `taintKey`/`taintEffect`/`timeoutSeconds` `addon.yaml` declares (a
    misnamed `config.*` key would otherwise pass `check_startup_taint_
    keys.py` while the chart silently falls back to its own default), and
    its rendered `Deployment` carries the declared `tolerations`/`affinity`.

Usage: check_startup_taint_renders.py <repo_root>
Prints one PASS/FAIL line per check; exits 1 if any failed.
"""
from __future__ import annotations

import copy
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_pinned_crds import helm_template_chart  # noqa: E402

FAILURES: list[str] = []

# gitops/addons/<name>/addon.yaml -> dotted path to its own tolerations
# list (same map check_startup_taint_keys.py uses).
DEVICE_PLUGIN_TOLERATIONS_PATHS = {
    "accel-nvidia-device-plugin": "tolerations",
    "accel-neuron-device-plugin": "devicePlugin.tolerations",
    "accel-efa-device-plugin-nvidia": "tolerations",
    "accel-efa-device-plugin-neuron": "tolerations",
}


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def load_addon(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    return doc if isinstance(doc, dict) else {}


def get_path(d: dict, dotted: str):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


def load_docs(rendered: str) -> list[dict]:
    return [d for d in yaml.safe_load_all(rendered) if d]


def normalize_toleration(t: dict) -> tuple:
    return tuple(sorted((k, str(v)) for k, v in t.items()))


def daemonset_tolerations(docs: list[dict]) -> dict[str, list[dict]]:
    out = {}
    for d in docs:
        if d.get("kind") == "DaemonSet":
            name = (d.get("metadata") or {}).get("name", "")
            out[name] = ((d.get("spec") or {}).get("template", {}).get("spec") or {}).get("tolerations") or []
    return out


def check_device_plugin_addon(repo_root: str, workdir: str, name: str, tol_path: str, taint_key: str, taint_effect: str) -> None:
    addon_path = os.path.join(repo_root, "gitops/addons", name, "addon.yaml")
    rel = os.path.relpath(addon_path, repo_root)
    if not os.path.isfile(addon_path):
        check(f"{rel} exists", False, "not found")
        return
    addon_doc = load_addon(addon_path)
    namespace = addon_doc.get("namespace")

    after_rendered = helm_template_chart(addon_doc, workdir, namespace=namespace)
    if after_rendered is None:
        check(f"{rel}: helm template with this add-on's own values succeeds", False, "see FAIL above for helm's own stderr")
        return
    before_doc = copy.deepcopy(addon_doc)
    before_doc["values"] = {}
    before_doc.pop("valuesFrom", None)
    before_rendered = helm_template_chart(before_doc, workdir, namespace=namespace)
    if before_rendered is None:
        check(f"{rel}: helm template with the chart's own defaults (no values override) succeeds", False, "see FAIL above")
        return

    before_ds = daemonset_tolerations(load_docs(before_rendered))
    after_ds = daemonset_tolerations(load_docs(after_rendered))
    check(
        f"{rel}: the override renders the same set of DaemonSets as the chart's own defaults ({sorted(before_ds)})",
        set(before_ds) == set(after_ds),
        f"before={sorted(before_ds)} after={sorted(after_ds)}",
    )
    target_entry = {"key": taint_key, "effect": taint_effect}
    for ds_name in sorted(set(before_ds) & set(after_ds)):
        before_set = {normalize_toleration(t) for t in before_ds[ds_name] if isinstance(t, dict)}
        after_set = {normalize_toleration(t) for t in after_ds[ds_name] if isinstance(t, dict)}
        added = after_set - before_set
        removed = before_set - after_set
        check(
            f"{rel}: DaemonSet {ds_name} gains exactly one toleration ({target_entry}), nothing else, nothing dropped",
            not removed and len(added) == 1 and normalize_toleration(target_entry) in added,
            f"removed={removed!r} added={added!r} (want added == {{{normalize_toleration(target_entry)!r}}}, removed == set())",
        )


def check_vigil_controller(repo_root: str, workdir: str) -> tuple[str | None, str | None]:
    addon_path = os.path.join(repo_root, "gitops/addons/vigil-controller/addon.yaml")
    rel = os.path.relpath(addon_path, repo_root)
    if not os.path.isfile(addon_path):
        check(f"{rel} exists", False, "not found")
        return None, None
    addon_doc = load_addon(addon_path)
    config = get_path(addon_doc, "values.config") or {}
    taint_key, taint_effect = config.get("taintKey"), config.get("taintEffect")
    timeout_seconds = config.get("timeoutSeconds")

    rendered = helm_template_chart(addon_doc, workdir, namespace=addon_doc.get("namespace"))
    if rendered is None:
        check(f"{rel}: helm template succeeds", False, "see FAIL above for helm's own stderr")
        return taint_key, taint_effect
    docs = load_docs(rendered)

    config_maps = [d for d in docs if d.get("kind") == "ConfigMap"]
    check(f"{rel}: renders exactly one ConfigMap", len(config_maps) == 1, f"got {len(config_maps)}")
    if config_maps:
        raw = (config_maps[0].get("data") or {}).get("config.yaml", "")
        rendered_config = yaml.safe_load(raw) or {}
        check(
            f"{rel}: rendered ConfigMap's config.yaml has taintKey == {taint_key!r} (addon.yaml's own declared value)",
            rendered_config.get("taintKey") == taint_key,
            f"got {rendered_config.get('taintKey')!r}",
        )
        check(
            f"{rel}: rendered ConfigMap's config.yaml has taintEffect == {taint_effect!r}",
            rendered_config.get("taintEffect") == taint_effect,
            f"got {rendered_config.get('taintEffect')!r}",
        )
        check(
            f"{rel}: rendered ConfigMap's config.yaml has timeoutSeconds == {timeout_seconds!r}",
            rendered_config.get("timeoutSeconds") == timeout_seconds,
            f"got {rendered_config.get('timeoutSeconds')!r}",
        )

    deployments = [d for d in docs if d.get("kind") == "Deployment"]
    check(f"{rel}: renders exactly one Deployment", len(deployments) == 1, f"got {len(deployments)}")
    if deployments:
        pod_spec = (deployments[0].get("spec") or {}).get("template", {}).get("spec") or {}
        want_tolerations = get_path(addon_doc, "values.tolerations") or []
        got_tolerations = pod_spec.get("tolerations") or []
        check(
            f"{rel}: rendered Deployment's tolerations equal addon.yaml's own declared values.tolerations",
            {normalize_toleration(t) for t in got_tolerations if isinstance(t, dict)}
            == {normalize_toleration(t) for t in want_tolerations if isinstance(t, dict)},
            f"got {got_tolerations!r}, want {want_tolerations!r}",
        )
        want_affinity = get_path(addon_doc, "values.affinity")
        check(
            f"{rel}: rendered Deployment's affinity equals addon.yaml's own declared values.affinity",
            pod_spec.get("affinity") == want_affinity,
            f"got {pod_spec.get('affinity')!r}, want {want_affinity!r}",
        )
    return taint_key, taint_effect


def main(repo_root: str) -> int:
    import tempfile

    workdir = tempfile.mkdtemp(prefix="check-startup-taint-renders-")
    try:
        taint_key, taint_effect = check_vigil_controller(repo_root, workdir)
        if not (taint_key and taint_effect):
            print("FAIL could not determine vigil-controller's own taintKey/taintEffect; skipping the device-plugin checks")
            FAILURES.append("vigil-controller taintKey/taintEffect unavailable")
        else:
            for name, tol_path in DEVICE_PLUGIN_TOLERATIONS_PATHS.items():
                check_device_plugin_addon(repo_root, workdir, name, tol_path, taint_key, taint_effect)
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all startup-taint render checks passed")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_startup_taint_renders.py <repo_root>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
