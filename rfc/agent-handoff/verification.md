# Verification: Task handoff between AI agent sessions

Design: `design.md` (this directory), approved after 7 rounds of Fable 5.2
adversarial review (`review-r1.md` through `review-r7.md`; `review-r7.md` ends
`VERDICT: APPROVE` - see "Fable 5.2 review rounds" below for the full history).
The prototype described below ran once, during round 2, against that round's
own version of the mechanism; see "Scope not covered" below for exactly what
later rounds changed without a second prototype run. All AWS work
ran on the `distai-platform` EC2 runner (`runner/run.sh`, account `776010787911`,
region `us-east-1`) - never on a Mac, per project rule. Prototype code:
`prototype/handoff_core.py` (Ledger primitives: `create_task`, `claim`, `heartbeat`,
`release`, `grant_human_go`, `setup`, `teardown`) and
`prototype/handoff_scenarios.py` (scenario tests), uploaded to and fetched from
`s3://claudecode-776010787911-46188a9b/scratch/handoff-proto/` (deleted after use)
because the runner's driver (`run.sh`) only clones `littlemex/distai-platform`
itself; the prototype is a separate, standalone artifact tied to this design, not
part of that repository.

## Re-verification against the round-7/APPROVEd shape (2026-11-20)

The round-2 prototype below (`prototype/`) exercised round 2's own version of the
mechanism - a caller-supplied `lease_seconds`, a broker-returned plaintext token,
and an AI-facing role with direct, attribute-Deny-gated `UpdateItem`. Rounds 3-7
changed the mechanism in ways the "Scope not covered" section below names
explicitly as never re-run: a strictly broker-only write model (no AI-facing
Ledger write action of any kind, not even attribute-gated), a client-generated
token the Ledger only ever stores hashed, `lease_seconds` read from the
maintainer-owned `KIND_POLICY` via the immutable plan (never a caller parameter),
and a two-call wait whose elapsed-time decision is the broker's own clock, never a
single in-process `sleep()`. `review-r7.md` itself names re-running design.md's
own "Experiments needed" 1-4 against this final shape as "the first thing the
implementation PR should do ... named explicitly by Fable 5.2 itself as the gate
before first real use." This section is that re-run: a second prototype,
`prototype-v2/` (`handoff_core.py`, `handoff_scenarios.py`), built from the
round-7 pseudocode (Decisions 2, 4, 5, 6 as they read in `design.md` today, not
round 2's superseded version), run on the `distai-platform` EC2 runner
(`runner/run.sh`, account `776010787911`, region `us-east-1`), never on a Mac.
The prototype files are a standalone artifact, uploaded to and fetched from
`s3://claudecode-776010787911-46188a9b/scratch/handoff-proto-v2/` for the same
reason as round 2 (the runner's driver clones `littlemex/distai-platform` itself,
not this RFC's own standalone code) - both the S3 scratch objects and every AWS
resource created during the run were deleted afterward, confirmed by direct,
separate `describe-table`/`get-role`/`get-policy`/`get-parameter` calls from
outside the run, not by trusting the teardown script's own exit code.

### What this round covers

Design.md's own "Experiments needed" 1-4 (cpu-only; no live EKS cell or real
Capacity Block needed). Experiment 5 (the Kueue-bound and bare-EC2 halves of use
case 1) is explicitly out of scope for this round, exactly as design.md's own
text already says: it needs a live cell and/or a real Capacity Block and is
deferred to the first real consumer PR, not required for this RFC's own
acceptance.

| # | Scenario (`handoff_scenarios.py`) | Use cases / findings it covers | Result |
| --- | --- | --- | --- |
| 1 | `race` - 8 concurrent claimants, each its own CSPRNG client token, on one `pending` task; the winner's own retry with the same token | 3, F4 | 4/4 PASS |
| 2 | `lease-and-takeover` - `claim()`'s own signature has no `lease_seconds` parameter at all (checked by introspection, not only behavior); a crashed holder is reclaimed only after the plan's own `lease_seconds` has elapsed by the broker's own clock; graceful release-then-reclaim does not charge `attempt_count`, a stale takeover does | 2, N1, N7 | 9/9 PASS |
| 3 | `approval-gate` - `claim()` itself rejects `awaiting_approval`; a grant bound to a stale plan hash is rejected; the plan hash is **recomputed from the plan's own stored content at claim time**, proven by mutating the stored plan out-of-band and showing the next claim rejects it; an expired grant is treated as no grant | 4, 12, F8 item 4, N4 | 6/6 PASS |
| 4 | `broker-boundary` - the AI-facing role cannot `AssumeRole` a work-credential role directly; the same role cannot write the Ledger table at all (not attribute-gated - no write action exists); it can still read; broker-vended, session-policy-narrowed work credentials can do the allowed action and cannot do a disallowed one; those same vended credentials still cannot write the Ledger | 5, 13, 14, N3, N5 | 7/7 PASS |

**Total: 26/26 PASS**, after four real bugs this run itself found and fixed (next
section) - none of which were "the DynamoDB conditional write failed to be
atomic"; every one was this prototype's own Python-level mistake about which
credentials to use or how to serialize a value, exactly the class of bug round 2's
own verification.md already noted a design document's pseudocode cannot catch.

### Bugs this run found (fixed in `prototype-v2/handoff_core.py` before the run above)

1. **`iam.put_role_permissions_boundary` takes `PermissionsBoundary`, not
   `PermissionsBoundaryArn`.** A parameter-name typo; `setup` failed before
   creating anything load-bearing. Caught immediately by the very first `setup`
   call failing with `ParamValidationError`.
2. **`boto3`'s DynamoDB resource API raises on a native Python `float`** ("Float
   types are not supported. Use Decimal types instead.") and, separately, a value
   **read back** from the table arrives as `decimal.Decimal` even when it was
   written as a plain Python `int` - breaking `claim()`'s own hash recomputation
   (N4) for a reason having nothing to do with the plan's actual content, since
   `json.dumps` does not know how to serialize `Decimal` either. Fixed by (a)
   making `broker_now()` return `Decimal(str(time.time()))` rather than a bare
   float, and (b) giving `canonical_json()` a `default=` that renders a whole-
   valued `Decimal` exactly as `json.dumps` already renders a plain `int` - so a
   value written as `int(3)` and later read back as `Decimal('3')` hashes
   identically either way.
3. **"`plan`" is a DynamoDB reserved keyword** and cannot appear unescaped in an
   `UpdateExpression`; the test harness's own out-of-band tampering write (used to
   exercise finding #2's hash-recomputation check) needed an
   `ExpressionAttributeNames` alias, not a design-level finding.
4. **The real finding of this round**: `vend_work_credentials()`'s first draft
   built a **fresh `boto3.client("sts")` with no session at all**, which silently
   used this *process's own ambient credentials* (the runner's admin role, when
   called from a test driver) to call `AssumeRole`, rather than the broker's own
   assumed-role session design.md's Decision 5 requires every write-adjacent
   action to run as. The very first run of scenario 4 caught this immediately as
   an `AccessDenied` ("is not authorized to perform: sts:AssumeRole"), because the
   runner's own role was never granted `sts:AssumeRole` on the work-credential
   roles directly (by design - Decision 5's whole point). Fixed by threading the
   broker's own `boto3.Session` through `Broker.__init__` and using it for this
   call. **Separately, and worth recording on its own merits**: the first fix
   attempt still failed, with AWS's own error message naming the actual mechanic
   design.md's prose ("explicit Deny statements layered server-side") had not
   spelled out precisely - `AssumeRole`'s `Policy` (session policy) parameter
   does not act as a pure blocklist layered on top of the role's own permissions;
   the AWS-documented rule is that the **effective permissions are the
   intersection** of the role's identity policy and the session policy, so a
   session policy containing only a `Deny` statement and no `Allow` intersects to
   *nothing at all*, for every action, not only the one it names. The corrected
   session policy is an explicit `Allow: *` baseline (the role's own, already-
   narrow identity policy remains the real ceiling) plus the intended `Deny` on
   top - this is the shape any real implementation of Decision 5's server-side
   narrowing must use, named here because design.md's own prose did not say so at
   this level of precision and a reader implementing it from the prose alone
   would plausibly repeat this exact mistake.

### Run IDs and cleanup evidence

Final, all-green run: `run-20261120T013611Z-71990` (26/26 PASS; three earlier
runs in this same session, `run-20261120T011527Z-54316` through
`run-20261120T013335Z-70643`, each caught exactly one of the four bugs above and
are not separately enumerated here). After the final run's own `teardown` step,
a direct, separate check from outside the runner confirmed every resource gone:

```
$ aws dynamodb describe-table --table-name distai-handoff-rfc-ledger --region us-east-1
ResourceNotFoundException: Requested resource not found: Table: distai-handoff-rfc-ledger not found
$ aws iam get-role --role-name distai-handoff-rfc-ai-base-role        # NoSuchEntity
$ aws iam get-role --role-name distai-handoff-rfc-broker-role          # NoSuchEntity
$ aws iam get-role --role-name distai-handoff-rfc-work-demo-light      # NoSuchEntity
$ aws iam get-role --role-name distai-handoff-rfc-work-demo-approval   # NoSuchEntity
$ aws iam get-policy --policy-arn arn:aws:iam::776010787911:policy/distai-handoff-rfc-broker-boundary   # NoSuchEntity
$ aws ssm get-parameter --name /distai-handoff-rfc/allowed      # ParameterNotFound
$ aws ssm get-parameter --name /distai-handoff-rfc/forbidden    # ParameterNotFound
```

The two S3 scratch objects (`handoff_core.py`, `handoff_scenarios.py`) were also
deleted after the final run. The EC2 runner instance itself was left running,
unstopped: at the time of this check it had two other, unrelated run units
already active (`run-20261120T004011Z-31438`, `run-20261120T010904Z-48433`,
both started before any run in this section and neither created by this round),
so stopping it would have killed someone else's in-flight work - consistent with
this project's own rule against treating another session's resources as
abandoned.

### Scope this round still does not cover

Unchanged from round 2's own list below for the items that round never claimed
either, plus what round 7's design added that this round's four scenarios do not
reach: `replan()`, `create_child()`, and `RenewWorkCredentials()` are not
implemented in `prototype-v2/` at all (design.md's own Experiments 1-4, which
this round re-verifies, do not exercise them); the `sweep()` reaper's own
behavior (notify-only, never claims) is implemented but not exercised by any
scenario in this round; real hardware MFA on `grant_go` remains unverified, as
does whether `aws:MultiFactorAuthPresent` is populated for IAM Identity Center
sessions (both named as open in design.md's own Decision 6 and Residual risks);
and Experiment 5 (Kueue binding, the bare-EC2 lane, a real Capacity Block)
remains deferred to the first real consumer PR, unchanged from round 2.

## What was built (round 2, 2026-11-19 - superseded in places, kept for history)

A minimal, real (no mocks) implementation of the Ledger's core primitives from
design.md Decision 2/4/5/6:

- One DynamoDB table (`distai-handoff-demo-tasks`, on-demand billing), created and
  destroyed per run.
- Two IAM roles: `distai-handoff-demo-ai-task-role` (the AI-facing, scoped role -
  its trust policy names only the broker role, not any AI base principal directly)
  and `distai-handoff-demo-broker-role` (stands in for the credential broker's own
  execution identity, Decision 5), both created and destroyed per run.
- `claim()`/`heartbeat()`/`release()`: version-based compare-and-swap, never an
  absolute, cross-machine-compared clock value (the round-1 fix, F1/F2).
- `grant_human_go()`: conditioned on the *current* plan hash matching what the
  grant names, closing the review/grant race (F8 item 4).
- A `DenyHumanGoWrite` IAM statement using the `dynamodb:Attributes` condition key,
  blocking the AI-facing role from ever writing `human_go`, regardless of session
  policy.

## Scenario results (round 2, after the design was revised per `review-r1.md`)

Run IDs on the EC2 runner: `run-20261119T143702Z-28714` (first attempt, caught a
real bug), `run-20261119T144012Z-31071` (after the fix, all green).

| # | Scenario | Use cases | First attempt | After fix |
| --- | --- | --- | --- | --- |
| 1 | `race` - 8 concurrent claimants on one `pending` task | 3 | **FAIL**: 2 winners (`claimant-1`, `claimant-6`) | PASS: exactly 1 winner, `attempt_count` advanced by exactly 1 |
| 2 | `crash-takeover` - A claims, never heartbeats/releases; B must wait a full lease window (local elapsed time only) before reclaiming | 2 | FAIL (downstream of the same bug): a too-early claim attempt was wrongly accepted, corrupting `attempt_count` | PASS: too-early attempt rejected; reclaim only after the full local wait; A's old token rejected post-takeover; B's heartbeat accepted |
| 3 | `approval-gate` - claim blocked with no `human_go`; a grant bound to a stale plan hash is rejected; claim succeeds once granted against the current hash; a plan change after granting invalidates it (use case 12) | 4, 12 | PASS (all 4 assertions) | PASS (unchanged) |
| 4 | `broker-boundary` - the AI base role cannot assume the task role directly; only the broker role can; broker-minted, session-policy-narrowed credentials can do the allowed action and cannot do a disallowed one; the full task role (reached only via the broker) is still denied writing `human_go`; a maintainer-equivalent principal can | 5, 13, 14 | PASS (all 7 assertions) | PASS (unchanged) |

**Total: 16/21 PASS on the first attempt, 21/21 PASS after the fix.**

### The bug the first attempt found

`claim(task_id, lease_seconds, wait_for_stale=False)` was meant to let a caller
attempt an immediate claim on a `pending` task without paying the full wait. The
code as first written checked `if item["state"] in ("claimed", "parked") and
wait_for_stale:` to decide whether to wait - when `wait_for_stale` was `False`, this
condition was false regardless of the task's actual state, and execution fell
through to an **unconditional write attempt with no state check at all**. In the
`race` scenario, this meant: the first thread to finish claimed the task (version
0 -> 1); a later-starting thread, which happened to read the *already-claimed* item
(version already 1) before issuing its own write, had `wait_for_stale=False` set
(deliberately, to test the immediate-race case) and - because of the bug - skipped
the wait-and-recheck step entirely and wrote anyway, successfully claiming a second
time (version 1 -> 2). Two threads each held a lease_token the Ledger accepted as
current at different moments, which is exactly the "two winners" failure the test
caught, not a flaw in DynamoDB's own conditional-write atomicity (each individual
write was still correctly atomic and version-gated - the bug was deciding to attempt
a second write at all). Fixed by making `wait_for_stale=False` refuse outright
(`return None`) whenever the task is already `claimed`/`parked`, rather than
falling through to a write. Re-run: exactly one winner every time.

This is the one piece of this verification's own evidence worth calling out
explicitly: the bug was not in the DynamoDB-conditional-write *mechanism*
design.md's Decision 4 describes (that mechanism, once actually reached, worked
every time, both before and after the fix) - it was in this prototype's own
Python-level decision about *when* to attempt a write, exactly the class of bug a
design document's pseudocode cannot catch and only a running program can.

## Cleanup verification (not just the script's own exit code)

After each `teardown` run, a direct, separate AWS API call confirmed each resource
gone:

```
$ aws dynamodb describe-table --table-name distai-handoff-demo-tasks --region us-east-1
ResourceNotFoundException: Requested resource not found: Table: distai-handoff-demo-tasks not found
$ aws iam get-role --role-name distai-handoff-demo-ai-task-role
NoSuchEntity: The role with name distai-handoff-demo-ai-task-role cannot be found.
$ aws iam get-role --role-name distai-handoff-demo-broker-role
NoSuchEntity: The role with name distai-handoff-demo-broker-role cannot be found.
```

No AWS resource from this verification was left running. The S3 scratch objects
used only to transfer the two prototype `.py` files onto the runner (since
`run.sh` clones `littlemex/distai-platform` itself, not this standalone prototype)
were deleted after each run.

## Scope not covered by any round of this verification

- Use case 1's Kueue binding (`maximumExecutionTimeSeconds` or the equivalent
  Job-level field, a dedicated `ClusterQueue`, Workload/Job adoption by a
  deterministic `task_id-step_id` name) needs a live EKS cell and is explicitly
  deferred to the first real consumer PR (design.md's own Experiment 5),
  consistent with "keep cloud resources tiny" for this design-verification round.
  The same is true of the bare-EC2 half of that same experiment (no Kueue/Kubernetes
  at all) - the first real consumer the maintainer named, a 24-hour `p5en x2`
  Capacity Block running an EKS-verification lane then a bare-EC2 engram GIN
  experiment, needs this mechanism's own real deployment to exercise for real,
  and nothing in that block depends on it being ready in time.
- The credential broker is verified only at its IAM trust-boundary (a real,
  load-bearing control: who can assume the task role at all); no Lambda was
  ever built, since the trust-policy boundary was the specific claim round 1
  disputed (F6) and is what the prototype (below) set out to prove.
- MFA-gated approval (Decision 6, F8 item 4's harder half) was not exercised with
  real hardware MFA; this remains a design-level commitment, not something any
  round demonstrates end-to-end.
- Rounds 3 through 7 revised the design substantially after the prototype ran
  (a strictly broker-only write model; a two-call, broker-enforced wait
  replacing a literal `sleep()`; a client-generated lease token instead of a
  broker-minted one; the deadline check folded into `claim()`/`heartbeat()`
  rather than a separate reaper state transition; `replan()`/`create_child()`/
  `RenewWorkCredentials()`/`sweep()` added). **None of these later-round
  mechanisms were re-run against a second prototype** - they were checked
  through seven rounds of adversarial, line-by-line pseudocode review by
  Fable 5.2 instead (culminating in `review-r7.md`'s `VERDICT: APPROVE`), which
  is a real, substantive form of verification (it caught and forced fixes for
  specific, concrete bugs - see the F1-F11/N1-N11/B1-B5/D1-D4/P1-P7 tables across
  `review-r1.md` through `review-r7.md` - not a rubber stamp), but it is review
  of text, not execution of code. The design is approved to build; re-running
  this prototype's own four scenarios (race, crash-takeover, approval-gate,
  broker-boundary) against the final, broker-only/two-call-wait/client-token
  shape is the first thing the implementation PR should do, named explicitly
  by Fable 5.2 itself as the gate before first real use.

## Fable 5.2 review rounds (summary; each file has the full text)

| Round | File | Verdict | What it found or closed |
| --- | --- | --- | --- |
| 1 | `review-r1.md` | CHANGES NEEDED | `claim()` could never reclaim a crashed task (F1); an absolute, cross-machine-clock-skew-prone lease timestamp contradicted this RFC's own cited reference pattern (F2); no fencing of an already-running side effect (F3); the human-approval gate was forgeable or bypassable six different ways (F8); permission scoping was purely cooperative/advisory (F6); a real factual error in how STS role chaining composes session policies (F7); F4/F5/F9/F10/F11. |
| 2 | `review-r2.md` | CHANGES NEEDED | Architecture (version-CAS, a credential broker, an immutable plan, a supervisor instead of the `Stop` hook) accepted as right; found 10 new problems the round-1 fixes themselves introduced or left unspecified (N1-N10), including a literal `sleep()` design flaw, an orphan-claim gap, and a confused-deputy path the broker had not actually closed. |
| 3 | `review-r3.md` | CHANGES NEEDED | Found `claim()`'s pseudocode disagreed with its own prose in five places (D1-D4, plus one `create()` idempotency defect, B1-B7 in that round's own numbering) - a parked holder stuck forever, a wait clock any observer could reset, an unrecoverable missing Go, no deadline check on `AppendEvidence`/`park`, Decision 9 still describing the old, rejected "bounce to pending" behavior. |
| 4 | `review-r4.md` | CHANGES NEEDED | All of round 3's findings fixed; found a new class of bug: the reaper's own `claim()` call made it the new holder of everything it scanned, charging an attempt every cycle until a crashed task self-abandoned regardless of whether the original holder was dead (B2) - fixed by replacing it with `sweep()`, an action that notifies and abandons but never claims. |
| 5 | `review-r5.md` | CHANGES NEEDED | Found a `create()` retry could silently reset a live task's own progress to a brand-new task's values (B1); `replan()`'s maintainer path had no read or terminal-state guard (B4); the retries-exhausted `abandon()` had no version guard (B5). |
| 6 | `review-r6.md` | BLOCK — B2, B3, B4, S1, N1 (first round using the maintainer's explicit approval bar) | `deadline_at` was never actually written by any pseudocode despite the prose claiming it was (B3); `sweep()` still charged an attempt against a `parked` task `claim()` itself never would (B2); `replan()`'s fix from round 5 had not actually landed in the text (B4); Decision 11 named a different set of callers than Decision 4 (S1); the new bare-EC2 first-consumer material could not actually pass `create()`'s own Kueue-only resource-binding check (N1). |
| 7 | `review-r7.md` | **APPROVE** | All five round-6 blockers closed; a full adversarial trace of every `replan()` start-state against `claim()`/`sweep()` found no double execution, stuck task, privilege escalation, approval bypass, or lost evidence. Nine further, explicitly non-blocking refinements were listed for the implementation PR (an unconditional `deadline_at` write that disagreed with its own comment; an attempt charge on a maintainer-initiated replan; several wording/cross-reference items) - the first two of these (and two of the wording-adjacent ones from round 6's own non-blocking list) were fixed immediately afterward as cheap, high-value corrections, not required for the APPROVE verdict itself. |

**Final state: `review-r7.md` ends `VERDICT: APPROVE`, under an explicit bar
(no design contradiction; no safety hole in double execution, a stuck task,
privilege escalation, approval bypass, or lost evidence; every decision has a
reason and a compared alternative; a prototype could be built from the text) the
maintainer stated directly for this round.** A short list of further, named
non-blocking refinements (Fable 5.2's own section 3/4 in `review-r7.md`) remains
for the implementation PR, not for this design round.
