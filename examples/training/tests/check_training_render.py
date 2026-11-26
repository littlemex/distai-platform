#!/usr/bin/env python3
import os  # ci-verify (throwaway, reverted before merge): unused import to fail ruff F401
"""Checks one `helm template` render of examples/training/pytorch-ddp
against what issue #34 says the chart is, without a cluster.

The checks look only at rendered objects, never at the chart's own
values.yaml key names: the caller passes the values it set (queue name,
ServiceAccount, bucket, prefix, replica count) and this script looks for
those values where the issue says they must end up. That keeps every
check's intent stable if the chart names its values differently (only
values-keys.sh changes then).

  R1  exactly one JobSet, apiVersion jobset.x-k8s.io/v1alpha2;
  R2  its metadata.labels["kueue.x-k8s.io/queue-name"] is the queue that
      was set (Kueue admits it through that LocalQueue);
  R3  spec.failurePolicy.restartStrategy is BlockingRecreate and
      maxRestarts is an integer >= 1 (a mid-run failure recreates the
      whole group, more than once is possible);
  R4  exactly one replicatedJob, whose replicas is the count that was
      set, and whose Job template's backoffLimit is 0 -- with any other
      backoffLimit the Job controller replaces a lost Pod on its own and
      the JobSet's failurePolicy never fires, so "kill one worker, the
      whole group restarts" would not happen;
  R5  the training container requests an accelerator (nvidia.com/gpu or
      aws.amazon.com/neuron), runs torchrun, sets FI_PROVIDER=efa and at
      least one NCCL_* variable; when --nproc-per-node / --nnodes are
      literal numbers they match the accelerator count and the replica
      count;
  R6  the pod template's serviceAccountName is the ServiceAccount that
      was set, that ServiceAccount is rendered by the chart, and it
      carries no eks.amazonaws.com/role-arn annotation (EKS Pod Identity,
      not IRSA: the association is made outside the chart);
  R7  the bucket and prefix that were set reach the training container
      (an env value, an argument, or a rendered ConfigMap);
  R8  the pod template passes Pod Security "restricted", the level
      gitops/bootstrap/team-onboard.sh enforces on every team namespace
      (a chart that fails it can never start a Pod there);
  R9  every container image is pinned (a tag or digest, never :latest);
  R10 (--team-onboard) every rendered object is a kind the
      <team>-deployer-role Role in team-onboard.sh step 3 grants create
      on, so that identity can apply the whole chart itself;
  R11 (--jobset-crd) the JobSet validates against the vendored CRD's own
      v1alpha2 openAPIV3Schema, with undeclared fields rejected (needs
      the jsonschema package).

Usage:
    check_training_render.py RENDERED.yaml --queue Q --service-account SA \\
        --bucket B --prefix P [--replicas N] [--team-onboard PATH] [--jobset-crd PATH]
    check_training_render.py --selftest

Prints one "PASS <label>" or "FAIL <label>: <reason>" line per check and
exits 1 if any check failed, 0 otherwise.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shlex
import shutil
import sys
import tempfile

import yaml

FAILURES: list[str] = []

QUEUE_LABEL = "kueue.x-k8s.io/queue-name"
ACCELERATORS = ("nvidia.com/gpu", "aws.amazon.com/neuron")
RESTRICTED_VOLUME_TYPES = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim", "projected", "secret"}


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def info(msg: str) -> None:
    print(f"INFO {msg}")


def group_of(api_version: str) -> str:
    return api_version.split("/", 1)[0] if "/" in api_version else ""


def plural(kind: str) -> str:
    k = kind.lower()
    if k.endswith("y"):
        return k[:-1] + "ies"
    if k.endswith("s"):
        return k + "es"
    return k + "s"


def containers_of(pod_spec: dict) -> list[dict]:
    return list(pod_spec.get("initContainers") or []) + list(pod_spec.get("containers") or [])


def command_text(c: dict) -> str:
    return " ".join(str(x) for x in (c.get("command") or []) + (c.get("args") or []))


def flag_value(text: str, *names: str) -> str | None:
    """The value of --name=V or --name V (or --name_with_underscores) in a
    command line, or None."""
    try:
        toks = shlex.split(text)
    except ValueError:
        toks = text.split()
    for i, t in enumerate(toks):
        for n in names:
            for spelling in (n, "--" + n[2:].replace("-", "_")):
                if t.startswith(spelling + "="):
                    return t.split("=", 1)[1]
                if t == spelling and i + 1 < len(toks):
                    return toks[i + 1]
    return None


# ------------------------------------------------- Pod Security restricted


def restricted_violations(pod_spec: dict) -> list[str]:
    """The Pod Security Standards "restricted" rules that matter for an
    ordinary workload Pod (pod-security.kubernetes.io/enforce: restricted):
    host namespaces, privileged, capabilities, volume types, hostPort,
    privilege escalation, running as non-root, seccomp."""
    out = []
    for f in ("hostNetwork", "hostPID", "hostIPC"):
        if pod_spec.get(f):
            out.append(f"{f}: true")
    for v in pod_spec.get("volumes") or []:
        types = set(v) - {"name"}
        if not types <= RESTRICTED_VOLUME_TYPES:
            out.append(f"volume {v.get('name')!r} uses {sorted(types - RESTRICTED_VOLUME_TYPES)}")
    psc = pod_spec.get("securityContext") or {}
    pod_nonroot = psc.get("runAsNonRoot") is True
    pod_seccomp = (psc.get("seccompProfile") or {}).get("type") in ("RuntimeDefault", "Localhost")
    if psc.get("runAsUser") == 0:
        out.append("pod securityContext.runAsUser: 0")
    for c in containers_of(pod_spec):
        n = c.get("name")
        sc = c.get("securityContext") or {}
        if sc.get("privileged"):
            out.append(f"container {n}: privileged")
        if sc.get("allowPrivilegeEscalation") is not False:
            out.append(f"container {n}: allowPrivilegeEscalation is not false")
        caps = sc.get("capabilities") or {}
        if "ALL" not in (caps.get("drop") or []):
            out.append(f"container {n}: capabilities.drop does not include ALL")
        extra = set(caps.get("add") or []) - {"NET_BIND_SERVICE"}
        if extra:
            out.append(f"container {n}: capabilities.add {sorted(extra)}")
        if not (sc.get("runAsNonRoot") is True or (pod_nonroot and sc.get("runAsNonRoot") is not False)):
            out.append(f"container {n}: runAsNonRoot is not true (pod or container)")
        if sc.get("runAsUser") == 0:
            out.append(f"container {n}: runAsUser: 0")
        c_seccomp = (sc.get("seccompProfile") or {}).get("type")
        if not (c_seccomp in ("RuntimeDefault", "Localhost") or (pod_seccomp and c_seccomp is None)):
            out.append(f"container {n}: seccompProfile is not RuntimeDefault/Localhost (pod or container)")
        for p in c.get("ports") or []:
            if p.get("hostPort"):
                out.append(f"container {n}: hostPort {p.get('hostPort')}")
    return out


# ------------------------------------------------ team-onboard.sh's Role


def deployer_grants(onboard_path: str) -> set[tuple[str, str]] | None:
    """(apiGroup, resource) pairs team-onboard.sh step 3's Role grants
    `create` on, read from the script's own heredoc."""
    with open(onboard_path, encoding="utf-8") as f:
        text = f.read()
    roles = []
    for b in re.findall(r"<<EOF\n(.*?)\nEOF\n", text, flags=re.S):
        b = re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", "placeholder", b)
        try:
            roles += [d for d in yaml.safe_load_all(b) if isinstance(d, dict) and d.get("kind") == "Role"]
        except yaml.YAMLError:
            continue
    if len(roles) != 1:
        check(f"{onboard_path} applies exactly one Role (step 3's <team>-deployer-role)", False, f"found {len(roles)}")
        return None
    out = set()
    for r in roles[0].get("rules") or []:
        if "create" in (r.get("verbs") or []):
            out |= {(g, res) for g in r.get("apiGroups") or [] for res in r.get("resources") or []}
    return out


# ---------------------------------------------------------------- schema


def close_objects(node):
    if isinstance(node, dict):
        if "properties" in node and "additionalProperties" not in node and not node.get("x-kubernetes-preserve-unknown-fields"):
            node["additionalProperties"] = False
        for v in node.values():
            close_objects(v)
    elif isinstance(node, list):
        for v in node:
            close_objects(v)
    return node


def validate_against_crd(jobset: dict, crd_path: str) -> None:
    import jsonschema  # only needed for R11

    with open(crd_path, encoding="utf-8") as f:
        crds = [d for d in yaml.safe_load_all(f) if isinstance(d, dict) and d.get("kind") == "CustomResourceDefinition"]
    version = jobset.get("apiVersion", "").split("/")[-1]
    schema = None
    for crd in crds:
        for v in (crd.get("spec") or {}).get("versions") or []:
            if v.get("name") == version:
                schema = ((v.get("schema") or {}).get("openAPIV3Schema"))
    if schema is None:
        check(f"R11 {crd_path} has an openAPIV3Schema for {version}", False)
        return
    # metadata is validated by the API server itself, not by the CRD's own
    # schema (which declares it as a bare object); drop it from the copy.
    doc = copy.deepcopy(jobset)
    doc.pop("metadata", None)
    schema = close_objects(copy.deepcopy(schema))
    (schema.get("properties") or {}).pop("metadata", None)
    errors = sorted(jsonschema.Draft7Validator(schema).iter_errors(doc), key=lambda e: list(e.absolute_path))
    check(
        f"R11 the JobSet validates against {os.path.basename(crd_path)}'s {version} schema (undeclared fields rejected)",
        not errors,
        "; ".join(f"{'/'.join(str(p) for p in e.absolute_path)}: {e.message}" for e in errors[:5]),
    )


# ------------------------------------------------------------------ main


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("rendered")
    ap.add_argument("--queue", required=True)
    ap.add_argument("--service-account", required=True)
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--replicas", type=int, default=None)
    ap.add_argument("--team-onboard")
    ap.add_argument("--jobset-crd")
    a = ap.parse_args(argv)

    with open(a.rendered, encoding="utf-8") as f:
        docs = [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]

    jobsets = [d for d in docs if d.get("kind") == "JobSet"]
    check("R1 exactly one JobSet is rendered", len(jobsets) == 1, f"found {len(jobsets)}; kinds: {sorted({d.get('kind') for d in docs})}")
    if len(jobsets) != 1:
        return finish()
    js = jobsets[0]
    check("R1 the JobSet's apiVersion is jobset.x-k8s.io/v1alpha2", js.get("apiVersion") == "jobset.x-k8s.io/v1alpha2", f"got {js.get('apiVersion')!r}")

    labels = (js.get("metadata") or {}).get("labels") or {}
    check(f"R2 the JobSet carries {QUEUE_LABEL}={a.queue}", labels.get(QUEUE_LABEL) == a.queue, f"got labels {labels}")

    spec = js.get("spec") or {}
    fp = spec.get("failurePolicy") or {}
    check("R3 failurePolicy.restartStrategy is BlockingRecreate", fp.get("restartStrategy") == "BlockingRecreate", f"got failurePolicy={fp!r}")
    mr = fp.get("maxRestarts")
    check("R3 failurePolicy.maxRestarts is an integer >= 1", isinstance(mr, int) and not isinstance(mr, bool) and mr >= 1, f"got maxRestarts={mr!r}")
    if isinstance(mr, int) and mr != 3:
        info(f"failurePolicy.maxRestarts is {mr}; issue #34's worked example names 3")

    rjs = spec.get("replicatedJobs") or []
    check("R4 exactly one replicatedJob", len(rjs) == 1, f"found {len(rjs)}")
    if len(rjs) != 1:
        return finish()
    rj = rjs[0]
    replicas = rj.get("replicas", 1)
    if a.replicas is not None:
        check(f"R4 replicatedJobs[0].replicas is the {a.replicas} that was set", replicas == a.replicas, f"got {replicas!r}")
    job_spec = ((rj.get("template") or {}).get("spec")) or {}
    check(
        "R4 the Job template's backoffLimit is 0 (a lost Pod fails its Job, so the JobSet's failurePolicy -- not the Job controller -- restarts the group)",
        job_spec.get("backoffLimit") == 0,
        f"got backoffLimit={job_spec.get('backoffLimit')!r}",
    )
    pod_spec = (((job_spec.get("template") or {}).get("spec")) or {})

    # R5
    workers = [c for c in pod_spec.get("containers") or [] if any(k in ((c.get("resources") or {}).get("limits") or {}) for k in ACCELERATORS)]
    check(f"R5 a container requests an accelerator in limits ({', '.join(ACCELERATORS)})", bool(workers), f"containers: {[c.get('name') for c in pod_spec.get('containers') or []]}")
    for c in workers:
        n = c.get("name")
        limits = (c.get("resources") or {}).get("limits") or {}
        acc = next(int(limits[k]) for k in ACCELERATORS if k in limits)
        env = {e.get("name"): e.get("value") for e in c.get("env") or [] if isinstance(e, dict)}
        cmd = command_text(c)
        check(f"R5 container {n} runs torchrun", "torchrun" in cmd or "torch.distributed.run" in cmd, f"command/args: {cmd[:300]!r}")
        check(f"R5 container {n} sets FI_PROVIDER=efa", env.get("FI_PROVIDER") == "efa", f"FI_PROVIDER={env.get('FI_PROVIDER')!r}")
        check(f"R5 container {n} sets at least one NCCL_* variable", any(k and k.startswith("NCCL_") for k in env), f"env names: {sorted(k for k in env if k)}")
        nproc = flag_value(cmd, "--nproc-per-node")
        if nproc is not None and nproc.isdigit():
            check(f"R5 container {n}: torchrun --nproc-per-node {nproc} equals its accelerator limit {acc}", int(nproc) == acc)
        else:
            info(f"container {n}: --nproc-per-node is not a literal number ({nproc!r}); not compared with the accelerator limit")
        # --nnodes is not always a literal in this command: a script that
        # fast-paths the single-node case (`--standalone --nnodes=1`) and
        # takes `--nnodes="$NNODES"` for every other case has no single
        # literal --nnodes value to compare against replicas (for
        # replicas=2 the first --nnodes token a naive scan finds is still
        # the literal "1" belonging to the untaken single-node branch).
        # Check the data flow instead: the container's own NNODES env var
        # (set from replicatedJobs[0].replicas, confirmed by string value
        # here, not by re-deriving it from the command text) must equal
        # replicas, and the command must actually reference it.
        nnodes_env = env.get("NNODES")
        if nnodes_env is not None:
            check(f"R5 container {n}: env NNODES={nnodes_env!r} equals replicatedJobs[0].replicas {replicas}", nnodes_env == str(replicas))
            check(f"R5 container {n}: the command references $NNODES", "NNODES" in cmd)
        else:
            nnodes = flag_value(cmd, "--nnodes")
            if nnodes is not None and nnodes.isdigit():
                check(f"R5 container {n}: torchrun --nnodes {nnodes} equals replicatedJobs[0].replicas {replicas}", int(nnodes) == replicas)
            else:
                check(f"R5 container {n}: torchrun's node count (env NNODES, or a literal --nnodes) is set and traceable to replicatedJobs[0].replicas {replicas}", False, f"no NNODES env var and --nnodes is {nnodes!r}")

    # R6
    sa_name = pod_spec.get("serviceAccountName")
    check(f"R6 the pod template's serviceAccountName is {a.service_account}", sa_name == a.service_account, f"got {sa_name!r}")
    sas = [d for d in docs if d.get("kind") == "ServiceAccount" and (d.get("metadata") or {}).get("name") == a.service_account]
    check(f"R6 the chart renders ServiceAccount {a.service_account}", len(sas) == 1, f"found {len(sas)}")
    for sa in sas:
        ann = (sa.get("metadata") or {}).get("annotations") or {}
        check(
            f"R6 ServiceAccount {a.service_account} carries no eks.amazonaws.com/role-arn annotation (EKS Pod Identity, not IRSA)",
            "eks.amazonaws.com/role-arn" not in ann,
            f"annotations: {ann}",
        )

    # R7
    haystack = []
    for c in containers_of(pod_spec):
        haystack.append(command_text(c))
        haystack += [str(e.get("value")) for e in c.get("env") or [] if isinstance(e, dict) and e.get("value") is not None]
    for d in docs:
        if d.get("kind") == "ConfigMap":
            haystack += [str(v) for v in (d.get("data") or {}).values()]
    text = "\n".join(haystack)
    check(f"R7 the bucket {a.bucket!r} reaches the training container (env, args or a rendered ConfigMap)", a.bucket in text)
    check(f"R7 the prefix {a.prefix!r} reaches the training container (env, args or a rendered ConfigMap)", a.prefix in text)

    # R8
    v = restricted_violations(pod_spec)
    check("R8 the pod template passes Pod Security 'restricted' (team-onboard.sh's enforce level)", not v, "; ".join(v))

    # R9
    for c in containers_of(pod_spec):
        img = str(c.get("image") or "")
        last = img.rsplit("/", 1)[-1]
        pinned = "@sha256:" in img or (":" in last and not last.endswith(":latest"))
        check(f"R9 container {c.get('name')}'s image {img!r} is pinned (tag or digest, not :latest)", pinned)

    # R10
    if a.team_onboard:
        grants = deployer_grants(a.team_onboard)
        if grants is not None:
            for d in docs:
                key = (group_of(str(d.get("apiVersion") or "")), plural(str(d.get("kind") or "")))
                check(
                    f"R10 {d.get('kind')}/{(d.get('metadata') or {}).get('name')}: team-onboard.sh's deployer Role grants create on {key[0] or 'core'}/{key[1]}",
                    key in grants,
                    f"granted: {sorted(grants)}",
                )

    # R11
    if a.jobset_crd:
        validate_against_crd(js, a.jobset_crd)

    return finish()


def finish() -> int:
    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all training render checks passed")
    return 0


# ------------------------------------------------------------- selftest
#
# A check that has only ever been seen green is not trusted to actually
# fail on the thing it claims to catch (the pattern of
# gitops/tests/check_addon_tiers.py). One synthetic render that passes
# with zero failures; each case breaks exactly one property and must fail
# exactly the one check that names it. R11 is not exercised here (it
# needs the jsonschema package and a CRD; 0.static.sh runs it for real).

_ONBOARD = (
    "kubectl apply -f - <<EOF\n"
    "apiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: ${SERVICE_ACCOUNT}-role\nrules:\n"
    '  - apiGroups: [""]\n    resources: ["serviceaccounts", "configmaps"]\n    verbs: ["get", "create"]\n'
    '  - apiGroups: ["jobset.x-k8s.io"]\n    resources: ["jobsets"]\n    verbs: ["get", "create"]\n'
    "EOF\n"
)


def _baseline_docs() -> list[dict]:
    return [
        {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "sa1"}},
        {
            "apiVersion": "jobset.x-k8s.io/v1alpha2",
            "kind": "JobSet",
            "metadata": {"name": "ddp", "labels": {QUEUE_LABEL: "q1"}},
            "spec": {
                "failurePolicy": {"restartStrategy": "BlockingRecreate", "maxRestarts": 3},
                "replicatedJobs": [{
                    "name": "worker",
                    "replicas": 2,
                    "template": {"spec": {"backoffLimit": 0, "template": {"spec": {
                        "serviceAccountName": "sa1",
                        "restartPolicy": "Never",
                        "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
                        "volumes": [{"name": "shm", "emptyDir": {"medium": "Memory"}}],
                        "containers": [{
                            "name": "trainer",
                            "image": "public.ecr.aws/example/trainer:1.0.0",
                            "command": ["torchrun", "--nnodes=2", "--nproc-per-node=2", "train.py"],
                            "env": [
                                {"name": "FI_PROVIDER", "value": "efa"},
                                {"name": "NCCL_DEBUG", "value": "INFO"},
                                {"name": "CHECKPOINT_BUCKET", "value": "bkt"},
                                {"name": "CHECKPOINT_PREFIX", "value": "pre/fix"},
                            ],
                            "resources": {"limits": {"nvidia.com/gpu": 2}},
                            "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
                        }],
                    }}}},
                }],
            },
        },
    ]


def _container(docs):
    return docs[1]["spec"]["replicatedJobs"][0]["template"]["spec"]["template"]["spec"]["containers"][0]


def _pod(docs):
    return docs[1]["spec"]["replicatedJobs"][0]["template"]["spec"]["template"]["spec"]


def _run(docs: list[dict], tmp: str) -> tuple[int, list[str]]:
    global FAILURES
    FAILURES = []
    rendered = os.path.join(tmp, "rendered.yaml")
    onboard = os.path.join(tmp, "team-onboard.sh")
    with open(rendered, "w", encoding="utf-8") as f:
        yaml.safe_dump_all(docs, f)
    with open(onboard, "w", encoding="utf-8") as f:
        f.write(_ONBOARD)
    import contextlib
    import io

    with contextlib.redirect_stdout(io.StringIO()):
        rc = main([rendered, "--queue", "q1", "--service-account", "sa1", "--bucket", "bkt", "--prefix", "pre/fix", "--replicas", "2", "--team-onboard", onboard])
    return rc, list(FAILURES)


def selftest() -> int:
    def m(fn):
        def apply(docs):
            fn(docs)
            return docs
        return apply

    cases = [
        ("baseline passes with zero failures", m(lambda d: None), None),
        ("a missing queue label fails only R2", m(lambda d: d[1]["metadata"].pop("labels")), "R2"),
        ("restartStrategy Recreate fails only the R3 strategy rule", m(lambda d: d[1]["spec"]["failurePolicy"].update(restartStrategy="Recreate")), "restartStrategy is BlockingRecreate"),
        ("maxRestarts 0 fails only the R3 maxRestarts rule", m(lambda d: d[1]["spec"]["failurePolicy"].update(maxRestarts=0)), "maxRestarts is an integer"),
        ("backoffLimit 6 fails only the R4 backoffLimit rule", m(lambda d: d[1]["spec"]["replicatedJobs"][0]["template"]["spec"].update(backoffLimit=6)), "backoffLimit is 0"),
        ("replicas 1 (with --nnodes=1) fails only the R4 replica rule",
         m(lambda d: (d[1]["spec"]["replicatedJobs"][0].update(replicas=1), _container(d).update(command=["torchrun", "--nnodes=1", "--nproc-per-node=2", "train.py"]))),
         "replicas is the 2 that was set"),
        ("--nproc-per-node 4 on a 2-GPU container fails only the nproc rule", m(lambda d: _container(d).update(command=["torchrun", "--nnodes=2", "--nproc-per-node=4", "train.py"])), "--nproc-per-node 4 equals"),
        ("FI_PROVIDER missing fails only the FI_PROVIDER rule", m(lambda d: _container(d).update(env=[e for e in _container(d)["env"] if e["name"] != "FI_PROVIDER"])), "FI_PROVIDER=efa"),
        ("no NCCL_* variable fails only the NCCL rule", m(lambda d: _container(d).update(env=[e for e in _container(d)["env"] if not e["name"].startswith("NCCL_")])), "NCCL_"),
        ("a different serviceAccountName fails only the R6 pod-template rule", m(lambda d: _pod(d).update(serviceAccountName="other")), "serviceAccountName is sa1"),
        ("an IRSA annotation on the ServiceAccount fails only the Pod Identity rule", m(lambda d: d[0]["metadata"].update(annotations={"eks.amazonaws.com/role-arn": "arn:aws:iam::111122223333:role/x"})), "no eks.amazonaws.com/role-arn"),
        ("the bucket not reaching the container fails only the R7 bucket rule", m(lambda d: _container(d).update(env=[e for e in _container(d)["env"] if e["name"] != "CHECKPOINT_BUCKET"])), "the bucket"),
        ("allowPrivilegeEscalation unset fails only R8", m(lambda d: _container(d)["securityContext"].pop("allowPrivilegeEscalation")), "R8"),
        ("a hostPath volume fails only R8", m(lambda d: _pod(d)["volumes"].append({"name": "h", "hostPath": {"path": "/"}})), "R8"),
        ("an image on :latest fails only R9", m(lambda d: _container(d).update(image="public.ecr.aws/example/trainer:latest")), "R9"),
        ("a rendered Role (not grantable by the deployer) fails only R10",
         m(lambda d: d.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role", "metadata": {"name": "r"}, "rules": []})),
         "R10 Role/r"),
    ]
    failures = 0
    for name, mutate, expect in cases:
        tmp = tempfile.mkdtemp(prefix="check-training-render-selftest-")
        try:
            docs = mutate(json.loads(json.dumps(_baseline_docs())))
            rc, fails = _run(docs, tmp)
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
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    sys.exit(main(sys.argv[1:]))
