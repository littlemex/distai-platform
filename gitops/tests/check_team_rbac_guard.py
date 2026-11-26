#!/usr/bin/env python3
"""Unit test of gitops/bootstrap/team-rbac-guard.yaml's own Role and
RoleBinding rules, and of the `<team>-deployer-role` Role that
gitops/bootstrap/team-onboard.sh step 3 creates, without a cluster
(issue #34, on top of RFC #22 Decision 10 H11).

infra/foundation/tests/4.argocd-impersonation.sh checks 8-9 already test
this guard on a real EKS API server. That needs a cell; this needs
nothing but Python, so a one-line allow-list change is tested on every
static run, in both directions, before it ever reaches a cell:

  1. the guard's own shape is still the one that makes it enforce
     anything: a ValidatingAdmissionPolicy matching CREATE/UPDATE of
     rbac.authorization.k8s.io roles/rolebindings in namespaces carrying
     distai.dev/team, failurePolicy Fail, and a Binding to it with
     validationActions [Deny];
  2. every case below is evaluated against the guard's OWN validation
     expressions, read from the file (never a copy of the allow-list
     typed into this script), with a real CEL evaluator (cel-python): a
     Role or RoleBinding is allowed only if every expression is true,
     exactly the ValidatingAdmissionPolicy rule;
       allowed: a Role granting get/list/watch/create/update/patch/delete
         on jobset.x-k8s.io jobsets (issue #34's widening), plus the
         existing shapes that must keep working (core configmaps CRUD,
         inferencepools read-only, a RoleBinding to a Role);
       denied, the close-but-wrong shapes around the widening:
         jobsets/status (a subresource -- every subresource stays
         denied), verb "*", verb deletecollection (not on the verb list),
         resources "*" in the jobset group, a look-alike group
         (jobsets.x-k8s.io), and Kueue's own kueue.x-k8s.io workloads and
         localqueues (the widening must not have pulled in the queueing
         group a team could use to give itself quota); plus the existing
         denials that must keep holding (inferencepools delete, Secrets,
         a RoleBinding to a ClusterRole);
  3. team-onboard.sh step 3's own Role, extracted from the script's own
     heredoc, (a) grants jobset.x-k8s.io jobsets with the full verb set
     (issue #34: the deployer identity can submit a JobSet), and (b) is
     itself allowed by the guard -- that Role is applied into a
     namespace the guard governs, so an allow-list that forgot what
     team-onboard.sh grants would make onboarding itself fail.

What this does not prove: cel-python is not the Kubernetes API server's
own CEL (cel-go with Kubernetes' extension libraries). The expressions
this guard uses (has(), all(), exists(), in, the ternary operator,
string equality) are core CEL, which both implement; anything a future
edit adds outside that core is a reason to check it on a real API
server, and examples/training/tests/1.e2e.sh step 2 re-runs the
jobsets / jobsets/status pair against the real one.

Run with pinned dependencies, e.g.:
    uv run --no-project -q --python 3.12 --with pyyaml==6.0.2 --with cel-python==0.5.0 \\
      python3 check_team_rbac_guard.py <repo-root>
    ... check_team_rbac_guard.py --selftest

Prints one "PASS <label>" or "FAIL <label>: <reason>" line per check and
exits 1 if any check failed, 0 otherwise.
"""
from __future__ import annotations

import os
import re
import shutil
import sys
import tempfile

import celpy
import yaml

FAILURES: list[str] = []

GUARD = "gitops/bootstrap/team-rbac-guard.yaml"
ONBOARD = "gitops/bootstrap/team-onboard.sh"

FULL_VERBS = ["get", "list", "watch", "create", "update", "patch", "delete"]
JOBSET_RULE = {"apiGroups": ["jobset.x-k8s.io"], "resources": ["jobsets"], "verbs": FULL_VERBS}


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def role(name: str, *rules: dict) -> dict:
    return {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role", "metadata": {"name": name, "namespace": "team-unit"}, "rules": list(rules)}


def rolebinding(name: str, ref_kind: str, ref_name: str) -> dict:
    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "RoleBinding",
        "metadata": {"name": name, "namespace": "team-unit"},
        "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": ref_kind, "name": ref_name},
        "subjects": [{"kind": "ServiceAccount", "name": "team-unit-deployer", "namespace": "team-unit"}],
    }


def rule(groups, resources, verbs) -> dict:
    return {"apiGroups": list(groups), "resources": list(resources), "verbs": list(verbs)}


# (label, object, expected allowed?)
CASES: list[tuple[str, dict, bool]] = [
    # issue #34's widening
    ("Role granting full CRUD on jobset.x-k8s.io jobsets (issue #34)", role("jobset-crud", JOBSET_RULE), True),
    ("Role granting read-only on jobset.x-k8s.io jobsets", role("jobset-read", rule(["jobset.x-k8s.io"], ["jobsets"], ["get", "list", "watch"])), True),
    # existing shapes that must keep working
    ("Role granting CRUD on core configmaps (existing allow, regression)", role("cm", rule([""], ["configmaps"], FULL_VERBS)), True),
    ("Role granting get/list/watch on inferencepools (existing narrowed allow, regression)", role("ip-read", rule(["inference.networking.k8s.io"], ["inferencepools"], ["get", "list", "watch"])), True),
    ("RoleBinding to a namespace-scoped Role (existing allow, regression)", rolebinding("rb", "Role", "jobset-crud"), True),
    # close-but-wrong shapes around the widening
    ("Role granting jobset.x-k8s.io jobsets/status (a subresource)", role("jobset-status", rule(["jobset.x-k8s.io"], ["jobsets/status"], ["get", "update", "patch"])), False),
    ("Role granting jobsets alongside jobsets/status in one rule", role("jobset-and-status", rule(["jobset.x-k8s.io"], ["jobsets", "jobsets/status"], ["get"])), False),
    ("Role granting verb '*' on jobsets", role("jobset-star-verb", rule(["jobset.x-k8s.io"], ["jobsets"], ["*"])), False),
    ("Role granting deletecollection on jobsets (not on the verb list)", role("jobset-deletecollection", rule(["jobset.x-k8s.io"], ["jobsets"], ["deletecollection"])), False),
    ("Role granting resources '*' in jobset.x-k8s.io", role("jobset-star-resource", rule(["jobset.x-k8s.io"], ["*"], ["get"])), False),
    ("Role granting jobsets in a look-alike group jobsets.x-k8s.io", role("jobset-lookalike", rule(["jobsets.x-k8s.io"], ["jobsets"], ["get"])), False),
    ("Role granting kueue.x-k8s.io workloads (Kueue's own group stays off the list)", role("kueue-workloads", rule(["kueue.x-k8s.io"], ["workloads"], ["get", "patch"])), False),
    ("Role granting kueue.x-k8s.io localqueues (a team must not create its own queue)", role("kueue-localqueues", rule(["kueue.x-k8s.io"], ["localqueues"], ["create"])), False),
    ("Role whose second rule is the jobsets/status subresource (every rule is checked, not the first)", role("jobset-second-rule", JOBSET_RULE, rule(["jobset.x-k8s.io"], ["jobsets/status"], ["patch"])), False),
    # existing denials that must keep holding
    ("Role granting delete on inferencepools (existing verb narrowing, regression)", role("ip-delete", rule(["inference.networking.k8s.io"], ["inferencepools"], ["get", "delete"])), False),
    ("Role granting core secrets (existing deny, regression)", role("secrets", rule([""], ["secrets"], ["get"])), False),
    ("RoleBinding to a ClusterRole (existing deny, regression)", rolebinding("rb-cluster", "ClusterRole", "edit"), False),
]


def load_docs(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]


def compile_validations(policy: dict) -> list[tuple[str, object]] | None:
    env = celpy.Environment()
    out = []
    for v in (policy.get("spec") or {}).get("validations") or []:
        expr = v.get("expression")
        try:
            out.append((expr, env.program(env.compile(expr))))
        except Exception as e:  # noqa: BLE001 -- any compile error is a FAIL to report
            check(f"{GUARD}: validation expression compiles as CEL", False, f"{type(e).__name__}: {e}")
            return None
    return out


def allowed(programs, obj: dict) -> tuple[bool, str]:
    """ValidatingAdmissionPolicy semantics: the request is admitted only if
    every validation evaluates to true; an evaluation error with
    failurePolicy: Fail is a denial."""
    resource = {"Role": "roles", "RoleBinding": "rolebindings"}[obj["kind"]]
    act = {
        "request": celpy.json_to_cel({"resource": {"group": "rbac.authorization.k8s.io", "version": "v1", "resource": resource}, "operation": "CREATE"}),
        "object": celpy.json_to_cel(obj),
    }
    for expr, prog in programs:
        try:
            result = prog.evaluate(act)
        except Exception as e:  # noqa: BLE001
            return False, f"evaluation error ({type(e).__name__}) in: {expr}"
        if not isinstance(result, celpy.celtypes.BoolType):
            return False, f"evaluated to {type(result).__name__}, not a bool, in: {expr}"
        if not bool(result):
            return False, f"false: {expr}"
    return True, ""


def check_guard_shape(docs: list[dict]) -> dict | None:
    policies = [d for d in docs if d.get("kind") == "ValidatingAdmissionPolicy"]
    bindings = [d for d in docs if d.get("kind") == "ValidatingAdmissionPolicyBinding"]
    check(f"{GUARD} has exactly one ValidatingAdmissionPolicy", len(policies) == 1, f"found {len(policies)}")
    if len(policies) != 1:
        return None
    policy = policies[0]
    name = (policy.get("metadata") or {}).get("name")
    spec = policy.get("spec") or {}
    check(f"{GUARD}: failurePolicy is Fail (an evaluation error denies)", spec.get("failurePolicy") == "Fail", f"got {spec.get('failurePolicy')!r}")
    mc = spec.get("matchConstraints") or {}
    exprs = (mc.get("namespaceSelector") or {}).get("matchExpressions") or []
    check(
        f"{GUARD}: matches namespaces carrying distai.dev/team (what team-onboard.sh labels a team namespace with)",
        {"key": "distai.dev/team", "operator": "Exists"} in exprs,
        f"got namespaceSelector={mc.get('namespaceSelector')!r}",
    )
    covered = set()
    for rr in mc.get("resourceRules") or []:
        if "rbac.authorization.k8s.io" in (rr.get("apiGroups") or []):
            for op in rr.get("operations") or []:
                for res in rr.get("resources") or []:
                    covered.add((op, res))
    want = {(op, res) for op in ("CREATE", "UPDATE") for res in ("roles", "rolebindings")}
    check(f"{GUARD}: matches CREATE and UPDATE of roles and rolebindings", want <= covered, f"covered: {sorted(covered)}")
    bound = [b for b in bindings if (b.get("spec") or {}).get("policyName") == name]
    check(
        f"{GUARD}: a ValidatingAdmissionPolicyBinding binds policy {name!r} with validationActions [Deny] (a policy with no Binding enforces nothing)",
        any("Deny" in ((b.get("spec") or {}).get("validationActions") or []) for b in bound),
        f"bindings for it: {bound!r}",
    )
    return policy


def onboard_role(path: str) -> dict | None:
    """The Role team-onboard.sh step 3 applies: the one `kind: Role` object
    in any of the script's own `kubectl apply -f - <<EOF` heredocs, with
    its shell variables replaced by inert placeholders."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    blocks = re.findall(r"<<EOF\n(.*?)\nEOF\n", text, flags=re.S)
    roles = []
    for b in blocks:
        b = b.replace("${SERVICE_ACCOUNT}", "team-unit-deployer").replace("${TEAM}", "team-unit")
        b = re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", "placeholder", b)
        try:
            docs = [d for d in yaml.safe_load_all(b) if isinstance(d, dict)]
        except yaml.YAMLError:
            continue
        roles += [d for d in docs if d.get("kind") == "Role"]
    check(f"{ONBOARD} applies exactly one Role (step 3's <team>-deployer-role)", len(roles) == 1, f"found {len(roles)}")
    return roles[0] if len(roles) == 1 else None


def main(root: str) -> int:
    guard_path = os.path.join(root, GUARD)
    onboard_path = os.path.join(root, ONBOARD)
    if not os.path.isfile(guard_path):
        check(f"{GUARD} exists", False)
        return 1
    policy = check_guard_shape(load_docs(guard_path))
    programs = compile_validations(policy) if policy else None
    if programs is not None:
        check(f"{GUARD} has at least one validation expression", bool(programs))
        for label, obj, want in CASES:
            got, why = allowed(programs, obj)
            check(
                f"{GUARD} {'ALLOWS' if want else 'DENIES'}: {label}",
                got == want,
                f"expected {'allowed' if want else 'denied'}, got {'allowed' if got else 'denied'}" + (f" ({why})" if why else ""),
            )

    if not os.path.isfile(onboard_path):
        check(f"{ONBOARD} exists", False)
    else:
        r = onboard_role(onboard_path)
        if r is not None:
            grants = [
                x for x in r.get("rules") or []
                if "jobset.x-k8s.io" in (x.get("apiGroups") or []) and "jobsets" in (x.get("resources") or [])
            ]
            check(
                f"{ONBOARD} step 3's Role grants {FULL_VERBS} on jobset.x-k8s.io jobsets (issue #34: the deployer identity can submit a JobSet)",
                any(set(FULL_VERBS) <= set(x.get("verbs") or []) for x in grants),
                f"jobset rules: {grants!r}",
            )
            if programs is not None:
                got, why = allowed(programs, r)
                check(
                    f"{GUARD} ALLOWS {ONBOARD} step 3's own Role (it is applied into a namespace the guard governs)",
                    got,
                    why,
                )

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all team-rbac-guard checks passed")
    return 0


# ------------------------------------------------------------- selftest
#
# A check that has only ever been seen green is not trusted to actually
# fail on the thing it claims to catch. The baseline is a synthetic guard
# and onboarding script (never this checkout, so the self-test means the
# same thing before and after the allow-list widening lands) that
# already carry the widening; each case undoes or overshoots the widening
# in exactly one way and must flip exactly the cases that widening is
# about.

_SELFTEST_GROUPS = "['', 'apps', 'batch', 'policy', 'networking.k8s.io', 'inference.networking.k8s.io', 'llm-d.ai', 'jobset.x-k8s.io']"
_SELFTEST_RESOURCES = "['serviceaccounts', 'configmaps', 'pods', 'services', 'deployments', 'statefulsets', 'daemonsets', 'jobs', 'cronjobs', 'poddisruptionbudgets', 'networkpolicies', 'inferencepools', 'inferenceobjectives', 'inferencemodelrewrites', 'jobsets']"
_SELFTEST_VERBS = "['get', 'list', 'watch', 'create', 'update', 'patch', 'delete']"


def _guard_text(groups: str = _SELFTEST_GROUPS, resources: str = _SELFTEST_RESOURCES, verbs: str = _SELFTEST_VERBS, deny_action: str = "Deny") -> str:
    return f"""\
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: team-rbac-guard
spec:
  failurePolicy: Fail
  matchConstraints:
    namespaceSelector:
      matchExpressions:
        - key: distai.dev/team
          operator: Exists
    resourceRules:
      - apiGroups: ["rbac.authorization.k8s.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["roles", "rolebindings"]
  validations:
    - expression: "request.resource.resource != 'rolebindings' || object.roleRef.kind != 'ClusterRole'"
    - expression: >-
        request.resource.resource != 'roles' || !has(object.rules) ||
        object.rules.all(r,
          r.apiGroups.all(g, g in {groups}) &&
          r.resources.all(x, x in {resources}) &&
          (r.resources.exists(x, x in ['inferencepools', 'inferenceobjectives', 'inferencemodelrewrites'])
            ? r.verbs.all(v, v in ['get', 'list', 'watch'])
            : r.verbs.all(v, v in {verbs}))
        )
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: team-rbac-guard-binding
spec:
  policyName: team-rbac-guard
  validationActions: ["{deny_action}"]
"""


def _onboard_text(jobset_rule: str = '  - apiGroups: ["jobset.x-k8s.io"]\n    resources: ["jobsets"]\n    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]\n') -> str:
    return (
        "#!/usr/bin/env bash\n"
        "kubectl apply -f - <<EOF\n"
        "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: ${SERVICE_ACCOUNT}\n  namespace: ${TEAM}\n"
        "---\n"
        "apiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: ${SERVICE_ACCOUNT}-role\n  namespace: ${TEAM}\nrules:\n"
        '  - apiGroups: [""]\n    resources: ["serviceaccounts", "configmaps", "pods", "services"]\n    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]\n'
        + jobset_rule
        + "EOF\n"
    )


def _write(root: str, rel: str, text: str) -> None:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _run(root: str) -> tuple[int, list[str]]:
    global FAILURES
    FAILURES = []
    import contextlib
    import io

    with contextlib.redirect_stdout(io.StringIO()):
        rc = main(root)
    return rc, list(FAILURES)


def selftest() -> int:
    # (name, guard text, onboard text, the failure-label substrings that
    # must appear -- each exactly once -- and nothing else)
    cases = [
        ("baseline passes with zero failures", _guard_text(), _onboard_text(), []),
        (
            "jobset.x-k8s.io missing from the group list: the jobset allow cases and the onboarding Role all flip to denied",
            _guard_text(groups=_SELFTEST_GROUPS.replace(", 'jobset.x-k8s.io'", "")),
            _onboard_text(),
            [
                "ALLOWS: Role granting full CRUD on jobset.x-k8s.io jobsets",
                "ALLOWS: Role granting read-only on jobset.x-k8s.io jobsets",
                "ALLOWS gitops/bootstrap/team-onboard.sh step 3's own Role",
            ],
        ),
        (
            "jobsets missing from the resource list: the same three flip",
            _guard_text(resources=_SELFTEST_RESOURCES.replace(", 'jobsets'", "")),
            _onboard_text(),
            [
                "ALLOWS: Role granting full CRUD on jobset.x-k8s.io jobsets",
                "ALLOWS: Role granting read-only on jobset.x-k8s.io jobsets",
                "ALLOWS gitops/bootstrap/team-onboard.sh step 3's own Role",
            ],
        ),
        (
            "an over-broad widening that also lists jobsets/status: only the subresource cases flip to allowed",
            _guard_text(resources=_SELFTEST_RESOURCES.replace("'jobsets']", "'jobsets', 'jobsets/status']")),
            _onboard_text(),
            [
                "DENIES: Role granting jobset.x-k8s.io jobsets/status",
                "DENIES: Role granting jobsets alongside jobsets/status",
                "DENIES: Role whose second rule is the jobsets/status subresource",
            ],
        ),
        (
            "an over-broad widening that adds deletecollection to the verb list: only that case flips",
            _guard_text(verbs=_SELFTEST_VERBS.replace("'delete']", "'delete', 'deletecollection']")),
            _onboard_text(),
            ["DENIES: Role granting deletecollection on jobsets"],
        ),
        (
            "an over-broad widening that adds kueue.x-k8s.io and its kinds: only the Kueue cases flip",
            _guard_text(
                groups=_SELFTEST_GROUPS.replace("]", ", 'kueue.x-k8s.io']"),
                resources=_SELFTEST_RESOURCES.replace("'jobsets']", "'jobsets', 'workloads', 'localqueues']"),
            ),
            _onboard_text(),
            ["DENIES: Role granting kueue.x-k8s.io workloads", "DENIES: Role granting kueue.x-k8s.io localqueues"],
        ),
        (
            "team-onboard.sh's Role without the jobsets rule fails only the deployer-grant check",
            _guard_text(),
            _onboard_text(jobset_rule=""),
            ["step 3's Role grants"],
        ),
        (
            "team-onboard.sh's Role granting jobsets read-only fails only the deployer-grant check",
            _guard_text(),
            _onboard_text(jobset_rule='  - apiGroups: ["jobset.x-k8s.io"]\n    resources: ["jobsets"]\n    verbs: ["get", "list", "watch"]\n'),
            ["step 3's Role grants"],
        ),
        (
            "a Binding in Audit instead of Deny fails only the Binding check",
            _guard_text(deny_action="Audit"),
            _onboard_text(),
            ["validationActions [Deny]"],
        ),
    ]
    failures = 0
    for name, guard, onboard, expect in cases:
        tmp = tempfile.mkdtemp(prefix="check-team-rbac-guard-selftest-")
        try:
            _write(tmp, GUARD, guard)
            _write(tmp, ONBOARD, onboard)
            rc, fails = _run(tmp)
            matched = [sum(1 for f in fails if e in f) for e in expect]
            ok = (rc == 0 and not fails) if not expect else (rc != 0 and len(fails) == len(expect) and all(m == 1 for m in matched))
            check(f"selftest: {name}", ok, f"expected exactly {expect or 'no failures'}, got {fails}")
            if not ok:
                failures += 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 2:
        print("usage: check_team_rbac_guard.py <repo-root> | check_team_rbac_guard.py --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
