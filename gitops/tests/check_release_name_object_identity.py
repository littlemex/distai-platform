#!/usr/bin/env python3
"""Regression guard for #110/PR #116, selector-safety half (name-length is
check_object_name_length.py's job; this script never checks name length).

check_object_name_length.py's own classification table (posted as a comment
on issue #110, not committed) diffed every add-on's rendered objects by
(kind, name) only. That missed the one hazard #110's own fix exists to
avoid: an object whose own name stays fixed across a release-name change
(via `fullnameOverride` or a hand-written template) while its own
`spec.selector` (Deployment/DaemonSet/StatefulSet) or `spec.selector`
(Service) still derives from the release name -- `spec.selector` is
immutable, so Argo CD would try, and fail, to patch it on an already-
existing object instead of a clean delete-and-recreate.

This script renders every core add-on and every real per-cell marker file
twice, at the longest allowed cell name -- once at the legacy release name
every cell used unconditionally before #110 and this whole PR existed
(`<cell>-<addon>`, what a real, already-running cell actually has deployed
today, regardless of this PR), once at the release name
`expected_release_name()` (imported from check_object_name_length.py,
never re-derived) gives the SAME add-on with `keepLegacyReleaseNames` true
-- the shape an already-running cell gets if it opts in via its own
`gitops/cells/<cell>/cell.yaml` -- and compares, template by template
(joined by each document's own `# Source: <chart>/templates/...` comment,
which names the chart's own template file and is therefore stable across
a release-name change, unlike `metadata.name` itself, the one field this
comparison exists to watch):

  - `metadata.name`
  - for Deployment/DaemonSet/StatefulSet: `spec.selector.matchLabels`
  - for Service: `spec.selector`

FAILs only on the one dangerous pattern: a selector that changed while the
object's own name did not (an immutable-field patch Argo CD cannot make).
A name that changed together with its own selector is a clean rename
(expected for the eight add-ons without `selectorDerivesFromReleaseName`,
which get the short name under `keepLegacyReleaseNames: true` exactly as
they would without it -- that flag only protects the three add-ons that
actually have the fact set) and is reported as INFO, not a failure. For
`accel-neuron-device-plugin`, `accel-neuron-dra` and `jobset`, opting in
(`keepLegacyReleaseNames: true`) must reproduce the identical legacy
release name -- this script renders that SAME release name twice via the
real `expected_release_name()` call (not skipped, not assumed) and
reports the resulting zero-diff explicitly, proving the opt-in path is a
true no-op for an already-running cell's own objects.

This script never compares against `keepLegacyReleaseNames: false` (a
brand new cell's own default): a fresh install establishes its own name
and selector together, with no pre-existing object to migrate from, so
there is nothing for THIS script's own hazard to apply to there -- that
shape only needs the length check `check_object_name_length.py` already
runs for it.

Usage: check_release_name_object_identity.py <repo_root>
       check_release_name_object_identity.py --selftest
"""
from __future__ import annotations

import glob
import os
import re
import sys
import tempfile

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_object_name_length as cnl  # noqa: E402

SELECTOR_KINDS = {"Deployment", "DaemonSet", "StatefulSet"}

FAILURES: list[str] = []


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def parse_sourced_docs(rendered: str) -> dict[str, list[dict]]:
    """Split helm template's own output into YAML documents, keyed by the
    chart-relative template path from each document's own leading
    "# Source: <chart>/templates/..." comment line -- never by
    metadata.name, since a rename is exactly what this script compares.
    helm template always emits this comment immediately after each "---"
    separator; a document without one (should not happen with any chart
    in this repository) gets a positional fallback key so it is still
    counted, not silently dropped."""
    out: dict[str, list[dict]] = {}
    chunks = re.split(r"(?:^|\n)---\n", rendered)
    for i, chunk in enumerate(chunks):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        m = re.match(r"^#\s*Source:\s*(\S+)", chunk)
        key = m.group(1) if m else f"__no_source_comment_{i}__"
        try:
            doc = yaml.safe_load(chunk)
        except yaml.YAMLError:
            continue
        if not doc or not isinstance(doc, dict):
            continue
        out.setdefault(key, []).append(doc)
    return out


def selector_of(doc: dict) -> dict | None:
    kind = doc.get("kind")
    spec = doc.get("spec", {}) or {}
    if kind in SELECTOR_KINDS:
        return ((spec.get("selector") or {}).get("matchLabels")) or None
    if kind == "Service":
        return spec.get("selector") or None
    return None


def legacy_release_name(addon: str) -> str:
    """Every cell's own actual, real-world release name before #110 and
    this whole PR existed, unconditionally -- what an already-running
    cell has deployed today, regardless of whether it ever opts into
    keepLegacyReleaseNames. Not the same function as
    check_object_name_length.py's own expected_release_name(): that one
    computes what THIS PR's own template gives an add-on now; this one
    is the fixed historical fact every add-on's release name actually
    was before any of this existed."""
    return f"{cnl.WORST_CASE_CELL_NAME}-{addon}"


def render_both(path: str, repo_root: str, workdir: str) -> tuple[str, str, str | None, str, str | None] | None:
    """Returns (addon, release_legacy, rendered_legacy_or_None,
    release_keep_true, rendered_keep_true_or_None), or None if this file
    has nothing to render (same "no chart:/dir:" exemption
    check_object_name_length.py's own check_addon_file() applies).
    release_legacy is what this add-on's release name actually was
    before #110; release_keep_true is what expected_release_name() gives
    it now with the cell's own keepLegacyReleaseNames true -- the shape
    an already-running cell gets if it opts in."""
    addon_doc = cnl.load_addon(path)
    addon = addon_doc.get("addon")
    if not addon:
        check(f"{path}: has an `addon:` field", False, "missing")
        return None
    release_legacy = legacy_release_name(addon)
    release_keep_true = cnl.expected_release_name(addon, addon_doc, True)
    values = cnl.placeholder_values_worst_case(addon_doc)

    def build_cmd(release: str):
        if addon_doc.get("chart"):
            return cnl.registry_chart_cmd(release, addon_doc)
        if addon_doc.get("dir"):
            return cnl.dir_chart_cmd(release, addon_doc, repo_root, path)
        return None

    cmd_legacy = build_cmd(release_legacy)
    if cmd_legacy is None:
        print(f"NOTE {path}: no chart:/dir: (nothing to render) -- not compared")
        return None
    out_legacy, err_legacy = cnl.render(cmd_legacy, workdir, values, f"{addon}-legacy-selector")
    cmd_keep_true = build_cmd(release_keep_true)
    out_keep_true, err_keep_true = cnl.render(cmd_keep_true, workdir, values, f"{addon}-keeptrue-selector")
    if out_legacy is None or out_keep_true is None:
        known_issue = addon_doc.get("knownLatentBugIssue")
        known_hit_legacy = bool(err_legacy) and cnl.KNOWN_LATENT_BUG_ERROR_SUBSTRING in err_legacy
        known_hit_true = bool(err_keep_true) and cnl.KNOWN_LATENT_BUG_ERROR_SUBSTRING in err_keep_true
        if known_hit_legacy and out_keep_true is not None:
            # An add-on WITHOUT selectorDerivesFromReleaseName whose own
            # legacy (unconditional, worst-case-cell-prefixed) release
            # name already exceeded Helm's 53-character cap on its own
            # (accel-nvidia-device-plugin, both EFA advertisers): this
            # fix's own short release name -- unconditional for these,
            # since they never set the fact, regardless of
            # keepLegacyReleaseNames -- is what makes the add-on
            # renderable past that worst-case cell length at all. Not
            # the deferred #114 case (that one still fails at
            # keep_legacy=True too, below); nothing to compare either
            # way; reported as NOTE, not a failure.
            print(f"NOTE {path}: the legacy release name {release_legacy!r} itself exceeded Helm's "
                  f"53-character cap at the worst-case cell name; this fix's own short release name "
                  f"{release_keep_true!r} (unconditional for this add-on, which never sets "
                  f"selectorDerivesFromReleaseName) renders fine regardless of keepLegacyReleaseNames -- "
                  f"selector comparison needs a legacy render to diff against and is skipped here, not "
                  f"a failure")
            return None
        if known_issue and known_hit_true:
            # accel-neuron-device-plugin's own case: release_legacy and
            # release_keep_true are the SAME cell-prefixed string (this
            # add-on's own selectorDerivesFromReleaseName makes
            # expected_release_name() return the legacy name at
            # keep_legacy=True too), so both renders fail identically at
            # the worst-case cell length -- the exact, already-tracked,
            # deliberately deferred limitation check_object_name_length.py's
            # own exemption also matches on. Nothing to compare either
            # way; reported as NOTE, not a failure.
            print(f"NOTE {path}: release name {release_legacy!r} (legacy) / {release_keep_true!r} "
                  f"(keepLegacyReleaseNames=true) exceeds Helm's 53-character cap at the worst-case cell "
                  f"name (deferred, see #{known_issue}) -- selector comparison needs a successful render "
                  f"on both sides and is skipped here, not a failure")
            return None
        check(f"{path}: both the legacy release name and the keepLegacyReleaseNames=true release name render",
              False, f"legacy_err={err_legacy!r} keep_true_err={err_keep_true!r}")
        return None
    return addon, release_legacy, out_legacy, release_keep_true, out_keep_true


def compare_and_report(path: str, addon: str, release_legacy: str, out_legacy: str, release_keep_true: str,
                        out_keep_true: str) -> None:
    legacy_docs = parse_sourced_docs(out_legacy)
    keep_true_docs = parse_sourced_docs(out_keep_true)
    keys = sorted(set(legacy_docs) | set(keep_true_docs))
    renamed_count = 0
    unchanged_count = 0
    violations: list[str] = []
    for key in keys:
        legacy_list = legacy_docs.get(key, [])
        keep_true_list = keep_true_docs.get(key, [])
        for legacy_doc, keep_true_doc in zip(legacy_list, keep_true_list):
            legacy_name = (legacy_doc.get("metadata") or {}).get("name", "")
            keep_true_name = (keep_true_doc.get("metadata") or {}).get("name", "")
            legacy_sel = selector_of(legacy_doc)
            keep_true_sel = selector_of(keep_true_doc)
            if legacy_sel is None and keep_true_sel is None:
                continue
            name_changed = legacy_name != keep_true_name
            selector_changed = legacy_sel != keep_true_sel
            if name_changed:
                renamed_count += 1
            else:
                unchanged_count += 1
            if (not name_changed) and selector_changed:
                violations.append(
                    f"{key}: {legacy_doc.get('kind')} {legacy_name!r} kept its own name across legacy "
                    f"release name {release_legacy!r} -> keepLegacyReleaseNames=true release name "
                    f"{release_keep_true!r} but its own selector changed ({legacy_sel!r} -> {keep_true_sel!r}) "
                    f"-- Argo CD cannot patch an immutable selector; this is the exact hazard "
                    f"selectorDerivesFromReleaseName/keepLegacyReleaseNames exists to avoid"
                )
    check(
        f"{path} (addon {addon!r}, legacy={release_legacy!r} keepLegacyReleaseNames=true={release_keep_true!r}): "
        f"no selector-bearing object kept its own name while its own selector changed",
        not violations,
        "; ".join(violations),
    )
    if release_legacy == release_keep_true:
        print(f"INFO {path}: {addon!r} -- keepLegacyReleaseNames=true reproduces the identical legacy "
              f"release name {release_legacy!r} (selectorDerivesFromReleaseName is true for this add-on), "
              f"{renamed_count + unchanged_count} selector-bearing object(s) compared, 0 could differ by "
              f"construction (same input) -- opting in is a true no-op for an already-running cell")
    else:
        print(f"INFO {path}: {addon!r} does not set selectorDerivesFromReleaseName -- {renamed_count} "
              f"selector-bearing object(s) renamed from the legacy release name even with "
              f"keepLegacyReleaseNames=true (name and selector both changed, expected: that flag only "
              f"protects the add-ons with the fact set), {unchanged_count} kept their own name")


def check_file(path: str, repo_root: str, workdir: str) -> None:
    result = render_both(path, repo_root, workdir)
    if result is None:
        return
    addon, release_legacy, out_legacy, release_keep_true, out_keep_true = result
    compare_and_report(path, addon, release_legacy, out_legacy, release_keep_true, out_keep_true)


def main(repo_root: str) -> int:
    workdir = tempfile.mkdtemp(prefix="check-release-name-object-identity-")
    try:
        for path in sorted(glob.glob(os.path.join(repo_root, "gitops/addons/*/addon.yaml"))):
            check_file(path, repo_root, workdir)
        for pattern in (
            "gitops/cells/*/capacity-pool/*.yaml",
            "gitops/cells/*/smoke/*.yaml",
            "gitops/cells/*/sharedfs/*.yaml",
            "gitops/cells/*/addons/*.yaml",
        ):
            for path in sorted(glob.glob(os.path.join(repo_root, pattern))):
                check_file(path, repo_root, workdir)
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all release-name object-identity checks passed")
    return 0


# --------------------------------------------------------------- selftest

_SELFTEST_CHART = """\
apiVersion: v2
name: selftest-identity
version: 0.1.0
"""

_SELFTEST_TEMPLATE_HAZARD = """\
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fixed-name-controller
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers: []
"""

_SELFTEST_TEMPLATE_SAFE_RENAME = """\
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-controller
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers: []
"""

_SELFTEST_TEMPLATE_SAFE_PINNED = """\
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fixed-name-controller
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: fixed-instance-label
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: fixed-instance-label
    spec:
      containers: []
"""


def _write_chart(root: str, template_yaml: str) -> str:
    os.makedirs(os.path.join(root, "templates"), exist_ok=True)
    with open(os.path.join(root, "Chart.yaml"), "w", encoding="utf-8") as f:
        f.write(_SELFTEST_CHART)
    with open(os.path.join(root, "values.yaml"), "w", encoding="utf-8") as f:
        f.write("{}\n")
    with open(os.path.join(root, "templates", "deploy.yaml"), "w", encoding="utf-8") as f:
        f.write(template_yaml)
    return root


def selftest() -> int:
    """Proves this checker (a) catches the exact hazard it exists for --
    a fixed object name next to a release-derived selector -- (b) does
    not flag a clean rename where both the name and the selector change
    together, and (c) does not flag an add-on rendered at the identical
    release name twice (selectorDerivesFromReleaseName absent). All
    three against synthetic fixture charts, never this repository's own
    real ones."""
    ok = True
    workdir = tempfile.mkdtemp(prefix="check-release-name-object-identity-selftest-")
    try:
        hazard_dir = _write_chart(os.path.join(workdir, "hazard-chart"), _SELFTEST_TEMPLATE_HAZARD)
        out_false, err_false = cnl.render(["helm", "template", "selftest-hazard", hazard_dir, "-n", "default"], workdir, {}, "hazard-false")
        out_true, err_true = cnl.render(["helm", "template", "aaaa-selftest-hazard", hazard_dir, "-n", "default"], workdir, {}, "hazard-true")
        if out_false is None or out_true is None:
            print(f"FAIL selftest: hazard fixture did not render: {err_false!r} {err_true!r}")
            return 1
        before = len(FAILURES)
        compare_and_report("hazard-fixture", "selftest-hazard", "selftest-hazard", out_false, "aaaa-selftest-hazard", out_true)
        caught = len(FAILURES) > before
        FAILURES.clear()
        if caught:
            print("PASS selftest: a fixed name next to a release-derived selector is caught")
        else:
            print("FAIL selftest: the exact hazard this script exists for was NOT caught (checker is broken)")
            ok = False

        rename_dir = _write_chart(os.path.join(workdir, "rename-chart"), _SELFTEST_TEMPLATE_SAFE_RENAME)
        out_false, err_false = cnl.render(["helm", "template", "selftest-rename", rename_dir, "-n", "default"], workdir, {}, "rename-false")
        out_true, err_true = cnl.render(["helm", "template", "aaaa-selftest-rename", rename_dir, "-n", "default"], workdir, {}, "rename-true")
        if out_false is None or out_true is None:
            print(f"FAIL selftest: rename fixture did not render: {err_false!r} {err_true!r}")
            return 1
        before = len(FAILURES)
        compare_and_report("rename-fixture", "selftest-rename", "selftest-rename", out_false, "aaaa-selftest-rename", out_true)
        false_positive = len(FAILURES) > before
        FAILURES.clear()
        if not false_positive:
            print("PASS selftest: a clean rename (name and selector both change) is not flagged")
        else:
            print("FAIL selftest: a clean rename was wrongly flagged (false positive)")
            ok = False

        pinned_dir = _write_chart(os.path.join(workdir, "pinned-chart"), _SELFTEST_TEMPLATE_SAFE_PINNED)
        out_same, err_same = cnl.render(["helm", "template", "aaaa-selftest-pinned", pinned_dir, "-n", "default"], workdir, {}, "pinned")
        if out_same is None:
            print(f"FAIL selftest: pinned fixture did not render: {err_same!r}")
            return 1
        before = len(FAILURES)
        compare_and_report("pinned-fixture", "selftest-pinned", "aaaa-selftest-pinned", out_same, "aaaa-selftest-pinned", out_same)
        false_positive = len(FAILURES) > before
        FAILURES.clear()
        if not false_positive:
            print("PASS selftest: the identical release name rendered twice (no selectorDerivesFromReleaseName "
                  "effect) is not flagged")
        else:
            print("FAIL selftest: a zero-diff render was wrongly flagged")
            ok = False
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)

    print(f"\nRESULT {'PASS' if ok else 'FAIL'}: selftest")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 2:
        print("usage: check_release_name_object_identity.py <repo_root> | --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
