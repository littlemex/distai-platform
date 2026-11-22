#!/usr/bin/env python3
"""Cross-check the platform AppProject's own clusterResourceWhitelist/
namespaceResourceWhitelist (gitops/bootstrap/appproject-whitelist.yaml)
against every (group, kind) pair this checkout's own addons actually
render -- the mechanical check gitops/bootstrap/appproject-whitelist.yaml's
own header comment promises (#63, independent security-axis review pass,
filed as "SA1" item 1).

For every gitops/addons/<name>/addon.yaml and gitops/addon-catalog/<name>/
addon.yaml, `helm template` it (registry chart or local `dir:`, matching
what Argo CD itself does) with that addon.yaml's own `values:` merged with
`valuesFrom`'s own helmKey paths filled by an inert placeholder (the same
technique check_pinned_crds.py's own placeholder_values() uses, imported
from there rather than duplicated), and record every (apiVersion's group,
kind) pair found. A pair missing from appproject-whitelist.yaml fails this
check -- it would otherwise reach a real cluster only to have Argo CD
refuse to sync it, a failure mode this check moves to CI.

What this intentionally does not do: tell Namespaced from Cluster-scoped
kinds. appproject-whitelist.yaml puts each pair under the one list it
belongs to; this check only asserts rendered pairs appear *somewhere* in
the union of both lists (catching a missing entry), and separately warns
(not fails) about an entry present in the whitelist but never actually
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


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def render_addon(path: str, workdir: str) -> str | None:
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    rel = os.path.relpath(path)
    name = doc.get("addon", os.path.basename(os.path.dirname(path)))
    namespace = doc.get("namespace") or "default"

    if "chart" in doc:
        # Registry chart: reuse check_pinned_crds.py's own helper
        # verbatim, rather than a second copy of its OCI-vs-classic-repo
        # and placeholder-values handling (both already fixed there once,
        # #28 - accel-nvidia-device-plugin/accel-nvidia-dra's classic
        # Helm repo and "default namespace" guard).
        rendered = helm_template_chart(doc, workdir)
        if rendered is None:
            FAILURES.append(f"FAIL helm template {rel}")
        return rendered

    if "dir" in doc:
        # dir: is rooted at the repo root itself (e.g. "gitops/charts/
        # optional-pool"); path is .../gitops/addons/<name>/addon.yaml, so
        # three dirname()s up from it is the repo root.
        repo_root = os.path.abspath(os.path.join(os.path.dirname(path), "..", "..", ".."))
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


def main(root: str) -> int:
    gitops = os.path.join(root, "gitops")
    whitelist_path = os.path.join(gitops, "bootstrap", "appproject-whitelist.yaml")
    with open(whitelist_path, encoding="utf-8") as f:
        whitelist = yaml.safe_load(f) or {}
    allowed = {
        (entry.get("group") or "", entry["kind"])
        for key in ("clusterResourceWhitelist", "namespaceResourceWhitelist")
        for entry in whitelist.get(key, [])
    }

    addon_files = sorted(
        glob.glob(os.path.join(gitops, "addons", "*", "addon.yaml"))
        + glob.glob(os.path.join(gitops, "addon-catalog", "*", "addon.yaml"))
    )
    check(f"found at least one addon.yaml to check (found {len(addon_files)})", len(addon_files) >= 1)

    seen: set[tuple[str, str]] = set()
    with tempfile.TemporaryDirectory() as workdir:
        for path in addon_files:
            rel = os.path.relpath(path, root)
            rendered = render_addon(path, workdir)
            if rendered is None:
                continue
            found_here: set[tuple[str, str]] = set()
            for doc in yaml.safe_load_all(rendered):
                if not doc or "kind" not in doc:
                    continue
                api_version = doc.get("apiVersion", "")
                group = api_version.split("/", 1)[0] if "/" in api_version else ""
                found_here.add((group, doc["kind"]))
            seen |= found_here
            missing = found_here - allowed
            check(
                f"{rel}'s own rendered (group, kind) pairs are all in appproject-whitelist.yaml",
                not missing,
                f"missing: {sorted(missing)}",
            )

    unused = allowed - seen
    if unused:
        print(f"WARN appproject-whitelist.yaml has {len(unused)} entrie(s) no rendered addon actually uses: {sorted(unused)}")

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
