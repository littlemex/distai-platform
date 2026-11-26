#!/usr/bin/env python3
"""Cross-check every `pool.startupTaints` entry a cell actually ships against
the one key `vigil-controller` is configured to watch (issue #96).

Root cause this closes: `capacity-pool`'s chart stays generic on purpose --
it renders whatever `pool.startupTaints` it is given, and does not know
`vigil-controller` exists at all (the chart-level design decision recorded
on issue #96). That genericity has a real failure mode nothing else in this
repository catches: a `pool.startupTaints` entry whose `key` is not the key
`gitops/addons/vigil-controller/addon.yaml`'s own `values.config.taintKey`
names is a taint no controller in this platform ever removes -- not even at
a timeout, since `vigil-controller` only acts on the one key it is
configured with. Karpenter's own NodePools documentation calls this out
directly ("Karpenter assumes that the taint is temporary and some other
system will remove the taint"): a startup taint with no real remover wedges
every node that pool ever launches, permanently, with no automatic recovery
-- not a race any real run would show until a different key is actually
used. This is a render-time, cross-file check precisely because `helm
template` on either file alone cannot see the other file at all.

Checked, for every `gitops/cells/*/capacity-pool/*.yaml`:
  - every `pool.startupTaints[].key` equals `vigil-controller`'s own
    `values.config.taintKey`;
  - every `pool.startupTaints[].effect` equals `vigil-controller`'s own
    `values.config.taintEffect`;
  - `vigil-controller`'s own `values.config.knownStartupTaintKeys` contains
    that same key (the chart's own config.example.yaml: "Must include
    taintKey itself" -- a cell could ship a value that drops it).

Usage: check_startup_taint_keys.py <repo_root>
Prints one PASS/FAIL line per check; exits 1 if any failed.
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


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def main(repo_root: str) -> int:
    vigil_path = os.path.join(repo_root, "gitops/addons/vigil-controller/addon.yaml")
    if not os.path.isfile(vigil_path):
        check("gitops/addons/vigil-controller/addon.yaml exists", False, "not found")
        return 1
    vigil = load(vigil_path)
    vigil_config = ((vigil.get("values") or {}).get("config")) or {}
    taint_key = vigil_config.get("taintKey")
    taint_effect = vigil_config.get("taintEffect")
    known_keys = vigil_config.get("knownStartupTaintKeys") or []
    check("vigil-controller's values.config.taintKey is set", bool(taint_key), f"got {taint_key!r}")
    check("vigil-controller's values.config.taintEffect is set", bool(taint_effect), f"got {taint_effect!r}")
    check(
        "vigil-controller's values.config.knownStartupTaintKeys contains its own taintKey",
        taint_key in known_keys,
        f"taintKey={taint_key!r} knownStartupTaintKeys={known_keys!r}",
    )
    if not (taint_key and taint_effect):
        return 1 if FAILURES else 0

    cell_files = sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/capacity-pool/*.yaml")))
    checked_any_startup_taint = False
    for path in cell_files:
        rel = os.path.relpath(path, repo_root)
        doc = load(path)
        startup_taints = ((doc.get("values") or {}).get("pool") or {}).get("startupTaints") or []
        for i, t in enumerate(startup_taints):
            checked_any_startup_taint = True
            key = t.get("key")
            effect = t.get("effect")
            check(
                f"{rel}'s pool.startupTaints[{i}].key ({key!r}) matches vigil-controller's taintKey ({taint_key!r})",
                key == taint_key,
                f"got key={key!r}, vigil-controller watches {taint_key!r} -- this taint would never be removed",
            )
            check(
                f"{rel}'s pool.startupTaints[{i}].effect ({effect!r}) matches vigil-controller's taintEffect ({taint_effect!r})",
                effect == taint_effect,
                f"got effect={effect!r}, vigil-controller watches effect {taint_effect!r} -- this taint would never be removed",
            )
    if not checked_any_startup_taint:
        print("INFO no gitops/cells/*/capacity-pool/*.yaml sets pool.startupTaints yet (the mechanism ships opt-in, issue #96)")

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all startup-taint-key checks passed")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_startup_taint_keys.py <repo_root>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
