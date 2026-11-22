#!/usr/bin/env python3
"""Semantic checks on `helm template` output of gitops/charts/capacity-pool and
gitops/charts/smoke, one rendered file per values fixture under
gitops/tests/fixtures/ (issue #27's acceptance criteria that `helm template`
alone can evidence).

0.static.sh renders every fixture into <rendered_dir> as
`fixture-<chart>-<fixture-name>.yaml` and calls this script afterwards.
This script checks what each values shape must render, including the
unchanged `on-demand-default`/`default` fixtures, which carry none of
issue #27's new values and must still render the exact same fields
`capacity-pool`/`smoke` rendered before #27, checked field by field, not
byte by byte: a checked-in golden file and a byte-level `diff` would also
fail on an unrelated base-branch rebase or a different Helm version,
neither a field regression, with no way to tell the two apart from a
byte diff alone. These checks do not have that problem; the acceptance
criterion is met at the level these checks assert, stated explicitly
since the chart's own rendered comments are not byte-identical to #25's
original (`gitops/tests/README.md`'s own assumptions section says so):

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
    """The {key, value, effect, has_value} entries the fixture asks for, in
    the order the issue names them (accelerator first, then tenancy).
    has_value distinguishes "no value given" (the chart must render
    operator: Exists) from a given value (operator: Equal) -- the two are
    not interchangeable to Kubernetes."""
    out = []
    accel_taint = ((values.get("accelerator") or {}).get("taint")) or {}
    team_taint = ((values.get("tenancy") or {}).get("teamTaint")) or {}
    for t in (accel_taint, team_taint):
        if t and t.get("key"):
            has_value = "value" in t and t["value"] not in (None, "")
            out.append({
                "key": t["key"],
                "value": str(t.get("value", "")) if has_value else "",
                "effect": t["effect"],
                "has_value": has_value,
            })
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
        {
            "key": t.get("key"),
            "value": str(t.get("value", "")) if "value" in t else "",
            "effect": t.get("effect"),
            "has_value": "value" in t,
        }
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
        want_operator = "Equal" if t["has_value"] else "Exists"
        mirrored = [
            tol for tol in got_tolerations
            if tol.get("key") == t["key"]
            and tol.get("effect") == t["effect"]
            and tol.get("operator") == want_operator
            and (want_operator == "Exists" or str(tol.get("value")) == t["value"])
            and (want_operator != "Exists" or "value" not in tol)
        ]
        check(f"{label} ResourceFlavor tolerates the NodePool taint {t['key']}:{t['effect']} "
              f"with operator {want_operator}" + (f" value {t['value']}" if t["has_value"] else " (no value)"),
              len(mirrored) == 1, f"got tolerations {got_tolerations!r}")
    check(f"{label} ResourceFlavor has no toleration beyond the mirrored taints",
          len(got_tolerations) == len(want_taints), f"got {got_tolerations!r}")

    method = accelerator.get("methodLabel") or {}
    want_labels = {}
    if method:
        want_labels[method["key"]] = str(method["value"])
    # distai.dev/efa-attached (Fable 5.2 review round 5): capacity-pool's own signal
    # that this pool's EC2NodeClass actually attaches an EFA device, read from
    # pool.networkInterfaces containing an interfaceType: efa-only entry -- not from
    # whether the list is merely non-empty (a pool can list only the primary
    # "interface" entry, #50's own CEL validation requires that one but never an
    # efa-only one) and not from accelerator.methodLabel or the instance type.
    network_interfaces = pool.get("networkInterfaces") or []
    has_efa = any(str(ni.get("interfaceType")) == "efa-only" for ni in network_interfaces)
    if has_efa:
        want_labels["distai.dev/efa-attached"] = "true"
    if method:
        check(f"{label} NodePool node template carries the method label {method['key']}={method['value']}",
              np_template_labels.get(method["key"]) == str(method["value"]), f"got {np_template_labels!r}")
    if has_efa:
        check(f"{label} NodePool node template carries distai.dev/efa-attached=true (pool.networkInterfaces has an efa-only entry)",
              np_template_labels.get("distai.dev/efa-attached") == "true", f"got {np_template_labels!r}")
    else:
        check(f"{label} NodePool node template carries no distai.dev/efa-attached label (no efa-only entry in pool.networkInterfaces)",
              "distai.dev/efa-attached" not in np_template_labels, f"got {np_template_labels!r}")
    if not want_labels:
        check(f"{label} NodePool node template carries no extra labels (no accelerator.methodLabel, no EFA interface)",
              not np_template_labels, f"got {np_template_labels!r}")
    else:
        check(f"{label} NodePool node template carries exactly the expected labels {want_labels}",
              np_template_labels == want_labels, f"got {np_template_labels!r}")

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


# The exact fixture files this PR ships, by chart -- not "at least one":
# deleting a fixture (or a must-fail one silently starting to render) must
# fail this check, not pass it with a smaller count. Keep in step with
# gitops/tests/fixtures/*/*.yaml and 0.static.sh's own expect_render_failure.
EXPECTED_FIXTURES = {
    "capacity-pool": {
        "on-demand-default", "reserved", "flex", "accelerator-tenancy", "taint-no-value",
        "efa-attached", "primary-interface-only", "efa-attached-no-method-label",
        "reserved-no-tags", "unknown-capacity-type", "capacity-type-in-requirements",
        "invalid-instance-match-criteria", "invalid-taint-effect", "duplicate-taint",
        "empty-tag-value",
    },
    "smoke": {"default", "mem-quota"},
}
# Of those, the ones 0.static.sh expects helm template to refuse (no
# rendered file is ever produced for these, by design).
EXPECTED_MUST_FAIL = {
    "reserved-no-tags", "unknown-capacity-type", "capacity-type-in-requirements",
    "invalid-instance-match-criteria", "invalid-taint-effect", "duplicate-taint",
    "empty-tag-value",
}


def main(fixtures_dir: str, rendered_dir: str) -> int:
    checked = 0
    for chart, checker in (("capacity-pool", check_capacity_pool), ("smoke", check_smoke)):
        chart_fixtures = os.path.join(fixtures_dir, chart)
        on_disk = {
            fname[: -len(".yaml")]
            for fname in os.listdir(chart_fixtures)
            if fname.endswith(".yaml")
        }
        check(f"fixtures/{chart}/ has exactly the expected fixture files",
              on_disk == EXPECTED_FIXTURES[chart],
              f"got {sorted(on_disk)}, want {sorted(EXPECTED_FIXTURES[chart])}")
        for name in sorted(on_disk):
            rendered = os.path.join(rendered_dir, f"fixture-{chart}-{name}.yaml")
            is_must_fail = name in EXPECTED_MUST_FAIL
            check(f"{chart}[{name}] has a rendered file iff it is not expected to fail rendering",
                  os.path.isfile(rendered) != is_must_fail,
                  f"rendered file exists={os.path.isfile(rendered)}, expected must-fail={is_must_fail}")
            if is_must_fail or not os.path.isfile(rendered):
                # 0.static.sh itself asserts a must-fail fixture actually fails.
                continue
            checker(name, load_values(os.path.join(chart_fixtures, f"{name}.yaml")), load_docs(rendered))
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
