#!/usr/bin/env python3
"""Structural checks for the gitops/ delivery layer (issue #25) that do not
need a cluster: the shape of the ApplicationSets, the root Application, and
every add-on/cell parameter file, against the decisions in the issue body.

This is a static, content-only check. It knows nothing about whether Argo CD
would actually accept these objects (that needs `1.e2e.sh`) and nothing
about the implementation that produced them -- every assertion below is
traceable to one decision in
https://github.com/littlemex/distai-platform/issues/25.

Run with a pinned PyYAML, e.g.:
    uv run --no-project -q --with pyyaml==6.0.2 python3 check_gitops_contract.py <repo-root>

Prints one "PASS <label>" or "FAIL <label>: <reason>" line per check and
exits 1 if any check failed, 0 otherwise -- the same contract 0.static.sh's
other checks use via run_check().
"""
from __future__ import annotations

import glob
import os
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
    # Decision 3's layout, scoped to Decision 9's first-PR content: no
    # accelerators/, no teams/* yet.
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
    # exact, hand-typed set of directory names instead; this PR (#41,
    # adding optional-pool) and #28/#40's chain each extended their own
    # copy of that literal for their own addons, so the merged tree's real
    # addon count matched neither copy and the check failed regardless of
    # which PR landed second (#63, filed as #55). This directory-shape
    # check is derived from the filesystem, like sourceRepos already is in
    # bootstrap.sh, and needs no further edit as addons/ grows; the three
    # addon.yaml files RFC #25's own Decisions discuss by name are still
    # checked explicitly below, independent of this generic shape check.
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
    for path in cell_capacity_pool_files:
        rel = os.path.relpath(path, root)
        doc = check_addon_yaml(path, allow_dir=True)
        check(f"{rel}'s addon value is 'capacity-pool-<pool>' (decision 2)", str(doc.get("addon", "")).startswith("capacity-pool-"))
        check(f"{rel}'s wave is one of {sorted(allowed_cells_waves)}", doc.get("wave") in allowed_cells_waves)
        if "dir" in doc:
            check(f"{rel}'s dir points under gitops/charts/", str(doc["dir"]).rstrip("/").endswith("charts/capacity-pool") or "charts/capacity-pool" in str(doc["dir"]))

    for path in cell_smoke_files:
        rel = os.path.relpath(path, root)
        doc = check_addon_yaml(path, allow_dir=True)
        check(f"{rel}'s addon value is 'smoke' (decision 2)", doc.get("addon") == "smoke")
        check(f"{rel}'s wave is one of {sorted(allowed_cells_waves)}", doc.get("wave") in allowed_cells_waves)

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

    check_applicationset(os.path.join(gitops, "appsets/platform.ApplicationSet.yaml"), {"crds", "controllers"})
    check_applicationset(os.path.join(gitops, "appsets/cells.ApplicationSet.yaml"), {"capacity"})
    check_applicationset(
        os.path.join(gitops, "appsets/addons-optional.ApplicationSet.yaml"),
        {"optional-1", "optional-2", "optional-3", "optional-4"},
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
