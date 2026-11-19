#!/usr/bin/env python3
"""Semantic checks on `helm template` output of gitops/charts/capacity-pool and
gitops/charts/smoke, one rendered file per values fixture under
gitops/tests/fixtures/ (issue #27's acceptance criteria that `helm template`
alone can evidence).

0.static.sh renders every fixture into <rendered_dir> as
`fixture-<chart>-<fixture-name>.yaml` and calls this script afterwards. The
byte-level comparison of the unchanged on-demand pool and the default smoke
queue against the pre-#27 golden files is done by 0.static.sh itself (a
`diff`); this script checks what each new values shape must render:

  * every capacity-pool fixture renders exactly one NodePool, one
    EC2NodeClass and one ResourceFlavor, joined by name and by the
    ResourceFlavor's `karpenter.sh/nodepool` node label;
  * `pool.capacityType` sets exactly one `karpenter.sh/capacity-type`
    requirement: on-demand -> [on-demand], reserved -> [reserved] only,
    flex -> [spot, on-demand];
  * only a reserved pool has `capacityReservationSelectorTerms`, and every
    term carries the fixture's own `reservation.tags` together with
    `instanceMatchCriteria` (targeted unless the fixture sets it). The two
    must sit in the same term: selector terms are ORed, so a term with only
    `instanceMatchCriteria: targeted` would select every targeted
    reservation in the account;
  * with `accelerator`/`tenancy` unset, no taint, toleration, method label
    or accelerator annotation is rendered; with both set, each taint is on
    the NodePool and mirrored as a toleration on the ResourceFlavor, the
    method label is on the NodePool's node template, and
    `distai.dev/accelerator-resource-name` is on both objects;
  * the smoke chart's `clusterQueue.memQuota` becomes the memory
    `nominalQuota` of its one flavor, next to `cpuQuota`.

Expectations are read from the fixture files themselves (tags, taints,
labels), so a fixture edit cannot leave this script checking stale values.

Usage: check_chart_renders.py <fixtures_dir> <rendered_dir>
Prints one PASS/FAIL line per check; exits 1 if any failed.
"""
from __future__ import annotations

import os
import sys

import yaml

FAILURES: list[str] = []

CAPACITY_TYPE_KEY = "karpenter.sh/capacity-type"
NODEPOOL_LABEL = "karpenter.sh/nodepool"
ACCEL_ANNOTATION = "distai.dev/accelerator-resource-name"

EXPECTED_CAPACITY_TYPES = {
    "on-demand": ["on-demand"],
    "reserved": ["reserved"],
    "flex": ["spot", "on-demand"],
}


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def load_docs(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [d for d in yaml.safe_load_all(f) if d]


def load_values(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def only(docs: list[dict], kind: str) -> list[dict]:
    return [d for d in docs if d.get("kind") == kind]


def taint_entries(values: dict) -> list[dict]:
    """The {key, value, effect} entries the fixture asks for, in the order
    the issue names them (accelerator first, then tenancy)."""
    out = []
    accel_taint = ((values.get("accelerator") or {}).get("taint")) or {}
    team_taint = ((values.get("tenancy") or {}).get("teamTaint")) or {}
    for t in (accel_taint, team_taint):
        if t:
            out.append({"key": t["key"], "value": str(t["value"]), "effect": t["effect"]})
    return out


def check_capacity_pool(name: str, values: dict, docs: list[dict]) -> None:
    label = f"capacity-pool[{name}]"
    pool = values.get("pool") or {}
    pool_name = pool.get("name")
    capacity_type = pool.get("capacityType", "on-demand")

    nodepools = only(docs, "NodePool")
    nodeclasses = only(docs, "EC2NodeClass")
    flavors = only(docs, "ResourceFlavor")
    check(f"{label} renders exactly one NodePool", len(nodepools) == 1, f"got {len(nodepools)}")
    check(f"{label} renders exactly one EC2NodeClass", len(nodeclasses) == 1, f"got {len(nodeclasses)}")
    check(f"{label} renders exactly one ResourceFlavor", len(flavors) == 1, f"got {len(flavors)}")
    others = sorted({d.get("kind") for d in docs} - {"NodePool", "EC2NodeClass", "ResourceFlavor"})
    check(f"{label} renders no other kind (zero new Kubernetes kinds, issue #27 option c)", not others, f"got {others}")
    if not (nodepools and nodeclasses and flavors):
        return
    np, nc, rf = nodepools[0], nodeclasses[0], flavors[0]

    # --- the join (#17's convention, unchanged by #27)
    np_name = (np.get("metadata") or {}).get("name")
    nc_name = (nc.get("metadata") or {}).get("name")
    rf_name = (rf.get("metadata") or {}).get("name")
    check(f"{label} NodePool/EC2NodeClass/ResourceFlavor are all named pool.name ({pool_name})",
          np_name == nc_name == rf_name == pool_name, f"got {np_name!r}/{nc_name!r}/{rf_name!r}")
    np_spec = (np.get("spec") or {}).get("template", {}).get("spec", {}) or {}
    check(f"{label} NodePool's nodeClassRef names the EC2NodeClass",
          (np_spec.get("nodeClassRef") or {}).get("name") == nc_name,
          f"got {np_spec.get('nodeClassRef')!r}")
    rf_spec = rf.get("spec") or {}
    check(f"{label} ResourceFlavor's nodeLabels['{NODEPOOL_LABEL}'] joins to the NodePool",
          (rf_spec.get("nodeLabels") or {}).get(NODEPOOL_LABEL) == np_name,
          f"got {rf_spec.get('nodeLabels')!r}")

    # --- capacity type
    reqs = [r for r in (np_spec.get("requirements") or []) if r.get("key") == CAPACITY_TYPE_KEY]
    check(f"{label} NodePool has exactly one {CAPACITY_TYPE_KEY} requirement", len(reqs) == 1, f"got {reqs!r}")
    if len(reqs) == 1:
        want = EXPECTED_CAPACITY_TYPES[capacity_type]
        got_values = [str(v) for v in (reqs[0].get("values") or [])]
        check(f"{label} {CAPACITY_TYPE_KEY} requirement is In {want} (pool.capacityType={capacity_type})",
              reqs[0].get("operator") == "In" and sorted(got_values) == sorted(want) and len(got_values) == len(want),
              f"got operator={reqs[0].get('operator')!r} values={got_values!r}")

    # --- reservation selector
    terms = (nc.get("spec") or {}).get("capacityReservationSelectorTerms")
    if capacity_type == "reserved":
        reservation = values.get("reservation") or {}
        want_tags = {str(k): str(v) for k, v in (reservation.get("tags") or {}).items()}
        want_imc = reservation.get("instanceMatchCriteria", "targeted")
        check(f"{label} EC2NodeClass has capacityReservationSelectorTerms", bool(terms), f"got {terms!r}")
        for i, term in enumerate(terms or []):
            got_tags = {str(k): str(v) for k, v in (term.get("tags") or {}).items()}
            check(f"{label} capacityReservationSelectorTerms[{i}].tags == reservation.tags {want_tags}",
                  got_tags == want_tags, f"got {term!r}")
            check(f"{label} capacityReservationSelectorTerms[{i}].instanceMatchCriteria == {want_imc!r} in the same term as the tags",
                  term.get("instanceMatchCriteria") == want_imc, f"got {term!r}")
            check(f"{label} capacityReservationSelectorTerms[{i}] does not select by id (tags only, issue #27)",
                  "id" not in term, f"got {term!r}")
    else:
        check(f"{label} EC2NodeClass has no capacityReservationSelectorTerms (capacityType={capacity_type})",
              not terms, f"got {terms!r}")

    # --- accelerator / tenancy (values only)
    want_taints = taint_entries(values)
    got_taints = [
        {"key": t.get("key"), "value": str(t.get("value")), "effect": t.get("effect")}
        for t in (np_spec.get("taints") or [])
    ]
    got_tolerations = rf_spec.get("tolerations") or []
    np_annotations = (np.get("metadata") or {}).get("annotations") or {}
    rf_annotations = (rf.get("metadata") or {}).get("annotations") or {}
    np_template_labels = ((np.get("spec") or {}).get("template", {}).get("metadata") or {}).get("labels") or {}
    accelerator = values.get("accelerator") or {}

    check(f"{label} NodePool taints are exactly the accelerator/tenancy taints set {want_taints}",
          sorted(got_taints, key=repr) == sorted(want_taints, key=repr), f"got {got_taints!r}")
    for t in want_taints:
        mirrored = [
            tol for tol in got_tolerations
            if tol.get("key") == t["key"]
            and str(tol.get("value")) == t["value"]
            and tol.get("effect") == t["effect"]
            and tol.get("operator", "Equal") == "Equal"
        ]
        check(f"{label} ResourceFlavor tolerates the NodePool taint {t['key']}={t['value']}:{t['effect']}",
              len(mirrored) == 1, f"got tolerations {got_tolerations!r}")
    check(f"{label} ResourceFlavor has no toleration beyond the mirrored taints",
          len(got_tolerations) == len(want_taints), f"got {got_tolerations!r}")

    method = accelerator.get("methodLabel") or {}
    if method:
        check(f"{label} NodePool node template carries the method label {method['key']}={method['value']}",
              np_template_labels.get(method["key"]) == str(method["value"]), f"got {np_template_labels!r}")
    else:
        check(f"{label} NodePool node template carries no extra labels (no accelerator.methodLabel set)",
              not np_template_labels, f"got {np_template_labels!r}")

    resource_name = accelerator.get("resourceName")
    if resource_name:
        check(f"{label} NodePool carries annotation {ACCEL_ANNOTATION}={resource_name}",
              np_annotations.get(ACCEL_ANNOTATION) == resource_name, f"got {np_annotations!r}")
        check(f"{label} ResourceFlavor carries annotation {ACCEL_ANNOTATION}={resource_name}",
              rf_annotations.get(ACCEL_ANNOTATION) == resource_name, f"got {rf_annotations!r}")
    else:
        check(f"{label} no {ACCEL_ANNOTATION} annotation without accelerator.resourceName",
              ACCEL_ANNOTATION not in np_annotations and ACCEL_ANNOTATION not in rf_annotations,
              f"got NodePool {np_annotations!r}, ResourceFlavor {rf_annotations!r}")


def check_smoke(name: str, values: dict, docs: list[dict]) -> None:
    label = f"smoke[{name}]"
    cq_values = values.get("clusterQueue") or {}
    want_cpu = str(cq_values.get("cpuQuota", "32"))
    want_mem = str(cq_values.get("memQuota", "64Gi"))
    queues = only(docs, "ClusterQueue")
    check(f"{label} renders exactly one ClusterQueue", len(queues) == 1, f"got {len(queues)}")
    if not queues:
        return
    groups = (queues[0].get("spec") or {}).get("resourceGroups") or []
    flavors = [f for g in groups for f in (g.get("flavors") or [])]
    check(f"{label} ClusterQueue names exactly one flavor ({cq_values.get('resourceFlavor')})",
          len(flavors) == 1 and flavors[0].get("name") == cq_values.get("resourceFlavor"), f"got {flavors!r}")
    if len(flavors) != 1:
        return
    quotas = {r.get("name"): str(r.get("nominalQuota")) for r in (flavors[0].get("resources") or [])}
    check(f"{label} cpu nominalQuota == {want_cpu}", quotas.get("cpu") == want_cpu, f"got {quotas!r}")
    check(f"{label} memory nominalQuota == {want_mem} (clusterQueue.memQuota)", quotas.get("memory") == want_mem,
          f"got {quotas!r}")


def main(fixtures_dir: str, rendered_dir: str) -> int:
    checked = 0
    for chart, checker in (("capacity-pool", check_capacity_pool), ("smoke", check_smoke)):
        chart_fixtures = os.path.join(fixtures_dir, chart)
        for fname in sorted(os.listdir(chart_fixtures)):
            if not fname.endswith(".yaml"):
                continue
            name = fname[: -len(".yaml")]
            rendered = os.path.join(rendered_dir, f"fixture-{chart}-{name}.yaml")
            if not os.path.isfile(rendered):
                # Fixtures 0.static.sh expects to fail rendering have no
                # rendered file; 0.static.sh itself asserts that failure.
                continue
            checker(name, load_values(os.path.join(chart_fixtures, fname)), load_docs(rendered))
            checked += 1
    check("at least one rendered fixture was checked", checked >= 1, f"checked {checked}")
    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} chart render check(s) failed")
        return 1
    print(f"\nRESULT PASS: all chart render checks passed ({checked} fixture(s))")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: check_chart_renders.py <fixtures_dir> <rendered_dir>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
