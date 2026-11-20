# Round 3 review: RFC "Task handoff between AI agent sessions"

**Bottom line.** Round 3 commits to the right write model and fixes the token, the naming, the attempt rule and all four leftover factual errors. Lack of code verification does not block approval. What blocks it is on paper: most transitions still have no pseudo-code, and the `claim()` that is written disagrees with the prose in several places. The takeover wait is also a `sleep()` inside a Lambda, which round 2 warned against. The remaining work is one editing pass with no new architecture.

I have not been shown `verification.md`; I take its contents as described.

## 1. Round-2 "minimum for round 3" list

| # | Item | Status | What remains |
| --- | --- | --- | --- |
| 1 | One write model; pseudo-code for every transition | **PARTIALLY FIXED** | The AI-side write path is closed. The text says "all five" and gives four: `create`, `claim`, `heartbeat`, `release`. Still unwritten: `complete`, `fail`, `park`, `reap`, `abandon`, `force-release`, `grant_go`, plan change, `AppendEvidence`. Non-AI writers are not reconciled with "broker is the only writer" (R3). |
| 2 | Stored lease duration, broker-enforced wait, hashed token | **PARTIALLY FIXED** | Duration is in the plan and the token is hashed. The wait mechanism is wrong (R1). |
| 3 | Go inside `claim()`, kind policy, hash recomputation, Go expiry | **PARTIALLY FIXED** | Hash recomputation and the kind policy are in. The pseudo-code checks only `state`; it never reads `human_go` or `expires_at` (R4). The policy does not constrain queues, as I asked. Who may change a plan is still deferred. |
| 4 | Broker protection, authorisation, identity, migration | **PARTIALLY FIXED** | Identity mechanism and change control are stated. The permissions boundary is misdescribed (section 3). Migration is a named follow-up, not a plan, and "Breaking changes: none" still contradicts it. |
| 5 | Deterministic names, enforced time limit, real cleanup access | **PARTIALLY FIXED** | Names are fixed. The admission policy is "not yet designed". Cleanup access is named, not designed, and now conflicts with adoption (R7). |
| 6 | Attempt accounting, deadline, edges | **PARTIALLY FIXED** | The rule is right in Decision 3. Decision 9 and the pseudo-code contradict it (R4, R5, R9). |
| 7 | Synchronous fencing, short credentials | **PARTIALLY FIXED** | Synchronous heartbeat is adopted in all modes. Credentials are still one hour, with no re-vend path and no re-check at renewal (R8). |
| 8 | Real Verification section; four factual items | **PARTIALLY FIXED** | All four factual items are fixed. The section is honest about scope but carries no commit, assertion list or output itself. |
| 9 | Complete residual list; run or descope UC1 | **PARTIALLY FIXED** | Every item from my section 4 is added or closed by design, and UC1 is honestly descoped. One bullet overclaims (section 3), and round 3's own open items are not listed. |

## 2. N1–N10

| # | Status | What remains |
| --- | --- | --- |
| N1 | **PARTIALLY FIXED** | No caller can shorten the wait. The broker implements it as `sleep(lease_seconds + margin)` (R1). |
| N2 | **FIXED** | Residual: the supervisor must pass the token to the child for `PreToolUse`, so same-user sessions on one box can likely read it. |
| N3 | **PARTIALLY FIXED** | R3. Also stale: Decision 1's diagram shows sessions writing the Ledger directly; Decision 10 says "the writing session's … identity"; Decision 11 says "admin-write access". |
| N4 | **PARTIALLY FIXED** | Item 3 above, plus R4 and R6. |
| N5 | **PARTIALLY FIXED** | Item 4 above. Until migration, the admin runner can rewrite the broker, the table policy and the kind policy. Label UC4, 5 and 14 "enforced only after migration". |
| N6 | **PARTIALLY FIXED** | Item 5 above. The Karpenter claim is withdrawn and `AdmissionCheck` is named as open. |
| N7 | **PARTIALLY FIXED** | Decision 9 charges a `parked` takeover; Decision 3 says park/resume never charges. `attempt_count < max_retries` blocks graceful claims at the cap (R4). |
| N8 | **PARTIALLY FIXED** | `REMOVE` syntax, `if_not_exists` and the two edges are fixed. New gaps in R5 and R9. Block end time is still not in the schema. |
| N9 | **PARTIALLY FIXED** | Sleep is now handled at the Ledger. Residual window in section 4. The kill still does not cover the process group. |
| N10 | **FIXED** | Declared intentional. Note the original holder must also wait a full lease window to resume its own parked task. |

## 3. Factual items

| Item | Now |
| --- | --- |
| `Notification` forwarding | **Gone.** The row now says the hook fires on Claude Code's own events and pushes nothing by itself. |
| "A Cohort's lifetime" | **Gone.** Replaced by "as long as the pool itself exists". |
| Dangling "Verification, scenario…" | **Gone.** All citations point to `verification.md` and a section that exists. |
| A2A state-name echo | **Gone.** Explicitly withdrawn. |

New text errors in round 3:
- **Overclaim.** The UC1 residual says "every Ledger-side mechanism (claim/heartbeat/release/broker boundary) is verified on real AWS". The Verification section says the opposite for round 3's mechanisms.
- **Permissions boundary.** A boundary on the broker's role does not bound the roles it assumes. It should cover `sts:AssumeRole` on the per-kind roles, the Ledger table and the secrets the broker needs. Setting it to "the union of every profile" lets the broker do everything directly.
- **"My own retry already won"** is still an acceptance criterion and is now undetectable: the token is generated per call, so a retry cannot recognise its earlier win (R2).
- **"N11"** is cited; my review has no N11. The MFA and Identity Center point was in section 5, not N5.
- **Experiment 5 is "optional"**, but an acceptance criterion requires observed Workload adoption.
- **Kueue.** As far as I know, users submit Jobs and Kueue generates the Workload name. The deterministic name and time limit belong on the Job.

## 4. Adversarial passes on round 3's own changes

### Your three named questions

**Does broker-only writing add a single-point-of-failure problem beyond round 2's? Yes, three.**
- **Concurrency starvation (R1).** Each takeover holds a Lambda for the full lease. Many sleeping claims can exhaust concurrency and throttle heartbeats. Live leases then lapse and the sleeping claims win. Give heartbeat its own function or reserved concurrency.
- **Outage semantics (R10).** The supervisor must tell "lease lost" from "broker unreachable". If it kills the child on either, every task goes stale after one outage and every recovery charges an attempt. With `max_retries: 2`, two outages abandon everything in flight.
- **No break-glass (R3).** If `grant-go`, `force-release` and `abandon` go through the broker, the maintainer cannot steer during an outage.

**Does the `KIND_POLICY` lookup at `create()` introduce a bypass? Not of the lookup itself, but around it (R6).**
- `resource_binding` and `steps` are caller-supplied and unconstrained. A no-approval kind can name the reserved queue.
- The policy is consulted once and frozen. `claim()` never re-reads it, so tightening a kind does not reach tasks already created.
- The plan-change path is not stated to pass through the policy.
- Child tasks (R11): nothing requires the creator to hold the parent's lease. A session could create a child of an approved task and obtain the parent's profile.

**Does the synchronous heartbeat race with the broker's takeover wait? Not at the Ledger.**
- The heartbeat bumps `version`. If it lands before B's write, B sees `v1 != v0` or fails the CAS. If it lands after, the heartbeat fails. No interleaving gives two owners.
- A successful heartbeat guarantees `lease_seconds` of real time, but only on the `claimed`/`parked` path. Two windows remain.
- **Wake window.** A machine suspended mid-step resumes that step with no `PreToolUse` check and runs until the supervisor's next tick. Have the supervisor detect a wall-clock jump and heartbeat before letting the child continue.
- **Skipped wait (R5).** Below.

### New findings by angle

**R1. The wait is a sleep.**
- Round 2 said a Lambda cannot sleep a long lease and needs two observations. The RFC wrote `sleep()` anyway.
- Any `lease_seconds` near 900 makes takeover impossible. Behind API Gateway the default integration timeout is about 30 seconds.
- Behind a Function URL the client must hold a connection for ten minutes. If it drops, the claim completes and nobody receives the token.
- Fix: the first call records (version, broker time) and returns "retry after". The second call verifies and writes.

**R2. Orphan claims (stuck tasks).**
- A lost response leaves a claim nobody holds. The takeover that clears it charges an attempt.
- Fix: the client generates the token and sends it. A retry with the same token is an idempotent success.

**R3. Non-AI writers (approval bypass).**
- The RFC and its acceptance criterion say only the broker's role may write. The maintainer's `grant_go`, the admin overrides, the reaper and the `ttl` write are all described as if they write directly.
- If they go through the broker, the MFA condition has no stated enforcement point. It would need to sit on the invoke permission of a separate grant endpoint.

**R4. `claim()` disagrees with the prose.**
- There is no check of `human_go.plan_hash` or `expires_at`. Once a task is `pending`, every later claim succeeds regardless of expiry.
- `attempt_count < max_retries` applies to every claim, so a healthy release at the cap strands the task.
- `is_takeover_from_stale_claimed` is undefined.
- The `claimed → abandoned` write is not shown.
- Nothing says every write bumps `version`. If `complete()` does not, a waiting claimant can take over a completed task.

**R5. Deposing into `pending` skips the wait (double execution).**
- The reaper moves a healthy overdue holder to `pending`, and `force-release` does the same. A `pending` task is claimable instantly, while the old holder may be mid-step.
- An overdue task bounced to `pending` is still overdue, so it cycles until attempts run out. `claim()` never checks `deadline_at`.
- Fix: overdue goes straight to `abandoned`. Forced release goes to a state that requires the wait.

**R6. `create()` defects (stuck tasks, escalation).**
- The plan write fails if an identical plan exists. A retried create fails forever, and so does a second task with the same content.
- The two writes are not transactional.
- `task_id` is used but is not a parameter. If the caller chooses it, `task_id-step_id` names can collide across tasks.

**R7. Adopt versus delete (double execution, lost work).**
- The new holder adopts the object by name. The reaper deletes "the stale holder's" object by the same name.
- A name fixed across attempts also adopts a failed or finished object, or one created under a superseded plan.
- Fix: carry the attempt and plan hash as labels, adopt by conditional patch, and delete only on a label mismatch.

**R8. No re-vend (stuck tasks).** Credentials last one hour and the example timebox is 180 minutes. No renewal call is specified.

**R9. State machine versus pseudo-code.**
- The diagram has no `claimed → pending` edge (release) and no `[*] → awaiting_approval` edge.
- `awaiting_approval` has no exit except a grant, and there is no deny.
- A never-claimed deadline runs from `created_at`. A task approved after its timebox is abandoned on the next reap.

**Lost evidence.**
- The deposed holder's last entry is now a named residual. A deterministic S3 prefix per task and step would let the successor find it.
- Trimming the list needs a read-modify-write, which is unspecified.
- Still absent: a predecessor link for UC1 and a working-state pointer for UC6.

## 5. Does unverified-in-code block approval?

No. An RFC approval is approval to build. These grounds alone would not hold it back, because three conditions are met:
- The document no longer cites evidence it does not have, apart from the one residual bullet in section 3.
- The experiments are restated against the new design.
- The acceptance criteria gate the build on denied-write and code-inspection evidence.

Re-verification is a legitimate tracked follow-up. If this were the only gap, I would approve.

## 6. What blocks approval on paper

These are specification gaps, not residual risks. Implemented as written, each produces a defect in a core use case.

1. Pseudo-code for the missing transitions, with one rule that every write bumps `version` (item 1, R4, R9).
2. A two-observation takeover and a client-generated token (R1, R2).
3. `claim()` checks `human_go` and expiry and re-reads the kind policy. The attempt cap applies only where an attempt is charged (R4).
4. One stated path for maintainer and reaper writes, including where MFA is enforced and a break-glass path (R3).
5. No transition puts a live holder's task into an instantly claimable state (R5).
6. A credential renewal call that re-checks lease and Go (R8).
7. A decision on who may change a plan, and proof of the parent's lease for child tasks (R11).
8. Text fixes: the overclaim bullet, the boundary description, "Breaking changes: none", the ill-formed retry criterion, and `create()` idempotency (R6).

**Honestly named, not blocking:**
- Base-credential migration, once the affected use cases are labelled.
- The whole Kueue half, including R7, which must be resolved in the consumer PR.
- MFA reuse and the Identity Center question.
- In-process sub-agents.
- The Terraform lock.
- Evidence as an injection channel.
- Self-certified completion.
- The broker as trust concentration.

If items 1–8 are addressed in text, I would approve without a new prototype, with experiments 1–4 as the tracked gate before first use.

VERDICT: CHANGES NEEDED