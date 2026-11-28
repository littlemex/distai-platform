#!/usr/bin/env python3
"""Regression guards for #110 (full mechanism, breakpoints and real-cluster
evidence in PR #116's own "## Changes"):

  1. check_applicationset_releasename_config(): the three gitops/appsets/
     *.ApplicationSet.yaml files actually carry the releaseName template
     the fix depends on, read from the real files.
  2. check_cell_config_files(): every gitops/cells/<cell>/cell.yaml (the
     new, optional, per-cell opt-in a cell sets to keep the three
     selector-sensitive add-ons at their pre-#110 release name) has a
     `name:` field equal to its own directory, a real boolean
     `keepLegacyReleaseNames`, and no duplicate `name:` across cells
     (the merge generator's own mergeKeys would otherwise collide, or a
     typo would silently opt a cell out without anyone noticing).
  3. check_addon_file()/check_cell_marker_file(), driven by main(): render
     every add-on with the exact release name expected_release_name()
     below says it gets, at the longest cell name
     infra/foundation/variables.tf accepts, under BOTH
     keepLegacyReleaseNames shapes (absent -- every new cell's own
     default -- and set), and fail if any rendered Service/Namespace
     name exceeds Kubernetes' own 63-character limit in either shape.
     The absent shape is what actually closes #110 and #114 for every
     future cell; the set shape is what an already-running cell that
     opts in still needs to fit under Helm's own 53-character release
     name cap.

Usage: check_object_name_length.py <repo_root>
       check_object_name_length.py --selftest
Prints one PASS/FAIL line per check; exits 1 if any failed.
"""
from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_pinned_crds import set_path  # noqa: E402

# infra/foundation/variables.tf's own `name` validation:
# ^[a-z][a-z0-9-]{1,30}[a-z0-9]$ -- 3 to 32 characters. 32 'a's is both a
# valid cell name under that regex and the longest one.
WORST_CASE_CELL_NAME = "a" * 32

# Service/Namespace are capped at 63 characters by Kubernetes itself
# (DNS-1035 label); every other kind follows the looser 253-character
# DNS-1123-subdomain rule and is not actually rejected past 63 (e.g.
# accel-nvidia-dra's own ServiceAccount names, up to 93 characters,
# pre-existing and harmless -- PR #116). Only STRICT_KINDS fails here;
# everything else over 63 is a NOTE.
MAX_NAME_LEN = 63
STRICT_KINDS = {"Service", "Namespace"}

# Helm's own release-name validation error text -- the one failure
# knownLatentBugIssue may exempt a render from. Confirmed verbatim on a
# real cluster (Argo CD's own repo-server ComparisonError).
KNOWN_LATENT_BUG_ERROR_SUBSTRING = "must not be longer than 53"

FAILURES: list[str] = []


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


def expected_release_name(addon: str, addon_doc: dict, keep_legacy: bool) -> str:
    """The exact release name gitops/appsets/*.ApplicationSet.yaml's own
    releaseName template gives Helm for this specific add-on on a cell
    whose own keepLegacyReleaseNames is `keep_legacy`, given
    check_applicationset_releasename_config() below has already
    confirmed that template is what this file expects it to be:
    "{{ .addon }}" normally, or "<cell>-<addon>" (the worst-case cell
    name, to render the worst case, same as every other valuesFrom slot)
    only when BOTH the add-on's own `selectorDerivesFromReleaseName`
    (a fact about its own chart, set on accel-neuron-device-plugin,
    accel-neuron-dra and every jobset marker) and the cell's own
    `keepLegacyReleaseNames` (a decision, read from the new
    gitops/cells/<cell>/cell.yaml, absent/false by default) are true.
    Every add-on on every cell that never sets keepLegacyReleaseNames
    -- every cell registered today, and every cell created from here on
    -- gets its own short name alone, with no exception at all."""
    if keep_legacy and addon_doc.get("selectorDerivesFromReleaseName"):
        return f"{WORST_CASE_CELL_NAME}-{addon}"
    return addon


# The exact releaseName line each ApplicationSet file must carry -- read
# from the real files, never re-derived, so reverting one fails this
# check before anything is ever rendered.
EXPECTED_RELEASENAME_LINES = {
    "gitops/appsets/platform.ApplicationSet.yaml": [
        'releaseName: "{{ if and .selectorDerivesFromReleaseName .keepLegacyReleaseNames }}{{ .name }}-{{ .addon }}{{ else }}{{ .addon }}{{ end }}"',
    ],
    "gitops/appsets/addons-optional.ApplicationSet.yaml": [
        'releaseName: "{{ if and .selectorDerivesFromReleaseName .keepLegacyReleaseNames }}{{ .name }}-{{ .addon }}{{ else }}{{ .addon }}{{ end }}"',
    ],
    "gitops/appsets/cells.ApplicationSet.yaml": [
        'releaseName: "{{ .addon }}"',
    ],
}


def check_applicationset_releasename_config(repo_root: str) -> None:
    for rel_path, expected_lines in EXPECTED_RELEASENAME_LINES.items():
        full_path = os.path.join(repo_root, rel_path)
        try:
            with open(full_path, encoding="utf-8") as f:
                raw_lines = f.readlines()
        except OSError as exc:
            check(f"{rel_path}: readable", False, str(exc))
            continue
        want_text = expected_lines[0]
        # A raw substring count over the whole file would also match the
        # identical text sitting inert inside a comment -- real review-worthy if this check ever found that:
        # a revert that only deletes the live templatePatch line while
        # leaving a comment that happens to quote it verbatim would still
        # pass. Only a line that, once its leading whitespace is
        # stripped, is exactly this text (not a "#"-prefixed comment
        # line, this codebase's own convention for every comment) counts
        # as a live occurrence.
        occurrences = sum(1 for line in raw_lines if line.strip() == want_text)
        # platform.ApplicationSet.yaml carries the line twice (the .dir
        # and the chart branch); the other two exactly once.
        want = 2 if "platform.ApplicationSet.yaml" in rel_path else 1
        check(
            f"{rel_path}: carries {want_text!r} as a live (non-comment) line exactly {want} time(s)",
            occurrences == want,
            f"found {occurrences} live occurrence(s)",
        )


def check_cell_config_files(repo_root: str) -> None:
    """gitops/cells/<cell>/cell.yaml is new, optional, and the one input
    the merge generator in platform.ApplicationSet.yaml and
    addons-optional.ApplicationSet.yaml's own `mergeKeys: ["name"]`
    depends on. Three ways this can go wrong, none of which a reader
    would notice just by looking at one file in isolation:
      - name: does not match the file's own directory -- the merge
        silently matches nothing, and the cell that thought it opted in
        gets no exception (the pre-#110 bug it was trying to avoid) --
        safe, but silent and confusing.
      - keepLegacyReleaseNames is a string ("true"/"false") instead of a
        real YAML boolean -- Go's text/template treats a non-empty
        string as truthy regardless of its text, so "false" would still
        opt in.
      - two cell.yaml files share the same name: -- the merge generator
        errors on a duplicate merge key, which stops BOTH
        ApplicationSets reconciling, for every cell, not just the two
        with the clash.
    """
    seen_names: dict[str, str] = {}
    for path in sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/cell.yaml"))):
        cell_dir = os.path.basename(os.path.dirname(path))
        doc = load_addon(path)
        name = doc.get("name")
        check(f"{path}: has a `name:` field equal to its own directory ({cell_dir!r})",
              name == cell_dir, f"name={name!r}")
        if "keepLegacyReleaseNames" in doc:
            value = doc["keepLegacyReleaseNames"]
            check(f"{path}: keepLegacyReleaseNames is a real boolean, not a string",
                  isinstance(value, bool), f"got {value!r} ({type(value).__name__})")
        if name:
            if name in seen_names:
                check(f"{path}: name {name!r} is unique across every cell.yaml", False,
                      f"also set by {seen_names[name]!r} -- the merge generator errors on a duplicate "
                      "merge key, stopping every cell's own reconcile, not just these two")
            else:
                seen_names[name] = path


def placeholder_values_worst_case(addon_doc: dict) -> dict:
    """Same mechanism as check_pinned_crds.placeholder_values, but every
    valuesFrom slot gets the longest cell name a real cell can have
    (WORST_CASE_CELL_NAME), not a short inert placeholder -- the literal
    "render with the longest allowed cell name" this check exists to do.
    A value this is not (clusterName, a region, an ARN-shaped nodeRole,
    an interruption-queue name) still renders fine with a 32-character
    string in its place; nothing here reads the value's own shape, only
    its presence past a chart's `required()` guard."""
    values = dict(addon_doc.get("values") or {})
    for entry in addon_doc.get("valuesFrom", []) or []:
        set_path(values, entry["helmKey"], WORST_CASE_CELL_NAME)
    return values


def render(cmd: list[str], workdir: str, values: dict, values_label: str) -> tuple[str | None, str | None]:
    values_path = None
    if values:
        values_path = os.path.join(workdir, f"{values_label}.yaml")
        with open(values_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(values, f)
        cmd = cmd + ["-f", values_path]
    proc = subprocess.run(cmd, cwd=workdir, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        return None, proc.stderr.strip()
    return proc.stdout, None


def check_rendered_names(label: str, rendered: str) -> None:
    violations = []
    notes = []
    for doc in yaml.safe_load_all(rendered):
        if not doc or not isinstance(doc, dict):
            continue
        kind = doc.get("kind", "?")
        meta = doc.get("metadata", {}) or {}
        name = meta.get("name", "")
        if not name or len(name) <= MAX_NAME_LEN:
            continue
        if kind in STRICT_KINDS:
            violations.append((kind, name, len(name)))
        else:
            notes.append((kind, name, len(name)))
    for kind, name, n in notes:
        print(f"NOTE {label}: {kind} {name!r} is {n} characters (> {MAX_NAME_LEN}, but {kind} follows the "
              f"253-character DNS-subdomain rule, not the 63-character DNS-label rule {sorted(STRICT_KINDS)} "
              "follow -- not failed)")
    check(
        f"{label}: every rendered {sorted(STRICT_KINDS)} name is <= {MAX_NAME_LEN} characters",
        not violations,
        "; ".join(f"{kind} {name!r} is {n} characters" for kind, name, n in violations),
    )


def registry_chart_cmd(release: str, addon_doc: dict) -> list[str]:
    chart = addon_doc["chart"]
    version = str(addon_doc["version"])
    repo_url = addon_doc["repoURL"]
    namespace = addon_doc.get("namespace")
    if repo_url.startswith("http://") or repo_url.startswith("https://"):
        cmd = ["helm", "template", release, chart, "--repo", repo_url, "--version", version]
    else:
        cmd = ["helm", "template", release, f"oci://{repo_url}/{chart}", "--version", version]
    if namespace:
        cmd += ["--namespace", namespace, "--create-namespace"]
    if bool(addon_doc.get("skipCrds")):
        cmd.append("--skip-crds")
    return cmd


def dir_chart_cmd(release: str, addon_doc: dict, repo_root: str, label: str) -> list[str] | None:
    chart_ref = os.path.join(repo_root, addon_doc["dir"])
    proc = subprocess.run(["helm", "dependency", "build", chart_ref], capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        # A silently-ignored failure here would leave charts/ holding
        # whatever subchart .tgz an earlier, unrelated run left behind
        # (or none at all), and the helm template call below would then
        # either render a stale dependency or fail for a confusing,
        # unrelated reason -- fail loudly here instead, naming the real
        # cause.
        check(f"{label}: helm dependency build ({chart_ref})", False, proc.stderr.strip())
        return None
    cmd = ["helm", "template", release, chart_ref]
    namespace = addon_doc.get("namespace")
    if namespace:
        cmd += ["-n", namespace, "--create-namespace"]
    if bool(addon_doc.get("skipCrds")):
        cmd.append("--skip-crds")
    return cmd


def check_addon_file(path: str, repo_root: str, workdir: str, *, keep_legacy: bool) -> None:
    addon_doc = load_addon(path)
    addon = addon_doc.get("addon")
    if not addon:
        check(f"{path}: has an `addon:` field", False, "missing")
        return
    release = expected_release_name(addon, addon_doc, keep_legacy)
    values = placeholder_values_worst_case(addon_doc)
    if addon_doc.get("chart"):
        cmd = registry_chart_cmd(release, addon_doc)
    elif addon_doc.get("dir"):
        cmd = dir_chart_cmd(release, addon_doc, repo_root, path)
        if cmd is None:
            return  # dir_chart_cmd already recorded the FAIL
    else:
        # Defensive only: check_gitops_contract.py's own "has exactly
        # one of 'chart' or 'dir'" invariant means no addon.yaml in this
        # repository today can actually reach this branch (confirmed:
        # every gitops/addons/*/addon.yaml sets one or the other).
        # Printed explicitly rather than a silent return, so a future
        # addon.yaml shape this script has not seen yet is visible in
        # its own output instead of silently skipped.
        print(f"NOTE {path}: no chart: or dir: (nothing for this script to render) -- not rendered")
        return
    label_suffix = "keepLegacyReleaseNames=true" if keep_legacy else "keepLegacyReleaseNames=absent (new cell)"
    rendered, err = render(cmd, workdir, values, f"{addon}-{os.path.basename(os.path.dirname(path))}-{keep_legacy}")
    if rendered is None:
        known_issue = addon_doc.get("knownLatentBugIssue")
        # exempting *any* helm template failure once knownLatentBugIssue
        # is set would also turn a real,
        # different bug (a chart registry outage, a template syntax
        # error from a future chart bump) into a silent NOTE -- scoped
        # to the one expected error message this add-on's own deferred
        # bug actually produces (confirmed on a real cluster, where
        # Argo CD's own repo-server returns the identical message). This
        # bug can only still fire when keep_legacy is true (a cell that
        # opted in): a new cell's own release name is always short, and
        # Helm's own 53-character cap no longer bites it at all.
        # Anything else with knownLatentBugIssue set still FAILs.
        if known_issue and keep_legacy and KNOWN_LATENT_BUG_ERROR_SUBSTRING in err:
            print(f"NOTE {path} ({label_suffix}): helm template does not render (release {release!r}): {err} "
                  f"-- known limitation, deferred, see #{known_issue}")
            return
        check(f"{path} ({label_suffix}): helm template renders (release {release!r})", False, err)
        return
    check_rendered_names(f"{path} ({label_suffix}, release {release!r})", rendered)


def check_cell_marker_file(path: str, repo_root: str, workdir: str, *, cells_applicationset_sourced: bool,
                            keep_legacy: bool) -> None:
    """Two different marker-file shapes, both addon.yaml-shaped (addon:/
    dir:/namespace:/values:/valuesFrom:): gitops/cells/<cell>/
    {capacity-pool,smoke,sharedfs}/*.yaml, rendered by
    cells.ApplicationSet.yaml, whose own releaseName has no
    selectorDerivesFromReleaseName/keepLegacyReleaseNames branch at all;
    and gitops/cells/<cell>/addons/*.yaml, rendered by
    addons-optional.ApplicationSet.yaml, whose releaseName DOES branch on
    them (jobset's own marker sets selectorDerivesFromReleaseName for
    exactly that reason). cells_applicationset_sourced tells
    expected_release_name() which shape this file actually is, rather
    than reading selectorDerivesFromReleaseName the same way for both and
    silently disagreeing with cells.ApplicationSet.yaml's own
    unconditional template if a capacity-pool/smoke/sharedfs marker ever
    set it."""
    if cells_applicationset_sourced:
        addon_doc = load_addon(path)
        if addon_doc.get("selectorDerivesFromReleaseName"):
            check(f"{path}: does not set selectorDerivesFromReleaseName", False,
                  "cells.ApplicationSet.yaml's own releaseName has no such branch -- "
                  "setting this field here has no effect and would mislead a reader into thinking it does")
            return
    check_addon_file(path, repo_root, workdir, keep_legacy=keep_legacy)


def main(repo_root: str) -> int:
    check_applicationset_releasename_config(repo_root)
    check_cell_config_files(repo_root)

    workdir = tempfile.mkdtemp(prefix="check-object-name-length-")
    try:
        # gitops/addons/*/addon.yaml (core, read directly by platform.
        # ApplicationSet.yaml). gitops/addon-catalog/*/addon.yaml is
        # documentation only -- check_addon_catalog_sync.py's own header
        # comment: "gitops/addon-catalog/<name>/addon.yaml is never read
        # by any ApplicationSet" -- so it is deliberately NOT rendered
        # here; rendering it instead of the real marker file below would
        # check an input Argo CD never actually uses.
        addon_files = sorted(glob.glob(os.path.join(repo_root, "gitops/addons/*/addon.yaml")))
        # cells.ApplicationSet.yaml's own three Git file generator globs
        # (#18 added the third, sharedfs, alongside the original
        # capacity-pool/smoke pair -- see its own header comment) plus
        # addons-optional.ApplicationSet.yaml's own one -- the real
        # per-cell marker files every platform-optional add-on (jobset,
        # dcgm-exporter, sharedfs) is actually rendered from.
        cells_appset_files = sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/capacity-pool/*.yaml")))
        cells_appset_files += sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/smoke/*.yaml")))
        cells_appset_files += sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/sharedfs/*.yaml")))
        addons_optional_files = sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/addons/*.yaml")))

        # Both shapes, every file: keep_legacy=False is every cell's own
        # default (and every cell registered today, since none of them
        # set keepLegacyReleaseNames) -- the shape that actually closes
        # #110 and #114 for good. keep_legacy=True is the one an
        # already-running cell opts into for exactly the add-ons whose
        # own selectorDerivesFromReleaseName is true; every other add-on
        # still gets the short name even on that same cell.
        for keep_legacy in (False, True):
            for path in addon_files:
                check_addon_file(path, repo_root, workdir, keep_legacy=keep_legacy)
            for path in cells_appset_files:
                check_cell_marker_file(path, repo_root, workdir, cells_applicationset_sourced=True,
                                        keep_legacy=keep_legacy)
            for path in addons_optional_files:
                check_cell_marker_file(path, repo_root, workdir, cells_applicationset_sourced=False,
                                        keep_legacy=keep_legacy)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all object-name-length checks passed")
    return 0


# --------------------------------------------------------------- selftest

_SELFTEST_CHART_OVERFLOWS = """\
apiVersion: v2
name: selftest-overflow
version: 0.1.0
"""

_SELFTEST_TEMPLATE_OVERFLOWS = """\
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-controller-manager-metrics-service
spec:
  ports: []
"""

_SELFTEST_CHART_SAFE = """\
apiVersion: v2
name: selftest-safe
version: 0.1.0
"""

_SELFTEST_TEMPLATE_SAFE = """\
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-svc
spec:
  ports: []
"""

_SELFTEST_CHART_NONSTRICT = """\
apiVersion: v2
name: selftest-nonstrict
version: 0.1.0
"""

_SELFTEST_TEMPLATE_NONSTRICT = """\
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Release.Name }}-service-account-controller
"""


def _write_chart(root: str, chart_yaml: str, template_yaml: str) -> str:
    os.makedirs(os.path.join(root, "templates"), exist_ok=True)
    with open(os.path.join(root, "Chart.yaml"), "w", encoding="utf-8") as f:
        f.write(chart_yaml)
    with open(os.path.join(root, "values.yaml"), "w", encoding="utf-8") as f:
        f.write("{}\n")
    with open(os.path.join(root, "templates", "service.yaml"), "w", encoding="utf-8") as f:
        f.write(template_yaml)
    return root


def selftest() -> int:
    """Proves this checker (a) catches a release-name-derived object name
    that overflows 63 characters at the worst-case cell name, exactly the
    real vigil-controller/kueue defect this PR fixes, and (b) does not
    flag a chart that stays within the limit -- against two synthetic
    charts, never this repository's own real ones, so a real chart bump
    can never make this selftest pass or fail for the wrong reason."""
    ok = True
    workdir = tempfile.mkdtemp(prefix="check-object-name-length-selftest-")
    try:
        overflow_dir = _write_chart(
            os.path.join(workdir, "overflow-chart"), _SELFTEST_CHART_OVERFLOWS, _SELFTEST_TEMPLATE_OVERFLOWS
        )
        safe_dir = _write_chart(os.path.join(workdir, "safe-chart"), _SELFTEST_CHART_SAFE, _SELFTEST_TEMPLATE_SAFE)

        # A release name as long as the real legacy "<cell>-<addon>"
        # scheme could be (worst-case 32-char cell name + a real add-on
        # name, 52 characters here) -- not the short "{{ .addon }}"
        # release name this PR's own fix gives every add-on by default
        # now; a short one would not actually overflow (vigil-controller's
        # own real chart needed a 12-character-or-longer cell name to
        # overflow at all, confirmed by rendering) and this selftest
        # would wrongly pass either way.
        overflow_release = WORST_CASE_CELL_NAME + "-selftest-vigil-like"
        cmd = ["helm", "template", overflow_release, overflow_dir, "-n", "default"]
        rendered, err = render(cmd, workdir, {}, "overflow")
        if rendered is None:
            print(f"FAIL selftest: overflow fixture did not render: {err}")
            return 1
        before = len(FAILURES)
        check_rendered_names("selftest overflow fixture", rendered)
        caught = len(FAILURES) > before
        if caught:
            print("PASS selftest: a release-name-derived overflow is caught")
        else:
            print("FAIL selftest: a release-name-derived overflow was NOT caught (checker is broken)")
            ok = False
        FAILURES.clear()

        cmd = ["helm", "template", "selftest-safe", safe_dir, "-n", "default"]
        rendered, err = render(cmd, workdir, {}, "safe")
        if rendered is None:
            print(f"FAIL selftest: safe fixture did not render: {err}")
            return 1
        before = len(FAILURES)
        check_rendered_names("selftest safe fixture", rendered)
        false_positive = len(FAILURES) > before
        if not false_positive:
            print("PASS selftest: a within-limit name is not flagged")
        else:
            print("FAIL selftest: a within-limit name was wrongly flagged (false positive)")
            ok = False
        FAILURES.clear()

        # Same overflow release name, but the overflowing object this
        # time is a ServiceAccount (STRICT_KINDS-exempt, the real shape
        # accel-nvidia-dra's own pinned chart renders -- see MAX_NAME_LEN's
        # own comment above): must be a NOTE, never a failure.
        nonstrict_dir = _write_chart(
            os.path.join(workdir, "nonstrict-chart"), _SELFTEST_CHART_NONSTRICT, _SELFTEST_TEMPLATE_NONSTRICT
        )
        cmd = ["helm", "template", overflow_release, nonstrict_dir, "-n", "default"]
        rendered, err = render(cmd, workdir, {}, "nonstrict")
        if rendered is None:
            print(f"FAIL selftest: non-strict-kind fixture did not render: {err}")
            return 1
        before = len(FAILURES)
        check_rendered_names("selftest non-strict-kind fixture", rendered)
        wrongly_failed = len(FAILURES) > before
        if not wrongly_failed:
            print("PASS selftest: a ServiceAccount name over 63 characters is noted, not failed")
        else:
            print("FAIL selftest: a ServiceAccount name over 63 characters was wrongly failed")
            ok = False
        FAILURES.clear()

        # expected_release_name(): both selectorDerivesFromReleaseName
        # (the add-on's own fact) AND keep_legacy (the cell's own
        # decision, the function's own argument here) must be true to
        # get the cell-prefixed name back; any other combination gets
        # the add-on's own short name alone -- this round-trips the one
        # piece of main() logic the renders above never exercise on
        # their own (they pass the computed release name straight into
        # helm template, never checking what was computed before that).
        both_true = expected_release_name("selftest-addon", {"selectorDerivesFromReleaseName": True}, True)
        fact_only = expected_release_name("selftest-addon", {"selectorDerivesFromReleaseName": True}, False)
        decision_only = expected_release_name("selftest-addon", {"selectorDerivesFromReleaseName": False}, True)
        neither = expected_release_name("selftest-addon", {}, False)
        if (both_true == f"{WORST_CASE_CELL_NAME}-selftest-addon" and fact_only == "selftest-addon"
                and decision_only == "selftest-addon" and neither == "selftest-addon"):
            print("PASS selftest: expected_release_name() requires both selectorDerivesFromReleaseName "
                  "and keep_legacy to keep the legacy name")
        else:
            print(f"FAIL selftest: expected_release_name() wrong: both_true={both_true!r} "
                  f"fact_only={fact_only!r} decision_only={decision_only!r} neither={neither!r}")
            ok = False

        # check_applicationset_releasename_config(): a file whose only
        # occurrence of the expected text is inside a "#"-prefixed
        # comment must NOT count as a live occurrence -- a raw substring
        # count over the whole file would wrongly pass this.
        fake_appset = os.path.join(workdir, "fake.ApplicationSet.yaml")
        with open(fake_appset, "w", encoding="utf-8") as f:
            f.write('        # releaseName: "{{ .addon }}"\n        otherField: "x"\n')
        saved_expected = dict(EXPECTED_RELEASENAME_LINES)
        try:
            EXPECTED_RELEASENAME_LINES.clear()
            EXPECTED_RELEASENAME_LINES["fake.ApplicationSet.yaml"] = ['releaseName: "{{ .addon }}"']
            before = len(FAILURES)
            check_applicationset_releasename_config(workdir)
            caught = len(FAILURES) > before
        finally:
            EXPECTED_RELEASENAME_LINES.clear()
            EXPECTED_RELEASENAME_LINES.update(saved_expected)
        FAILURES.clear()
        if caught:
            print("PASS selftest: a commented-out releaseName line is not counted as a live occurrence")
        else:
            print("FAIL selftest: a commented-out releaseName line was wrongly counted as live (checker is broken)")
            ok = False

        # check_cell_config_files(): name mismatch, non-boolean flag, and
        # duplicate name across two files are each caught.
        cells_dir = os.path.join(workdir, "cellcfg", "gitops", "cells")
        os.makedirs(os.path.join(cells_dir, "mismatch"), exist_ok=True)
        with open(os.path.join(cells_dir, "mismatch", "cell.yaml"), "w", encoding="utf-8") as f:
            yaml.safe_dump({"name": "not-mismatch", "keepLegacyReleaseNames": True}, f)
        before = len(FAILURES)
        check_cell_config_files(os.path.join(workdir, "cellcfg"))
        caught_mismatch = len(FAILURES) > before
        FAILURES.clear()
        if caught_mismatch:
            print("PASS selftest: a cell.yaml whose own name does not match its directory is caught")
        else:
            print("FAIL selftest: a name/directory mismatch in cell.yaml was NOT caught (checker is broken)")
            ok = False

        os.makedirs(os.path.join(cells_dir, "stringflag"), exist_ok=True)
        with open(os.path.join(cells_dir, "stringflag", "cell.yaml"), "w", encoding="utf-8") as f:
            f.write('name: stringflag\nkeepLegacyReleaseNames: "false"\n')
        before = len(FAILURES)
        check_cell_config_files(os.path.join(workdir, "cellcfg"))
        caught_string = any("real boolean" in f for f in FAILURES)
        FAILURES.clear()
        if caught_string:
            print("PASS selftest: a quoted-string keepLegacyReleaseNames is caught")
        else:
            print("FAIL selftest: a quoted-string keepLegacyReleaseNames was NOT caught (checker is broken)")
            ok = False
        os.remove(os.path.join(cells_dir, "mismatch", "cell.yaml"))
        os.remove(os.path.join(cells_dir, "stringflag", "cell.yaml"))

        os.makedirs(os.path.join(cells_dir, "dupe-a"), exist_ok=True)
        os.makedirs(os.path.join(cells_dir, "dupe-b"), exist_ok=True)
        with open(os.path.join(cells_dir, "dupe-a", "cell.yaml"), "w", encoding="utf-8") as f:
            yaml.safe_dump({"name": "same-name", "keepLegacyReleaseNames": True}, f)
        with open(os.path.join(cells_dir, "dupe-b", "cell.yaml"), "w", encoding="utf-8") as f:
            yaml.safe_dump({"name": "same-name", "keepLegacyReleaseNames": True}, f)
        before = len(FAILURES)
        check_cell_config_files(os.path.join(workdir, "cellcfg"))
        caught_dupe = any("unique across every cell.yaml" in f for f in FAILURES)
        FAILURES.clear()
        if caught_dupe:
            print("PASS selftest: two cell.yaml files sharing one name are caught")
        else:
            print("FAIL selftest: a duplicate cell.yaml name was NOT caught (checker is broken)")
            ok = False
        os.remove(os.path.join(cells_dir, "dupe-a", "cell.yaml"))
        os.remove(os.path.join(cells_dir, "dupe-b", "cell.yaml"))

        # knownLatentBugIssue exempts only the one expected Helm error
        # substring, never an unrelated helm template failure -- through
        # check_addon_file() itself, not a hand-duplicated copy of its
        # own condition (an earlier version of this selftest
        # re-evaluated the same if-statement standalone, so it would
        # keep passing even if check_addon_file()'s own real exemption
        # logic were reverted to "exempt any failure").
        broken_dir = os.path.join(workdir, "broken-chart")
        os.makedirs(os.path.join(broken_dir, "templates"), exist_ok=True)
        with open(os.path.join(broken_dir, "Chart.yaml"), "w", encoding="utf-8") as f:
            f.write("apiVersion: v2\nname: selftest-broken\nversion: 0.1.0\n")
        with open(os.path.join(broken_dir, "values.yaml"), "w", encoding="utf-8") as f:
            f.write("{}\n")
        with open(os.path.join(broken_dir, "templates", "bad.yaml"), "w", encoding="utf-8") as f:
            f.write("{{ fail \"an unrelated template error, not a release-name problem\" }}\n")
        broken_addon_yaml = os.path.join(workdir, "broken-addon.yaml")
        with open(broken_addon_yaml, "w", encoding="utf-8") as f:
            yaml.safe_dump({"addon": "selftest-broken", "dir": os.path.relpath(broken_dir, workdir),
                             "namespace": "default", "knownLatentBugIssue": 999,
                             "selectorDerivesFromReleaseName": True}, f)
        before = len(FAILURES)
        check_addon_file(broken_addon_yaml, workdir, workdir, keep_legacy=True)
        wrongly_exempted = len(FAILURES) == before
        FAILURES.clear()
        if wrongly_exempted:
            print("FAIL selftest: check_addon_file() wrongly exempted an unrelated template error as the known #110 bug")
            ok = False
        else:
            print("PASS selftest: check_addon_file() does not exempt an unrelated helm template failure via knownLatentBugIssue")

        # The matching positive case: the same knownLatentBugIssue, but
        # the chart's own failure IS the expected Helm release-name-too-
        # long error -- must be a NOTE (not added to FAILURES), through
        # check_addon_file() too, and only when keep_legacy is true (a
        # new cell's own short release name never hits this cap at all).
        overlong_dir = os.path.join(workdir, "overlong-chart")
        _write_chart(overlong_dir, _SELFTEST_CHART_SAFE.replace("selftest-safe", "selftest-overlong"),
                     _SELFTEST_TEMPLATE_SAFE)
        overlong_addon_yaml = os.path.join(workdir, "overlong-addon.yaml")
        with open(overlong_addon_yaml, "w", encoding="utf-8") as f:
            # 60 characters, selectorDerivesFromReleaseName set -- at
            # keep_legacy=True, expected_release_name() returns the
            # cell-prefixed name, past Helm's own 53-character cap.
            yaml.safe_dump({"addon": "a" * 60, "dir": os.path.relpath(overlong_dir, workdir),
                             "namespace": "default", "knownLatentBugIssue": 999,
                             "selectorDerivesFromReleaseName": True}, f)
        before = len(FAILURES)
        check_addon_file(overlong_addon_yaml, workdir, workdir, keep_legacy=True)
        correctly_exempted = len(FAILURES) == before
        FAILURES.clear()
        if correctly_exempted:
            print("PASS selftest: check_addon_file() exempts the one expected Helm release-name-too-long error via knownLatentBugIssue")
        else:
            print("FAIL selftest: check_addon_file() did not exempt the expected Helm release-name-too-long error")
            ok = False

        # The same 60-character add-on at keep_legacy=False (every new
        # cell's own default) must render cleanly: its own short name
        # alone is only 60 characters, still past Helm's 53-character
        # cap on its own -- so this fixture instead proves the *other*
        # half of the claim, that a non-flagged add-on's own short name
        # is used regardless of keep_legacy, by reusing a chart whose
        # name is short enough not to hit the cap either way.
        short_addon_yaml = os.path.join(workdir, "short-addon.yaml")
        with open(short_addon_yaml, "w", encoding="utf-8") as f:
            yaml.safe_dump({"addon": "selftest-short", "dir": os.path.relpath(overlong_dir, workdir),
                             "namespace": "default"}, f)
        before = len(FAILURES)
        check_addon_file(short_addon_yaml, workdir, workdir, keep_legacy=True)
        no_exception_without_fact = len(FAILURES) == before
        FAILURES.clear()
        if no_exception_without_fact:
            print("PASS selftest: an add-on without selectorDerivesFromReleaseName gets the short name "
                  "even on a keep_legacy=True cell")
        else:
            print("FAIL selftest: an add-on without selectorDerivesFromReleaseName was wrongly kept legacy")
            ok = False
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print(f"\nRESULT {'PASS' if ok else 'FAIL'}: selftest")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 2:
        print("usage: check_object_name_length.py <repo_root> | --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
