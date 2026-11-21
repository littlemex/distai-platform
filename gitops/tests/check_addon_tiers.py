#!/usr/bin/env python3
"""Tier and naming checks for gitops/addons/ and gitops/addon-catalog/
(issue #41, Decision 2). Static, content-only, no cluster and no network.

Decision 2 keeps the three tiers apart by directory, and this script is
what makes that split hold:

  1. every gitops/addons/*/addon.yaml declares `tier: core` -- the
     directory platform.ApplicationSet.yaml delivers to every cell
     unconditionally, so nothing else may live there;
  2. every gitops/addon-catalog/*/addon.yaml declares `tier:
     platform-optional` or `tier: workload` -- never `core` (reserved for
     gitops/addons/), never left unstated;
  3. naming rule (i): for every gitops/addons/<X>/addon.yaml and every
     gitops/addon-catalog/<X>/addon.yaml whose tier is platform-optional,
     the directory name X equals that file's own `addon:` field (a
     `tier: workload` catalog entry carries no `addon` field, so the rule
     does not apply to it);
  4. naming rule (ii): no directory name X exists under both
     gitops/addons/ and gitops/addon-catalog/ (every tier, including a
     workload entry with no `addon` field).

Rules (i) and (ii) are what make check_addon_catalog_sync.py's two-step
`dependsOn` lookup unambiguous, and keep the shared
"{{ .name }}-{{ .addon }}" Application name template collision-free
between a core and a platform-optional component.

Nothing here names a particular add-on: the script applies the same
rules to whatever directories exist.

Run with a pinned PyYAML, e.g.:
    uv run --no-project -q --with pyyaml==6.0.2 python3 check_addon_tiers.py <repo-root>

Prints one "PASS <label>" or "FAIL <label>: <reason>" line per check and
exits 1 if any check failed, 0 otherwise -- the same contract
check_gitops_contract.py and 0.static.sh's run_check() use.
"""
from __future__ import annotations

import os
import sys

import yaml

FAILURES: list[str] = []

CORE_TIER = "core"
CATALOG_TIERS = ("platform-optional", "workload")


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def load_one(path: str, rel: str) -> dict | None:
    """The one YAML document in path, or None (after recording a FAIL)
    if the file does not parse to exactly one mapping."""
    try:
        with open(path, encoding="utf-8") as f:
            docs = [d for d in yaml.safe_load_all(f) if d is not None]
    except (OSError, yaml.YAMLError) as e:
        check(f"{rel} parses as YAML", False, str(e))
        return None
    if len(docs) != 1 or not isinstance(docs[0], dict):
        check(f"{rel} is exactly one YAML mapping", False, f"found {len(docs)} document(s)")
        return None
    return docs[0]


def subdirs(path: str) -> list[str]:
    if not os.path.isdir(path):
        return []
    return sorted(d for d in os.listdir(path) if os.path.isdir(os.path.join(path, d)))


def main(root: str) -> int:
    gitops = os.path.join(root, "gitops")
    addons_root = os.path.join(gitops, "addons")
    catalog_root = os.path.join(gitops, "addon-catalog")

    addon_dirs = subdirs(addons_root)
    catalog_dirs = subdirs(catalog_root)
    check("gitops/addons/ has at least one add-on directory", len(addon_dirs) >= 1, f"found: {addon_dirs}")

    # ------------------------------------------- 1. gitops/addons/: core
    for name in addon_dirs:
        path = os.path.join(addons_root, name, "addon.yaml")
        rel = os.path.relpath(path, root)
        if not os.path.isfile(path):
            check(f"{rel} exists (every gitops/addons/<X>/ directory carries one addon.yaml)", False)
            continue
        doc = load_one(path, rel)
        if doc is None:
            continue
        tier = doc.get("tier")
        check(
            f"{rel} declares tier: {CORE_TIER} (issue #41 Decision 2 -- gitops/addons/ is delivered to every cell unconditionally)",
            tier == CORE_TIER,
            f"got tier={tier!r}",
        )
        # 3. naming rule (i), core side.
        addon = doc.get("addon")
        check(
            f"{rel}'s directory name equals its own addon: field (issue #41 Decision 2, naming rule (i))",
            addon == name,
            f"directory {name!r}, addon={addon!r}",
        )

    # ----------------------------------- 2. gitops/addon-catalog/: optional
    for name in catalog_dirs:
        path = os.path.join(catalog_root, name, "addon.yaml")
        rel = os.path.relpath(path, root)
        if not os.path.isfile(path):
            check(f"{rel} exists (every gitops/addon-catalog/<X>/ directory carries one addon.yaml)", False)
            continue
        doc = load_one(path, rel)
        if doc is None:
            continue
        tier = doc.get("tier")
        check(
            f"{rel} declares tier: platform-optional or workload (issue #41 Decision 2 -- never core, never unstated)",
            tier in CATALOG_TIERS,
            f"got tier={tier!r}",
        )
        # 3. naming rule (i), catalog side: platform-optional only. A
        # workload entry carries no addon field (Decision 2/3), so the
        # rule has nothing to compare for it.
        if tier == "platform-optional":
            addon = doc.get("addon")
            check(
                f"{rel}'s directory name equals its own addon: field (issue #41 Decision 2, naming rule (i))",
                addon == name,
                f"directory {name!r}, addon={addon!r}",
            )

    # ------------------------------------------------ 4. naming rule (ii)
    both = sorted(set(addon_dirs) & set(catalog_dirs))
    check(
        "no directory name exists under both gitops/addons/ and gitops/addon-catalog/ (issue #41 Decision 2, naming rule (ii))",
        not both,
        f"in both: {both}",
    )

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all add-on tier checks passed")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_addon_tiers.py <repo-root>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
