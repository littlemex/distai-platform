#!/usr/bin/env python3
"""handoff_core.py - minimal prototype of the Ledger described in
distai-platform-ops/handoff/design.md: a DynamoDB-conditional-write task
coordination core (claim / heartbeat / release / reap), plus small CLI scenarios
that exercise use cases 2 (crash+takeover), 3 (race), 4 (approval gate) and 5
(scoped credentials) against REAL AWS resources (no mocks). Everything this
script creates is named with a fixed, grep-able prefix and is deleted by the
`teardown` subcommand.

Run only on the distai-platform EC2 runner, never on a developer Mac (project rule).

Usage:
  handoff_core.py setup                     # create the tiny demo table + IAM role
  handoff_core.py scenario race             # use case 3
  handoff_core.py scenario crash-takeover   # use case 2
  handoff_core.py scenario approval-gate    # use case 4
  handoff_core.py scenario scoped-creds     # use case 5
  handoff_core.py teardown                  # delete everything this script created
"""
import argparse
import json
import sys
import time
import uuid
import threading

import boto3
from botocore.exceptions import ClientError

PREFIX = "distai-handoff-demo"
TABLE = f"{PREFIX}-tasks"
ROLE = f"{PREFIX}-ai-task-role"
BROKER_ROLE = f"{PREFIX}-broker-role"
REGION = "us-east-1"


def ddb():
    return boto3.resource("dynamodb", region_name=REGION)


def ddb_client():
    return boto3.client("dynamodb", region_name=REGION)


def iam():
    return boto3.client("iam", region_name=REGION)


def sts():
    return boto3.client("sts", region_name=REGION)


def now():
    return int(time.time())


def _retry_not_found(fn, *args, **kwargs):
    """DynamoDB can return ResourceNotFoundException for a brief window right after
    create_table's own table_exists waiter returns, on a freshly created table
    (observed on this account 2026-11-19, not documented behavior - the waiter
    guarantees table STATUS, not that every API endpoint has propagated it yet).
    Retried here with a short backoff rather than silently masked."""
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
    c = ddb_client()
    try:
        c.create_table(
            TableName=TABLE,
            AttributeDefinitions=[{"AttributeName": "task_id", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "task_id", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        c.get_waiter("table_exists").wait(TableName=TABLE)
        c.update_time_to_live(
            TableName=TABLE,
            TimeToLiveSpecification={"Enabled": True, "AttributeName": "ttl"},
        )
        print(f"[setup] created table {TABLE}")
    except ClientError as e:
        if e.response["Error"]["Code"] == "ResourceInUseException":
            print(f"[setup] table {TABLE} already exists")
        else:
            raise

    caller = sts().get_caller_identity()
    runner_arn = caller["Arn"]
    account = caller["Account"]
    table_arn = f"arn:aws:dynamodb:{REGION}:{account}:table/{TABLE}"
    broker_arn = f"arn:aws:iam::{account}:role/{BROKER_ROLE}"

    # design.md Decision 5 (round 2, F6's fix): the AI-facing task role trusts ONLY
    # the broker's own identity, never the AI's own base/ambient principal directly.
    # This test stands the runner's own role in for "the AI's base credentials" and
    # separately for "the broker's execution identity" (a Lambda role in production)
    # - the point under test is the TASK role's trust policy, not who the broker is.
    task_trust = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"AWS": broker_arn},
            "Action": "sts:AssumeRole",
        }],
    }
    broker_trust = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"AWS": runner_arn},
            "Action": "sts:AssumeRole",
        }],
    }
    try:
        iam().create_role(RoleName=BROKER_ROLE, AssumeRolePolicyDocument=json.dumps(broker_trust))
    except ClientError as e:
        if e.response["Error"]["Code"] == "EntityAlreadyExists":
            iam().update_assume_role_policy(RoleName=BROKER_ROLE, PolicyDocument=json.dumps(broker_trust))
        else:
            raise
    iam().put_role_policy(
        RoleName=BROKER_ROLE, PolicyName=f"{PREFIX}-broker-perms",
        PolicyDocument=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{"Effect": "Allow", "Action": "sts:AssumeRole",
                            "Resource": f"arn:aws:iam::{account}:role/{ROLE}"}],
        }),
    )
    print(f"[setup] created/updated broker role {BROKER_ROLE} (trusts: runner, for this test)")

    trust = task_trust
    perms = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AllowTaskRW",
                "Effect": "Allow",
                "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"],
                "Resource": table_arn,
            },
            {
                # The IAM control this RFC's Decision 5/6 relies on: deny any write
                # that touches the human_go attribute, regardless of what else the
                # request also writes. ForAnyValue matches if ANY attribute named in
                # the request equals "human_go" - the correct operator for a blocklist
                # (ForAllValues would only fire if EVERY attribute in the request were
                # "human_go", which a mixed UpdateExpression never is).
                "Sid": "DenyHumanGoWrite",
                "Effect": "Deny",
                "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem"],
                "Resource": table_arn,
                "Condition": {
                    "ForAnyValue:StringEquals": {"dynamodb:Attributes": ["human_go"]},
                },
            },
            {
                "Sid": "AllowDemoSecretRead",
                "Effect": "Allow",
                "Action": "ssm:GetParameter",
                "Resource": f"arn:aws:ssm:{REGION}:{account}:parameter/{PREFIX}/*",
            },
        ],
    }
    # IAM can take well over 10s before a freshly created role's ARN can be resolved
    # as a Principal in ANOTHER role's trust policy (observed on this account
    # 2026-11-19: MalformedPolicyDocumentException "Invalid principal in policy" on
    # the first several attempts). Retried with backoff rather than a fixed sleep.
    last_err = None
    for attempt in range(10):
        try:
            iam().create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(trust))
            print(f"[setup] created role {ROLE}")
            last_err = None
            break
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code == "EntityAlreadyExists":
                iam().update_assume_role_policy(RoleName=ROLE, PolicyDocument=json.dumps(trust))
                print(f"[setup] role {ROLE} already exists, trust policy refreshed")
                last_err = None
                break
            if code == "MalformedPolicyDocument":
                last_err = e
                time.sleep(5)
                continue
            raise
    if last_err is not None:
        raise last_err
    iam().put_role_policy(RoleName=ROLE, PolicyName=f"{PREFIX}-perms", PolicyDocument=json.dumps(perms))
    print("[setup] attached inline policy; IAM propagation can take ~10s")
    time.sleep(12)


def cmd_teardown(_args):
    try:
        iam().delete_role_policy(RoleName=ROLE, PolicyName=f"{PREFIX}-perms")
    except ClientError:
        pass
    try:
        iam().delete_role(RoleName=ROLE)
        print(f"[teardown] deleted role {ROLE}")
    except ClientError as e:
        print(f"[teardown] role delete: {e}")
    try:
        iam().delete_role_policy(RoleName=BROKER_ROLE, PolicyName=f"{PREFIX}-broker-perms")
    except ClientError:
        pass
    try:
        iam().delete_role(RoleName=BROKER_ROLE)
        print(f"[teardown] deleted role {BROKER_ROLE}")
    except ClientError as e:
        print(f"[teardown] role delete: {e}")
    try:
        ddb_client().delete_table(TableName=TABLE)
        ddb_client().get_waiter("table_not_exists").wait(TableName=TABLE)
        print(f"[teardown] deleted table {TABLE}")
    except ClientError as e:
        print(f"[teardown] table delete: {e}")


# ------------------------------------------------------------------- Ledger primitives
#
# Round 2 of design.md (after Fable 5.2's adversarial review, review-r1.md) fixed two
# bugs this prototype's round 1 either had or narrowly avoided:
#   F1: round 1's DESIGN DOC pseudocode gated claim() on state IN ('pending'), which
#       makes an expired-but-still-'claimed' task permanently unreclaimable. This
#       prototype never had that specific line, but round 2 makes the real fix
#       explicit here too: a reclaim is gated on VERSION, never on 'state' alone.
#   F2: round 1's DESIGN DOC and this prototype BOTH stored an absolute lease_expiry
#       compared against the CALLER's own clock - a real cross-machine clock-skew
#       hazard. Fixed below: no absolute timestamp is ever compared across machines.
#       A takeover is only ever "I observed no version change across a LOCAL sleep of
#       lease_seconds" - exactly the amazon-dynamodb-lock-client algorithm design.md
#       itself cites.

def create_task(task_id, max_retries=3, **extra):
    """attribute_not_exists(task_id) prevents an AI (or anyone) from overwriting a
    live record by reusing a deterministic id (F4)."""
    item = {
        "task_id": task_id,
        "state": "pending",
        "version": 0,
        "attempt_count": 0,
        "max_retries": max_retries,
        "created_at": now(),
    }
    item.update(extra)
    _retry_not_found(
        ddb().Table(TABLE).put_item,
        Item=item,
        ConditionExpression="attribute_not_exists(task_id)",
    )


def claim(task_id, lease_seconds=5, wait_for_stale=True):
    """Version-CAS claim/reclaim, never comparing a stored clock value against the
    caller's own. Returns a fresh, random lease_token (string) on success, or None.

    Protocol: read version v0. If the task looks live ('claimed'/'parked') and
    wait_for_stale is allowed, sleep lease_seconds locally, re-read; only proceed if
    the version STILL equals v0 (nobody renewed meanwhile). Then attempt the
    conditional write keyed on that same v0 - exactly one caller's write can win.
    """
    t = ddb().Table(TABLE)
    item = t.get_item(Key={"task_id": task_id}).get("Item")
    if item is None or item["state"] in ("completed", "abandoned"):
        return None  # terminal states are never claimable, by design (Decision 3)
    v0 = item["version"]
    if item["state"] in ("claimed", "parked"):
        # A task that already LOOKS live is never claimed on the spot, with or
        # without wait_for_stale - that flag only controls whether THIS call is
        # willing to spend the wait proving it is actually stale; it must never
        # become a way to skip the wait and steal a live lease immediately. (Bug
        # found by this prototype's own race scenario on 2026-11-19: passing
        # wait_for_stale=False fell through to an unguarded write here, letting a
        # "late" claimant that observed a freshly-claimed task take over with no
        # wait at all - two winners instead of one. Fixed by refusing outright
        # instead of writing when the wait is skipped.)
        if not wait_for_stale:
            return None
        time.sleep(lease_seconds + 1)  # LOCAL elapsed time only - no remote clock read
        item2 = t.get_item(Key={"task_id": task_id}).get("Item")
        if item2 is None or item2["version"] != v0:
            return None  # someone renewed or completed it meanwhile; abort, no takeover
    lease_token = f"lease:{uuid.uuid4().hex[:16]}"
    # Approval gate (design.md Decision 6): requires_approval is set only by
    # create_task (the broker's own narrow "create" action in the real design, never
    # raw AI PutItem), so an AI cannot opt itself out by choosing what it writes. The
    # grant is bound to the CURRENT plan hash (current_plan_hash), closing the
    # tautology round 1 found when both sides of the comparison lived on the same
    # AI-writable item with no independent check.
    approval_cond = (
        "(attribute_not_exists(requires_approval) OR requires_approval = :false "
        "OR (attribute_exists(human_go) AND human_go.plan_hash = current_plan_hash))"
    )
    try:
        t.update_item(
            Key={"task_id": task_id},
            UpdateExpression=(
                "SET lease_holder=:tok, #s=:claimed, version=:v1, "
                "attempt_count=attempt_count+:one, heartbeat_at=:now"
            ),
            ConditionExpression=f"version = :v0 AND attempt_count < max_retries AND {approval_cond}",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={
                ":false": False,
                ":tok": lease_token, ":claimed": "claimed",
                ":v0": v0, ":v1": v0 + 1, ":one": 1, ":now": now(),
            },
            ReturnValuesOnConditionCheckFailure="ALL_OLD",
        )
        return lease_token
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return None  # lost the race, or retries exhausted
        raise


def heartbeat(task_id, lease_token):
    """Bumps version to prove liveness; never writes or compares any wall-clock value."""
    t = ddb().Table(TABLE)
    try:
        t.update_item(
            Key={"task_id": task_id},
            UpdateExpression="SET version = version + :one, heartbeat_at=:now",
            ConditionExpression="lease_holder = :tok AND #s = :claimed",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={":one": 1, ":now": now(), ":tok": lease_token, ":claimed": "claimed"},
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def release(task_id, lease_token, evidence_entry=None):
    t = ddb().Table(TABLE)
    update_expr = "SET version = version + :one, #s = :s"
    vals = {":one": 1, ":s": "pending", ":tok": lease_token}
    if evidence_entry is not None:
        update_expr += ", evidence = list_append(if_not_exists(evidence, :empty), :ev)"
        vals[":empty"] = []
        vals[":ev"] = [evidence_entry]
    update_expr += " REMOVE lease_holder"
    try:
        t.update_item(
            Key={"task_id": task_id},
            UpdateExpression=update_expr,
            ConditionExpression="lease_holder = :tok",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues=vals,
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def get(task_id):
    return ddb().Table(TABLE).get_item(Key={"task_id": task_id}).get("Item")


def grant_human_go(task_id, granted_by, plan_hash):
    """Only ever called with the MAINTAINER-equivalent (unscoped) credentials in
    this prototype - the AI-scoped role's IAM policy denies this write outright
    (DenyHumanGoWrite, set up in cmd_setup), demonstrated in scenario approval-gate.

    Round 2 fix (F8 item 3, the review/grant race): the grant is itself conditional
    on the CURRENT plan reference still matching the hash the maintainer reviewed -
    if the plan changed between review and grant, this write fails loudly instead of
    silently approving the wrong content."""
    ddb().Table(TABLE).update_item(
        Key={"task_id": task_id},
        UpdateExpression="SET human_go=:hg",
        ConditionExpression="current_plan_hash = :expected",
        ExpressionAttributeValues={
            ":hg": {"granted_by": granted_by, "granted_at": now(), "plan_hash": plan_hash},
            ":expected": plan_hash,
        },
    )


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("setup")
    sub.add_parser("teardown")
    args = ap.parse_args()
    if args.cmd == "setup":
        cmd_setup(args)
    elif args.cmd == "teardown":
        cmd_teardown(args)


if __name__ == "__main__":
    main()
