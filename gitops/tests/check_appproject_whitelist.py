#!/usr/bin/env python3
"""Cross-check the platform AppProject's own scoping (destinations and
clusterResourceWhitelist/namespaceResourceWhitelist) against every object
this checkout's own addons and cells actually render -- the mechanical
check gitops/bootstrap/appproject-whitelist.yaml's own header comment
promises (#63, independent security-axis review pass, filed as "SA1"
item 1).

For every gitops/addons/<name>/addon.yaml, gitops/addon-catalog/<name>/
addon.yaml, and gitops/cells/*/{capacity-pool,smoke}/*.yaml, `helm
template` it (registry chart or local `dir:`, matching what Argo CD
itself does) with that file's own `values:` merged with `valuesFrom`'s
own helmKey paths filled by an inert placeholder (the same technique
check_pinned_crds.py's own placeholder_values() uses, imported from
there rather than duplicated), and check every rendered object two ways:

  1. its (apiVersion's group, kind) pair appears in appproject-whitelist.yaml
     (either list - this check does not itself tell Namespaced from
     Cluster-scoped kinds; appproject-whitelist.yaml puts each pair under
     the one list it belongs to).
  2. if the object is namespaced (has a metadata.namespace), that
     namespace is one bootstrap.sh's own destinations.namespace
     computation would actually include - EXPECTED_NAMESPACES below
     mirrors that computation (every addon.yaml/addon-catalog/cells file's
     own namespace: field, plus kube-system unconditionally - see that
     script's own comment for why kube-system is unconditional). This is
     a second, independent implementation of the same rule stated in
     prose, not an import of bootstrap.sh's bash - if the two drift, this
     check and bootstrap.sh's own behavior can disagree silently; keep
     them in sync by hand.

A pair or a namespace missing from the project's own scope fails this
check -- it would otherwise reach a real cluster only to have Argo CD
refuse to sync it, a failure mode this check moves to CI. This check
also separately warns (not fails) about a whitelist entry never actually
rendered by anything (catching a stale, no-longer-needed grant) -- a
warning, not a failure, since removing an unused grant is a judgement
call this script should surface, not force.

Usage: check_appproject_whitelist.py <repo_root>
"""
from __future__ import annotations

import glob
import os
import subprocess
import sys
import tempfile

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_pinned_crds import helm_template_chart, placeholder_values  # noqa: E402

FAILURES: list[str] = []
ALWAYS_ALLOWED_NAMESPACES = {"kube-system"}


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def render_addon(path: str, workdir: str, repo_root: str) -> str | None:
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    rel = os.path.relpath(path, repo_root)
    name = doc.get("addon", os.path.basename(os.path.dirname(path)))
    namespace = doc.get("namespace") or "default"

    if "chart" in doc:
        # Registry chart: reuse check_pinned_crds.py's own helper
        # verbatim, rather than a second copy of its OCI-vs-classic-repo
        # and placeholder-values handling (both already fixed there once,
        # #28 - accel-nvidia-device-plugin/accel-nvidia-dra's classic
        # Helm repo and "default namespace" guard). Pass this addon's own
        # declared namespace through explicitly (#63): helm_template_chart's
        # original caller (check_pinned_crds.py) never needed one, since a
        # CustomResourceDefinition is cluster-scoped, so it left
        # `.Release.Namespace` unset -- which Helm itself then resolves to
        # literal "default", not this addon's own namespace. Every
        # namespaced object a chart like karpenter/kueue renders via
        # `{{ .Release.Namespace }}` was therefore rendering into "default"
        # here, a false FAIL this check's own namespace comparison produced
        # (caught by this file's own first real run, not assumed).
        rendered = helm_template_chart(doc, workdir, namespace=namespace)
        if rendered is None:
            FAILURES.append(f"FAIL helm template {rel}")
        return rendered

    if "dir" in doc:
        chart_ref = os.path.join(repo_root, doc["dir"])
        subprocess.run(["helm", "dependency", "build", chart_ref], capture_output=True, text=True, timeout=120)
        cmd = ["helm", "template", f"{name}-whitelist-check", chart_ref, "-n", namespace, "--create-namespace"]
        values = placeholder_values(doc)
        values_path = None
        if values:
            values_path = os.path.join(workdir, f"{name}-values.yaml")
            with open(values_path, "w", encoding="utf-8") as f:
                yaml.safe_dump(values, f)
            cmd += ["-f", values_path]
        proc = subprocess.run(cmd, cwd=workdir, capture_output=True, text=True, timeout=300)
        if proc.returncode != 0:
            print(f"FAIL helm template {rel}: {proc.stderr.strip()[-500:]}")
            FAILURES.append(f"FAIL helm template {rel}")
            return None
        return proc.stdout

    print(f"FAIL {rel}: has neither 'chart' nor 'dir'")
    FAILURES.append(f"FAIL {rel}")
    return None


def declared_namespace(path: str) -> str | None:
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    return doc.get("namespace")


def main(root: str) -> int:
    gitops = os.path.join(root, "gitops")
    whitelist_path = os.path.join(gitops, "bootstrap", "appproject-whitelist.yaml")
    with open(whitelist_path, encoding="utf-8") as f:
        whitelist = yaml.safe_load(f) or {}
    allowed_kinds = {
        (entry.get("group") or "", entry["kind"])
        for key in ("clusterResourceWhitelist", "namespaceResourceWhitelist")
        for entry in whitelist.get(key, [])
    }

    addon_files = sorted(glob.glob(os.path.join(gitops, "addons", "*", "addon.yaml")))
    catalog_files = sorted(glob.glob(os.path.join(gitops, "addon-catalog", "*", "addon.yaml")))
    cell_files = sorted(
        glob.glob(os.path.join(gitops, "cells", "*", "capacity-pool", "*.yaml"))
        + glob.glob(os.path.join(gitops, "cells", "*", "smoke", "*.yaml"))
    )
    all_files = addon_files + catalog_files + cell_files
    check(f"found at least one addon.yaml/cells parameter file to check (found {len(all_files)})", len(all_files) >= 1)

    allowed_namespaces = set(ALWAYS_ALLOWED_NAMESPACES)
    for path in all_files:
        ns = declared_namespace(path)
        if ns:
            allowed_namespaces.add(ns)

    seen_kinds: set[tuple[str, str]] = set()
    with tempfile.TemporaryDirectory() as workdir:
        for path in all_files:
            rel = os.path.relpath(path, root)
            rendered = render_addon(path, workdir, root)
            if rendered is None:
                continue
            found_here: set[tuple[str, str]] = set()
            bad_namespaces: set[str] = set()
            for doc in yaml.safe_load_all(rendered):
                if not doc or "kind" not in doc:
                    continue
                api_version = doc.get("apiVersion", "")
                group = api_version.split("/", 1)[0] if "/" in api_version else ""
                found_here.add((group, doc["kind"]))
                ns = (doc.get("metadata") or {}).get("namespace")
                if ns and ns not in allowed_namespaces:
                    bad_namespaces.add(ns)
            seen_kinds |= found_here
            missing = found_here - allowed_kinds
            check(
                f"{rel}'s own rendered (group, kind) pairs are all in appproject-whitelist.yaml",
                not missing,
                f"missing: {sorted(missing)}",
            )
            check(
                f"{rel}'s own rendered objects all land in a namespace bootstrap.sh's destinations would include",
                not bad_namespaces,
                f"rendered into namespace(s) not in the expected destination set {sorted(allowed_namespaces)}: {sorted(bad_namespaces)}",
            )

    unused = allowed_kinds - seen_kinds
    if unused:
        print(f"WARN appproject-whitelist.yaml has {len(unused)} entrie(s) no rendered addon/cell file actually uses: {sorted(unused)}")

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <repo_root>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
