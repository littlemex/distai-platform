#!/usr/bin/env python3
"""Structural checks for the gitops/ delivery layer (issue #25) that do not
need a cluster: the shape of the ApplicationSets, the root Application, and
every add-on/cell parameter file, against the decisions in the issue body.
Extended for issue #28 (the accelerator add-ons): the four accel-* add-ons,
the platform's own Neuron DeviceClass chart, capacity-pool's pool.labels
and the two light-tier accelerator cells, against that issue's
"Interface" table and acceptance criteria.

This is a static, content-only check. It knows nothing about whether Argo CD
would actually accept these objects (that needs `1.e2e.sh`) and nothing
about the implementation that produced them -- every assertion below is
traceable to one decision in
https://github.com/littlemex/distai-platform/issues/25 or to one row of the
"Interface" table in https://github.com/littlemex/distai-platform/issues/28.

Run with a pinned PyYAML, e.g.:
    uv run --no-project -q --with pyyaml==6.0.2 python3 check_gitops_contract.py <repo-root>

Prints one "PASS <label>" or "FAIL <label>: <reason>" line per check and
exits 1 if any check failed, 0 otherwise -- the same contract 0.static.sh's
other checks use via run_check().
"""
from __future__ import annotations

import glob
import os
import re
import sys

import yaml

FAILURES: list[str] = []


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def load_yaml_docs(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [d for d in yaml.safe_load_all(f) if d is not None]


def load_one(path: str) -> dict:
    docs = load_yaml_docs(path)
    if len(docs) != 1:
        raise ValueError(f"{path}: expected exactly one YAML document, found {len(docs)}")
    return docs[0]


def main(root: str) -> int:
    gitops = os.path.join(root, "gitops")

    # ---------------------------------------------------- required files
    # Decision 3's layout, scoped to Decision 9's first-PR content plus
    # issue #28's accelerator add-ons; no teams/* yet.
    required = [
        "bootstrap/bootstrap.sh",
        "bootstrap/root-application.yaml",
        "appsets/platform.ApplicationSet.yaml",
        "appsets/cells.ApplicationSet.yaml",
        "addons/karpenter-crd/addon.yaml",
        "addons/karpenter/addon.yaml",
        "addons/kueue/addon.yaml",
        "charts/capacity-pool/Chart.yaml",
        "charts/smoke/Chart.yaml",
        # Issue #28, Interface table: four accel-* add-ons, the platform's own
        # DeviceClass catalog add-on and its local chart.
        "addons/accel-nvidia-device-plugin/addon.yaml",
        "addons/accel-nvidia-dra/addon.yaml",
        "addons/accel-neuron-device-plugin/addon.yaml",
        "addons/accel-neuron-dra/addon.yaml",
        "addons/accel-device-classes/addon.yaml",
        "charts/accel-device-classes/Chart.yaml",
    ]
    for rel in required:
        check(f"file gitops/{rel} exists", os.path.isfile(os.path.join(gitops, rel)))

    cell_capacity_pool_files = sorted(glob.glob(os.path.join(gitops, "cells", "*", "capacity-pool", "*.yaml")))
    cell_smoke_files = sorted(glob.glob(os.path.join(gitops, "cells", "*", "smoke", "*.yaml")))
    check(
        "at least one cells/<cluster>/capacity-pool/*.yaml parameter file exists",
        len(cell_capacity_pool_files) >= 1,
        f"found: {cell_capacity_pool_files}",
    )
    check(
        "at least one cells/<cluster>/smoke/*.yaml parameter file exists",
        len(cell_smoke_files) >= 1,
        f"found: {cell_smoke_files}",
    )

    # Every directory under addons/ has exactly one addon.yaml, and that
    # file is independently structurally valid (checked below via
    # check_addon_yaml). An earlier version of this check asserted an
    # exact, hand-typed set of directory names instead; this PR (#28,
    # adding five accelerator-step add-ons) and #41 each extended their
    # own copy of that literal for their own addons, so the merged tree's
    # real addon count matched neither copy and the check failed
    # regardless of which PR landed second (#63, filed as #55). This
    # directory-shape check is derived from the filesystem, like
    # sourceRepos already is in bootstrap.sh, and needs no further edit
    # as addons/ grows; the three addon.yaml files RFC #25's own
    # Decisions discuss by name are still checked explicitly below,
    # independent of this generic shape check.
    addon_dirs = sorted(
        d
        for d in os.listdir(os.path.join(gitops, "addons"))
        if os.path.isdir(os.path.join(gitops, "addons", d))
    ) if os.path.isdir(os.path.join(gitops, "addons")) else []
    check(
        "addons/ contains at least karpenter-crd, karpenter, kueue",
        {"karpenter-crd", "karpenter", "kueue"}.issubset(set(addon_dirs)),
        f"found: {addon_dirs}",
    )
    for cluster_dir in glob.glob(os.path.join(gitops, "cells", "*")):
        teams_glob = glob.glob(os.path.join(cluster_dir, "teams", "*.yaml"))
        check(
            f"{os.path.relpath(cluster_dir, root)}/teams/ is empty in this PR (decision 9, #22 not shipped yet)",
            len(teams_glob) == 0,
            f"found: {teams_glob}",
        )

    # ---------------------------------------------------- addon.yaml shape
    # Decision 2: addon.yaml's own keys. "addon" (not "name"), and either a
    # chart reference (chart/repoURL/version) or a local dir (never both --
    # Decision 2 says cell-specific parameter files use "dir ... never a
    # chart from an upstream registry").
    def check_addon_yaml(path: str, *, allow_dir: bool) -> dict:
        rel = os.path.relpath(path, root)
        doc = load_one(path)
        check(f"{rel} has an 'addon' key (not 'name')", isinstance(doc.get("addon"), str) and doc.get("addon"))
        check(f"{rel} has a 'wave' key", isinstance(doc.get("wave"), str) and bool(doc.get("wave")))
        has_chart = "chart" in doc
        has_dir = "dir" in doc
        if allow_dir:
            check(f"{rel} has exactly one of 'chart' or 'dir'", has_chart != has_dir)
        else:
            check(f"{rel} is a registry add-on: has 'chart', not 'dir' (decision 2)", has_chart and not has_dir)
            if has_chart:
                for k in ("repoURL", "version"):
                    check(f"{rel} has '{k}' alongside 'chart'", k in doc and bool(doc[k]))
        if "namespace" in doc:
            check(f"{rel}'s 'namespace' is a non-empty string", isinstance(doc["namespace"], str) and doc["namespace"])
        return doc

    allowed_platform_waves = {"crds", "controllers", "accelerators", "extras"}
    allowed_cells_waves = {"capacity", "teams"}

    karpenter_crd_doc = check_addon_yaml(os.path.join(gitops, "addons/karpenter-crd/addon.yaml"), allow_dir=False)
    karpenter_doc = check_addon_yaml(os.path.join(gitops, "addons/karpenter/addon.yaml"), allow_dir=False)
    kueue_doc = check_addon_yaml(os.path.join(gitops, "addons/kueue/addon.yaml"), allow_dir=False)

    # Every other addons/ directory (whatever a later PR added) gets the
    # same generic structural check, derived from the filesystem rather
    # than a hand-typed per-PR list (see the comment above addon_dirs).
    for addon_dir in addon_dirs:
        if addon_dir in ("karpenter-crd", "karpenter", "kueue"):
            continue
        addon_yaml_files = glob.glob(os.path.join(gitops, "addons", addon_dir, "addon.yaml"))
        check(
            f"addons/{addon_dir}/ contains exactly one addon.yaml",
            len(addon_yaml_files) == 1,
            f"found: {glob.glob(os.path.join(gitops, 'addons', addon_dir, '*'))}",
        )
        if len(addon_yaml_files) == 1:
            check_addon_yaml(addon_yaml_files[0], allow_dir=True)

    for rel_doc, doc in (("karpenter-crd", karpenter_crd_doc), ("karpenter", karpenter_doc), ("kueue", kueue_doc)):
        wave = doc.get("wave")
        check(f"addons/{rel_doc}/addon.yaml's wave is one of {sorted(allowed_platform_waves)}", wave in allowed_platform_waves, f"got {wave!r}")

    check(
        "addons/karpenter-crd/addon.yaml is in the 'crds' step (decision 4)",
        karpenter_crd_doc.get("wave") == "crds",
    )
    check(
        "addons/karpenter/addon.yaml and addons/kueue/addon.yaml are in the 'controllers' step (decision 4)",
        karpenter_doc.get("wave") == "controllers" and kueue_doc.get("wave") == "controllers",
    )

    # Decision 4: karpenter-crd defines the CRDs as plain templates; the
    # karpenter chart also ships the same five in a crds/ folder, so its own
    # Application must skip them.
    check(
        "addons/karpenter/addon.yaml sets skipCrds: true (decision 4 -- avoids owning the same CRDs as karpenter-crd)",
        karpenter_doc.get("skipCrds") is True,
        f"got {karpenter_doc.get('skipCrds')!r}",
    )
    check(
        "addons/karpenter-crd/addon.yaml does not set skipCrds (it has no CRDs of a parent chart to skip)",
        "skipCrds" not in karpenter_crd_doc or karpenter_crd_doc.get("skipCrds") is not True,
    )

    # Decision 4: kueue's Application sets ServerSideApply=true, matching
    # its own install docs (large CRDs exceed the client-side
    # last-applied-configuration annotation size limit).
    kueue_sync_options = kueue_doc.get("syncOptions") or []
    check(
        "addons/kueue/addon.yaml's syncOptions includes ServerSideApply=true (decision 4)",
        "ServerSideApply=true" in kueue_sync_options,
        f"got {kueue_sync_options!r}",
    )

    # Decision 6: a karpenter/karpenter-crd version bump must move both
    # files together -- the "mechanical" version-pair check this issue's
    # upgrade e2e (decision 9) is required to exercise.
    karpenter_version = karpenter_doc.get("version")
    karpenter_crd_version = karpenter_crd_doc.get("version")
    check(
        "addons/karpenter/addon.yaml and addons/karpenter-crd/addon.yaml pin the same version (decision 6)",
        karpenter_version == karpenter_crd_version,
        f"karpenter={karpenter_version!r} karpenter-crd={karpenter_crd_version!r}",
    )

    # Decision 2: valuesFrom entries have exactly one of annotationKey or
    # param alongside helmKey.
    for rel_doc, doc in (("karpenter-crd", karpenter_crd_doc), ("karpenter", karpenter_doc), ("kueue", kueue_doc)):
        for entry in doc.get("valuesFrom") or []:
            has_ann = "annotationKey" in entry
            has_param = "param" in entry
            check(
                f"addons/{rel_doc}/addon.yaml valuesFrom entry {entry.get('helmKey')!r} has exactly one of annotationKey/param (decision 2)",
                bool(entry.get("helmKey")) and (has_ann != has_param),
                f"got {entry!r}",
            )

    # ------------------------------------------------- cells/ parameter files
    # Issue #27: pool.capacityType is an enum, and a reserved pool selects
    # its reservation by tag -- a reserved pool with no tags would leave a
    # selector term matching every reservation of its instanceMatchCriteria
    # in the account.
    allowed_capacity_types = {"on-demand", "reserved", "flex"}
    addons_by_cell: dict[str, list[tuple[str, str]]] = {}
    for path in cell_capacity_pool_files:
        rel = os.path.relpath(path, root)
        doc = check_addon_yaml(path, allow_dir=True)
        addons_by_cell.setdefault(os.path.dirname(os.path.dirname(path)), []).append((rel, str(doc.get("addon", ""))))
        check(f"{rel}'s addon value is 'capacity-pool-<pool>' (decision 2)", str(doc.get("addon", "")).startswith("capacity-pool-"))
        check(f"{rel}'s wave is one of {sorted(allowed_cells_waves)}", doc.get("wave") in allowed_cells_waves)
        if "dir" in doc:
            check(f"{rel}'s dir points under gitops/charts/", str(doc["dir"]).rstrip("/").endswith("charts/capacity-pool") or "charts/capacity-pool" in str(doc["dir"]))
        values = doc.get("values") or {}
        capacity_type = (values.get("pool") or {}).get("capacityType", "on-demand")
        check(
            f"{rel}'s values.pool.capacityType is one of {sorted(allowed_capacity_types)} (issue #27)",
            capacity_type in allowed_capacity_types,
            f"got {capacity_type!r}",
        )
        if capacity_type == "reserved":
            tags = (values.get("reservation") or {}).get("tags")
            check(
                f"{rel} is a reserved pool and sets a non-empty values.reservation.tags (issue #27)",
                isinstance(tags, dict) and len(tags) >= 1 and all(str(k) and str(v) for k, v in tags.items()),
                f"got {tags!r}",
            )
            imc = (values.get("reservation") or {}).get("instanceMatchCriteria", "targeted")
            check(
                f"{rel}'s values.reservation.instanceMatchCriteria is 'targeted' (issue #27: never 'open' for a pool's own reservation)",
                imc == "targeted",
                f"got {imc!r}",
            )

    # A cell may carry more than one smoke queue (one per pool, as
    # 1.e2e.sh's issue #27 fixture does), so 'smoke-<suffix>' is accepted
    # alongside 'smoke'.
    for path in cell_smoke_files:
        rel = os.path.relpath(path, root)
        doc = check_addon_yaml(path, allow_dir=True)
        addon = str(doc.get("addon", ""))
        addons_by_cell.setdefault(os.path.dirname(os.path.dirname(path)), []).append((rel, addon))
        check(f"{rel}'s addon value is 'smoke' or 'smoke-<suffix>' (decision 2)", addon == "smoke" or addon.startswith("smoke-"))
        check(f"{rel}'s wave is one of {sorted(allowed_cells_waves)}", doc.get("wave") in allowed_cells_waves)

    # Decision 2: a generated Application is named {{name}}-{{addon}}, so two
    # parameter files of one cell with the same addon value would generate
    # two Applications with one name.
    for cell_dir, entries in sorted(addons_by_cell.items()):
        seen: dict[str, str] = {}
        dupes = []
        for rel, addon in entries:
            if addon in seen:
                dupes.append(f"{addon} ({seen[addon]}, {rel})")
            seen.setdefault(addon, rel)
        check(
            f"{os.path.relpath(cell_dir, root)}'s parameter files have unique addon values (decision 2: one Application name each)",
            not dupes,
            f"duplicates: {dupes}",
        )

    # ----------------------------------------------- ApplicationSet shape
    def check_applicationset(path: str, expected_steps: set[str]) -> dict:
        rel = os.path.relpath(path, root)
        doc = load_one(path)
        check(f"{rel} is kind ApplicationSet", doc.get("kind") == "ApplicationSet")
        spec = doc.get("spec", {})

        sync_policy = spec.get("syncPolicy", {}) or {}
        check(
            f"{rel} spec.syncPolicy.preserveResourcesOnDeletion is true (decision 8)",
            sync_policy.get("preserveResourcesOnDeletion") is True,
            f"got {sync_policy!r}",
        )

        generators = spec.get("generators", [])
        check(f"{rel} has at least one top-level generator", len(generators) >= 1)
        matrix_found = False
        for gen in generators:
            matrix = gen.get("matrix")
            if not matrix:
                continue
            matrix_found = True
            children = matrix.get("generators", [])
            check(f"{rel}'s matrix generator has exactly 2 children (Cluster, Git file) (decision 2)", len(children) == 2, f"got {len(children)}")
            cluster_children = [c for c in children if "clusters" in c]
            git_children = [c for c in children if "git" in c]
            check(f"{rel}'s matrix generator has one Cluster generator child", len(cluster_children) == 1)
            check(f"{rel}'s matrix generator has one Git generator child", len(git_children) == 1)
            if cluster_children:
                sel = cluster_children[0]["clusters"].get("selector", {}).get("matchLabels", {})
                check(
                    f"{rel}'s Cluster generator selects argocd.argoproj.io/secret-type: cluster (decision 2 -- excludes the built-in in-cluster entry)",
                    sel.get("argocd.argoproj.io/secret-type") == "cluster",
                    f"got matchLabels={sel!r}",
                )
            if git_children:
                git = git_children[0]["git"]
                check(f"{rel}'s Git generator has a 'files' list (a file generator, never a directory generator) (decisions 2/3)", bool(git.get("files")))
                revision = git.get("revision", "")
                check(
                    f"{rel}'s Git generator revision is templated from the Cluster generator's annotation, not a literal (decision 2)",
                    "{{" in str(revision) and "annotations" in str(revision) and "revision" in str(revision),
                    f"got revision={revision!r}",
                )
        check(f"{rel} has a Matrix generator (decision 2)", matrix_found)

        strategy = spec.get("strategy") or {}
        if strategy.get("type") == "RollingSync":
            steps = strategy.get("rollingSync", {}).get("steps", [])
            step_labels: set[str] = set()
            for step in steps:
                for m in step.get("matchExpressions", []):
                    if m.get("key") == "distai.dev/wave":
                        step_labels.update(m.get("values", []))
            check(
                f"{rel}'s RollingSync steps match the expected wave labels {sorted(expected_steps)} (decision 4)",
                step_labels == expected_steps,
                f"got {sorted(step_labels)}",
            )
        else:
            # Unconfirmed-by-fact branch (decision 4 / facts: RollingSync
            # availability on the managed capability is not confirmed as of
            # the issue's own read date). Falling back to retry-based
            # convergence is a valid outcome, not a failure of this check;
            # 1.e2e.sh's ordering experiment (acceptance criterion 4)
            # settles which branch a real capability is actually in.
            print(f"INFO {rel} has no strategy.type: RollingSync -- assuming the retry-based fallback branch of decision 4 (unconfirmed by the issue's own facts)")
        return doc

    check_applicationset(os.path.join(gitops, "appsets/platform.ApplicationSet.yaml"), {"crds", "controllers", "accelerators"})
    check_applicationset(os.path.join(gitops, "appsets/cells.ApplicationSet.yaml"), {"capacity"})

    # #28 Interface: "rollingSync.steps gains one step matching
    # distai.dev/wave In [accelerators], after controllers". The set check
    # above cannot see order; this one can.
    platform_appset_path = os.path.join(gitops, "appsets/platform.ApplicationSet.yaml")
    platform_appset = load_one(platform_appset_path)
    platform_strategy = (platform_appset.get("spec") or {}).get("strategy") or {}
    if platform_strategy.get("type") == "RollingSync":
        step_order: list[str] = []
        for step in (platform_strategy.get("rollingSync") or {}).get("steps", []) or []:
            for m in step.get("matchExpressions", []) or []:
                if m.get("key") == "distai.dev/wave":
                    step_order.extend(m.get("values", []) or [])
        check(
            "appsets/platform.ApplicationSet.yaml's 'accelerators' RollingSync step comes after 'controllers' (#28 Interface)",
            "accelerators" in step_order
            and "controllers" in step_order
            and step_order.index("accelerators") > step_order.index("controllers"),
            f"got step order {step_order!r}",
        )

    # #28 section B: accel-device-classes is the first *platform* add-on
    # delivered from a local dir instead of a registry chart. The platform
    # ApplicationSet's own template must therefore be able to emit a
    # path-sourced Application at all -- an addon.yaml with no 'chart' key
    # generating `chart: ""` would never sync. Checked on the raw text (the
    # template is a Go template, not data): it must reference .dir somewhere.
    with open(platform_appset_path, encoding="utf-8") as f:
        platform_appset_text = f.read()
    check(
        "appsets/platform.ApplicationSet.yaml's template references .dir (#28 section B: a local-dir platform add-on must be deliverable)",
        re.search(r"\{\{[^}]*\.dir\b", platform_appset_text) is not None,
        "no '{{ ... .dir ... }}' reference found; accel-device-classes/addon.yaml (dir, no chart) could not generate a working Application",
    )

    # --------------------------------------- accelerator add-ons (#28)
    #
    # Every expectation below is one row of issue #28's Interface table.
    # The method label's exact chart-values *path* differs per upstream
    # chart (NVIDIA: values.nodeSelector; Neuron: values.devicePlugin.* /
    # values.draDriver.*), so the label is found by walking the whole
    # values block, never by a hardcoded path. What is asserted is the
    # issue's core safety property at the one layer a static check reaches:
    # each release declares exactly one method label, for its own vendor,
    # with its own method as the value -- never both methods, never the
    # other vendor's label (#19 E1/E4: two advertisers for one device class
    # on one node silently double-allocate).
    def load_one_or_fail(path: str) -> dict | None:
        rel = os.path.relpath(path, root)
        if not os.path.isfile(path):
            check(f"{rel} exists", False)
            return None
        try:
            return load_one(path)
        except (ValueError, yaml.YAMLError) as e:
            check(f"{rel} parses as exactly one YAML document", False, str(e))
            return None

    def method_labels(node, path: str = "") -> list[tuple[str, str, str]]:
        """Every (path, label key, label value) for a distai.dev/*-method
        label anywhere under `node`: a nodeSelector-style mapping entry
        ({key: value}) or a nodeAffinity-style matchExpression
        ({key: ..., values: [...]})."""
        found: list[tuple[str, str, str]] = []
        if isinstance(node, dict):
            k_ = node.get("key")
            if isinstance(k_, str) and k_.startswith("distai.dev/") and k_.endswith("-method"):
                for v in node.get("values", []) or []:
                    found.append((path, k_, str(v)))
            for key, value in node.items():
                child = f"{path}.{key}" if path else str(key)
                if isinstance(key, str) and key.startswith("distai.dev/") and key.endswith("-method"):
                    found.append((path, key, str(value)))
                else:
                    found.extend(method_labels(value, child))
        elif isinstance(node, list):
            for i, item in enumerate(node):
                found.extend(method_labels(item, f"{path}[{i}]"))
        return found

    def find_key_anywhere(node, wanted: str) -> list:
        out = []
        if isinstance(node, dict):
            for key, value in node.items():
                if key == wanted:
                    out.append(value)
                out.extend(find_key_anywhere(value, wanted))
        elif isinstance(node, list):
            for item in node:
                out.extend(find_key_anywhere(item, wanted))
        return out

    def enabled_of(values: dict, component: str):
        sub = values.get(component)
        return sub.get("enabled") if isinstance(sub, dict) else None

    accel_registry_addons = {
        "accel-nvidia-device-plugin": {
            "chart": "nvidia-device-plugin",
            "repoURL": "https://nvidia.github.io/k8s-device-plugin",
            "version": "0.20.2",
            "namespace": "nvidia-device-plugin",
            "label": "distai.dev/nvidia-gpu-method",
            "method": "device-plugin",
        },
        "accel-nvidia-dra": {
            "chart": "dra-driver-nvidia-gpu",
            "repoURL": "registry.k8s.io/dra-driver-nvidia/charts",
            "version": "0.5.1",
            "namespace": "dra-driver-nvidia-gpu",
            "label": "distai.dev/nvidia-gpu-method",
            "method": "dra",
        },
        "accel-neuron-device-plugin": {
            "chart": "neuron-helm-chart",
            "repoURL": "public.ecr.aws/neuron",
            "version": "1.11.2",
            "namespace": "neuron-device-plugin",
            "label": "distai.dev/neuron-method",
            "method": "device-plugin",
        },
        "accel-neuron-dra": {
            "chart": "neuron-helm-chart",
            "repoURL": "public.ecr.aws/neuron",
            "version": "1.11.2",
            "namespace": "neuron-dra",
            "label": "distai.dev/neuron-method",
            "method": "dra",
        },
    }
    accel_docs: dict[str, dict] = {}
    for name, want in accel_registry_addons.items():
        path = os.path.join(gitops, "addons", name, "addon.yaml")
        rel = f"addons/{name}/addon.yaml"
        if load_one_or_fail(path) is None:
            continue
        doc = check_addon_yaml(path, allow_dir=False)
        accel_docs[name] = doc
        # The generated Application is "<cell>-<addon>" (#25 decision 2);
        # 1.e2e.sh waits on exactly "<cell>-accel-nvidia-device-plugin" and
        # "<cell>-accel-neuron-device-plugin", so addon must equal the
        # directory name.
        check(f"{rel}'s addon is {name!r} (#28 Interface; 1.e2e.sh waits on <cell>-{name})", doc.get("addon") == name, f"got {doc.get('addon')!r}")
        check(f"{rel} is in the 'accelerators' step (#28 Interface)", doc.get("wave") == "accelerators", f"got {doc.get('wave')!r}")
        for field in ("chart", "repoURL", "version", "namespace"):
            check(
                f"{rel}'s {field} is {want[field]!r} (#28 Interface)",
                str(doc.get(field)) == want[field],
                f"got {doc.get(field)!r}",
            )
        values = doc.get("values")
        check(f"{rel} has a non-empty 'values' block (#28 section A: the method-label nodeSelector lives there)", isinstance(values, dict) and bool(values))
        if not isinstance(values, dict):
            continue
        labels = method_labels(values)
        pairs = {(k_, v) for _, k_, v in labels}
        check(
            f"{rel}'s values declare exactly one method label, {want['label']}={want['method']} (#28 section A, #19 E1/E4: never two advertisers for one device class on one node)",
            pairs == {(want["label"], want["method"])},
            f"found {sorted(labels)!r}",
        )
        other_method = "dra" if want["method"] == "device-plugin" else "device-plugin"
        check(
            f"{rel}'s values never select {other_method!r} as a method value (#28 section A)",
            all(v != other_method for _, _, v in labels),
            f"found {sorted(labels)!r}",
        )
        check(
            f"{rel}'s method label sits under a nodeSelector/affinity key, where it actually restricts scheduling (#28 section A)",
            bool(labels) and all(("nodeSelector" in p or "affinity" in p.lower()) for p, _, _ in labels),
            f"found at paths {sorted({p for p, _, _ in labels})!r}",
        )
        # gpuResourcesEnabledOverride is the NVIDIA DRA chart's own flag
        # (#28 Facts checked: "the install does nothing without this flag").
        overrides = find_key_anywhere(values, "gpuResourcesEnabledOverride")
        if name == "accel-nvidia-dra":
            check(
                f"{rel} sets values.gpuResourcesEnabledOverride: true (#28 Facts checked/section A: whole-GPU allocation is off without it)",
                values.get("gpuResourcesEnabledOverride") is True,
                f"got {values.get('gpuResourcesEnabledOverride')!r}",
            )
        else:
            check(
                f"{rel} does not set gpuResourcesEnabledOverride (a key of the NVIDIA DRA chart only)",
                not overrides,
                f"found {overrides!r}",
            )

    # #28 Interface, Neuron's one-chart-two-releases split (#25 decision 5:
    # without it both releases run the same sub-components twice, colliding
    # on object names; Neuron docs: device plugin and DRA driver "cannot run
    # on the same node").
    ndp = (accel_docs.get("accel-neuron-device-plugin") or {}).get("values")
    if isinstance(ndp, dict):
        check(
            "addons/accel-neuron-device-plugin/addon.yaml sets draDriver.enabled: false (#28 Interface)",
            enabled_of(ndp, "draDriver") is False,
            f"got draDriver={ndp.get('draDriver')!r}",
        )
        check(
            "addons/accel-neuron-device-plugin/addon.yaml does not disable devicePlugin (#28 Interface)",
            enabled_of(ndp, "devicePlugin") is not False,
            f"got devicePlugin={ndp.get('devicePlugin')!r}",
        )
        for comp in ("scheduler", "npd", "observer"):
            check(
                f"addons/accel-neuron-device-plugin/addon.yaml keeps {comp} at the chart default (not disabled; #28 section A)",
                enabled_of(ndp, comp) is not False,
                f"got {comp}={ndp.get(comp)!r}",
            )
    ndra = (accel_docs.get("accel-neuron-dra") or {}).get("values")
    if isinstance(ndra, dict):
        check(
            "addons/accel-neuron-dra/addon.yaml sets draDriver.enabled: true (#28 Interface)",
            enabled_of(ndra, "draDriver") is True,
            f"got draDriver={ndra.get('draDriver')!r}",
        )
        check(
            "addons/accel-neuron-dra/addon.yaml sets devicePlugin.enabled: false (#28 Interface; Neuron DRA docs: never both on one cluster node)",
            enabled_of(ndra, "devicePlugin") is False,
            f"got devicePlugin={ndra.get('devicePlugin')!r}",
        )
        for comp in ("scheduler", "npd", "observer"):
            check(
                f"addons/accel-neuron-dra/addon.yaml sets {comp}.enabled: false (#28 Interface, #25 decision 5: no duplicate sub-components across the two releases)",
                enabled_of(ndra, comp) is False,
                f"got {comp}={ndra.get(comp)!r}",
            )
    ndp_doc = accel_docs.get("accel-neuron-device-plugin") or {}
    ndra_doc = accel_docs.get("accel-neuron-dra") or {}
    if ndp_doc and ndra_doc:
        check(
            "addons/accel-neuron-device-plugin and accel-neuron-dra pin the same chart and version (#28 Interface: 'same chart/version')",
            (ndp_doc.get("chart"), str(ndp_doc.get("version"))) == (ndra_doc.get("chart"), str(ndra_doc.get("version"))),
        )
        check(
            "addons/accel-neuron-device-plugin and accel-neuron-dra install into different namespaces (two releases of one chart)",
            ndp_doc.get("namespace") != ndra_doc.get("namespace"),
        )

    # valuesFrom shape (#25 decision 2) applies to the new add-ons as well.
    for name, doc in accel_docs.items():
        for entry in doc.get("valuesFrom") or []:
            check(
                f"addons/{name}/addon.yaml valuesFrom entry {entry.get('helmKey')!r} has exactly one of annotationKey/param (decision 2)",
                bool(entry.get("helmKey")) and (("annotationKey" in entry) != ("param" in entry)),
                f"got {entry!r}",
            )

    # ----------------------------- accel-device-classes add-on and chart (#28 B)
    adc_path = os.path.join(gitops, "addons/accel-device-classes/addon.yaml")
    if load_one_or_fail(adc_path) is not None:
        adc = check_addon_yaml(adc_path, allow_dir=True)
        check("addons/accel-device-classes/addon.yaml's addon is 'accel-device-classes' (#28 Interface)", adc.get("addon") == "accel-device-classes", f"got {adc.get('addon')!r}")
        check("addons/accel-device-classes/addon.yaml is in the 'accelerators' step (#28 Interface)", adc.get("wave") == "accelerators", f"got {adc.get('wave')!r}")
        check(
            "addons/accel-device-classes/addon.yaml's dir is gitops/charts/accel-device-classes (#28 Interface: a local chart)",
            "charts/accel-device-classes" in str(adc.get("dir", "")),
            f"got dir={adc.get('dir')!r}",
        )
        for k_ in ("chart", "repoURL", "version"):
            check(f"addons/accel-device-classes/addon.yaml has no '{k_}' (#28 Interface: never an upstream registry)", k_ not in adc)

    adc_templates = sorted(glob.glob(os.path.join(gitops, "charts/accel-device-classes/templates/*.yaml")))
    check(
        "charts/accel-device-classes/templates/ has at least one *.yaml (#28 Interface: templates/neuron-deviceclass.yaml)",
        len(adc_templates) >= 1,
        f"found {adc_templates!r}",
    )

    # Templates may carry Helm directives and are not necessarily standalone
    # YAML; a line holding only a directive is dropped and an inline one
    # replaced by a placeholder, which is enough to read the literal fields
    # the Interface fixes ("name and selector fixed, no cell-specific value
    # needed"). helm lint/template of the chart itself is 0.static.sh's.
    directive_only_line = re.compile(r"^\s*\{\{.*\}\}\s*$")
    inline_directive = re.compile(r"\{\{.*?\}\}")
    adc_docs: list[dict] = []
    adc_raw = ""
    for tpl in adc_templates:
        with open(tpl, encoding="utf-8") as f:
            raw = f.read()
        adc_raw += raw
        cleaned = "\n".join(
            inline_directive.sub("helm-directive-placeholder", line)
            for line in raw.splitlines()
            if not directive_only_line.match(line)
        )
        try:
            adc_docs.extend(d for d in yaml.safe_load_all(cleaned) if d is not None)
        except yaml.YAMLError as e:
            check(f"{os.path.relpath(tpl, root)} is readable as YAML once Helm directives are masked", False, str(e))
    if adc_templates:
        check(
            "charts/accel-device-classes renders exactly one object (#28 Interface: 'one DeviceClass')",
            len(adc_docs) == 1,
            f"found {len(adc_docs)}: {[d.get('kind') for d in adc_docs]!r}",
        )
        dc = adc_docs[0] if len(adc_docs) == 1 else {}
        check("charts/accel-device-classes' object is kind DeviceClass (#28 section B)", dc.get("kind") == "DeviceClass", f"got {dc.get('kind')!r}")
        check(
            "charts/accel-device-classes' DeviceClass is named neuron-extended-resource (#28 section B)",
            (dc.get("metadata") or {}).get("name") == "neuron-extended-resource",
            f"got {(dc.get('metadata') or {}).get('name')!r}",
        )
        check(
            "charts/accel-device-classes' DeviceClass sets spec.extendedResourceName: aws.amazon.com/neuron (#28 section B, #19 E4b)",
            (dc.get("spec") or {}).get("extendedResourceName") == "aws.amazon.com/neuron",
            f"got {(dc.get('spec') or {}).get('extendedResourceName')!r}",
        )
        selector_text = yaml.safe_dump((dc.get("spec") or {}).get("selectors") or [])
        check(
            "charts/accel-device-classes' DeviceClass selects device.driver == \"neuron.aws.com\" (#28 section B)",
            "neuron.aws.com" in adc_raw and "device.driver" in selector_text and "neuron.aws.com" in selector_text,
            f"spec.selectors={selector_text.strip()!r}",
        )

    # ---------------------------------------- capacity-pool pool.labels (#28 C)
    cp_values_path = os.path.join(gitops, "charts/capacity-pool/values.yaml")
    cp_values = load_one_or_fail(cp_values_path) or {}
    cp_pool = cp_values.get("pool") if isinstance(cp_values, dict) else None
    check(
        "charts/capacity-pool/values.yaml declares pool.labels (#28 section C; its default value is the chart's choice)",
        isinstance(cp_pool, dict) and "labels" in cp_pool,
        f"pool keys: {sorted(cp_pool) if isinstance(cp_pool, dict) else cp_pool!r}",
    )
    cp_nodepool_tpl = os.path.join(gitops, "charts/capacity-pool/templates/nodepool.yaml")
    if os.path.isfile(cp_nodepool_tpl):
        with open(cp_nodepool_tpl, encoding="utf-8") as f:
            nodepool_tpl_text = f.read()
        check(
            "charts/capacity-pool/templates/nodepool.yaml reads .Values.pool.labels (#28 section C: rendered as spec.template.metadata.labels)",
            ".Values.pool.labels" in nodepool_tpl_text,
        )

    # ------------------------------------ light-tier accelerator cells (#28 D)
    #
    # The two real cells 1.e2e.sh (GITOPS_RUN_ACCEL_E2E=1) and the
    # real-machine verification launch nodes from. Their names and label
    # values must be exact, not just present: 1.e2e.sh runs with
    # NAME=dp-a19-gpu-r3 and ACCEL_TRN_CELL_NAME=dp-a19-trn-r3, and
    # cells.ApplicationSet reads gitops/cells/<that name>/.
    #
    # Exactly one capacity-pool file per accelerator cell: 1.e2e.sh's
    # existing step 10 (which runs unchanged on the GPU cell) asserts
    # exactly one NodePool/EC2NodeClass/ResourceFlavor in the cell.
    accel_cells = {
        "dp-a19-gpu-r3": {"pool": "gpu", "label": "distai.dev/nvidia-gpu-method", "family": "g7"},
        "dp-a19-trn-r3": {"pool": "trn", "label": "distai.dev/neuron-method", "family": "trn2"},
    }
    for cell, want in accel_cells.items():
        files = sorted(glob.glob(os.path.join(gitops, "cells", cell, "capacity-pool", "*.yaml")))
        check(
            f"cells/{cell}/capacity-pool/ has exactly one parameter file (#28 section D; 1.e2e.sh step 10 expects one NodePool per cell)",
            len(files) == 1,
            f"found {[os.path.relpath(p, root) for p in files]!r}",
        )
        for path in files:
            rel = os.path.relpath(path, root)
            doc = load_one_or_fail(path) or {}
            pool = ((doc.get("values") or {}).get("pool") or {}) if isinstance(doc, dict) else {}
            check(f"{rel}'s pool.name is {want['pool']!r} (#28 section D)", pool.get("name") == want["pool"], f"got {pool.get('name')!r}")
            check(
                f"{rel}'s pool.labels is exactly {{{want['label']}: device-plugin}} (#28 section D: device-plugin method, never DRA, one key per device class)",
                pool.get("labels") == {want["label"]: "device-plugin"},
                f"got {pool.get('labels')!r}",
            )
            reqs = {r.get("key"): r for r in (pool.get("requirements") or []) if isinstance(r, dict)}
            family = reqs.get("karpenter.k8s.aws/instance-family") or {}
            check(
                f"{rel}'s pool.requirements allow instance-family {want['family']} (#28 section D/acceptance criteria)",
                family.get("operator") == "In" and want["family"] in (family.get("values") or []),
                f"got {family!r}",
            )
            ctype = reqs.get("karpenter.sh/capacity-type") or {}
            check(
                f"{rel}'s pool.requirements allow capacity-type spot only, no on-demand fallback (#28 acceptance criteria 2/3 name a real spot node; 1.e2e.sh's check_accel_layer1 asserts the launched node's own capacity-type label, which an on-demand fallback could silently fail)",
                ctype.get("operator") == "In" and (ctype.get("values") or []) == ["spot"],
                f"got {ctype!r}",
            )

    # The GPU cell also runs 1.e2e.sh's existing steps 8-11 unchanged
    # (NAME=dp-a19-gpu-r3): they need one smoke LocalQueue, whose
    # ClusterQueue must name that cell's own (only) ResourceFlavor.
    gpu_smoke = sorted(glob.glob(os.path.join(gitops, "cells", "dp-a19-gpu-r3", "smoke", "*.yaml")))
    check(
        "cells/dp-a19-gpu-r3/smoke/ has exactly one parameter file (1.e2e.sh steps 8-11 run on this cell when GITOPS_RUN_ACCEL_E2E=1)",
        len(gpu_smoke) == 1,
        f"found {[os.path.relpath(p, root) for p in gpu_smoke]!r}",
    )
    for path in gpu_smoke:
        doc = load_one_or_fail(path) or {}
        flavor = (((doc.get("values") or {}).get("clusterQueue") or {}).get("resourceFlavor")) if isinstance(doc, dict) else None
        check(
            f"{os.path.relpath(path, root)}'s clusterQueue.resourceFlavor names the cell's own pool 'gpu'",
            flavor == accel_cells["dp-a19-gpu-r3"]["pool"],
            f"got {flavor!r}",
        )

    # ----------------------------------------------------- root Application
    root_app_path = os.path.join(gitops, "bootstrap/root-application.yaml")
    root_app = load_one(root_app_path)
    check("bootstrap/root-application.yaml is kind Application", root_app.get("kind") == "Application")
    finalizers = root_app.get("metadata", {}).get("finalizers", [])
    check(
        "bootstrap/root-application.yaml carries the cascade finalizer (decision 8 -- it is never generated by an ApplicationSet, so nothing else adds one)",
        "resources-finalizer.argocd.argoproj.io" in finalizers,
        f"got {finalizers!r}",
    )
    root_spec = root_app.get("spec", {})
    check("bootstrap/root-application.yaml's spec.project is 'platform' (decision 1)", root_spec.get("project") == "platform")
    source = root_spec.get("source", {})
    check(
        "bootstrap/root-application.yaml's source path is gitops/appsets/ (decision 1)",
        str(source.get("path", "")).rstrip("/").endswith("gitops/appsets") or str(source.get("path", "")).rstrip("/") == "appsets",
        f"got source={source!r}",
    )

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all gitops contract checks passed")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_gitops_contract.py <repo-root>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
