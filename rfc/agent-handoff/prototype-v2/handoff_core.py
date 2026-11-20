#!/usr/bin/env python3
"""handoff_core.py (v2) - prototype of the Ledger at the shape design.md's
review-r7.md actually APPROVEd: a broker-only write model, a client-generated
token the Ledger only ever stores hashed, lease_seconds read from the plan
(never a caller parameter), and a two-call wait whose clock is the broker's
own, never a caller's local sleep(). This supersedes prototype/handoff_core.py,
which exercised round 2's shape (a caller-supplied lease_seconds, a
broker-returned plaintext token, a task role with direct, attribute-Deny-gated
UpdateItem). verification.md's own "Scope not covered" section names that gap
explicitly: rounds 3-7 changed the mechanism after the prototype ran, and
nothing re-ran it against the final shape - this file and
handoff_scenarios.py are that re-run (design.md "Experiments needed" 1-4,
cpu-only; experiment 5 needs a live EKS cell/Capacity Block and is explicitly
deferred by design.md itself to the first real consumer PR, not required here).

Run only on the distai-platform EC2 runner, never on a developer Mac (project
rule). Everything this script creates is named with a fixed, grep-able prefix
and is deleted by `teardown`.

Usage:
  handoff_core.py setup      # table, broker role, two work-credential roles, SSM params
  handoff_core.py teardown   # delete everything this script created
"""
import argparse
import hashlib
import json
import sys
import time
import uuid
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

PREFIX = "distai-handoff-rfc"
TABLE = f"{PREFIX}-ledger"
AI_BASE_ROLE = f"{PREFIX}-ai-base-role"          # stands in for an AI session's own
                                                   # (narrowed, post-migration) base role -
                                                   # Decision 5's "base-credential migration"
BROKER_ROLE = f"{PREFIX}-broker-role"            # stands in for the broker Lambda's own
                                                   # execution role (Decision 5)
WORK_ROLE_LIGHT = f"{PREFIX}-work-demo-light"    # per-profile work-credential role
WORK_ROLE_APPROVAL = f"{PREFIX}-work-demo-approval"
SSM_ALLOWED = f"/{PREFIX}/allowed"
SSM_FORBIDDEN = f"/{PREFIX}/forbidden"
REGION = "us-east-1"

# KIND_POLICY: maintainer-owned, read by create()/claim()/replan() ONLY - never
# caller-supplied (Decision 4/6). kind selection and lease_seconds both live
# here, closing round 2's N1/N4 (a caller could shorten the wait, or pick a
# kind nothing requires approval for).
KIND_POLICY = {
    "demo-light": {
        "allowed_profiles": ["demo-light-profile"],
        "work_role": WORK_ROLE_LIGHT,
        "lease_seconds": 3,          # short for a fast test run, not production sizing
        "timebox_minutes": 5,
        "max_cost_usd": 5,
        "max_retries": 2,
        "requires_approval": False,
        "allowed_queues": [],
        "allowed_capacity_blocks": ["demo-cb-0001"],
    },
    "demo-approval": {
        "allowed_profiles": ["demo-approval-profile"],
        "work_role": WORK_ROLE_APPROVAL,
        "lease_seconds": 3,
        "timebox_minutes": 5,
        "max_cost_usd": 5,
        "max_retries": 2,
        "requires_approval": True,
        "allowed_queues": [],
        "allowed_capacity_blocks": ["demo-cb-0001"],
    },
}


def broker_now():
    """The broker's OWN clock. Every elapsed-time decision in claim()/sweep() is
    this value against a value this same process wrote earlier - never a value a
    caller supplies, and never compared across machines (Decision 4). Sub-second
    precision (not int(time.time())) so a short lease_seconds used for a fast
    test run is not shaved by truncation at both ends of the wait. Decimal, via
    str() (never float() directly), because boto3's DynamoDB resource API
    refuses a native Python float outright ("Float types are not supported") -
    going through str() avoids binary-float imprecision leaking into the
    Decimal boto3 does accept."""
    return Decimal(str(time.time()))


def _decimal_default(o):
    # boto3's DynamoDB resource API returns every number read back from the
    # table as decimal.Decimal, even one written as a plain Python int - a
    # read-back plan item would otherwise hash differently from the plan
    # create() originally hashed, breaking claim()'s own hash recomputation
    # (N4) for reasons that have nothing to do with the plan's own content.
    # Rendered the same way json.dumps already renders a plain int/float, so
    # a value written as int(3) and later read back as Decimal('3') produces
    # the identical canonical string either way.
    if isinstance(o, Decimal):
        return int(o) if o == o.to_integral_value() else float(o)
    raise TypeError(f"Object of type {o.__class__.__name__} is not JSON serializable")


def canonical_json(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=_decimal_default)


def plan_ref_for(plan):
    return "plan:sha256:" + hashlib.sha256(canonical_json(plan).encode()).hexdigest()


def hash_token(client_token):
    return "sha256:" + hashlib.sha256(client_token.encode()).hexdigest()


def new_client_token():
    """128 bits from a CSPRNG (Residual risks: client_token needs enough entropy
    that guessing it is infeasible)."""
    return uuid.uuid4().hex + uuid.uuid4().hex


def _retry_not_found(fn, *args, **kwargs):
    last = None
    for attempt in range(8):
        try:
            return fn(*args, **kwargs)
        except ClientError as e:
            if e.response["Error"]["Code"] != "ResourceNotFoundException":
                raise
            last = e
            time.sleep(1 + attempt)
    raise last


# --------------------------------------------------------------------------- setup

def cmd_setup(_args):
    sts = boto3.client("sts", region_name=REGION)
    caller = sts.get_caller_identity()
    account = caller["Account"]
    runner_arn = caller["Arn"]
    table_arn = f"arn:aws:dynamodb:{REGION}:{account}:table/{TABLE}"
    broker_arn = f"arn:aws:iam::{account}:role/{BROKER_ROLE}"
    ai_base_arn = f"arn:aws:iam::{account}:role/{AI_BASE_ROLE}"

    ddbc = boto3.client("dynamodb", region_name=REGION)
    try:
        ddbc.create_table(
            TableName=TABLE,
            AttributeDefinitions=[{"AttributeName": "task_id", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "task_id", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        ddbc.get_waiter("table_exists").wait(TableName=TABLE)
        ddbc.update_time_to_live(
            TableName=TABLE, TimeToLiveSpecification={"Enabled": True, "AttributeName": "ttl"},
        )
        print(f"[setup] created table {TABLE} (single table: task items AND plan items, "
              f"overloading the task_id partition key - plan items key on their own plan_ref)")
    except ClientError as e:
        if e.response["Error"]["Code"] == "ResourceInUseException":
            print(f"[setup] table {TABLE} already exists")
        else:
            raise

    iamc = boto3.client("iam", region_name=REGION)

    # --- SSM demo parameters: one profile may read, the other may not ----------
    ssm = boto3.client("ssm", region_name=REGION)
    for name, value in ((SSM_ALLOWED, "visible-to-demo-light-profile"),
                        (SSM_FORBIDDEN, "must-never-be-readable-by-demo-light-profile")):
        try:
            ssm.put_parameter(Name=name, Value=value, Type="String")
        except ClientError as e:
            if e.response["Error"]["Code"] != "ParameterAlreadyExists":
                raise

    # --- broker role: the Ledger's ONLY writer (Decision 5(c)) ------------------
    # Trust: in production this is a Lambda execution role, reachable only via a
    # SigV4-authenticated endpoint the AI calls - no IAM principal "assumes" it on
    # request. This test stands the runner's own ambient identity in for "however
    # the broker's own process gets invoked", which is a real, named simplification
    # (verification.md's own prototype does the same) - the property actually under
    # test here is the WORK-CREDENTIAL roles' and the TABLE's own trust/permission
    # boundary against the AI-facing role, not who may invoke the broker's code.
    broker_trust = {
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Principal": {"AWS": runner_arn}, "Action": "sts:AssumeRole"}],
    }
    _create_or_update_role(iamc, BROKER_ROLE, broker_trust)
    # Decision 5's permissions boundary: bounds the broker's OWN identity to
    # exactly sts:AssumeRole on the enumerated work-credential roles plus the
    # Ledger table's own actions and the demo SSM namespace - never the union of
    # every profile's own permissions (that would let the broker bypass AssumeRole
    # and act with a profile's full access on its own identity).
    boundary_doc = {
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": "sts:AssumeRole",
             "Resource": [f"arn:aws:iam::{account}:role/{WORK_ROLE_LIGHT}",
                           f"arn:aws:iam::{account}:role/{WORK_ROLE_APPROVAL}"]},
            {"Effect": "Allow",
             "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"],
             "Resource": table_arn},
            {"Effect": "Allow", "Action": "ssm:GetParameter",
             "Resource": f"arn:aws:ssm:{REGION}:{account}:parameter/{PREFIX}/*"},
        ],
    }
    boundary_name = f"{PREFIX}-broker-boundary"
    iamc.create_policy(PolicyName=boundary_name, PolicyDocument=json.dumps(boundary_doc)) \
        if not _policy_exists(iamc, account, boundary_name) else None
    boundary_arn = f"arn:aws:iam::{account}:policy/{boundary_name}"
    iamc.put_role_permissions_boundary(RoleName=BROKER_ROLE, PermissionsBoundary=boundary_arn)
    iamc.put_role_policy(
        RoleName=BROKER_ROLE, PolicyName=f"{PREFIX}-broker-perms",
        PolicyDocument=json.dumps(boundary_doc),  # identity policy == boundary here; the boundary
    )                                              # is the load-bearing ceiling under test

    # --- AI base role: Decision 5(c) - no write action on the Ledger at all -----
    # Stands in for "an AI session's own, migrated base credentials" (Decision 5's
    # named, separate base-credential migration). Grants ONLY GetItem/Query, plus
    # an explicit Deny on every write action for defense in depth (the real
    # boundary is that no Allow for a write action exists at all).
    ai_trust = {
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Principal": {"AWS": runner_arn}, "Action": "sts:AssumeRole"}],
    }
    _create_or_update_role(iamc, AI_BASE_ROLE, ai_trust)
    ai_perms = {
        "Version": "2012-10-17",
        "Statement": [
            {"Sid": "ReadOnlyLedger", "Effect": "Allow",
             "Action": ["dynamodb:GetItem", "dynamodb:Query"], "Resource": table_arn},
            {"Sid": "DenyAllLedgerWrites", "Effect": "Deny",
             "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
                        "dynamodb:BatchWriteItem", "dynamodb:TransactWriteItems",
                        "dynamodb:PartiQLInsert", "dynamodb:PartiQLUpdate", "dynamodb:PartiQLDelete"],
             "Resource": table_arn},
        ],
    }
    iamc.put_role_policy(RoleName=AI_BASE_ROLE, PolicyName=f"{PREFIX}-ai-base-perms",
                          PolicyDocument=json.dumps(ai_perms))

    # --- per-profile work-credential roles: trust ONLY the broker ---------------
    work_trust = {
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Principal": {"AWS": broker_arn}, "Action": "sts:AssumeRole"}],
    }
    _create_or_update_role(iamc, WORK_ROLE_LIGHT, work_trust)
    iamc.put_role_policy(
        RoleName=WORK_ROLE_LIGHT, PolicyName=f"{PREFIX}-work-perms",
        PolicyDocument=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{"Effect": "Allow", "Action": "ssm:GetParameter",
                            "Resource": f"arn:aws:ssm:{REGION}:{account}:parameter{SSM_ALLOWED}"}],
        }),
    )
    _create_or_update_role(iamc, WORK_ROLE_APPROVAL, work_trust)
    iamc.put_role_policy(
        RoleName=WORK_ROLE_APPROVAL, PolicyName=f"{PREFIX}-work-perms",
        PolicyDocument=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{"Effect": "Allow", "Action": "ssm:GetParameter",
                            "Resource": f"arn:aws:ssm:{REGION}:{account}:parameter{SSM_ALLOWED}"}],
        }),
    )
    print("[setup] roles and boundary attached; waiting ~15s for IAM propagation")
    time.sleep(15)


def _policy_exists(iamc, account, name):
    try:
        iamc.get_policy(PolicyArn=f"arn:aws:iam::{account}:policy/{name}")
        return True
    except ClientError:
        return False


def _create_or_update_role(iamc, name, trust_doc):
    last_err = None
    for attempt in range(10):
        try:
            iamc.create_role(RoleName=name, AssumeRolePolicyDocument=json.dumps(trust_doc))
            print(f"[setup] created role {name}")
            return
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code == "EntityAlreadyExists":
                iamc.update_assume_role_policy(RoleName=name, PolicyDocument=json.dumps(trust_doc))
                print(f"[setup] role {name} already exists, trust policy refreshed")
                return
            if code == "MalformedPolicyDocument":
                last_err = e
                time.sleep(5)
                continue
            raise
    raise last_err


def cmd_teardown(_args):
    iamc = boto3.client("iam", region_name=REGION)
    sts = boto3.client("sts", region_name=REGION)
    account = sts.get_caller_identity()["Account"]
    for role, policies in (
        (AI_BASE_ROLE, [f"{PREFIX}-ai-base-perms"]),
        (WORK_ROLE_LIGHT, [f"{PREFIX}-work-perms"]),
        (WORK_ROLE_APPROVAL, [f"{PREFIX}-work-perms"]),
        (BROKER_ROLE, [f"{PREFIX}-broker-perms"]),
    ):
        for pol in policies:
            try:
                iamc.delete_role_policy(RoleName=role, PolicyName=pol)
            except ClientError:
                pass
        try:
            iamc.delete_role_permissions_boundary(RoleName=role)
        except ClientError:
            pass
        try:
            iamc.delete_role(RoleName=role)
            print(f"[teardown] deleted role {role}")
        except ClientError as e:
            print(f"[teardown] role {role}: {e}")
    boundary_name = f"{PREFIX}-broker-boundary"
    boundary_arn = f"arn:aws:iam::{account}:policy/{boundary_name}"
    try:
        iamc.delete_policy(PolicyArn=boundary_arn)
        print(f"[teardown] deleted policy {boundary_name}")
    except ClientError as e:
        print(f"[teardown] policy {boundary_name}: {e}")
    ssm = boto3.client("ssm", region_name=REGION)
    for name in (SSM_ALLOWED, SSM_FORBIDDEN):
        try:
            ssm.delete_parameter(Name=name)
        except ClientError:
            pass
    ddbc = boto3.client("dynamodb", region_name=REGION)
    try:
        ddbc.delete_table(TableName=TABLE)
        ddbc.get_waiter("table_not_exists").wait(TableName=TABLE)
        print(f"[teardown] deleted table {TABLE}")
    except ClientError as e:
        print(f"[teardown] table: {e}")


# =============================================================================
# Broker: EVERY one of these must be called with the broker's OWN credentials
# (Decision 4 restated without exception: create/claim/heartbeat/park/resume/
# release/complete/fail/abandon/force_release/grant_go/sweep/AppendEvidence are
# broker actions - nothing else ever writes this table). `table` below is
# always a boto3 Table resource built from the BROKER_ROLE's own assumed
# session - callers in handoff_scenarios.py never pass an AI-session table in
# here, and the scenarios separately prove an AI-session table CANNOT do what
# this class does, because its own IAM policy denies every write action.
# replan()/create_child()/RenewWorkCredentials() are NOT implemented in this
# round - design.md's own "Experiments needed" 1-4 (what this file re-verifies)
# do not exercise them; left as a named gap in verification.md, same as before.
# =============================================================================

class Rejected(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


class Wait(Exception):
    def __init__(self, retry_after):
        super().__init__(f"wait {retry_after}s")
        self.retry_after = retry_after


class Broker:
    def __init__(self, table, session=None):
        self.t = table  # boto3 Table resource, broker credentials only
        # `session` (also the broker's own credentials) is used for the ONE
        # other AWS call a broker action makes on a caller's behalf: minting
        # work credentials via sts:AssumeRole. Without this, an earlier draft
        # of vend_work_credentials() built its own boto3.client("sts") with no
        # session at all, which silently fell back to this PROCESS's ambient
        # (here: the runner's admin) credentials instead of the broker's own -
        # defeating the very permissions-boundary check this method exists to
        # exercise. Caught by this prototype's own first run on the EC2 runner.
        self.session = session or boto3

    def _sts(self):
        return self.session.client("sts", region_name=REGION)

    # ---------------------------------------------------------------- create()
    def create(self, task_id, kind, requested_profile, resource_binding):
        policy = KIND_POLICY.get(kind)
        if policy is None or requested_profile not in policy["allowed_profiles"]:
            raise Rejected("unknown kind or profile not allowed for this kind")
        has_queue = "cluster_queue" in resource_binding
        has_block = "capacity_block_id" in resource_binding
        if not (has_queue or has_block):
            raise Rejected("resource_binding names neither a cluster_queue nor a capacity_block_id")
        if has_queue and resource_binding["cluster_queue"] not in policy["allowed_queues"]:
            raise Rejected("cluster_queue not allowed for this kind")
        if has_block and resource_binding["capacity_block_id"] not in policy["allowed_capacity_blocks"]:
            raise Rejected("capacity_block_id not allowed for this kind")
        plan = {
            "kind": kind, "profile": requested_profile, "resource_binding": resource_binding,
            "lease_seconds": policy["lease_seconds"], "timebox_minutes": policy["timebox_minutes"],
            "max_cost_usd": policy["max_cost_usd"], "max_retries": policy["max_retries"],
            "work_role": policy["work_role"],
        }
        plan_ref = plan_ref_for(plan)
        try:
            self.t.put_item(
                Item={"task_id": plan_ref, "plan": plan},
                ConditionExpression="attribute_not_exists(task_id)",
            )
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            existing = self.t.get_item(Key={"task_id": plan_ref}).get("Item")
            if existing is None or existing["plan"] != plan:
                raise Rejected("plan_ref collision with different content")
        requires_approval = policy["requires_approval"]
        item = {
            "task_id": task_id, "plan_ref": plan_ref, "version": 0, "attempt_count": 0,
            "state": "awaiting_approval" if requires_approval else "pending",
            "created_at": broker_now(),
        }
        if not requires_approval:
            item["deadline_at"] = broker_now() + policy["timebox_minutes"] * 60  # B3: starts NOW -
                                                                                   # nothing to wait on
        try:
            self.t.put_item(Item=item, ConditionExpression="attribute_not_exists(task_id)")
            return self.get(task_id)
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            existing = self.get(task_id)
            if existing is not None and existing.get("plan_ref") == plan_ref:
                return existing  # true retry of the same request: report success, write nothing
            raise Rejected(f"task_id {task_id} already exists with different content")

    def get(self, task_id):
        return self.t.get_item(Key={"task_id": task_id}).get("Item")

    def _plan(self, plan_ref):
        item = self.t.get_item(Key={"task_id": plan_ref}).get("Item")
        if item is None:
            raise Rejected("plan not found")
        return item["plan"]

    # ----------------------------------------------------------------- claim()
    def claim(self, task_id, client_token):
        item = self.get(task_id)
        if item is None:
            raise Rejected("no such task")
        if item["state"] in ("completed", "abandoned", "awaiting_approval"):
            raise Rejected(f"not claimable: {item['state']}")  # checked BEFORE ownership (closes P1)

        if broker_now() > item.get("deadline_at", 0):
            self._abandon_internal(task_id, "deadline exceeded", expected_version=None)
            raise Rejected("deadline exceeded")

        plan = self._plan(item["plan_ref"])
        recomputed = plan_ref_for(plan)
        if recomputed != item["plan_ref"]:
            raise Rejected("plan content does not match plan_ref")  # N4: recomputed, not trusted
        policy = KIND_POLICY.get(plan["kind"])
        if policy is None:
            raise Rejected("kind removed from policy")  # S3: fail closed

        token_hash = hash_token(client_token)
        owned = item["state"] == "claimed" and item.get("lease_holder_hash") == token_hash

        if not owned and item["state"] in ("claimed", "parked"):
            v0 = item["version"]
            if item.get("wait_started_version") != v0:
                try:
                    self.t.update_item(
                        Key={"task_id": task_id},
                        UpdateExpression="SET wait_started_at=:now, wait_started_version=:v0",
                        ConditionExpression=(
                            "version = :v0 AND "
                            "(attribute_not_exists(wait_started_version) OR wait_started_version <> :v0)"
                        ),
                        ExpressionAttributeValues={":now": broker_now(), ":v0": v0},
                    )
                except ClientError as e:
                    if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                        raise
                    # someone else started the clock for this exact version a moment ago;
                    # fall through and re-read rather than treat this as a hard failure
                raise Wait(policy["lease_seconds"])
            elapsed = broker_now() - item["wait_started_at"]
            if elapsed < policy["lease_seconds"]:
                raise Wait(policy["lease_seconds"] - elapsed)
            item = self.get(task_id)  # version may have moved; recompute owned/charge fresh
            owned = item["state"] == "claimed" and item.get("lease_holder_hash") == token_hash

        charge = (not owned) and item["state"] in ("claimed", "failed")

        if policy["requires_approval"]:
            hg = item.get("human_go")
            if hg is None or hg.get("plan_hash") != item["plan_ref"] or broker_now() > hg.get("expires_at", 0):
                self.t.update_item(
                    Key={"task_id": task_id},
                    UpdateExpression="SET #s = :aa, version = version + :one",
                    ConditionExpression="version = :v0",
                    ExpressionAttributeNames={"#s": "state"},
                    ExpressionAttributeValues={":aa": "awaiting_approval", ":one": 1, ":v0": item["version"]},
                )
                raise Rejected("awaiting human Go")

        if charge and item["attempt_count"] >= plan["max_retries"]:
            self._abandon_internal(task_id, "retries exhausted", expected_version=item["version"])
            raise Rejected("retries exhausted")

        if owned:
            return ("already_owned", item)

        self.t.update_item(
            Key={"task_id": task_id},
            UpdateExpression=(
                "SET lease_holder_hash = :h, #s = :claimed, "
                "claimed_at = if_not_exists(claimed_at, :now), "
                "attempt_count = attempt_count + :charge, version = version + :one"
            ),
            ConditionExpression="version = :v0",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={
                ":h": token_hash, ":claimed": "claimed", ":now": broker_now(),
                ":charge": 1 if charge else 0, ":one": 1, ":v0": item["version"],
            },
        )
        return ("claimed", self.get(task_id))

    def claim_wait_loop(self, task_id, client_token, poll_interval=0.3, max_wait=30):
        """Test-harness convenience: repeatedly call claim() until it stops
        returning Wait, sleeping `poll_interval` between calls - standing in for
        a supervisor's own retry loop against the broker's two-call protocol.
        The ELAPSED-TIME DECISION itself still happens inside claim(), against
        the broker's own clock (wait_started_at) - this loop only decides how
        often to ask again, never how long the wait actually was."""
        deadline = time.monotonic() + max_wait
        while True:
            try:
                return self.claim(task_id, client_token)
            except Wait:
                if time.monotonic() > deadline:
                    raise
                time.sleep(poll_interval)

    # -------------------------------------------------------------- heartbeat()
    def heartbeat(self, task_id, client_token):
        item = self.get(task_id)
        if item is None or item.get("lease_holder_hash") != hash_token(client_token) or item["state"] != "claimed":
            return False
        if broker_now() > item.get("deadline_at", 0):
            return False  # self-fencing signal; claim() handles the state transition
        try:
            self.t.update_item(
                Key={"task_id": task_id},
                UpdateExpression="SET heartbeat_at = :now, version = version + :one",
                ConditionExpression="lease_holder_hash = :h AND #s = :claimed",
                ExpressionAttributeNames={"#s": "state"},
                ExpressionAttributeValues={":now": broker_now(), ":one": 1,
                                            ":h": hash_token(client_token), ":claimed": "claimed"},
            )
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    # ------------------------------------------------------------------ park()
    def park(self, task_id, client_token, evidence_entry=None):
        item = self.get(task_id)
        if item is None or item.get("lease_holder_hash") != hash_token(client_token) or item["state"] != "claimed":
            raise Rejected("not the current holder of a claimed task")
        if broker_now() > item.get("deadline_at", 0):
            raise Rejected("deadline exceeded")  # P4: parking never extends past the deadline
        expr = "SET #s = :parked, version = version + :one"
        vals = {":parked": "parked", ":one": 1, ":h": hash_token(client_token), ":claimed": "claimed"}
        if evidence_entry is not None:
            expr += ", evidence = list_append(if_not_exists(evidence, :empty), :ev)"
            vals[":empty"] = []
            vals[":ev"] = [evidence_entry]
        self.t.update_item(
            Key={"task_id": task_id}, UpdateExpression=expr,
            ConditionExpression="lease_holder_hash = :h AND #s = :claimed",
            ExpressionAttributeNames={"#s": "state"}, ExpressionAttributeValues=vals,
        )

    def resume(self, task_id, client_token):
        return self.claim(task_id, client_token)  # same CAS, same wait (N10: intentional)

    # --------------------------------------------------------------- release()
    def release(self, task_id, client_token, evidence_entry=None):
        item = self.get(task_id)
        if item is None or item.get("lease_holder_hash") != hash_token(client_token) or item["state"] != "claimed":
            return False
        expr = "SET #s = :pending, version = version + :one REMOVE lease_holder_hash"
        vals = {":pending": "pending", ":one": 1, ":h": hash_token(client_token), ":claimed": "claimed"}
        if evidence_entry is not None:
            expr = ("SET #s = :pending, version = version + :one, "
                    "evidence = list_append(if_not_exists(evidence, :empty), :ev) REMOVE lease_holder_hash")
            vals[":empty"] = []
            vals[":ev"] = [evidence_entry]
        try:
            self.t.update_item(
                Key={"task_id": task_id}, UpdateExpression=expr,
                ConditionExpression="lease_holder_hash = :h AND #s = :claimed",
                ExpressionAttributeNames={"#s": "state"}, ExpressionAttributeValues=vals,
            )
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    # ------------------------------------------------------- complete()/fail()
    def _terminal(self, task_id, client_token, new_state, evidence_entry):
        item = self.get(task_id)
        if item is None or item.get("lease_holder_hash") != hash_token(client_token) or item["state"] != "claimed":
            return False
        expr = "SET #s = :s, version = version + :one REMOVE lease_holder_hash"
        vals = {":s": new_state, ":one": 1, ":h": hash_token(client_token), ":claimed": "claimed"}
        if new_state == "completed":
            vals[":ttl"] = broker_now() + 7 * 86400
            expr = ("SET #s = :s, version = version + :one, ttl = :ttl, "
                    "evidence = list_append(if_not_exists(evidence, :empty), :ev) REMOVE lease_holder_hash")
            vals[":empty"] = []
            vals[":ev"] = [evidence_entry or {}]
        elif evidence_entry is not None:
            expr = ("SET #s = :s, version = version + :one, "
                    "evidence = list_append(if_not_exists(evidence, :empty), :ev) REMOVE lease_holder_hash")
            vals[":empty"] = []
            vals[":ev"] = [evidence_entry]
        try:
            self.t.update_item(
                Key={"task_id": task_id}, UpdateExpression=expr,
                ConditionExpression="lease_holder_hash = :h AND #s = :claimed",
                ExpressionAttributeNames={"#s": "state"}, ExpressionAttributeValues=vals,
            )
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    def complete(self, task_id, client_token, evidence_entry=None):
        return self._terminal(task_id, client_token, "completed", evidence_entry)

    def fail(self, task_id, client_token, evidence_entry=None):
        return self._terminal(task_id, client_token, "failed", evidence_entry)

    # ------------------------------------------------------------ AppendEvidence
    def append_evidence(self, task_id, client_token, evidence_entry):
        item = self.get(task_id)
        if item is None or item.get("lease_holder_hash") != hash_token(client_token):
            return False
        if item["state"] not in ("claimed", "parked"):
            return False
        if item["state"] == "claimed" and broker_now() > item.get("deadline_at", 0):
            return False  # P4: cannot keep an over-deadline lease alive via evidence calls
        try:
            self.t.update_item(
                Key={"task_id": task_id},
                UpdateExpression="SET version = version + :one, evidence = list_append(if_not_exists(evidence, :empty), :ev)",
                ConditionExpression="lease_holder_hash = :h AND (#s = :claimed OR #s = :parked)",
                ExpressionAttributeNames={"#s": "state"},
                ExpressionAttributeValues={
                    ":one": 1, ":empty": [], ":ev": [evidence_entry],
                    ":h": hash_token(client_token), ":claimed": "claimed", ":parked": "parked",
                },
            )
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    # ------------------------------------------------------------ abandon() etc
    def _abandon_internal(self, task_id, reason, expected_version):
        cond = "#s <> :completed AND #s <> :abandoned"
        vals = {":s": "abandoned", ":one": 1, ":ttl": broker_now() + 7 * 86400, ":reason": reason,
                ":completed": "completed", ":abandoned": "abandoned"}
        if expected_version is not None:
            cond += " AND version = :v0"
            vals[":v0"] = expected_version
        try:
            self.t.update_item(
                Key={"task_id": task_id},
                UpdateExpression="SET #s = :s, version = version + :one, ttl = :ttl, abandon_reason = :reason REMOVE lease_holder_hash",
                ConditionExpression=cond,
                ExpressionAttributeNames={"#s": "state"}, ExpressionAttributeValues=vals,
            )
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise  # a version-guarded abandon that lost the race is a no-op, not an error

    def abandon(self, task_id, reason):
        """EXTERNAL shape - maintainer only, through the MFA-gated endpoint."""
        self._abandon_internal(task_id, reason, expected_version=None)

    def force_release(self, task_id, reason):
        """MAINTAINER-ONLY break-glass: clears the lease hash but does NOT change
        state and does NOT skip the wait - the next claim() still runs the full
        two-call protocol (no instant 'pending' shortcut)."""
        try:
            self.t.update_item(
                Key={"task_id": task_id},
                UpdateExpression="SET version = version + :one, force_released_reason = :r REMOVE lease_holder_hash",
                ConditionExpression="#s = :claimed OR #s = :parked",
                ExpressionAttributeNames={"#s": "state"},
                ExpressionAttributeValues={":one": 1, ":r": reason, ":claimed": "claimed", ":parked": "parked"},
            )
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    # ------------------------------------------------------------------- sweep()
    def sweep(self):
        """Never calls claim(), never writes lease_holder_hash. The only state
        change it ever makes is abandon() for an objectively over-budget task -
        it never takes ownership of anything (closes B2: the round-4 bug where
        the reaper's own claim() made it the new holder of everything it scanned)."""
        notifications = []
        resp = self.t.scan()
        for item in resp.get("Items", []):
            tid = item["task_id"]
            if str(tid).startswith("plan:"):
                continue
            state = item["state"]
            if state in ("completed", "abandoned"):
                continue
            if state == "awaiting_approval":
                if "deadline_at" in item and broker_now() > item["deadline_at"]:
                    self._abandon_internal(tid, "deadline exceeded", expected_version=item["version"])
                else:
                    notifications.append((tid, "awaiting a Go"))
                continue
            if broker_now() > item.get("deadline_at", 0):
                self._abandon_internal(tid, "deadline exceeded", expected_version=None)
                continue
            if state in ("claimed", "parked"):
                plan = self._plan(item["plan_ref"])
                policy = KIND_POLICY[plan["kind"]]
                v0 = item["version"]
                if item.get("wait_started_version") != v0:
                    try:
                        self.t.update_item(
                            Key={"task_id": tid},
                            UpdateExpression="SET wait_started_at=:now, wait_started_version=:v0",
                            ConditionExpression=(
                                "version = :v0 AND "
                                "(attribute_not_exists(wait_started_version) OR wait_started_version <> :v0)"
                            ),
                            ExpressionAttributeValues={":now": broker_now(), ":v0": v0},
                        )
                    except ClientError as e:
                        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                            raise
                    continue
                if broker_now() - item["wait_started_at"] < policy["lease_seconds"]:
                    continue
                if state == "claimed" and item["attempt_count"] >= policy["max_retries"]:
                    self._abandon_internal(tid, "retries exhausted", expected_version=item["version"])
                else:
                    notifications.append((tid, "reclaimable"))
            elif state == "failed":
                notifications.append((tid, "reclaimable (failed, never retried)"))
        return notifications

    # ------------------------------------------------------------------ grant_go
    def grant_go(self, task_id, plan_hash, expires_in_seconds, granted_by):
        """Reachable ONLY through the MFA-gated endpoint in production (Decision
        6 item 4) - this prototype does not exercise real hardware MFA (named in
        verification.md as a residual, unverified item), but DOES exercise the
        plan-hash binding and expiry this function itself is responsible for."""
        item = self.get(task_id)
        plan = self._plan(item["plan_ref"]) if item else None
        if item is None or plan is None:
            raise Rejected("no such task")
        self.t.update_item(
            Key={"task_id": task_id},
            UpdateExpression=(
                "SET human_go = :hg, #s = :pending, version = version + :one, "
                "deadline_at = if_not_exists(deadline_at, :deadline)"
            ),
            ConditionExpression="plan_ref = :ph AND #s = :aa",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={
                ":hg": {"granted_by": granted_by, "granted_at": broker_now(), "plan_hash": plan_hash,
                        "expires_at": broker_now() + expires_in_seconds},
                ":pending": "pending", ":one": 1, ":ph": plan_hash, ":aa": "awaiting_approval",
                ":deadline": broker_now() + plan["timebox_minutes"] * 60,
            },
        )

    # -------------------------------------------------------- work credentials
    def vend_work_credentials(self, task_id, client_token, duration=900):
        """claim()'s own ALREADY_OWNED/claimed success path, in production,
        mints work credentials here by AssumeRole-ing the plan's own
        KIND_POLICY work_role with an explicit Deny-narrowed session policy
        (Decision 5: server-side narrowing, never a second client-side chain)."""
        item = self.get(task_id)
        if item is None or item.get("lease_holder_hash") != hash_token(client_token) or item["state"] != "claimed":
            raise Rejected("not the current holder")
        plan = self._plan(item["plan_ref"])
        sts = self._sts()  # the BROKER's own credentials - never a fresh,
                             # ambient-credentialed client (the bug this
                             # prototype's own first run on the EC2 runner caught)
        account = sts.get_caller_identity()["Account"]
        work_role_arn = f"arn:aws:iam::{account}:role/{plan['work_role']}"
        session_policy = {
            # AWS's own documented rule for AssumeRole's `Policy` parameter: the
            # EFFECTIVE permissions are the INTERSECTION of the role's identity
            # policy and this session policy - a session policy with only a
            # Deny statement and no Allow intersects to NOTHING at all, for
            # every action, not just the one it names (caught by this
            # prototype's own first run: "no session policy allows the
            # ssm:GetParameter action" even for the ALLOWED parameter). The
            # correct shape, and what this RFC's "explicit Deny statements
            # layered server-side" (Decision 5) actually requires, is an
            # Allow-everything-the-role-already-grants baseline PLUS the
            # narrowing Deny on top - the role's own, already-narrow identity
            # policy remains the real ceiling (Decision 5's own "never greater
            # than the identity-based policy").
            "Version": "2012-10-17",
            "Statement": [
                {"Effect": "Allow", "Action": "*", "Resource": "*"},
                {"Effect": "Deny", "Action": "ssm:GetParameter",
                 "Resource": f"arn:aws:ssm:{REGION}:{account}:parameter{SSM_FORBIDDEN}"},
            ],
        }
        creds = sts.assume_role(
            RoleArn=work_role_arn, RoleSessionName=f"work-{task_id[:40]}",
            DurationSeconds=duration, Policy=json.dumps(session_policy),
        )["Credentials"]
        return boto3.Session(
            aws_access_key_id=creds["AccessKeyId"], aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"], region_name=REGION,
        )


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("setup")
    sub.add_parser("teardown")
    args = ap.parse_args()
    {"setup": cmd_setup, "teardown": cmd_teardown}[args.cmd](args)


if __name__ == "__main__":
    main()
