#!/usr/bin/env python3
"""Per-cell platform-optional marker files against the add-on catalog
(issue #41, Decision 3). Static: no cluster, and no AWS credentials.
One sub-check (the overridableKeys existence check below) needs `helm`
and network access to each wrapper chart's own upstream dependency
repository.

A marker file gitops/cells/<cell>/addons/<addon>.yaml is the only thing
addons-optional.ApplicationSet.yaml reads; gitops/addon-catalog/<name>/
addon.yaml is never read by any ApplicationSet. This script is the one
place the two are compared, and enforces Decision 3's five checks:

  (0) the marker's filename stem, its `addon` field and its
      `fromCatalog` field are the identical string, and that string is
      unique across the same cell's capacity-pool/*.yaml, smoke/*.yaml
      and addons/*.yaml (capacity-pool/smoke share cells.ApplicationSet's
      "{{ .name }}-{{ .addon }}" Application name template);
  (1) the fromCatalog entry exists under gitops/addon-catalog/, its tier
      is platform-optional (never workload, never core), and the marker's
      own dir/namespace/skipCrds equal the catalog entry's own values
      (values/valuesFrom are exempt here; check (4) bounds them);
  (2) the marker's wave is one of optional-1..optional-4;
  (3) every dependsOn entry on the catalog entry resolves by the two-step
      lookup: gitops/addons/<dep>/addon.yaml exists (core, always
      satisfied), or gitops/addon-catalog/<dep>/addon.yaml exists with
      tier platform-optional AND the same cell carries a sibling marker
      addons/<dep>.yaml whose wave is strictly earlier; anything else is
      unresolvable and rejected;
  (4) every dotted path a marker sets through `values` or
      `valuesFrom[].helmKey` is listed, exactly (never by prefix), in the
      catalog entry's own overridableKeys.

It also checks what those five depend on and nothing reads otherwise:
every catalog entry's own shape (overridableKeys mandatory for every
tier; addon/dir/namespace for platform-optional; dependsOn resolvable),
the overridableKeys list itself against the wrapper chart's coalesced
default values (a kind: scalar path must resolve to a scalar, a kind:
object path to a map or list, and a path that does not resolve at all
fails), and that addons-optional.ApplicationSet.yaml's own RollingSync
steps and Git file glob are the ones checks (2) and (3) assume.

The coalesced default tree is the one `helm template` itself renders
from -- the wrapper's values.yaml coalesced over every dependency's own
default values.yaml, with `global` propagated -- not the wrapper's
values.yaml in isolation (which is all `helm show values` prints). This
script obtains it from Helm itself rather than re-implementing Helm's
merge rules: it copies the chart to a temporary directory, runs `helm
dependency build` there (never in the repository), replaces the copy's
own templates with a single template that dumps `.Values`, and parses
the `helm template` output. The repository checkout is never modified.

Run with a pinned PyYAML, e.g.:
    uv run --no-project -q --with pyyaml==6.0.2 python3 check_addon_catalog_sync.py <repo-root>
Optional environment: HELM (helm).

Prints one "PASS <label>" or "FAIL <label>: <reason>" line per check and
exits 1 if any check failed, 0 otherwise.
"""
from __future__ import annotations

import glob
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

FAILURES: list[str] = []

# Decision 3: addons-optional.ApplicationSet.yaml's four RollingSync
# steps, in order. Check (2) accepts exactly these; check (3) compares
# positions in this list. check_appset_shape() below confirms the
# ApplicationSet's own steps are these, in this order.
WAVE_ORDER = ["optional-1", "optional-2", "optional-3", "optional-4"]
OPTIONAL_APPSET = "gitops/appsets/addons-optional.ApplicationSet.yaml"
MARKER_GLOB = "gitops/cells/{{ .name }}/addons/*.yaml"
KINDS = ("scalar", "object")


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def load_one(path: str, rel: str) -> dict | None:
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


# ------------------------------------------------------- dotted paths
#
# A dotted path names a Helm value the same way `helm --set` and an Argo
# CD `parameters[].name` do: segments separated by ".", with "\." for a
# literal dot inside one key (a nodeSelector label key, for example).


def split_path(path: str) -> list[str]:
    parts, cur, i = [], "", 0
    while i < len(path):
        c = path[i]
        if c == "\\" and i + 1 < len(path) and path[i + 1] == ".":
            cur += "."
            i += 2
            continue
        if c == ".":
            parts.append(cur)
            cur = ""
        else:
            cur += c
        i += 1
    parts.append(cur)
    return parts


def join_path(parts: list[str]) -> str:
    return ".".join(p.replace(".", "\\.") for p in parts)


_MISSING = object()


def resolve(tree, path: str):
    cur = tree
    for seg in split_path(path):
        if not isinstance(cur, dict) or seg not in cur:
            return _MISSING
        cur = cur[seg]
    return cur


def parse_overridable(entries, rel: str) -> dict[str, str] | None:
    """{path: kind} from an overridableKeys list, or None (after
    recording a FAIL) if the list itself is malformed. A bare string is
    shorthand for {path: <string>, kind: scalar}."""
    if not isinstance(entries, list):
        check(f"{rel} has an overridableKeys list (issue #41 Decision 2(b): mandatory, even if empty)", False, f"got {entries!r}")
        return None
    out: dict[str, str] = {}
    ok = True
    for e in entries:
        if isinstance(e, str) and e:
            path, kind = e, "scalar"
        elif isinstance(e, dict) and isinstance(e.get("path"), str) and e.get("path") and set(e) <= {"path", "kind"}:
            path, kind = e["path"], e.get("kind", "scalar")
        else:
            check(f"{rel} overridableKeys entry {e!r} is a dotted path or {{path, kind}}", False)
            ok = False
            continue
        if kind not in KINDS:
            check(f"{rel} overridableKeys entry {path!r} has kind scalar or object", False, f"got kind={kind!r}")
            ok = False
            continue
        if path in out:
            check(f"{rel} overridableKeys lists {path!r} once", False)
            ok = False
            continue
        out[path] = kind
    if ok:
        check(f"{rel} has a well-formed overridableKeys list ({len(out)} path(s))", True)
    return out


def marker_value_paths(values, allowed: dict[str, str]) -> list[tuple[str, object]]:
    """Every dotted path a marker's `values` sets, with the value set
    there. Descends into a map unless the path reached so far is listed
    as kind: object -- that is the one case a marker sets a whole map
    or list at once, and it is matched as that single path, not by its
    own leaves. Anything else is walked down to its leaves (a scalar, a
    list, or an empty map), and each leaf's full path must itself be
    listed exactly."""
    out: list[tuple[str, object]] = []

    def walk(node, parts):
        path = join_path(parts)
        if parts and allowed.get(path) == "object":
            out.append((path, node))
            return
        if isinstance(node, dict) and node:
            for k, v in node.items():
                walk(v, parts + [str(k)])
            return
        out.append((path, node))

    if isinstance(values, dict):
        for k, v in values.items():
            walk(v, [str(k)])
    return out


# ------------------------------------------------ coalesced defaults


VALUES_DUMP_TEMPLATE = """\
apiVersion: v1
kind: ConfigMap
metadata:
  name: overridable-keys-values-dump
data:
  values.yaml: |
{{ toYaml .Values | indent 4 }}
"""


def coalesced_defaults(chart_dir: str, helm: str) -> tuple[dict | None, str]:
    try:
        return _coalesced_defaults(chart_dir, helm)
    except (OSError, subprocess.TimeoutExpired, yaml.YAMLError) as e:
        return None, f"{type(e).__name__}: {e}"


def _coalesced_defaults(chart_dir: str, helm: str) -> tuple[dict | None, str]:
    """(tree, "") or (None, error). The values tree `helm template` renders
    chart_dir from, with no values file supplied: Helm's own coalescing
    of the chart's values.yaml over each dependency's defaults, global
    propagated. Works on a temporary copy; chart_dir is never written."""
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, os.path.basename(chart_dir.rstrip("/")))
        shutil.copytree(chart_dir, copy, ignore=shutil.ignore_patterns("charts"))
        with open(os.path.join(copy, "Chart.yaml"), encoding="utf-8") as f:
            meta = yaml.safe_load(f) or {}
        if meta.get("dependencies"):
            proc = subprocess.run(
                [helm, "dependency", "build", copy], capture_output=True, text=True, timeout=600
            )
            if proc.returncode != 0:
                return None, f"helm dependency build: {proc.stderr.strip() or proc.stdout.strip()}"
        # The wrapper's own templates cannot change .Values, so dropping
        # them only removes failure modes unrelated to this check (a
        # required() guard on a cell-specific value); every dependency's
        # templates still render, unchanged, from inside charts/.
        templates = os.path.join(copy, "templates")
        shutil.rmtree(templates, ignore_errors=True)
        os.makedirs(templates)
        with open(os.path.join(templates, "zz-values-dump.yaml"), "w", encoding="utf-8") as f:
            f.write(VALUES_DUMP_TEMPLATE)
        proc = subprocess.run(
            [helm, "template", "overridable-keys-check", copy, "--show-only", "templates/zz-values-dump.yaml"],
            capture_output=True, text=True, timeout=300,
        )
        if proc.returncode != 0:
            return None, f"helm template: {proc.stderr.strip() or proc.stdout.strip()}"
        for doc in yaml.safe_load_all(proc.stdout):
            if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
                tree = yaml.safe_load((doc.get("data") or {}).get("values.yaml") or "{}")
                return (tree if isinstance(tree, dict) else {}), ""
        return None, "helm template printed no values dump"


# ------------------------------------------------------------ checks


_DIGEST_RE = re.compile(r"sha256:([0-9a-f]{64})")
_EXACT_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[.\-+][0-9A-Za-z.\-+]*)?$")


def check_dependency_pin(chart_dir: str, rel_chart_yaml: str, helm: str) -> None:
    """Issue #41 Decision 4 row 1: "the pin lives one level down ... the
    wrapper's own Chart.yaml dependencies[].version with the same
    OCI-digest comment convention karpenter/karpenter-crd already use".
    Extended here (not done by any existing script) to every wrapper
    Chart.yaml a platform-optional catalog entry's dir points at: each
    dependency's version is an exact pin (no range operator Helm's own
    SemVer constraint syntax would accept -- ^, ~, >, <, *, a comma or a
    space), a sha256 digest appears in a comment anywhere in the file,
    and that digest is the one the dependency actually resolves to today
    (not merely a string recorded once and never checked again): this
    function runs `helm dependency build` on a throwaway copy and hashes
    the fetched tarball itself. A stale digest comment -- the dependency
    bumped without updating the comment -- fails here instead of silently
    drifting, the same drift check #0.static.sh already applies to the
    karpenter/kueue chart versions it does track (check_pinned_crds.py)."""
    chart_yaml_path = os.path.join(chart_dir, "Chart.yaml")
    with open(chart_yaml_path, encoding="utf-8") as f:
        raw = f.read()
    meta = yaml.safe_load(raw) or {}
    deps = meta.get("dependencies") or []
    if not deps:
        return
    for dep in deps:
        name, version = dep.get("name"), dep.get("version")
        check(
            f"{rel_chart_yaml}: dependency {name!r}'s version {version!r} is an exact pin, not a range (issue #41 Decision 4 row 1)",
            isinstance(version, str) and bool(_EXACT_VERSION_RE.match(version)),
        )
    digest_match = _DIGEST_RE.search(raw)
    check(f"{rel_chart_yaml} has a sha256 digest comment for its dependency (issue #41 Decision 4 row 1)", digest_match is not None)
    if digest_match is None:
        return
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, os.path.basename(chart_dir.rstrip("/")))
        shutil.copytree(chart_dir, copy, ignore=shutil.ignore_patterns("charts"))
        proc = subprocess.run([helm, "dependency", "build", copy], capture_output=True, text=True, timeout=600)
        if proc.returncode != 0:
            check(f"{rel_chart_yaml}: helm dependency build to verify the digest", False, proc.stderr.strip() or proc.stdout.strip())
            return
        tgzs = glob.glob(os.path.join(copy, "charts", "*.tgz"))
        if len(tgzs) != 1:
            check(f"{rel_chart_yaml}: exactly one fetched dependency tarball to hash", False, f"found {tgzs}")
            return
        with open(tgzs[0], "rb") as f:
            got = hashlib.sha256(f.read()).hexdigest()
        check(
            f"{rel_chart_yaml}'s comment digest matches the dependency's actual fetched tarball (issue #41 Decision 4 row 1 -- a drift check, not a one-time record)",
            got == digest_match.group(1),
            f"comment says {digest_match.group(1)}, fetched tarball hashes to {got}",
        )


def check_appset_shape(root: str) -> None:
    path = os.path.join(root, OPTIONAL_APPSET)
    if not os.path.isfile(path):
        check(f"{OPTIONAL_APPSET} exists", False)
        return
    doc = load_one(path, OPTIONAL_APPSET)
    if doc is None:
        return
    spec = doc.get("spec") or {}
    steps = ((spec.get("strategy") or {}).get("rollingSync") or {}).get("steps") or []
    step_values = []
    for step in steps:
        vals = [v for m in step.get("matchExpressions", []) if m.get("key") == "distai.dev/wave" for v in m.get("values", [])]
        step_values.append(vals)
    check(
        f"{OPTIONAL_APPSET}'s RollingSync steps are {WAVE_ORDER}, one wave per step, in that order (the ordering checks (2)/(3) assume)",
        step_values == [[w] for w in WAVE_ORDER],
        f"got {step_values}",
    )
    files = []
    for gen in spec.get("generators", []):
        for child in (gen.get("matrix") or {}).get("generators", []):
            files += [f.get("path") for f in (child.get("git") or {}).get("files", [])]
    check(
        f"{OPTIONAL_APPSET}'s only Git file glob is {MARKER_GLOB} (the files this script checks are the files it delivers)",
        files == [MARKER_GLOB],
        f"got {files}",
    )
    template_spec = (spec.get("template") or {}).get("spec") or {}
    source = template_spec.get("source") or {}
    check(f"{OPTIONAL_APPSET}'s template targets project platform (issue #41 Decision 3)", template_spec.get("project") == "platform", f"got {template_spec.get('project')!r}")
    check(
        f"{OPTIONAL_APPSET}'s base source is path: \"{{{{ .dir }}}}\" with no chart (every platform-optional marker is dir-only, issue #41 Decision 3)",
        source.get("path") == "{{ .dir }}" and "chart" not in source,
        f"got source={source!r}",
    )


def main(root: str) -> int:
    helm = os.environ.get("HELM", "helm")
    gitops = os.path.join(root, "gitops")
    addons_root = os.path.join(gitops, "addons")
    catalog_root = os.path.join(gitops, "addon-catalog")

    def core_exists(name: str) -> bool:
        return os.path.isfile(os.path.join(addons_root, name, "addon.yaml"))

    catalog: dict[str, dict] = {}
    for path in sorted(glob.glob(os.path.join(catalog_root, "*", "addon.yaml"))):
        name = os.path.basename(os.path.dirname(path))
        doc = load_one(path, os.path.relpath(path, root))
        if doc is not None:
            catalog[name] = doc

    check_appset_shape(root)

    # --------------------------------------------- catalog entries alone
    allow: dict[str, dict[str, str]] = {}
    for name, doc in sorted(catalog.items()):
        rel = f"gitops/addon-catalog/{name}/addon.yaml"
        tier = doc.get("tier")
        if tier != "platform-optional":
            # Issue #41 Decision 2(b): "a tier: workload catalog entry
            # carries only tier: workload and whatever #22's own path
            # later requires" -- not dir, and not a mandatory
            # overridableKeys either, since nothing in this RFC delivers
            # a workload entry or reads its overridableKeys. Parse it only
            # if the author chose to include one anyway (still validated,
            # just not required); a wrong tier is check_addon_tiers.py's
            # to report.
            if doc.get("overridableKeys") is not None:
                parsed = parse_overridable(doc.get("overridableKeys"), rel)
                if parsed is not None:
                    allow[name] = parsed
            continue
        parsed = parse_overridable(doc.get("overridableKeys"), rel)
        if parsed is not None:
            allow[name] = parsed
        check(f"{rel} has an addon field (platform-optional)", isinstance(doc.get("addon"), str) and bool(doc.get("addon")))
        dir_ = doc.get("dir")
        dir_ok = isinstance(dir_, str) and dir_.startswith("gitops/charts/")
        check(f"{rel}'s dir is a local chart under gitops/charts/ (issue #41 Decision 3: platform-optional is dir-only)", dir_ok, f"got dir={dir_!r}")
        for k in ("chart", "repoURL", "version"):
            check(f"{rel} has no {k!r} (dir-only, never an upstream chart directly)", k not in doc)
        if dir_ok:
            check(f"{rel}'s dir {dir_} is a chart (has Chart.yaml)", os.path.isfile(os.path.join(root, dir_, "Chart.yaml")))
        check(f"{rel} has a non-empty namespace", isinstance(doc.get("namespace"), str) and bool(doc.get("namespace")), f"got {doc.get('namespace')!r}")
        if "skipCrds" in doc:
            check(f"{rel}'s skipCrds is a boolean", isinstance(doc["skipCrds"], bool), f"got {doc['skipCrds']!r}")
        if "wave" in doc:
            check(f"{rel} carries no wave (the wave is each cell's marker's own choice)", False)
        deps = doc.get("dependsOn", [])
        if not (isinstance(deps, list) and all(isinstance(d, str) and d for d in deps)):
            check(f"{rel}'s dependsOn is a list of names", False, f"got {deps!r}")
        else:
            for dep in deps:
                resolvable = core_exists(dep) or (dep in catalog and catalog[dep].get("tier") == "platform-optional")
                check(
                    f"{rel}'s dependsOn {dep!r} names gitops/addons/{dep}/ (core) or a platform-optional gitops/addon-catalog/{dep}/ (issue #41 Decision 3)",
                    resolvable,
                    "unresolvable: an infra-level or Argo CD prerequisite belongs in the catalog entry's README, not dependsOn",
                )

        if not dir_ok or not os.path.isfile(os.path.join(root, dir_, "Chart.yaml")):
            continue
        check_dependency_pin(os.path.join(root, dir_), f"{dir_}/Chart.yaml", helm)

        # overridableKeys against the chart's own coalesced defaults.
        if parsed is None:
            continue
        tree, err = coalesced_defaults(os.path.join(root, dir_), helm)
        if tree is None:
            check(f"{rel}: coalesced default values of {dir_} obtained (helm dependency build + helm template)", False, err)
            continue
        for path, kind in sorted(parsed.items()):
            val = resolve(tree, path)
            if val is _MISSING:
                check(f"{rel} overridableKeys {path!r} resolves in {dir_}'s coalesced defaults", False, "no such key (typo, or renamed upstream)")
            elif kind == "object":
                check(f"{rel} overridableKeys {path!r} (kind: object) resolves to a map or list", isinstance(val, (dict, list)), f"got {type(val).__name__}")
            else:
                check(
                    f"{rel} overridableKeys {path!r} (kind: scalar) resolves to a scalar (a map or list needs an explicit kind: object)",
                    not isinstance(val, (dict, list)),
                    f"got {type(val).__name__}",
                )

    # ---------------------------------------------------- marker files
    markers = sorted(glob.glob(os.path.join(gitops, "cells", "*", "addons", "*.yaml")))
    if not markers:
        print("INFO no gitops/cells/*/addons/*.yaml marker file; checks (0)-(4) have nothing to compare")

    def addon_names(cell_dir: str) -> list[str]:
        names = []
        for sub in ("capacity-pool", "smoke", "addons"):
            for p in sorted(glob.glob(os.path.join(cell_dir, sub, "*.yaml"))):
                d = load_one(p, os.path.relpath(p, root))
                if d is not None:
                    names.append(d.get("addon"))
        return names

    cell_names: dict[str, list[str]] = {}
    for path in markers:
        rel = os.path.relpath(path, root)
        cell_dir = os.path.dirname(os.path.dirname(path))
        stem = os.path.splitext(os.path.basename(path))[0]
        doc = load_one(path, rel)
        if doc is None:
            continue
        addon = doc.get("addon")
        from_catalog = doc.get("fromCatalog")

        # (0)
        check(
            f"{rel}: filename stem, addon and fromCatalog are identical (issue #41 Decision 3 check (0))",
            stem == addon == from_catalog,
            f"stem={stem!r} addon={addon!r} fromCatalog={from_catalog!r}",
        )
        if cell_dir not in cell_names:
            cell_names[cell_dir] = addon_names(cell_dir)
        count = cell_names[cell_dir].count(addon)
        check(
            f"{rel}: addon {addon!r} is unique across {os.path.relpath(cell_dir, root)}/{{capacity-pool,smoke,addons}}/*.yaml (check (0))",
            count == 1,
            f"appears {count} time(s)",
        )
        for k in ("chart", "repoURL", "version"):
            check(f"{rel} has no {k!r} (markers are dir-only, issue #41 Decision 3)", k not in doc)
        for entry in doc.get("valuesFrom") or []:
            ok = isinstance(entry, dict) and bool(entry.get("helmKey")) and (("annotationKey" in entry) != ("param" in entry))
            check(f"{rel} valuesFrom entry {entry!r} has helmKey and exactly one of annotationKey/param", ok)

        # (2)
        wave = doc.get("wave")
        check(f"{rel}: wave is one of {WAVE_ORDER} (check (2))", wave in WAVE_ORDER, f"got wave={wave!r}")

        # (1)
        entry = catalog.get(from_catalog) if isinstance(from_catalog, str) else None
        check(f"{rel}: fromCatalog {from_catalog!r} names an existing gitops/addon-catalog/<name>/addon.yaml (check (1))", entry is not None)
        if entry is None:
            continue
        tier = entry.get("tier")
        check(
            f"{rel}: catalog entry {from_catalog!r} is tier platform-optional (check (1) -- never workload, never core)",
            tier == "platform-optional",
            f"got tier={tier!r}",
        )
        if tier != "platform-optional":
            continue
        for k in ("dir", "namespace", "skipCrds"):
            check(
                f"{rel}: {k} equals catalog entry {from_catalog!r}'s own {k} (check (1))",
                doc.get(k) == entry.get(k),
                f"marker {k}={doc.get(k)!r}, catalog {k}={entry.get(k)!r}",
            )

        # (3) -- dependencies come from the catalog entry, never the marker.
        deps = entry.get("dependsOn", [])
        if isinstance(deps, list):
            for dep in deps:
                if not isinstance(dep, str):
                    continue
                if core_exists(dep):
                    check(f"{rel}: dependsOn {dep!r} resolves to gitops/addons/{dep}/ (core, always delivered) (check (3))", True)
                    continue
                dep_entry = catalog.get(dep)
                sibling = os.path.join(cell_dir, "addons", f"{dep}.yaml")
                sibling_doc = load_one(sibling, os.path.relpath(sibling, root)) if os.path.isfile(sibling) else None
                if dep_entry is None or dep_entry.get("tier") != "platform-optional":
                    check(
                        f"{rel}: dependsOn {dep!r} resolves (check (3))",
                        False,
                        "neither gitops/addons/<dep>/ nor a platform-optional gitops/addon-catalog/<dep>/ exists",
                    )
                elif sibling_doc is None:
                    check(
                        f"{rel}: dependsOn {dep!r} has a sibling marker {os.path.relpath(sibling, root)} in the same cell (check (3))",
                        False,
                    )
                else:
                    dep_wave = sibling_doc.get("wave")
                    earlier = dep_wave in WAVE_ORDER and wave in WAVE_ORDER and WAVE_ORDER.index(dep_wave) < WAVE_ORDER.index(wave)
                    check(
                        f"{rel}: dependsOn {dep!r}'s marker wave is strictly earlier than this marker's (check (3))",
                        earlier,
                        f"{dep} wave={dep_wave!r}, {addon} wave={wave!r}",
                    )

        # (4)
        allowed = allow.get(from_catalog)
        if allowed is None:
            check(f"{rel}: catalog entry {from_catalog!r} has a usable overridableKeys list (check (4))", False)
            continue
        set_paths = [p for p, _ in marker_value_paths(doc.get("values"), allowed)]
        set_paths += [e["helmKey"] for e in (doc.get("valuesFrom") or []) if isinstance(e, dict) and isinstance(e.get("helmKey"), str)]
        if "values" in doc and not isinstance(doc.get("values"), (dict, type(None))):
            check(f"{rel}: values is a map", False, f"got {type(doc['values']).__name__}")
        for p in set_paths:
            kind = allowed.get(p)
            check(
                f"{rel}: sets {p!r}, listed exactly in catalog entry {from_catalog!r}'s overridableKeys (check (4) -- no prefix match)",
                kind is not None,
                f"listed: {sorted(allowed)}",
            )
        for p, v in marker_value_paths(doc.get("values"), allowed):
            if allowed.get(p) == "scalar":
                check(f"{rel}: {p!r} (kind: scalar) is set to a scalar", not isinstance(v, (dict, list)), f"got {type(v).__name__}")
        if not set_paths:
            check(f"{rel}: sets no values/valuesFrom (takes every catalog default) (check (4))", True)

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all add-on catalog sync checks passed")
    return 0


# ------------------------------------------------------------- selftest
#
# DA-24/DA-43/C-53: build one mutated copy per rule, confirm it fails
# only that rule against an otherwise-passing baseline. The chart each
# catalog entry's `dir` points at is local-only (no Chart.yaml
# `dependencies`), so every case below runs offline -- `check_dependency_pin`
# returns immediately with nothing to check, and `coalesced_defaults`
# needs only a local `helm template`, no network.

_APPSET_FIXTURE = """\
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: addons-optional
spec:
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  argocd.argoproj.io/secret-type: cluster
          - git:
              repoURL: https://example.invalid/repo.git
              files:
                - path: "gitops/cells/{{ .name }}/addons/*.yaml"
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions: [{key: distai.dev/wave, operator: In, values: ["optional-1"]}]
        - matchExpressions: [{key: distai.dev/wave, operator: In, values: ["optional-2"]}]
        - matchExpressions: [{key: distai.dev/wave, operator: In, values: ["optional-3"]}]
        - matchExpressions: [{key: distai.dev/wave, operator: In, values: ["optional-4"]}]
  template:
    spec:
      project: platform
      source:
        path: "{{ .dir }}"
"""


def _write(root: str, rel: str, doc: dict) -> None:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f)


def _write_text(root: str, rel: str, text: str) -> None:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _write_chart(root: str, name: str) -> None:
    base = f"gitops/charts/{name}"
    _write_text(root, f"{base}/Chart.yaml", f"apiVersion: v2\nname: {name}\nversion: 0.1.0\n")
    _write_text(root, f"{base}/values.yaml", "foo: bar\nresources:\n  cpu: 1\n")
    _write_text(root, f"{base}/templates/cm.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x}\ndata: {}\n")


def _baseline2(root: str) -> None:
    _write_text(root, "gitops/appsets/addons-optional.ApplicationSet.yaml", _APPSET_FIXTURE)
    _write_chart(root, "widget")
    _write(root, "gitops/addon-catalog/widget/addon.yaml", {
        "addon": "widget", "tier": "platform-optional", "dir": "gitops/charts/widget",
        "namespace": "ns", "overridableKeys": [{"path": "resources", "kind": "object"}],
    })
    _write(root, "gitops/cells/testcell/addons/widget.yaml", {
        "addon": "widget", "fromCatalog": "widget", "dir": "gitops/charts/widget",
        "namespace": "ns", "wave": "optional-1",
    })


def selftest() -> int:
    import shutil
    import tempfile

    cases: list = []

    def case(name, mutate, expect_substr):
        cases.append((name, mutate, expect_substr))

    case("baseline passes with zero failures", lambda root: None, None)
    case(
        "marker stem != addon/fromCatalog fails only check (0)",
        lambda root: _write(root, "gitops/cells/testcell/addons/widget.yaml", {
            "addon": "widget-renamed", "fromCatalog": "widget-renamed", "dir": "gitops/charts/widget",
            "namespace": "ns", "wave": "optional-1",
        }),
        "check (0)",
    )
    case(
        "catalog entry is tier: workload referenced by a marker fails check (1)",
        lambda root: _write(root, "gitops/addon-catalog/widget/addon.yaml", {
            "addon": "widget", "tier": "workload",
        }),
        "never workload, never core",
    )
    case(
        "marker dir differs from catalog dir fails check (1)",
        lambda root: _write(root, "gitops/cells/testcell/addons/widget.yaml", {
            "addon": "widget", "fromCatalog": "widget", "dir": "gitops/charts/widget-wrong",
            "namespace": "ns", "wave": "optional-1",
        }),
        "equals catalog entry",
    )
    case(
        "marker wave outside optional-1..4 fails check (2)",
        lambda root: _write(root, "gitops/cells/testcell/addons/widget.yaml", {
            "addon": "widget", "fromCatalog": "widget", "dir": "gitops/charts/widget",
            "namespace": "ns", "wave": "capacity",
        }),
        "check (2)",
    )
    def _depends_unresolvable(root):
        _write(root, "gitops/addon-catalog/widget/addon.yaml", {
            "addon": "widget", "tier": "platform-optional", "dir": "gitops/charts/widget",
            "namespace": "ns", "overridableKeys": [], "dependsOn": ["nonexistent-thing"],
        })
    case("dependsOn naming nothing real fails check (3), catalog side", _depends_unresolvable, "unresolvable")

    def _depends_no_sibling(root):
        _write_chart(root, "base")
        _write(root, "gitops/addon-catalog/base/addon.yaml", {
            "addon": "base", "tier": "platform-optional", "dir": "gitops/charts/base",
            "namespace": "ns", "overridableKeys": [],
        })
        _write(root, "gitops/addon-catalog/widget/addon.yaml", {
            "addon": "widget", "tier": "platform-optional", "dir": "gitops/charts/widget",
            "namespace": "ns", "overridableKeys": [], "dependsOn": ["base"],
        })
    case("dependsOn with no sibling marker in the same cell fails check (3)", _depends_no_sibling, "sibling marker")

    def _depends_wrong_order(root):
        _depends_no_sibling(root)
        _write(root, "gitops/cells/testcell/addons/base.yaml", {
            "addon": "base", "fromCatalog": "base", "dir": "gitops/charts/base",
            "namespace": "ns", "wave": "optional-2",  # later than widget's optional-1: wrong order
        })
    case("dependsOn sibling marker in a later wave fails check (3)", _depends_wrong_order, "strictly earlier")

    case(
        "marker sets a value not in overridableKeys fails check (4)",
        lambda root: _write(root, "gitops/cells/testcell/addons/widget.yaml", {
            "addon": "widget", "fromCatalog": "widget", "dir": "gitops/charts/widget",
            "namespace": "ns", "wave": "optional-1", "values": {"notAllowed": "x"},
        }),
        "no prefix match",
    )
    case(
        "overridableKeys lists a path that does not resolve in the chart's defaults fails",
        lambda root: _write(root, "gitops/addon-catalog/widget/addon.yaml", {
            "addon": "widget", "tier": "platform-optional", "dir": "gitops/charts/widget",
            "namespace": "ns", "overridableKeys": [{"path": "typoPath", "kind": "scalar"}],
        }),
        "no such key",
    )
    case(
        "overridableKeys kind: scalar on a path that resolves to a map fails",
        lambda root: _write(root, "gitops/addon-catalog/widget/addon.yaml", {
            "addon": "widget", "tier": "platform-optional", "dir": "gitops/charts/widget",
            "namespace": "ns", "overridableKeys": [{"path": "resources", "kind": "scalar"}],
        }),
        "a map or list needs an explicit kind: object",
    )
    case(
        "tier: workload catalog entry needs no overridableKeys (issue #41 Decision 2(b))",
        lambda root: _write(root, "gitops/addon-catalog/widget/addon.yaml", {"addon": "widget", "tier": "workload"}),
        None,
    )

    failures = 0
    for name, mutate, expect_substr in cases:
        tmp = tempfile.mkdtemp(prefix="check-addon-catalog-sync-selftest-")
        try:
            _baseline2(tmp)
            mutate(tmp)
            if name.startswith("tier: workload catalog entry needs no overridableKeys"):
                # This case intentionally also removes the marker that
                # would otherwise reference the now-workload entry: a
                # workload entry is never a valid fromCatalog target
                # (check (1) would correctly fail it), which is a
                # different rule than the one this case tests.
                os.remove(os.path.join(tmp, "gitops/cells/testcell/addons/widget.yaml"))
            global FAILURES
            FAILURES = []
            import contextlib
            import io

            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = main(tmp)
            fails = list(FAILURES)
            if expect_substr is None:
                ok = rc == 0 and not fails
                detail = f"expected a clean pass, got rc={rc} failures={fails}"
            else:
                ok = rc != 0 and any(expect_substr in f for f in fails)
                detail = f"expected the {expect_substr!r} rule among the failures, got {fails}"
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
        print("usage: check_addon_catalog_sync.py <repo-root> | check_addon_catalog_sync.py --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
