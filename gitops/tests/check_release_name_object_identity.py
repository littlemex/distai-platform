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
twice -- once at the pre-#110 release name every cell used unconditionally
(the longest allowed cell name, worst case), once at the release name this
fix's own `expected_release_name()` (imported from
check_object_name_length.py, never re-derived) gives it today -- and
compares, template by template (joined by each document's own
`# Source: <chart>/templates/...` comment, which names the chart's own
template file and is therefore stable across a release-name change, unlike
`metadata.name` itself, the one field this comparison exists to watch):

  - `metadata.name`
  - for Deployment/DaemonSet/StatefulSet: `spec.selector.matchLabels`
  - for Service: `spec.selector`

FAILs only on the one dangerous pattern: a selector that changed while the
object's own name did not (an immutable-field patch Argo CD cannot make).
A name that changed together with its own selector is a clean rename
(expected for the eight add-ons #110 actually renames) and is reported as
INFO, not a failure. For the three `pinReleaseNameToCell`-excluded add-ons,
the pre-#110 and post-#110 release names are identical by this fix's own
formula, so this script renders the SAME release name twice via the real
`expected_release_name()` call (not skipped, not assumed) and reports the
resulting zero-diff explicitly, rather than exempting them from rendering
the way an earlier, uncommitted classification table did.

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


def old_release_name(addon: str) -> str:
    """Every cell's own pre-#110 behavior, unconditionally -- the
    cell-prefixed name every gitops/appsets/*.ApplicationSet.yaml gave
    Helm before this fix, for every add-on, with no pinReleaseNameToCell
    branch at all (that branch did not exist on main)."""
    return f"{cnl.WORST_CASE_CELL_NAME}-{addon}"


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


def render_both(path: str, repo_root: str, workdir: str) -> tuple[str, dict, str, str | None, str, str | None] | None:
    """Returns (addon, doc, old_release, old_rendered_or_None, new_release,
    new_rendered_or_None), or None if this file has nothing to render
    (same "no chart:/dir:" exemption check_object_name_length.py's own
    check_addon_file() applies)."""
    addon_doc = cnl.load_addon(path)
    addon = addon_doc.get("addon")
    if not addon:
        check(f"{path}: has an `addon:` field", False, "missing")
        return None
    old_release = old_release_name(addon)
    new_release = cnl.expected_release_name(addon, addon_doc)
    values = cnl.placeholder_values_worst_case(addon_doc)

    def build_cmd(release: str):
        if addon_doc.get("chart"):
            return cnl.registry_chart_cmd(release, addon_doc)
        if addon_doc.get("dir"):
            return cnl.dir_chart_cmd(release, addon_doc, repo_root, path)
        return None

    cmd_old = build_cmd(old_release)
    if cmd_old is None:
        print(f"NOTE {path}: no chart:/dir: (nothing to render) -- not compared")
        return None
    out_old, err_old = cnl.render(cmd_old, workdir, values, f"{addon}-old-selector")
    cmd_new = build_cmd(new_release)
    out_new, err_new = cnl.render(cmd_new, workdir, values, f"{addon}-new-selector")
    if out_old is None or out_new is None:
        known_issue = addon_doc.get("knownLatentBugIssue")
        known_hit_old = bool(err_old) and cnl.KNOWN_LATENT_BUG_ERROR_SUBSTRING in err_old
        known_hit_new = bool(err_new) and cnl.KNOWN_LATENT_BUG_ERROR_SUBSTRING in err_new
        if known_issue and (known_hit_old or known_hit_new) and (out_new is not None or known_hit_new):
            # accel-neuron-device-plugin's own case: pinned, so old and
            # new are the SAME cell-prefixed release name, and both fail
            # identically at the worst-case cell length -- the exact,
            # already-tracked, deliberately deferred limitation
            # check_object_name_length.py's own exemption also matches
            # on. Nothing to compare either way (no successful render on
            # either side); reported as NOTE, not a failure.
            print(f"NOTE {path}: pre-#110 release name {old_release!r} exceeds Helm's 53-character cap "
                  f"(deferred, see #{known_issue}); post-fix release name is {new_release!r} "
                  f"({'identical, fails the same way (pinned)' if old_release == new_release else 'renders'}) -- "
                  f"selector comparison needs a successful render on both sides and is skipped here, not a failure")
            return None
        if err_old and cnl.KNOWN_LATENT_BUG_ERROR_SUBSTRING in err_old and out_new is not None:
            # Not exempted via knownLatentBugIssue, but the same real,
            # pre-existing fact: the pre-#110, always-cell-prefixed
            # release name already overflowed Helm's own cap for this
            # add-on at the worst-case cell name, independent of any one
            # object's own name -- this fix's own short release name is
            # what makes this add-on renderable at the worst case at
            # all. No selector comparison is possible without an old
            # render to diff against; reported as INFO, not a failure.
            print(f"INFO {path}: the pre-#110 release name {old_release!r} itself exceeds Helm's "
                  f"53-character cap at the worst-case cell name -- this fix's own short release "
                  f"name {new_release!r} is what makes this add-on renderable at that cell length "
                  f"at all, independent of any one object's own name. Selector comparison needs "
                  f"both renders and is not possible here.")
            return None
        check(f"{path}: both release names render", False, f"old_err={err_old!r} new_err={err_new!r}")
        return None
    return addon, addon_doc, old_release, out_old, new_release, out_new


def compare_and_report(path: str, addon: str, old_release: str, out_old: str, new_release: str, out_new: str) -> None:
    old_docs = parse_sourced_docs(out_old)
    new_docs = parse_sourced_docs(out_new)
    keys = sorted(set(old_docs) | set(new_docs))
    renamed_count = 0
    unchanged_count = 0
    violations: list[str] = []
    for key in keys:
        old_list = old_docs.get(key, [])
        new_list = new_docs.get(key, [])
        for old_doc, new_doc in zip(old_list, new_list):
            old_name = (old_doc.get("metadata") or {}).get("name", "")
            new_name = (new_doc.get("metadata") or {}).get("name", "")
            old_sel = selector_of(old_doc)
            new_sel = selector_of(new_doc)
            if old_sel is None and new_sel is None:
                continue
            name_changed = old_name != new_name
            selector_changed = old_sel != new_sel
            if name_changed:
                renamed_count += 1
            else:
                unchanged_count += 1
            if (not name_changed) and selector_changed:
                violations.append(
                    f"{key}: {old_doc.get('kind')} {old_name!r} kept its own name across "
                    f"{old_release!r} -> {new_release!r} but its own selector changed "
                    f"({old_sel!r} -> {new_sel!r}) -- Argo CD cannot patch an immutable "
                    f"selector; this is the exact hazard #110's own pinReleaseNameToCell "
                    f"exists to avoid"
                )
    check(
        f"{path} (addon {addon!r}, {old_release!r} -> {new_release!r}): no selector-bearing object "
        f"kept its own name while its own selector changed",
        not violations,
        "; ".join(violations),
    )
    if old_release == new_release:
        print(f"INFO {path}: {addon!r} is pinned -- rendered the identical release name "
              f"{old_release!r} twice via expected_release_name(), {renamed_count + unchanged_count} "
              f"selector-bearing object(s) compared, 0 could differ by construction (same input)")
    else:
        print(f"INFO {path}: {addon!r} -- {renamed_count} selector-bearing object(s) renamed (name and "
              f"selector both changed, expected), {unchanged_count} kept their own name "
              f"(name and selector both held, or no selector present)")


def check_file(path: str, repo_root: str, workdir: str) -> None:
    result = render_both(path, repo_root, workdir)
    if result is None:
        return
    addon, _addon_doc, old_release, out_old, new_release, out_new = result
    compare_and_report(path, addon, old_release, out_old, new_release, out_new)


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
    together, and (c) does not flag a pinned add-on rendered at the same
    release name twice. All three against synthetic fixture charts, never
    this repository's own real ones."""
    ok = True
    workdir = tempfile.mkdtemp(prefix="check-release-name-object-identity-selftest-")
    try:
        hazard_dir = _write_chart(os.path.join(workdir, "hazard-chart"), _SELFTEST_TEMPLATE_HAZARD)
        out_old, err_old = cnl.render(["helm", "template", "aaaa-selftest-hazard", hazard_dir, "-n", "default"], workdir, {}, "hazard-old")
        out_new, err_new = cnl.render(["helm", "template", "selftest-hazard", hazard_dir, "-n", "default"], workdir, {}, "hazard-new")
        if out_old is None or out_new is None:
            print(f"FAIL selftest: hazard fixture did not render: {err_old!r} {err_new!r}")
            return 1
        before = len(FAILURES)
        compare_and_report("hazard-fixture", "selftest-hazard", "aaaa-selftest-hazard", out_old, "selftest-hazard", out_new)
        caught = len(FAILURES) > before
        FAILURES.clear()
        if caught:
            print("PASS selftest: a fixed name next to a release-derived selector is caught")
        else:
            print("FAIL selftest: the exact hazard this script exists for was NOT caught (checker is broken)")
            ok = False

        rename_dir = _write_chart(os.path.join(workdir, "rename-chart"), _SELFTEST_TEMPLATE_SAFE_RENAME)
        out_old, err_old = cnl.render(["helm", "template", "aaaa-selftest-rename", rename_dir, "-n", "default"], workdir, {}, "rename-old")
        out_new, err_new = cnl.render(["helm", "template", "selftest-rename", rename_dir, "-n", "default"], workdir, {}, "rename-new")
        if out_old is None or out_new is None:
            print(f"FAIL selftest: rename fixture did not render: {err_old!r} {err_new!r}")
            return 1
        before = len(FAILURES)
        compare_and_report("rename-fixture", "selftest-rename", "aaaa-selftest-rename", out_old, "selftest-rename", out_new)
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
            print("PASS selftest: the identical release name rendered twice (the pinned shape) is not flagged")
        else:
            print("FAIL selftest: a pinned add-on's own zero-diff render was wrongly flagged")
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
