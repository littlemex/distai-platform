#!/usr/bin/env python3
"""handoff_scenarios.py (v2) - re-runs design.md's own "Experiments needed" 1-4
against the round-7/APPROVEd shape (broker-only writes, client-generated hashed
token, plan-sourced lease_seconds, two-call wait, sweep() that never claims).
No mocks: every assertion is the observed result of a real boto3 call against
real DynamoDB/STS/IAM/SSM in this account, on the distai-platform EC2 runner.
Usage: python3 handoff_scenarios.py <race|lease-and-takeover|approval-gate|broker-boundary|all>
after `handoff_core.py setup`.
"""
import sys
import threading
import time
import uuid

import boto3
from botocore.exceptions import ClientError

import handoff_core as hc
from handoff_core import Broker, Rejected, Wait

REGION = hc.REGION
PASS, FAIL = "PASS", "FAIL"
results = []


def check(name, condition, detail=""):
    status = PASS if condition else FAIL
    results.append((name, status, detail))
    print(f"[{status}] {name} {('- ' + detail) if detail else ''}")


def new_task_id(prefix):
    return f"{hc.PREFIX}-{prefix}-{uuid.uuid4().hex[:8]}"


def assume(role_name, session_name, duration=900):
    sts = boto3.client("sts", region_name=REGION)
    account = sts.get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account}:role/{role_name}"
    creds = sts.assume_role(RoleArn=role_arn, RoleSessionName=session_name, DurationSeconds=duration)["Credentials"]
    return boto3.Session(
        aws_access_key_id=creds["AccessKeyId"], aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"], region_name=REGION,
    )


def broker():
    """Every call in this file that is supposed to succeed goes through a
    Broker built from the BROKER_ROLE's own assumed session - never the
    runner's ambient (admin) credentials and never AI_BASE_ROLE. The session
    itself is passed through to Broker so vend_work_credentials()'s own
    AssumeRole call also runs as the broker, not as whatever process
    constructed it (the bug this prototype's own first run caught)."""
    session = assume(hc.BROKER_ROLE, "broker-under-test")
    table = session.resource("dynamodb").Table(hc.TABLE)
    return Broker(table, session=session)


LIGHT_BINDING = {"capacity_block_id": "demo-cb-0001", "lane": 1}


# --------------------------------------------------------------------- use case 3
# Experiment 1: 8 concurrent claim requests race on the same pending task.

def scenario_race():
    b = broker()
    task_id = new_task_id("race")
    b.create(task_id, "demo-light", "demo-light-profile", LIGHT_BINDING)
    outcomes = {}

    def attempt(name):
        token = hc.new_client_token()
        try:
            status, item = b.claim(task_id, token)
            outcomes[name] = (status, token, item["version"])
        except (Rejected, Wait) as e:
            outcomes[name] = (type(e).__name__, None, None)

    threads = [threading.Thread(target=attempt, args=(f"claimant-{i}",)) for i in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    winners = {k: v for k, v in outcomes.items() if v[0] == "claimed"}
    check("race: exactly one of 8 concurrent, distinct-token claimants wins",
          len(winners) == 1, f"outcomes={ {k: v[0] for k, v in outcomes.items()} }")
    item = b.get(task_id)
    check("race: attempt_count did not advance (a fresh claim of a pending task is not a retry)",
          item["attempt_count"] == 0, f"attempt_count={item['attempt_count']}")

    winner_name, (status, winner_token, _) = next(iter(winners.items()))
    retry_status, retry_item = b.claim(task_id, winner_token)
    check("race: the winner's OWN retry with the SAME client_token gets ALREADY_OWNED, "
          "not a fresh race against its own earlier success",
          retry_status == "already_owned", f"retry_status={retry_status}")

    other_token = hc.new_client_token()
    try:
        b.claim(task_id, other_token)
        rejected_or_waits = False
    except Wait:
        rejected_or_waits = True
    except Rejected:
        rejected_or_waits = True
    check("race: a DIFFERENT token attempting to claim the already-claimed task "
          "is told to wait, never handed the lease immediately",
          rejected_or_waits)


# --------------------------------------------------------- use case 2, N1, N7
# Experiment 2: lease_seconds comes from the PLAN (per-kind policy), never a
# caller parameter; a crashed claimant is reclaimed only after that plan value
# has elapsed, measured by the broker's own clock; a graceful release-then-claim
# does not charge attempt_count, but a stale takeover does.

def scenario_lease_and_takeover():
    b = broker()
    task_id = new_task_id("crash")
    b.create(task_id, "demo-light", "demo-light-profile", LIGHT_BINDING)
    policy_lease = hc.KIND_POLICY["demo-light"]["lease_seconds"]

    tok_a = hc.new_client_token()
    status, _ = b.claim(task_id, tok_a)
    check("lease: session A's initial claim succeeds with no wait", status == "claimed")

    # Experiment 2 (N1): claim()'s own signature takes NO lease_seconds argument
    # at all - there is no parameter through which a caller could even attempt
    # to shorten the wait. This is checked by code shape, not just behavior:
    import inspect
    sig = inspect.signature(Broker.claim)
    check("lease: claim()'s own signature has no caller-supplied lease_seconds "
          "parameter - the wait is read from the plan, with no path to shorten it",
          "lease_seconds" not in sig.parameters, f"params={list(sig.parameters)}")

    # session A "crashes": no heartbeat, no release call at all from here on.
    tok_b = hc.new_client_token()
    try:
        b.claim(task_id, tok_b)
        got_wait = False
    except Wait as w:
        got_wait = True
        first_retry_after = w.retry_after
    check("lease: session B's claim immediately after A's claim returns Wait, "
          "not an immediate takeover", got_wait, f"retry_after={first_retry_after if got_wait else None}")

    t0 = time.monotonic()
    status, item = b.claim_wait_loop(task_id, tok_b, poll_interval=0.3, max_wait=20)
    elapsed = time.monotonic() - t0
    check(f"lease: session B reclaims only after the PLAN's own lease_seconds "
          f"({policy_lease}s) has elapsed (broker's own clock), with no release ever "
          f"called by A and no lease_seconds argument passed by B",
          status == "claimed" and elapsed >= policy_lease - 0.35,  # poll_interval=0.3 slack
          f"elapsed={elapsed:.1f}s status={status}")
    check("lease: attempt_count is now 1 (a stale-claimed takeover counts as an attempt)",
          item["attempt_count"] == 1, f"attempt_count={item['attempt_count']}")

    hb_a = b.heartbeat(task_id, tok_a)
    check("lease: session A's OLD token heartbeat is rejected once B has taken over "
          "(a late-reviving A cannot keep working after losing the lease)", hb_a is False)
    hb_b = b.heartbeat(task_id, tok_b)
    check("lease: session B's current token heartbeat succeeds", hb_b is True)

    # Graceful release-then-reclaim must NOT charge attempt_count (design.md N7) -
    # distinguishing a healthy multi-session handoff from a crash loop.
    released = b.release(task_id, tok_b, evidence_entry={"type": "note", "by": "session-b"})
    check("lease: session B's graceful release succeeds", released is True)
    tok_c = hc.new_client_token()
    status, item = b.claim(task_id, tok_c)
    check("lease: session C claims the released (pending) task immediately, no wait",
          status == "claimed")
    check("lease: attempt_count did NOT advance on a graceful release-then-reclaim "
          "(still 1, unchanged from the one real crash-takeover above)",
          item["attempt_count"] == 1, f"attempt_count={item['attempt_count']}")


# ------------------------------------------------------------------- use case 4/12
# Experiment 3: claim() itself rejects awaiting_approval; the plan hash is
# RECOMPUTED at claim time, not trusted from a stored comparison; an expired
# grant is treated as no grant at all.

def scenario_approval_gate():
    b = broker()
    task_id = new_task_id("approve")
    item = b.create(task_id, "demo-approval", "demo-approval-profile", LIGHT_BINDING)
    check("approval-gate: a freshly created approval-required task starts in "
          "awaiting_approval, not pending", item["state"] == "awaiting_approval")

    tok_none = hc.new_client_token()
    try:
        b.claim(task_id, tok_none)
        rejected_before_go = False
    except Rejected:
        rejected_before_go = True
    check("approval-gate: claim() itself rejects an awaiting_approval task before "
          "any human_go exists - the Go condition lives INSIDE claim(), not implied "
          "by a prior write", rejected_before_go)

    current_plan_ref = item["plan_ref"]
    try:
        b.grant_go(task_id, "WRONG-STALE-HASH", expires_in_seconds=3600, granted_by="littlemex")
        stale_grant_blocked = False
    except ClientError as e:
        stale_grant_blocked = e.response["Error"]["Code"] == "ConditionalCheckFailedException"
    check("approval-gate (F8 item 4, review/grant race): a grant bound to a hash "
          "that does not match the CURRENT plan_ref is rejected, not silently approved",
          stale_grant_blocked)

    b.grant_go(task_id, current_plan_ref, expires_in_seconds=3600, granted_by="littlemex")
    tok_ok = hc.new_client_token()
    status, _ = b.claim(task_id, tok_ok)
    check("approval-gate: claim AFTER a matching, unexpired human_go succeeds",
          status == "claimed")

    # N4: the hash is RECOMPUTED from the plan's own stored content at claim
    # time, never trusted from a prior comparison. Prove it by mutating the
    # plan item's own content out-of-band (bypassing create() entirely, using
    # the broker's own write credentials to simulate "something corrupted the
    # stored plan") and showing the NEXT claim rejects it.
    b.release(task_id, tok_ok)
    b.t.update_item(
        Key={"task_id": current_plan_ref},
        UpdateExpression="SET #p.max_cost_usd = :tampered",
        ExpressionAttributeNames={"#p": "plan"},  # "plan" is a DynamoDB reserved keyword
        ExpressionAttributeValues={":tampered": 999999},
    )
    tok_tampered = hc.new_client_token()
    try:
        b.claim(task_id, tok_tampered)
        tamper_detected = False
    except Rejected as e:
        tamper_detected = "does not match" in str(e.reason)
    check("approval-gate (N4): claim() recomputes sha256(plan content) and rejects "
          "when the stored plan no longer matches its own plan_ref, rather than "
          "trusting a prior comparison", tamper_detected)

    # Expired grant treated as no grant at all. A DISTINCT resource_binding (not
    # LIGHT_BINDING) is used deliberately: LIGHT_BINDING's own plan was just
    # tampered with above, out-of-band, to prove N4's recomputation - reusing it
    # here would make this task's plan_ref collide with that now-corrupted plan
    # item, which is a test-harness artifact, not the thing use case 15 covers.
    task_id2 = new_task_id("expired")
    item2 = b.create(task_id2, "demo-approval", "demo-approval-profile",
                      {"capacity_block_id": "demo-cb-0001", "lane": 2})
    b.grant_go(task_id2, item2["plan_ref"], expires_in_seconds=1, granted_by="littlemex")
    time.sleep(2)
    tok_exp = hc.new_client_token()
    try:
        b.claim(task_id2, tok_exp)
        expired_blocks = False
    except Rejected:
        expired_blocks = True
    check("approval-gate: a human_go whose expires_at has passed is treated "
          "exactly like a missing grant", expired_blocks)


# ------------------------------------------------------------- use case 5/13/14
# Experiment 4: no principal other than the broker's own execution role can
# write the Ledger; the AI base role cannot assume a work-credential role
# directly; broker-vended, Deny-narrowed work credentials can do the allowed
# action and cannot do a disallowed one.

def scenario_broker_boundary():
    account = boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]
    work_role_arn = f"arn:aws:iam::{account}:role/{hc.WORK_ROLE_LIGHT}"
    table_arn = f"arn:aws:dynamodb:{REGION}:{account}:table/{hc.TABLE}"

    b = broker()
    task_id = new_task_id("boundary")
    b.create(task_id, "demo-light", "demo-light-profile", LIGHT_BINDING)

    ai_session = assume(hc.AI_BASE_ROLE, "ai-base-direct-attempt")
    try:
        ai_session.client("sts").assume_role(RoleArn=work_role_arn, RoleSessionName="ai-tries-work-role")
        direct_denied = False
    except ClientError as e:
        direct_denied = e.response["Error"]["Code"] == "AccessDenied"
    check("broker-boundary: the AI base role CANNOT assume a per-kind work-credential "
          "role directly - its trust policy names only the broker", direct_denied)

    try:
        ai_session.resource("dynamodb").Table(hc.TABLE).update_item(
            Key={"task_id": task_id}, UpdateExpression="SET version = version + :one",
            ExpressionAttributeValues={":one": 1},
        )
        ai_write_denied = False
    except ClientError as e:
        ai_write_denied = e.response["Error"]["Code"] == "AccessDeniedException"
    check("broker-boundary (Decision 5(c)): the AI base role CANNOT write the Ledger "
          "table at all - no PutItem/UpdateItem path exists outside the broker",
          ai_write_denied)

    try:
        ai_session.resource("dynamodb").Table(hc.TABLE).get_item(Key={"task_id": task_id})
        ai_read_ok = True
    except ClientError:
        ai_read_ok = False
    check("broker-boundary: the AI base role CAN still read the Ledger (GetItem/Query), "
          "for list/show", ai_read_ok)

    tok = hc.new_client_token()
    b.claim(task_id, tok)
    work_session = b.vend_work_credentials(task_id, tok)
    allowed_val = work_session.client("ssm").get_parameter(Name=hc.SSM_ALLOWED)["Parameter"]["Value"]
    check("broker-boundary (use case 5): broker-vended, task-scoped credentials CAN "
          "read the parameter this profile is allowed to read",
          allowed_val == "visible-to-demo-light-profile")

    try:
        work_session.client("ssm").get_parameter(Name=hc.SSM_FORBIDDEN)
        forbidden_denied = False
    except ClientError as e:
        forbidden_denied = e.response["Error"]["Code"] == "AccessDeniedException"
    check("broker-boundary (use case 5/13): the SAME broker-vended credentials CANNOT "
          "read a parameter this profile was not granted - narrowed by an explicit, "
          "server-side Deny session policy, never a second client-side AssumeRole "
          "chain", forbidden_denied)

    try:
        work_session.resource("dynamodb").Table(hc.TABLE).update_item(
            Key={"task_id": task_id}, UpdateExpression="SET version = version + :one",
            ExpressionAttributeValues={":one": 1},
        )
        work_table_write_denied = False
    except ClientError as e:
        work_table_write_denied = e.response["Error"]["Code"] == "AccessDeniedException"
    check("broker-boundary: broker-vended work credentials also cannot write the "
          "Ledger table (the work role's own policy never grants it)",
          work_table_write_denied)


SCENARIOS = {
    "race": scenario_race,
    "lease-and-takeover": scenario_lease_and_takeover,
    "approval-gate": scenario_approval_gate,
    "broker-boundary": scenario_broker_boundary,
}


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    to_run = list(SCENARIOS.items()) if which == "all" else [(which, SCENARIOS[which])]
    for name, fn in to_run:
        print(f"\n=== {name} ===")
        fn()
    print("\n=== summary ===")
    n_fail = sum(1 for _, s, _ in results if s == FAIL)
    for name, status, detail in results:
        print(f"{status}  {name}")
    print(f"\n{len(results)-n_fail}/{len(results)} PASS")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
