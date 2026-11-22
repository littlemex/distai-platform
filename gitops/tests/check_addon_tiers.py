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
        # A core addon.yaml is either a registry chart (chart/repoURL/
        # version) or a local dir (optional-pool), never both at once --
        # platform.ApplicationSet.yaml's own {{- if .dir }} branch picks
        # one source shape or the other, so a file carrying both would
        # render a chart source with a dangling, unused dir value, never
        # the local chart it also names.
        # allowEmpty (RFC #41 Decision 4 Finding 1) is an escape hatch
        # from Argo CD's own safety mechanism against pruning an
        # Application to zero resources by accident -- platform.
        # ApplicationSet.yaml's own templatePatch renders it only when
        # this key is present, never from its own shared base template
        # (the regression this check exists to catch: that field going
        # back into the shared template would quietly remove the safety
        # net for every core addon, not just the one that asked for it).
        # A quoted "true" string is also wrong here, not just absent: Go
        # templates render `{{- if "true" }}` as truthy too (a non-empty
        # string), so a YAML string would still enable the branch while
        # looking like a careless copy-paste rather than a reviewed
        # boolean.
        if "allowEmpty" in doc:
            check(
                f"{rel}'s allowEmpty is the boolean true, not a string or false (issue #41 Decision 4 Finding 1 -- an intentional, reviewed escape hatch, not a stray value)",
                doc.get("allowEmpty") is True,
                f"got allowEmpty={doc.get('allowEmpty')!r} ({type(doc.get('allowEmpty')).__name__})",
            )
            print(f"INFO {rel} declares allowEmpty: true -- review why this one core addon may legitimately render empty")
        check(
            f"{rel} has 'dir' or 'chart', never both",
            ("dir" in doc) != ("chart" in doc),
            f"dir={'dir' in doc} chart={'chart' in doc}",
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


# ------------------------------------------------------------- selftest
#
# A check that has only ever been seen green is not
# trusted to actually fail on the thing it claims to catch. Each case
# below builds a minimal, otherwise-valid fixture, breaks exactly one
# rule, and asserts that the resulting FAILURES mention that rule's own
# label substring and nothing else that was not already expected to
# differ (every case starts from a byte-identical baseline that itself
# passes with zero failures, so this also proves the baseline is clean).


def _write(root: str, rel: str, doc: dict) -> None:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f)


def _baseline(root: str) -> None:
    _write(root, "gitops/addons/good/addon.yaml", {"addon": "good", "tier": "core", "chart": "x", "repoURL": "y", "version": "1", "wave": "controllers"})
    _write(root, "gitops/addon-catalog/good2/addon.yaml", {"addon": "good2", "tier": "platform-optional", "dir": "gitops/charts/good2", "namespace": "ns", "overridableKeys": ["resources"]})


def _run(root: str) -> tuple[int, list[str]]:
    global FAILURES
    FAILURES = []
    import contextlib
    import io

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = main(root)
    return rc, list(FAILURES)


def selftest() -> int:
    import shutil
    import tempfile

    cases: list[tuple[str, callable, str]] = []

    def case(name, mutate, expect_substr):
        cases.append((name, mutate, expect_substr))

    case(
        "baseline passes with zero failures",
        lambda root: None,
        None,
    )
    case(
        "wrong tier on a core add-on fails only the tier rule",
        lambda root: _write(root, "gitops/addons/good/addon.yaml", {"addon": "good", "tier": "platform-optional", "chart": "x", "repoURL": "y", "version": "1", "wave": "controllers"}),
        "declares tier: core",
    )
    case(
        "directory name != addon field fails only naming rule (i)",
        lambda root: _write(root, "gitops/addons/good/addon.yaml", {"addon": "not-good", "tier": "core", "chart": "x", "repoURL": "y", "version": "1", "wave": "controllers"}),
        "directory name equals its own addon",
    )
    case(
        "catalog entry with tier: core fails the catalog tier rule",
        lambda root: _write(root, "gitops/addon-catalog/good2/addon.yaml", {"addon": "good2", "tier": "core", "dir": "gitops/charts/good2", "namespace": "ns", "overridableKeys": []}),
        "declares tier: platform-optional or workload",
    )
    case(
        "same directory name under both addons/ and addon-catalog/ fails naming rule (ii)",
        lambda root: _write(root, "gitops/addon-catalog/good/addon.yaml", {"addon": "good", "tier": "platform-optional", "dir": "gitops/charts/good", "namespace": "ns", "overridableKeys": []}),
        "no directory name exists under both",
    )

    failures = 0
    for name, mutate, expect_substr in cases:
        tmp = tempfile.mkdtemp(prefix="check-addon-tiers-selftest-")
        try:
            _baseline(tmp)
            mutate(tmp)
            rc, fails = _run(tmp)
            if expect_substr is None:
                ok = rc == 0 and not fails
                detail = f"expected a clean pass, got rc={rc} failures={fails}"
            else:
                # #63 (filed as #55 item 7): these cases are each named "fails
                # only" one specific rule, but the assertion let a second,
                # unrelated failure through silently (len(fails) <= 2). Tightened
                # to match what the case names actually claim -- exactly one
                # failure, and it is the expected one.
                ok = rc != 0 and len(fails) == 1 and expect_substr in fails[0]
                detail = f"expected exactly one failure, the {expect_substr!r} rule, got {fails}"
            check(f"selftest: {name}", ok, detail)
            if not ok:
                failures += 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 2:
        print("usage: check_addon_tiers.py <repo-root> | check_addon_tiers.py --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
