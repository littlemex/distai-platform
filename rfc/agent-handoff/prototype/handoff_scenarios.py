#!/usr/bin/env python3
"""handoff_scenarios.py - real-AWS scenario tests for the Ledger prototype
(handoff_core.py), round 2 (after Fable 5.2's adversarial review, review-r1.md),
covering design.md use cases 2 (crash+takeover, version-CAS, no cross-machine clock
compare), 3 (race, with ReturnValuesOnConditionCheckFailure disambiguation), 4/12
(approval gate bound to an independently-tracked plan hash, review/grant race),
5/13/14 (broker trust boundary: the AI base role cannot reach the task role
directly; human_go is unwritable by the task role regardless of session policy).
No mocks: every assertion is the observed result of a real boto3 call against real
DynamoDB/STS/IAM in this account. Run via
`python3 handoff_scenarios.py <race|crash-takeover|approval-gate|broker-boundary|all>`
after `handoff_core.py setup`, on the EC2 runner only.
"""
import json
import sys
import threading
import time
import uuid

import boto3
from botocore.exceptions import ClientError

import handoff_core as hc

REGION = hc.REGION
PASS, FAIL = "PASS", "FAIL"
results = []


def check(name, condition, detail=""):
    status = PASS if condition else FAIL
    results.append((name, status, detail))
    print(f"[{status}] {name} {('- ' + detail) if detail else ''}")


def new_task_id(prefix):
    return f"{hc.PREFIX}-{prefix}-{uuid.uuid4().hex[:8]}"


# --------------------------------------------------------------------- use case 3

def scenario_race():
    task_id = new_task_id("race")
    hc.create_task(task_id)
    outcomes = {}

    def attempt(name):
        outcomes[name] = hc.claim(task_id, lease_seconds=30, wait_for_stale=False)

    threads = [threading.Thread(target=attempt, args=(f"claimant-{i}",)) for i in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    winners = {name: tok for name, tok in outcomes.items() if tok is not None}
    item = hc.get(task_id)
    check("race: exactly one of 8 concurrent claimants wins", len(winners) == 1, f"winners={list(winners)}")
    check(
        "race: the winning claimant's own lease_token matches the item's lease_holder "
        "(a random per-claim token, not a self-asserted name - F4's fix)",
        len(winners) == 1 and item.get("lease_holder") == list(winners.values())[0],
        f"item.lease_holder={item.get('lease_holder')}",
    )
    check("race: attempt_count advanced by exactly 1, not once per attempt", item.get("attempt_count") == 1)


# --------------------------------------------------------------------- use case 2

def scenario_crash_takeover():
    task_id = new_task_id("crash")
    hc.create_task(task_id)
    tok_a = hc.claim(task_id, lease_seconds=3, wait_for_stale=False)
    check("crash-takeover: session A's initial claim succeeds", tok_a is not None)

    # session A "crashes": no heartbeat, no release call at all from here on.
    tok_b_too_early = hc.claim(task_id, lease_seconds=3, wait_for_stale=False)
    check(
        "crash-takeover: session B's claim attempt BEFORE any wait is rejected "
        "(version unchanged, no attempt to wait yet)",
        tok_b_too_early is None,
    )

    # session B now runs the FULL protocol: observe version, wait lease_seconds
    # LOCALLY (its own clock only, no comparison to any stored timestamp or to A's
    # clock), re-check, then attempt the conditional write.
    t0 = time.monotonic()
    tok_b = hc.claim(task_id, lease_seconds=3, wait_for_stale=True)
    elapsed = time.monotonic() - t0
    check(
        "crash-takeover: session B reclaims only AFTER a full local wait, with no "
        "release ever called by A, and no absolute clock value read from the item",
        tok_b is not None and elapsed >= 3,
        f"elapsed={elapsed:.1f}s tok_b={tok_b}",
    )
    item = hc.get(task_id)
    check(
        "crash-takeover: the Ledger now shows session B's token as the sole holder",
        item.get("lease_holder") == tok_b,
    )
    check(
        "crash-takeover: attempt_count is now 2 (the crash-and-reclaim counts as an "
        "attempt, closing the infinite-retry gap - F10's fix)",
        item.get("attempt_count") == 2,
    )
    hb_a_after_takeover = hc.heartbeat(task_id, tok_a)
    check(
        "crash-takeover: session A's own heartbeat (its OLD token) is rejected once B "
        "has taken over, so a late-reviving A cannot keep working after losing the lease",
        hb_a_after_takeover is False,
    )
    hb_b = hc.heartbeat(task_id, tok_b)
    check("crash-takeover: session B's own heartbeat (current token) succeeds", hb_b is True)


# ------------------------------------------------------------------- use case 4/12

def scenario_approval_gate():
    task_id = new_task_id("approve")
    hc.create_task(task_id, requires_approval=True, current_plan_hash="h1")

    tok_none = hc.claim(task_id, lease_seconds=30, wait_for_stale=False)
    check("approval-gate: claim BEFORE any human_go is rejected", tok_none is None)

    # review/grant race (F8 item 4): a grant bound to a STALE hash must fail even if
    # the live plan has since moved on.
    try:
        hc.grant_human_go(task_id, "littlemex", plan_hash="WRONG-STALE-HASH")
        stale_grant_blocked = False
    except ClientError as e:
        stale_grant_blocked = e.response["Error"]["Code"] == "ConditionalCheckFailedException"
    check(
        "approval-gate (F8 item 4, review/grant race): a grant bound to a hash that "
        "does not match the CURRENT plan is rejected, not silently approved",
        stale_grant_blocked,
    )

    hc.grant_human_go(task_id, "littlemex", plan_hash="h1")
    tok_ok = hc.claim(task_id, lease_seconds=30, wait_for_stale=False)
    check("approval-gate: claim AFTER a matching human_go (plan_hash=h1) succeeds", tok_ok is not None)

    hc.release(task_id, tok_ok)
    # the plan changes after approval was granted (use case 12): the live plan hash
    # moves to h2, but human_go.plan_hash is still h1 - a stale, now-invalid Go.
    hc.ddb().Table(hc.TABLE).update_item(
        Key={"task_id": task_id},
        UpdateExpression="SET current_plan_hash = :h",
        ExpressionAttributeValues={":h": "h2"},
    )
    tok_stale = hc.claim(task_id, lease_seconds=30, wait_for_stale=False)
    check(
        "approval-gate (use case 12): claim is rejected once the plan changed after "
        "approval, even though a human_go record still exists",
        tok_stale is None,
    )


# ------------------------------------------------------------- use case 5/13/14

def assume(role_arn, session_name, session=None, session_policy=None, duration=900):
    client = session.client("sts", region_name=REGION) if session is not None else hc.sts()
    kwargs = dict(RoleArn=role_arn, RoleSessionName=session_name, DurationSeconds=duration)
    if session_policy is not None:
        kwargs["Policy"] = json.dumps(session_policy)
    creds = client.assume_role(**kwargs)["Credentials"]
    return boto3.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        region_name=REGION,
    )


def scenario_broker_boundary():
    """design.md Decision 5, round 2 (F6/F7's fix): the AI-facing task role's trust
    policy names ONLY the broker's own identity. An AI's base/ambient credentials
    (here, the runner's own role, standing in for 'AI base') must be DENIED assuming
    the task role directly; only something chaining through the broker role can."""
    account = hc.sts().get_caller_identity()["Account"]
    task_role_arn = f"arn:aws:iam::{account}:role/{hc.ROLE}"
    broker_role_arn = f"arn:aws:iam::{account}:role/{hc.BROKER_ROLE}"
    table_arn = f"arn:aws:dynamodb:{REGION}:{account}:table/{hc.TABLE}"
    task_id = new_task_id("boundary")
    hc.create_task(task_id)

    try:
        hc.sts().assume_role(RoleArn=task_role_arn, RoleSessionName="ai-base-direct-attempt")
        direct_denied = False
    except ClientError as e:
        direct_denied = e.response["Error"]["Code"] == "AccessDenied"
    check(
        "broker-boundary (F6): the AI's own base credentials CANNOT assume the "
        "task role directly - the task role's trust policy names only the broker",
        direct_denied,
    )

    broker_session = assume(broker_role_arn, "broker-execution-identity")
    task_via_broker = assume(
        task_role_arn, "ai-task-via-broker", session=broker_session,
        session_policy={
            "Version": "2012-10-17",
            "Statement": [{"Effect": "Allow", "Action": "dynamodb:GetItem", "Resource": table_arn}],
        },
    )
    check("broker-boundary: the broker's own identity CAN mint narrowed task credentials", task_via_broker is not None)

    try:
        task_via_broker.resource("dynamodb").Table(hc.TABLE).get_item(Key={"task_id": task_id})
        get_ok = True
    except ClientError:
        get_ok = False
    check("broker-boundary: broker-minted credentials CAN GetItem (the allowed action)", get_ok)

    try:
        task_via_broker.resource("dynamodb").Table(hc.TABLE).update_item(
            Key={"task_id": task_id},
            UpdateExpression="SET lease_holder=:w",
            ExpressionAttributeValues={":w": "should-not-work"},
        )
        update_denied = False
    except ClientError as e:
        update_denied = e.response["Error"]["Code"] == "AccessDeniedException"
    check(
        "broker-boundary: the SAME broker-minted credentials CANNOT UpdateItem "
        "(the session policy never granted it)",
        update_denied,
    )

    # The full (un-narrowed) task role, reached only via the broker, is still denied
    # writing human_go by the ROLE's own IAM policy - use case 14's control, holding
    # regardless of session policy, closing F6's confused-deputy path at the one
    # layer a session policy can never undo (an IAM Deny on the role itself).
    task_full = assume(task_role_arn, "ai-task-full-via-broker", session=broker_session)
    try:
        task_full.resource("dynamodb").Table(hc.TABLE).update_item(
            Key={"task_id": task_id},
            UpdateExpression="SET lease_holder=:w",
            ExpressionAttributeValues={":w": "ai-session-full"},
        )
        ordinary_write_ok = True
    except ClientError:
        ordinary_write_ok = False
    check("broker-boundary: the full task role CAN write an ordinary field", ordinary_write_ok)

    try:
        task_full.resource("dynamodb").Table(hc.TABLE).update_item(
            Key={"task_id": task_id},
            UpdateExpression="SET human_go=:hg",
            ExpressionAttributeValues={":hg": {"granted_by": "ai-session", "granted_at": hc.now(), "plan_hash": "forged"}},
        )
        human_go_denied = False
    except ClientError as e:
        human_go_denied = e.response["Error"]["Code"] == "AccessDeniedException"
    check(
        "broker-boundary (use case 14): the task role is DENIED writing human_go by "
        "its own IAM policy, even reached via the broker with no narrowing session policy",
        human_go_denied,
    )

    hc.ddb().Table(hc.TABLE).update_item(
        Key={"task_id": task_id}, UpdateExpression="SET current_plan_hash=:h",
        ExpressionAttributeValues={":h": "h1"},
    )
    hc.grant_human_go(task_id, "littlemex", plan_hash="h1")
    item = hc.get(task_id)
    check(
        "broker-boundary: maintainer-equivalent (this script's own ambient) credentials CAN write human_go",
        item.get("human_go", {}).get("granted_by") == "littlemex",
    )


SCENARIOS = {
    "race": scenario_race,
    "crash-takeover": scenario_crash_takeover,
    "approval-gate": scenario_approval_gate,
    "broker-boundary": scenario_broker_boundary,
}


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    to_run = SCENARIOS.values() if which == "all" else [SCENARIOS[which]]
    for fn in to_run:
        print(f"\n=== {fn.__name__} ===")
        fn()
    print("\n=== summary ===")
    n_fail = sum(1 for _, s, _ in results if s == FAIL)
    for name, status, detail in results:
        print(f"{status}  {name}")
    print(f"\n{len(results)-n_fail}/{len(results)} PASS")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
