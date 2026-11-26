#!/usr/bin/env python3
"""JobSet delivery checks (issue #34): the core `jobset-crd` add-on, the
platform-optional `jobset` catalog entry, and the one fact about the
`kueue` add-on the issue relies on without changing that file.

check_addon_tiers.py and check_addon_catalog_sync.py already apply the
generic tier, naming, dir-only, dependsOn, overridableKeys and
dependency-pin rules to every add-on directory that exists, these two
included, with no change to either script. What neither of them can know
is the shape this one pair has to have for the issue's own design to
hold, so this script checks exactly that and nothing generic:

  1. gitops/addons/jobset-crd/addon.yaml is `tier: core`, `wave: crds`,
     `dir: gitops/charts/jobset-crd`, with no `chart`/`repoURL`/`version`
     -- a vendored local chart in the core `crds` step, ahead of the
     controller, the same reason `karpenter-crd` precedes `karpenter`;
  2. gitops/charts/jobset-crd/ is CRD-only: no Helm `dependencies`, and
     `helm template` (no --include-crds) renders nothing at all, so this
     Application owns the CRD and nothing else (the issue's own reason
     for vendoring instead of depending on the full upstream chart:
     no double ownership of the controller's Deployment/webhook);
  3. its crds/ folder holds exactly one *.yaml file, which is exactly
     one YAML document: an apiextensions.k8s.io/v1
     CustomResourceDefinition named jobsets.jobset.x-k8s.io, spec.group
     jobset.x-k8s.io, names.kind JobSet, names.plural jobsets,
     Namespaced, serving and storing v1alpha2 (the apiVersion the
     worked example's JobSet uses);
  4. that file's leading comment block cites the upstream version and a
     sha256 digest; the digest equals the sha256 of the file's own body
     (everything after that leading comment block), so "copied
     verbatim" is checked, not only stated; and the cited version is
     the exact version gitops/charts/jobset/Chart.yaml pins for its
     upstream dependency -- the CRD and the controller form a version
     pair, the same rule gitops/README.md states for
     karpenter/karpenter-crd;
  5. gitops/addon-catalog/jobset/addon.yaml is `tier:
     platform-optional`, `dir: gitops/charts/jobset`, lists `jobset-crd`
     in `dependsOn`, and sets `skipCrds: true` (a real boolean);
  6. gitops/charts/jobset/Chart.yaml has exactly one dependency, named
     `jobset`, from oci://registry.k8s.io/jobset/charts;
  7. gitops/addons/kueue/addon.yaml does not override Kueue's own
     integrations list away from JobSet: no `integrations` key anywhere
     in its values, and a `managerConfig` override (if one is ever
     added) still names jobset.x-k8s.io/jobset.

With --network (0.static.sh passes it; it needs the same registry access
check_addon_catalog_sync.py and check_pinned_crds.py already need):

  N1. the vendored CRD's body is semantically identical to the CRD the
      pinned upstream jobset chart itself ships in its own crds/ folder
      (`helm pull` of exactly the wrapper's pinned version) -- a drift
      check, not a one-time record;
  N2. the wrapper chart, rendered the way `skipCrds: true` makes Argo CD
      render it (no CRDs), contains no CustomResourceDefinition, does
      contain the controller Deployment and at least one webhook
      configuration, and ships a NetworkPolicy selecting the controller
      Pod with no "every pod" ingress peer (gitops/README.md "NetworkPolicy
      defaults": an add-on exposing a port -- here the JobSet webhook --
      ships default deny and names its exception);
  N3. the pinned Kueue chart, rendered with kueue/addon.yaml's own
      values, really does list jobset.x-k8s.io/jobset in its manager
      configuration's integrations.frameworks (the issue's "no change
      needed" claim, re-derived from the exact pinned chart every run).

Run with pinned PyYAML, e.g.:
    uv run --no-project -q --with pyyaml==6.0.2 python3 check_jobset_addon.py <repo-root> [--network]
    uv run --no-project -q --with pyyaml==6.0.2 python3 check_jobset_addon.py --selftest
Optional environment: HELM (helm).

Prints one "PASS <label>" or "FAIL <label>: <reason>" line per check and
exits 1 if any check failed, 0 otherwise -- the same contract as the other
check_*.py scripts here.
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

CRD_ADDON = "gitops/addons/jobset-crd/addon.yaml"
CRD_CHART = "gitops/charts/jobset-crd"
CATALOG_ENTRY = "gitops/addon-catalog/jobset/addon.yaml"
WRAPPER_CHART = "gitops/charts/jobset"
KUEUE_ADDON = "gitops/addons/kueue/addon.yaml"

JOBSET_GROUP = "jobset.x-k8s.io"
JOBSET_CRD_NAME = "jobsets.jobset.x-k8s.io"
JOBSET_VERSION = "v1alpha2"
JOBSET_FRAMEWORK = "jobset.x-k8s.io/jobset"
UPSTREAM_REPOSITORY = "oci://registry.k8s.io/jobset/charts"

_DIGEST_RE = re.compile(r"sha256:([0-9a-f]{64})")


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


def split_header(text: str) -> tuple[str, str]:
    """(leading comment block, body). The header is every line from the
    top of the file that is a comment ("#...") or blank, up to the first
    line that is neither; the body is the rest, byte for byte."""
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines) and (lines[i].lstrip().startswith("#") or not lines[i].strip()):
        i += 1
    return "".join(lines[:i]), "".join(lines[i:])


def deep_keys(node, key: str) -> list:
    """Every value stored under `key` anywhere in a nested map/list."""
    out = []
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key:
                out.append(v)
            out += deep_keys(v, key)
    elif isinstance(node, list):
        for v in node:
            out += deep_keys(v, key)
    return out


def run(cmd: list[str], timeout: int = 600) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def render_docs(stdout: str) -> list[dict]:
    return [d for d in yaml.safe_load_all(stdout) if isinstance(d, dict)]


# --------------------------------------------------------------- checks


def check_crd_addon(root: str) -> None:
    path = os.path.join(root, CRD_ADDON)
    if not os.path.isfile(path):
        check(f"{CRD_ADDON} exists (issue #34: the JobSet CRD is a core add-on)", False)
        return
    doc = load_one(path, CRD_ADDON)
    if doc is None:
        return
    check(f"{CRD_ADDON} addon is 'jobset-crd'", doc.get("addon") == "jobset-crd", f"got {doc.get('addon')!r}")
    check(f"{CRD_ADDON} is tier: core (delivered to every cell, ahead of the optional controller)", doc.get("tier") == "core", f"got {doc.get('tier')!r}")
    check(f"{CRD_ADDON} is wave: crds (the CRD lands before anything that uses it)", doc.get("wave") == "crds", f"got {doc.get('wave')!r}")
    check(f"{CRD_ADDON} dir is {CRD_CHART} (the vendored, local CRD-only chart)", doc.get("dir") == CRD_CHART, f"got {doc.get('dir')!r}")
    for k in ("chart", "repoURL", "version"):
        check(f"{CRD_ADDON} has no {k!r} (dir-shaped: no upstream chart, no Helm dependency on the full JobSet chart)", k not in doc)


def check_crd_chart(root: str, helm: str) -> tuple[list[str] | None, str | None]:
    """Returns (versions cited in the leading comment block, body) of the
    vendored CRD file; either is None if it could not be established."""
    chart = os.path.join(root, CRD_CHART)
    chart_yaml = os.path.join(chart, "Chart.yaml")
    if not os.path.isfile(chart_yaml):
        check(f"{CRD_CHART}/Chart.yaml exists", False)
        return None, None
    meta = load_one(chart_yaml, f"{CRD_CHART}/Chart.yaml") or {}
    check(
        f"{CRD_CHART}/Chart.yaml has no dependencies (vendored CRD only, never the full upstream chart)",
        not meta.get("dependencies"),
        f"got dependencies={meta.get('dependencies')!r}",
    )

    proc = run([helm, "template", "jobset-crd-check", chart], timeout=120)
    if proc.returncode != 0:
        check(f"helm template {CRD_CHART} succeeds", False, proc.stderr.strip() or proc.stdout.strip())
    else:
        rendered = render_docs(proc.stdout)
        check(
            f"helm template {CRD_CHART} (no --include-crds) renders no object at all (this Application owns the CRD and nothing else)",
            not rendered,
            f"rendered kinds: {sorted({d.get('kind') for d in rendered})}",
        )

    crd_files = sorted(glob.glob(os.path.join(chart, "crds", "*.yaml")) + glob.glob(os.path.join(chart, "crds", "*.yml")))
    check(f"{CRD_CHART}/crds/ holds exactly one YAML file", len(crd_files) == 1, f"found {[os.path.relpath(f, root) for f in crd_files]}")
    if len(crd_files) != 1:
        return None, None
    rel = os.path.relpath(crd_files[0], root)
    with open(crd_files[0], encoding="utf-8") as f:
        text = f.read()
    try:
        docs = [d for d in yaml.safe_load_all(text) if d is not None]
    except yaml.YAMLError as e:
        check(f"{rel} parses as YAML", False, str(e))
        return None, None
    check(f"{rel} is exactly one YAML document", len(docs) == 1, f"found {len(docs)} document(s)")
    if len(docs) != 1 or not isinstance(docs[0], dict):
        return None, None
    crd = docs[0]
    spec = crd.get("spec") or {}
    names = spec.get("names") or {}
    check(f"{rel} is an apiextensions.k8s.io/v1 CustomResourceDefinition", crd.get("apiVersion") == "apiextensions.k8s.io/v1" and crd.get("kind") == "CustomResourceDefinition", f"got {crd.get('apiVersion')}/{crd.get('kind')}")
    check(f"{rel} metadata.name is {JOBSET_CRD_NAME}", (crd.get("metadata") or {}).get("name") == JOBSET_CRD_NAME, f"got {(crd.get('metadata') or {}).get('name')!r}")
    check(f"{rel} spec.group is {JOBSET_GROUP}", spec.get("group") == JOBSET_GROUP, f"got {spec.get('group')!r}")
    check(f"{rel} spec.names.kind is JobSet", names.get("kind") == "JobSet", f"got {names.get('kind')!r}")
    check(f"{rel} spec.names.plural is jobsets (the resource team-rbac-guard.yaml and team-onboard.sh grant)", names.get("plural") == "jobsets", f"got {names.get('plural')!r}")
    check(f"{rel} spec.scope is Namespaced (a team applies it into its own namespace)", spec.get("scope") == "Namespaced", f"got {spec.get('scope')!r}")
    versions = {v.get("name"): v for v in spec.get("versions") or [] if isinstance(v, dict)}
    v = versions.get(JOBSET_VERSION) or {}
    # Built outside the f-string on purpose, not nested inside one with the
    # same quote character: a same-quote nested f-string only parses on
    # Python 3.12+ (PEP 701), and nothing else in this repository's static
    # checks pins a Python version that high (gitops/tests/0.static.sh runs
    # this file the same way as every other uv-run check here).
    versions_summary = ", ".join(f"{n}: served={x.get('served')} storage={x.get('storage')}" for n, x in versions.items())
    check(
        f"{rel} serves and stores {JOBSET_VERSION} (the apiVersion the worked example's JobSet uses)",
        v.get("served") is True and v.get("storage") is True,
        f"versions: {{{versions_summary}}}",
    )

    header, body = split_header(text)
    m = _DIGEST_RE.search(header)
    check(f"{rel}'s leading comment block cites a sha256 digest of the upstream file", m is not None, "no 'sha256:<64 hex>' in the leading comment block")
    if m is not None:
        got = hashlib.sha256(body.encode("utf-8")).hexdigest()
        check(
            f"{rel}'s cited digest is the sha256 of its own body, after the leading comment block (the file is the upstream file verbatim)",
            got == m.group(1),
            f"cited {m.group(1)}, body hashes to {got}",
        )
    versions_cited = re.findall(r"\bv?(\d+\.\d+\.\d+)\b", header)
    check(f"{rel}'s leading comment block cites an upstream version", bool(versions_cited), "no x.y.z version in the leading comment block")
    return (versions_cited or None), body


def check_catalog_entry(root: str) -> None:
    path = os.path.join(root, CATALOG_ENTRY)
    if not os.path.isfile(path):
        check(f"{CATALOG_ENTRY} exists (issue #34: the JobSet controller is a platform-optional catalog entry)", False)
        return
    doc = load_one(path, CATALOG_ENTRY)
    if doc is None:
        return
    check(f"{CATALOG_ENTRY} addon is 'jobset'", doc.get("addon") == "jobset", f"got {doc.get('addon')!r}")
    check(f"{CATALOG_ENTRY} is tier: platform-optional (a cell opts in)", doc.get("tier") == "platform-optional", f"got {doc.get('tier')!r}")
    check(f"{CATALOG_ENTRY} dir is {WRAPPER_CHART}", doc.get("dir") == WRAPPER_CHART, f"got {doc.get('dir')!r}")
    deps = doc.get("dependsOn")
    check(f"{CATALOG_ENTRY} dependsOn lists jobset-crd", isinstance(deps, list) and "jobset-crd" in deps, f"got dependsOn={deps!r}")
    check(
        f"{CATALOG_ENTRY} sets skipCrds: true, the boolean (the CRD is jobset-crd's alone)",
        doc.get("skipCrds") is True,
        f"got skipCrds={doc.get('skipCrds')!r} ({type(doc.get('skipCrds')).__name__})",
    )


def check_wrapper_chart(root: str) -> dict | None:
    """Returns the one upstream dependency entry, or None."""
    rel = f"{WRAPPER_CHART}/Chart.yaml"
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        check(f"{rel} exists", False)
        return None
    meta = load_one(path, rel) or {}
    deps = meta.get("dependencies") or []
    check(f"{rel} has exactly one dependency (the upstream JobSet chart)", len(deps) == 1, f"got {deps!r}")
    if len(deps) != 1 or not isinstance(deps[0], dict):
        return None
    dep = deps[0]
    check(f"{rel}'s dependency is named 'jobset'", dep.get("name") == "jobset", f"got {dep.get('name')!r}")
    check(
        f"{rel}'s dependency repository is {UPSTREAM_REPOSITORY}",
        (dep.get("repository") or "").rstrip("/") == UPSTREAM_REPOSITORY,
        f"got {dep.get('repository')!r}",
    )
    return dep


def check_version_pair(cited: list[str] | None, dep: dict | None) -> None:
    if cited is None or dep is None:
        return
    pinned = str(dep.get("version") or "").lstrip("v")
    check(
        f"the vendored JobSet CRD's cited upstream version equals {WRAPPER_CHART}'s pinned dependency version {pinned!r} (CRD and controller are a version pair, like karpenter-crd/karpenter)",
        pinned in cited,
        f"versions cited in the CRD header: {cited}",
    )


def check_kueue_offline(root: str) -> None:
    path = os.path.join(root, KUEUE_ADDON)
    if not os.path.isfile(path):
        check(f"{KUEUE_ADDON} exists", False)
        return
    doc = load_one(path, KUEUE_ADDON)
    if doc is None:
        return
    values = doc.get("values") or {}
    check(
        f"{KUEUE_ADDON}'s values set no 'integrations' key (the chart's own default list, which includes {JOBSET_FRAMEWORK}, is what reaches the cell)",
        not deep_keys(values, "integrations"),
        f"found integrations={deep_keys(values, 'integrations')!r}",
    )
    for mc in deep_keys(values, "managerConfig"):
        check(
            f"{KUEUE_ADDON}'s managerConfig override still names {JOBSET_FRAMEWORK}",
            JOBSET_FRAMEWORK in yaml.safe_dump(mc),
        )


# ------------------------------------------------------- network checks


def network_crd_matches_upstream(root: str, helm: str, body: str | None, dep: dict | None) -> None:
    if body is None or dep is None:
        return
    ref = f"{(dep.get('repository') or '').rstrip('/')}/{dep.get('name')}"
    with tempfile.TemporaryDirectory() as tmp:
        proc = run([helm, "pull", ref, "--version", str(dep.get("version")), "--untar", "--untardir", tmp])
        if proc.returncode != 0:
            check(f"helm pull {ref} --version {dep.get('version')}", False, proc.stderr.strip() or proc.stdout.strip())
            return
        upstream = sorted(glob.glob(os.path.join(tmp, "*", "crds", "*.yaml")))
        upstream_docs = []
        for p in upstream:
            with open(p, encoding="utf-8") as f:
                upstream_docs += [d for d in yaml.safe_load_all(f) if isinstance(d, dict) and d.get("kind") == "CustomResourceDefinition"]
        check(f"the pinned upstream chart {ref}:{dep.get('version')} ships exactly one CRD in its crds/ folder", len(upstream_docs) == 1, f"found {len(upstream_docs)}")
        if len(upstream_docs) != 1:
            return
        vendored = [d for d in yaml.safe_load_all(body) if isinstance(d, dict)]
        check(
            f"{CRD_CHART}/crds/ is the same CRD the pinned upstream chart {ref}:{dep.get('version')} ships (drift check)",
            vendored == upstream_docs,
            "the vendored CRD differs from the upstream chart's own crds/ copy of that version",
        )


def network_wrapper_render(root: str, helm: str) -> None:
    chart = os.path.join(root, WRAPPER_CHART)
    if not os.path.isfile(os.path.join(chart, "Chart.yaml")):
        return
    catalog = load_one(os.path.join(root, CATALOG_ENTRY), CATALOG_ENTRY) if os.path.isfile(os.path.join(root, CATALOG_ENTRY)) else None
    namespace = (catalog or {}).get("namespace") or "jobset-system"
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "jobset")
        shutil.copytree(chart, copy, ignore=shutil.ignore_patterns("charts"))
        proc = run([helm, "dependency", "build", copy])
        if proc.returncode != 0:
            check(f"helm dependency build {WRAPPER_CHART} (temporary copy)", False, proc.stderr.strip() or proc.stdout.strip())
            return
        # skipCrds: true is Argo CD's --skip-crds; plain `helm template`
        # already omits every crds/ folder, which is the same output.
        proc = run([helm, "template", "jobset", copy, "--namespace", namespace], timeout=300)
        if proc.returncode != 0:
            check(f"helm template {WRAPPER_CHART}", False, proc.stderr.strip() or proc.stdout.strip())
            return
    docs = render_docs(proc.stdout)
    kinds = sorted({d.get("kind") for d in docs})
    check(
        f"{WRAPPER_CHART} rendered as skipCrds: true renders it contains no CustomResourceDefinition (no double ownership with jobset-crd)",
        "CustomResourceDefinition" not in kinds,
        f"kinds: {kinds}",
    )
    deployments = [d for d in docs if d.get("kind") == "Deployment"]
    check(f"{WRAPPER_CHART} renders the JobSet controller Deployment", len(deployments) >= 1, f"kinds: {kinds}")
    check(
        f"{WRAPPER_CHART} renders at least one webhook configuration (JobSet's own validating/mutating webhook)",
        any(d.get("kind") in ("ValidatingWebhookConfiguration", "MutatingWebhookConfiguration") for d in docs),
        f"kinds: {kinds}",
    )
    # gitops/README.md "NetworkPolicy defaults": default deny, name the
    # exception. The controller exposes a webhook port, so a
    # NetworkPolicy must select its Pod, and no ingress rule may admit
    # "every pod" (an empty namespaceSelector/podSelector peer, or a rule
    # with neither `from` nor `ports`, which admits everything).
    def selects(np, labels: dict) -> bool:
        sel = (np.get("spec") or {}).get("podSelector") or {}
        ml = sel.get("matchLabels") or {}
        if sel.get("matchExpressions"):
            return False
        return bool(ml) and all(labels.get(k) == v for k, v in ml.items())

    def every_pod(rule: dict) -> bool:
        if not rule.get("from") and not rule.get("ports"):
            return True
        for peer in rule.get("from") or []:
            if peer in ({"namespaceSelector": {}}, {"podSelector": {}}, {"namespaceSelector": {}, "podSelector": {}}):
                return True
        return False

    nps = [d for d in docs if d.get("kind") == "NetworkPolicy"]
    for dep in deployments:
        labels = (((dep.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {}
        selecting = [np for np in nps if selects(np, labels)]
        name = (dep.get("metadata") or {}).get("name")
        check(
            f"{WRAPPER_CHART}: a NetworkPolicy selects Deployment {name}'s Pod (gitops/README.md 'NetworkPolicy defaults')",
            bool(selecting),
            f"{len(nps)} NetworkPolicy object(s) rendered, none selecting labels {labels}",
        )
        for np in selecting:
            spec = np.get("spec") or {}
            check(
                f"{WRAPPER_CHART}: NetworkPolicy {(np.get('metadata') or {}).get('name')} restricts Ingress",
                "Ingress" in (spec.get("policyTypes") or []) or "ingress" in spec,
                f"policyTypes={spec.get('policyTypes')!r}",
            )
            check(
                f"{WRAPPER_CHART}: NetworkPolicy {(np.get('metadata') or {}).get('name')} has no 'every pod' ingress rule",
                not any(every_pod(r) for r in spec.get("ingress") or []),
                f"ingress={spec.get('ingress')!r}",
            )


def network_kueue_frameworks(root: str, helm: str) -> None:
    path = os.path.join(root, KUEUE_ADDON)
    if not os.path.isfile(path):
        return
    doc = load_one(path, KUEUE_ADDON) or {}
    repo = str(doc.get("repoURL") or "").rstrip("/")
    ref = f"{repo if repo.startswith('oci://') else 'oci://' + repo}/{doc.get('chart')}"
    with tempfile.TemporaryDirectory() as tmp:
        vf = os.path.join(tmp, "values.yaml")
        with open(vf, "w", encoding="utf-8") as f:
            yaml.safe_dump(doc.get("values") or {}, f)
        proc = run([helm, "template", "kueue", ref, "--version", str(doc.get("version")), "--namespace", str(doc.get("namespace") or "kueue-system"), "-f", vf], timeout=300)
    if proc.returncode != 0:
        check(f"helm template {ref}:{doc.get('version')} with {KUEUE_ADDON}'s values", False, proc.stderr.strip() or proc.stdout.strip())
        return
    frameworks: list = []
    for d in render_docs(proc.stdout):
        if d.get("kind") != "ConfigMap":
            continue
        for v in (d.get("data") or {}).values():
            try:
                cfg = yaml.safe_load(v)
            except yaml.YAMLError:
                continue
            if isinstance(cfg, dict) and isinstance(cfg.get("integrations"), dict):
                frameworks += cfg["integrations"].get("frameworks") or []
    check(
        f"the pinned Kueue chart {ref}:{doc.get('version')}, rendered with {KUEUE_ADDON}'s own values, lists {JOBSET_FRAMEWORK} in integrations.frameworks (issue #34: no Kueue change needed)",
        JOBSET_FRAMEWORK in frameworks,
        f"frameworks found: {frameworks}",
    )


def main(root: str, network: bool) -> int:
    helm = os.environ.get("HELM", "helm")
    check_crd_addon(root)
    cited, body = check_crd_chart(root, helm)
    check_catalog_entry(root)
    dep = check_wrapper_chart(root)
    check_version_pair(cited, dep)
    check_kueue_offline(root)
    if network:
        network_crd_matches_upstream(root, helm, body, dep)
        network_wrapper_render(root, helm)
        network_kueue_frameworks(root, helm)
    else:
        print("INFO --network not given: skipped the upstream CRD drift check, the wrapper render checks and the pinned-Kueue integrations check")
    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all JobSet add-on checks passed")
    return 0


# ------------------------------------------------------------- selftest
#
# A check that has only ever been seen green is not trusted to actually
# fail on the thing it claims to catch. Same pattern as
# check_addon_tiers.py: every case starts from one synthetic, otherwise
# valid tree (which must itself pass with zero failures), breaks exactly
# one thing, and must produce exactly one failure, the expected one.
# Offline only (main(..., network=False)); needs a local `helm` for the
# CRD-only render check, no registry access.

_BODY = """\
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: jobsets.jobset.x-k8s.io
spec:
  group: jobset.x-k8s.io
  names:
    kind: JobSet
    listKind: JobSetList
    plural: jobsets
    singular: jobset
  scope: Namespaced
  versions:
    - name: v1alpha2
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
"""


def _write(root: str, rel: str, text: str) -> None:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _crd_file(body: str = _BODY, version: str = "0.13.1", digest: str | None = None) -> str:
    d = digest if digest is not None else hashlib.sha256(body.encode("utf-8")).hexdigest()
    return f"# Vendored verbatim from kubernetes-sigs/jobset v{version}\n# sha256:{d}\n" + body


def _baseline(root: str) -> None:
    _write(root, CRD_ADDON, "addon: jobset-crd\ntier: core\nwave: crds\ndir: gitops/charts/jobset-crd\nnamespace: kube-system\n")
    _write(root, f"{CRD_CHART}/Chart.yaml", "apiVersion: v2\nname: jobset-crd\nversion: 0.1.0\n")
    _write(root, f"{CRD_CHART}/crds/jobset.x-k8s.io_jobsets.yaml", _crd_file())
    _write(root, CATALOG_ENTRY, "addon: jobset\ntier: platform-optional\ndir: gitops/charts/jobset\nnamespace: jobset-system\nskipCrds: true\ndependsOn: [jobset-crd]\noverridableKeys: []\n")
    _write(root, f"{WRAPPER_CHART}/Chart.yaml", "apiVersion: v2\nname: jobset\nversion: 0.1.0\ndependencies:\n  - name: jobset\n    version: \"0.13.1\"\n    repository: oci://registry.k8s.io/jobset/charts\n")
    _write(root, KUEUE_ADDON, "addon: kueue\ntier: core\nchart: kueue\nrepoURL: registry.k8s.io/kueue/charts\nversion: \"0.20.6\"\nwave: controllers\nnamespace: kueue-system\nvalues:\n  controllerManager:\n    tolerations: []\n")


def _run(root: str) -> tuple[int, list[str]]:
    global FAILURES
    FAILURES = []
    import contextlib
    import io

    with contextlib.redirect_stdout(io.StringIO()):
        rc = main(root, network=False)
    return rc, list(FAILURES)


def selftest() -> int:
    cases: list = []

    def case(name, mutate, expect_substr):
        cases.append((name, mutate, expect_substr))

    case("baseline passes with zero failures", lambda r: None, None)
    case("jobset-crd in the controllers wave fails only the wave rule",
         lambda r: _write(r, CRD_ADDON, "addon: jobset-crd\ntier: core\nwave: controllers\ndir: gitops/charts/jobset-crd\nnamespace: kube-system\n"),
         "is wave: crds")
    case("jobset-crd as platform-optional fails only the tier rule",
         lambda r: _write(r, CRD_ADDON, "addon: jobset-crd\ntier: platform-optional\nwave: crds\ndir: gitops/charts/jobset-crd\nnamespace: kube-system\n"),
         "is tier: core")
    case("jobset-crd also naming an upstream chart fails only the no-chart rule",
         lambda r: _write(r, CRD_ADDON, "addon: jobset-crd\ntier: core\nwave: crds\ndir: gitops/charts/jobset-crd\nnamespace: kube-system\nchart: jobset\n"),
         "has no 'chart'")
    case("jobset-crd chart rendering a template object fails only the CRD-only render rule",
         lambda r: _write(r, f"{CRD_CHART}/templates/cm.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x}\n"),
         "renders no object at all")
    case("a second document in the CRD file fails only the one-document rule",
         lambda r: _write(r, f"{CRD_CHART}/crds/jobset.x-k8s.io_jobsets.yaml", _crd_file(_BODY + "---\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: x}\n")),
         "exactly one YAML document")
    case("a wrong CRD group fails only the spec.group rule (name kept)",
         lambda r: _write(r, f"{CRD_CHART}/crds/jobset.x-k8s.io_jobsets.yaml", _crd_file(_BODY.replace("  group: jobset.x-k8s.io", "  group: jobsets.example.com"))),
         "spec.group is")
    case("a wrong CRD kind fails only the names.kind rule",
         lambda r: _write(r, f"{CRD_CHART}/crds/jobset.x-k8s.io_jobsets.yaml", _crd_file(_BODY.replace("kind: JobSet\n", "kind: Job\n"))),
         "names.kind is JobSet")
    case("v1alpha2 not served fails only the version rule",
         lambda r: _write(r, f"{CRD_CHART}/crds/jobset.x-k8s.io_jobsets.yaml", _crd_file(_BODY.replace("served: true", "served: false"))),
         "serves and stores v1alpha2")
    case("an edited body with the old digest fails only the verbatim-digest rule",
         lambda r: _write(r, f"{CRD_CHART}/crds/jobset.x-k8s.io_jobsets.yaml",
                          _crd_file(_BODY + "# local edit\n", digest=hashlib.sha256(_BODY.encode()).hexdigest())),
         "sha256 of its own body")
    case("a CRD header citing a different version than the wrapper pins fails only the version-pair rule",
         lambda r: _write(r, f"{CRD_CHART}/crds/jobset.x-k8s.io_jobsets.yaml", _crd_file(version="0.12.0")),
         "version pair")
    case("catalog entry with skipCrds: \"true\" (a string) fails only the skipCrds rule",
         lambda r: _write(r, CATALOG_ENTRY, "addon: jobset\ntier: platform-optional\ndir: gitops/charts/jobset\nnamespace: jobset-system\nskipCrds: \"true\"\ndependsOn: [jobset-crd]\noverridableKeys: []\n"),
         "skipCrds: true")
    case("catalog entry with no dependsOn fails only the dependsOn rule",
         lambda r: _write(r, CATALOG_ENTRY, "addon: jobset\ntier: platform-optional\ndir: gitops/charts/jobset\nnamespace: jobset-system\nskipCrds: true\noverridableKeys: []\n"),
         "dependsOn lists jobset-crd")
    case("catalog entry as tier: workload fails only the tier rule",
         lambda r: _write(r, CATALOG_ENTRY, "addon: jobset\ntier: workload\ndir: gitops/charts/jobset\nnamespace: jobset-system\nskipCrds: true\ndependsOn: [jobset-crd]\noverridableKeys: []\n"),
         "is tier: platform-optional")
    case("wrapper depending on a different registry fails only the repository rule",
         lambda r: _write(r, f"{WRAPPER_CHART}/Chart.yaml", "apiVersion: v2\nname: jobset\nversion: 0.1.0\ndependencies:\n  - name: jobset\n    version: \"0.13.1\"\n    repository: oci://example.invalid/charts\n"),
         "dependency repository is")
    case("kueue values overriding integrations fails only the Kueue rule",
         lambda r: _write(r, KUEUE_ADDON, "addon: kueue\ntier: core\nchart: kueue\nrepoURL: registry.k8s.io/kueue/charts\nversion: \"0.20.6\"\nwave: controllers\nnamespace: kueue-system\nvalues:\n  integrations:\n    frameworks: [batch/job]\n"),
         "set no 'integrations' key")

    failures = 0
    for name, mutate, expect in cases:
        tmp = tempfile.mkdtemp(prefix="check-jobset-addon-selftest-")
        try:
            _baseline(tmp)
            mutate(tmp)
            rc, fails = _run(tmp)
            if expect is None:
                ok = rc == 0 and not fails
                detail = f"expected a clean pass, got rc={rc} failures={fails}"
            else:
                ok = rc != 0 and len(fails) == 1 and expect in fails[0]
                detail = f"expected exactly one failure, the {expect!r} rule, got {fails}"
            check(f"selftest: {name}", ok, detail)
            if not ok:
                failures += 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["--selftest"]:
        sys.exit(selftest())
    network = "--network" in args
    rest = [a for a in args if a != "--network"]
    if len(rest) != 1:
        print("usage: check_jobset_addon.py <repo-root> [--network] | check_jobset_addon.py --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(rest[0], network))
