#!/usr/bin/env python3
"""Two regression guards for #110 (full mechanism, breakpoints and
real-cluster evidence in PR #116's own "## Changes"):

  1. check_applicationset_releasename_config(): the three gitops/appsets/
     *.ApplicationSet.yaml files actually carry the releaseName template
     the fix depends on, read from the real files.
  2. check_addon_file()/check_cell_marker_file(), driven by main(): render
     every add-on with the exact release name expected_release_name()
     below says it gets, at the longest cell name
     infra/foundation/variables.tf accepts, and fail if any rendered
     Service/Namespace name exceeds Kubernetes' own 63-character limit.

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


def expected_release_name(addon: str, addon_doc: dict) -> str:
    """The exact release name gitops/appsets/*.ApplicationSet.yaml's own
    releaseName template gives Helm for this specific add-on, given
    check_applicationset_releasename_config() below has already
    confirmed that template is what this file expects it to be:
    "{{ .addon }}" normally, or "<cell>-<addon>" (the worst-case cell
    name, to render the worst case, same as every other valuesFrom slot)
    when the add-on's own addon.yaml/cell-marker file sets
    pinReleaseNameToCell: true."""
    if addon_doc.get("pinReleaseNameToCell"):
        return f"{WORST_CASE_CELL_NAME}-{addon}"
    return addon


# The exact releaseName line each ApplicationSet file must carry -- read
# from the real files, never re-derived, so reverting one fails this
# check before anything is ever rendered.
EXPECTED_RELEASENAME_LINES = {
    "gitops/appsets/platform.ApplicationSet.yaml": [
        'releaseName: "{{ if .pinReleaseNameToCell }}{{ .name }}-{{ .addon }}{{ else }}{{ .addon }}{{ end }}"',
    ],
    "gitops/appsets/addons-optional.ApplicationSet.yaml": [
        'releaseName: "{{ if .pinReleaseNameToCell }}{{ .name }}-{{ .addon }}{{ else }}{{ .addon }}{{ end }}"',
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
        # identical text sitting inert inside a comment (round-2 review
        # finding) -- real review-worthy if this check ever found that:
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


def check_addon_file(path: str, repo_root: str, workdir: str) -> None:
    addon_doc = load_addon(path)
    addon = addon_doc.get("addon")
    if not addon:
        check(f"{path}: has an `addon:` field", False, "missing")
        return
    release = expected_release_name(addon, addon_doc)
    values = placeholder_values_worst_case(addon_doc)
    if addon_doc.get("chart"):
        cmd = registry_chart_cmd(release, addon_doc)
    elif addon_doc.get("dir"):
        cmd = dir_chart_cmd(release, addon_doc, repo_root, path)
        if cmd is None:
            return  # dir_chart_cmd already recorded the FAIL
    else:
        # core addons with neither chart: nor dir: (karpenter-netpol,
        # kueue-netpol, jobset-crd, accel-device-classes) render no Helm
        # release of their own upstream chart kind here -- every one of
        # them ships only fixed, hand-written object names, confirmed by
        # reading every template under their own gitops/charts/<name>/
        # templates/, never release-name-derived, so there is nothing
        # for this check to render. Printed explicitly (not a silent
        # return) so this script's own output accounts for every
        # gitops/addons/*/addon.yaml and gitops/addon-catalog/*/
        # addon.yaml it read, rather than leaving a gap a reader cannot
        # tell apart from a bug that skipped a file by accident.
        print(f"NOTE {path}: no chart: or dir: (fixed, hand-written object names) -- not rendered")
        return
    rendered, err = render(cmd, workdir, values, f"{addon}-{os.path.basename(os.path.dirname(path))}")
    if rendered is None:
        known_issue = addon_doc.get("knownLatentBugIssue")
        # round-2 review finding: exempting *any* helm template failure
        # once knownLatentBugIssue is set would also turn a real,
        # different bug (a chart registry outage, a template syntax
        # error from a future chart bump) into a silent NOTE -- scoped
        # to the one expected error message this add-on's own deferred
        # bug actually produces (confirmed on a real cluster, where
        # Argo CD's own repo-server returns the identical message).
        # Anything else with knownLatentBugIssue set still FAILs.
        if known_issue and KNOWN_LATENT_BUG_ERROR_SUBSTRING in err:
            print(f"NOTE {path}: helm template does not render (release {release!r}): {err} "
                  f"-- known limitation, deferred, see #{known_issue}")
            return
        check(f"{path}: helm template renders (release {release!r})", False, err)
        return
    check_rendered_names(f"{path} (release {release!r})", rendered)


def check_cell_marker_file(path: str, repo_root: str, workdir: str) -> None:
    """Two different marker-file shapes, both addon.yaml-shaped (addon:/
    dir:/namespace:/values:/valuesFrom:), both covered by
    expected_release_name() the same way:
    gitops/cells/<cell>/{capacity-pool,smoke,sharedfs}/*.yaml, rendered by
    cells.ApplicationSet.yaml, whose own releaseName has no
    pinReleaseNameToCell branch at all (capacity-pool, smoke and
    sharedfs-shares never had #110's bug or the immutable-selector risk,
    so a marker file setting that field would have no effect there
    either way); and gitops/cells/<cell>/addons/*.yaml, rendered by
    addons-optional.ApplicationSet.yaml, whose releaseName DOES branch on
    it -- jobset's own marker file sets pinReleaseNameToCell: true for
    exactly that reason (see gitops/addon-catalog/jobset/addon.yaml's own
    comment)."""
    check_addon_file(path, repo_root, workdir)


def main(repo_root: str) -> int:
    check_applicationset_releasename_config(repo_root)

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
        for path in addon_files:
            check_addon_file(path, repo_root, workdir)

        # cells.ApplicationSet.yaml's own three Git file generator globs
        # (#18 added the third, sharedfs, alongside the original
        # capacity-pool/smoke pair -- see its own header comment) plus
        # addons-optional.ApplicationSet.yaml's own one -- the real
        # per-cell marker files every platform-optional add-on (jobset,
        # dcgm-exporter, sharedfs) is actually rendered from.
        cell_files = sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/capacity-pool/*.yaml")))
        cell_files += sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/smoke/*.yaml")))
        cell_files += sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/sharedfs/*.yaml")))
        cell_files += sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/addons/*.yaml")))
        for path in cell_files:
            check_cell_marker_file(path, repo_root, workdir)
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

        # A release name as long as the real pre-#110 "<cell>-<addon>"
        # scheme could be (worst-case 32-char cell name + a real add-on
        # name, 52 characters here) -- not the short "{{ .addon }}"
        # release name this PR's own fix always gives Helm now; a short
        # one would not actually overflow (vigil-controller's own real
        # chart needed a 12-character-or-longer cell name to overflow at
        # all, confirmed by rendering) and this
        # selftest would wrongly pass either way.
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

        # expected_release_name(): pinReleaseNameToCell true gets the
        # cell-prefixed name back; false (or absent, the default) gets
        # the add-on's own name alone. round-2 review's own S2 finding --
        # this round-trips the one piece of main() logic the renders
        # above never exercise on their own (they pass the computed
        # release name straight into helm template, never checking what
        # was computed before that).
        pinned = expected_release_name("selftest-addon", {"pinReleaseNameToCell": True})
        unpinned = expected_release_name("selftest-addon", {"pinReleaseNameToCell": False})
        absent = expected_release_name("selftest-addon", {})
        if pinned == f"{WORST_CASE_CELL_NAME}-selftest-addon" and unpinned == "selftest-addon" and absent == "selftest-addon":
            print("PASS selftest: expected_release_name() honors pinReleaseNameToCell (true/false/absent)")
        else:
            print(f"FAIL selftest: expected_release_name() wrong: pinned={pinned!r} unpinned={unpinned!r} absent={absent!r}")
            ok = False

        # check_applicationset_releasename_config(): a file whose only
        # occurrence of the expected text is inside a "#"-prefixed
        # comment must NOT count as a live occurrence (round-2 review's
        # own S1 finding -- a raw substring count over the whole file
        # would pass this).
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

        # knownLatentBugIssue exempts only the one expected Helm error
        # substring, never an unrelated helm template failure (round-2
        # review's own B7 finding) -- through check_addon_file() itself,
        # not a hand-duplicated copy of its own condition (round-3
        # review's own finding: an earlier version of this selftest
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
                             "namespace": "default", "knownLatentBugIssue": 999}, f)
        before = len(FAILURES)
        check_addon_file(broken_addon_yaml, workdir, workdir)
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
        # check_addon_file() too.
        overlong_dir = os.path.join(workdir, "overlong-chart")
        _write_chart(overlong_dir, _SELFTEST_CHART_SAFE.replace("selftest-safe", "selftest-overlong"),
                     _SELFTEST_TEMPLATE_SAFE)
        overlong_addon_yaml = os.path.join(workdir, "overlong-addon.yaml")
        with open(overlong_addon_yaml, "w", encoding="utf-8") as f:
            # 60 characters, no pinReleaseNameToCell set -- expected_release_name()
            # returns this name alone, past Helm's own 53-character cap.
            yaml.safe_dump({"addon": "a" * 60, "dir": os.path.relpath(overlong_dir, workdir),
                             "namespace": "default", "knownLatentBugIssue": 999}, f)
        before = len(FAILURES)
        check_addon_file(overlong_addon_yaml, workdir, workdir)
        correctly_exempted = len(FAILURES) == before
        FAILURES.clear()
        if correctly_exempted:
            print("PASS selftest: check_addon_file() exempts the one expected Helm release-name-too-long error via knownLatentBugIssue")
        else:
            print("FAIL selftest: check_addon_file() did not exempt the expected Helm release-name-too-long error")
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
