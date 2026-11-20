# Round 2 review: RFC "Task handoff between AI agent sessions"

**Bottom line.** Round 2 fixes the architecture: version-CAS takeover, a broker, an immutable plan, a supervisor instead of `Stop`, and an honest at-least-once guarantee. It still does not deserve approval. Three of round 2's own changes open new holes, and the RFC now describes two incompatible write models, so several "closed" findings are closed under one reading and open under the other.

Two of the new problems come from round-1 advice of mine that the RFC adopted verbatim and that was underspecified. I mark those as mine (N7, N9).

## 1. F1–F11 status

| # | Status | What remains |
| --- | --- | --- |
| F1 | **FIXED** | `claim()` now accepts `claimed`/`parked`/`failed` under version-CAS. The prototype's crash-takeover scenario is adequate evidence. |
| F2 | **FIXED** for my sequence | No cross-machine clock comparison decides takeover. A different hole of the same class replaces it (N1). |
| F3 | **PARTIALLY FIXED** | The guarantee is restated honestly. Adoption does not work as written (N6), self-fencing has a sleep hole (N9), and credentials still outlive the lease by up to an hour. |
| F4 | **PARTIALLY FIXED** | `create()` and the token are right. The token is stored readable (N2). `complete`, `fail`, `park`, `reap`, `abandon`, `force-release`, the plan change and the full `grant_go` still have no pseudo-code. A lost broker response leaves an orphan claim nobody holds; this needs a client-supplied idempotency token. |
| F5 | **FIXED** | `Stop` is unwired and the lease lives in a supervisor. The `PreToolUse` guard should apply to headless sessions too (N9), and the kill must cover the child's process group. |
| F6 | **PARTIALLY FIXED** | The broker is the right enforcement point. It is unprotected and under-specified (N3, N5), and the AI still picks its own profile (N4). |
| F7 | **FIXED** | The chaining claim is gone and described correctly. Note the broker's own `AssumeRole` is role chaining, so vended sessions cap at one hour, and no re-vend path is specified. |
| F8 | **PARTIALLY FIXED** | Item 4 (review/grant race) is closed. Items 1–3 are moved, not closed (N4). Item 5 is partly closed (MFA; see section 5). Item 6 depends on the write model (N3) and still omits PartiQL. Item 7 stops heartbeats mechanically, not work. No Go expiry and no re-check at credential renewal. |
| F9 | **PARTIALLY FIXED** | `maximumExecutionTimeSeconds` and a dedicated ClusterQueue are adopted. The time limit is set by the submitting client, cleanup is best-effort, and `AdmissionCheck` is still not discussed (N6). |
| F10 | **PARTIALLY FIXED** | `claimed_at`, `deadline_at` and in-claim counting exist. The deadline is resettable, a never-claimed task still has no clock, and edges are missing (N7, N8). |
| F11 | **PARTIALLY FIXED** | Per-step appends, `if_not_exists`, digest-pinned URLs and reaper-only TTL are in. A deposed holder's last evidence is still dropped (no deterministic per-attempt prefix, no Job-identity writer). The 400 KB limit is unaddressed and now more likely. Overwrite is a residual that should not exist (N3). |

## 2. New problems introduced by round 2

**N1. The staleness wait is a caller courtesy, and the lease duration is not in the record.**
- `lease_seconds` is a parameter of `claim()`. Holder A works to a 600 s lease; B calls with 5 s, sees no version change, and its CAS on `version = v0` succeeds against a live lease.
- This is the bug your prototype caught (`wait_for_stale=False`), in parameter form. The CAS protects against concurrent writers; only the wait protects a live holder.
- The RFC's own Facts row says the lock client stores the relative duration in the record. The schema stores none.
- If the broker enforces the wait, a Lambda cannot sleep a long lease. It needs two observations: record (version, broker time) on the first call, then verify on the second.
- Fix: store `lease_seconds` in the plan or record, and have the broker enforce the wait.

**N2. The lease token is a bearer secret stored in plaintext.**
- It sits in `lease_holder`, is copied into every evidence entry's `by`, and the Ledger is readable by every session.
- Any session can read it and heartbeat, release, complete or park as the holder.
- "Bound to the caller's IAM identity" does not help: sessions on one box share a role.
- Fix: store only a hash of the token and never echo it.

**N3. Two incompatible write models.**
- Decision 5 says AI principals may only invoke the broker and read the Ledger.
- Decision 6 item 5, Decision 8 and experiment 4 describe an AI or task role with `UpdateItem` and a deny list of three attribute names.
- Under the second model, `state`, `lease_holder`, `version`, `attempt_count`, `deadline_at`, `kind`, `evidence` and the plan item's own content are all writable. That reopens F4, F8 and F10.
- Fix: commit to broker-only writes. The evidence-overwrite residual then disappears, because the broker exposes only an append action.

**N4. The tautology moved; it did not close.**
- `claim()` contains no Go condition at all, and there is no `create → awaiting_approval` edge. An approval-required task starts `pending` and is claimable as written. The prototype evidently implements a check the RFC does not specify.
- `kind` is AI-chosen at creation, on the mutable item. Choosing a kind that needs no Go, with a plan naming a broad profile, opts out of approval. "Nothing it writes decides this" is false.
- Nothing recomputes the plan hash. `attribute_not_exists` gives write-once, not content-addressing.
- Fix:
  - Add `human_go.plan_hash = plan_ref` to the claim condition.
  - Add a maintainer-owned map from kind to allowed profiles, queues and budget caps, with `kind` inside the hashed plan.
  - Have the broker and CLI recompute the hash on every read.
  - Clear `human_go` on plan change and give it an expiry.
  - Say who may change `plan_ref`. Otherwise any session can depose any holder.

**N5. The broker is now the most privileged principal and nothing protects it.**
- Its role can assume every task role, write every Ledger field, mint GitHub tokens and create RBAC bindings.
- Compromise: the RFC does not say who may update its code, role, profiles or the kind policy. The `AdministratorAccess` runner can, and so can any task profile that includes Lambda or IAM actions.
- Authorisation: any AI principal can claim any task and receive its profile.
- Base credentials: the RFC asserts AI principals are restricted but does not say how. On the Mac the session inherits the maintainer's credentials. Cutting the runner from admin to two actions contradicts "Breaking changes: none".
- Availability: if the broker is down, no heartbeat lands, every lease lapses and nothing can be reclaimed.
- Caller identity: as far as I know, a plain `lambda:Invoke` does not pass the caller's ARN to the function. It needs a function URL with IAM auth or API Gateway.
- Fix: put the broker, profiles and Ledger behind a permission boundary or a separate account, with MFA-gated deployment.

**N6. Attempt-suffixed names defeat adoption.**
- B is attempt 2, so its Workload is `…-att2`. A's orphan `…-att1` still runs. B creates a duplicate; it adopts nothing. My F3 sequence 2 still works.
- The name must be deterministic in (task, step), with the attempt as a label.
- Cleanup is "best-effort", done by a reaper whose stated scope is Ledger-only, so it has no cluster access.
- `maximumExecutionTimeSeconds` bounds duration, not concurrency, and the submitting client sets it. Enforce it with an admission policy.
- A dedicated ClusterQueue does not stop Karpenter consolidating empty nodes; that claim is wrong.

**N7. `attempt_count` charges normal handoffs (my advice, underspecified).**
- Every claim increments it, including a graceful release-and-claim and every `resume()`.
- With `max_retries: 2`, a task that spans three healthy sessions (the RFC's own motivation) becomes unclaimable.
- Fix: count only takeovers from stale `claimed` or from `failed`.

**N8. Deadline and state-machine gaps.**
- `release()` removes `claimed_at` and `deadline_at`, so release-and-reclaim resets the "fixed point". `park()` is "the same shape".
- A never-claimed task has no `deadline_at`, so `pending → abandoned` on deadline is uncomputable. Use `created_at`.
- Missing edges: `claimed → abandoned` (dead holder with attempts exhausted is stuck), `failed → abandoned`, and whatever the reaper does when the deadline passes on a healthy holder.
- `SET x = REMOVE` is not valid DynamoDB syntax.

**N9. Self-fencing fails on the case it exists for (partly my wording).**
- Common monotonic clocks (Linux `CLOCK_MONOTONIC`, macOS `mach_absolute_time`) do not advance during suspend, as far as I know.
- A Mac that slept two hours wakes believing its last heartbeat was seconds ago and passes its own check.
- Fix:
  - Make a synchronous heartbeat round trip before each side-effecting step, via `PreToolUse` in all modes.
  - Vend 15-minute credentials, renewed only on a valid lease and Go.

**N10. `parked` is treated as stale `claimed`.** Any claimant, including `handoff reap`, takes a parked task after one lease window. Decide whether that is intended and say so.

### Adversarial passes, indexed

| Angle | Still works or new |
| --- | --- |
| Double execution | Short `lease_seconds` (N1); stolen token (N2); `att1`/`att2` duplicate Jobs (N6); sleep and resume (N9); credentials valid after lease or plan loss |
| Stuck tasks | Attempts exhausted by healthy handoffs (N7); dead `claimed` at max attempts, `failed` at max (N8); broker outage (N5); never-claimed with no clock (N8); orphan claim after a lost broker response; Terraform lock (named) |
| Privilege escalation | Self-selected kind and profile (N4); any caller claims any task (N5); editing the broker or profiles (N5); broad base credentials (N5); the `UpdateItem` model (N3) |
| Approval bypass | No Go condition in `claim()`, kind opt-out, unverified hash (N4); mutable plan item under N3; cached MFA credentials; admin runner |
| Lost evidence | Deposed holder's final evidence; list overwrite under N3; 400 KB limit; no lane-to-lane link |

## 3. Use cases

| UC | Round 2 | Why |
| --- | --- | --- |
| 1 | Fails | No predecessor link to A's evidence; duplicate Jobs (N6); experiment 5 is optional and unrun, so the headline use case is untested. |
| 2 | Holds at the Ledger | Prototype-verified. Side-effect safety depends on N1, N6 and N9. |
| 3 | Holds | Prototype-verified, subject to N1 and N2. |
| 4 | Partial | N4, N5, cached MFA. |
| 5 | Partial | Right design. Base credentials, authorisation, and the GitHub and Kubernetes mechanisms are named but not designed. Evidence remains an exfiltration path. |
| 6 | Partial | Native idempotency and acceptance criteria are added. Still no working-state pointer (branch SHA). |
| 7 | Partial | Block end is handled in principle. Deadline is resettable (N8). The block's end time is not in the schema. |
| 8 | Mostly holds | Only if the broker is the sole writer (N3). The Stream's 24-hour loss window is unmentioned. |
| 9 | Mostly holds | Steering verbs and push for capacity-bound tasks are added. `grant-go` reachability is corrected. |
| 10 | Partial | Reachability holds. Per-environment base credentials are unspecified (N5). |
| 11 | Partial | `park()` exists. N7, N10. No `progress_at` (named as residual). |
| 12 | Holds at the Ledger | Prototype-verified. Who may change the plan is unspecified. Credentials persist. |
| 13 | Holds for out-of-process sub-agents | Deny-only narrowing is sound. The in-process limit is named. |
| 14 | Partial | N2, N5. Free-text evidence still instructs the next session. |
| 15 | Partial | Crash loops are bounded. N8 edges and best-effort cleanup remain. |

## 4. Residual risks list

The list is honest about what it names. It fails its own last acceptance criterion because these are omitted or understated:

- **Broker as trust concentration and as a single point of failure (N5).** It is listed only as "standing infrastructure".
- **Broad base credentials on the Mac and runner until migrated,** and an admin principal that can rewrite every control.
- **Readable lease token (N2).**
- **Laptop sleep.** It is presented as a liveness nuisance. It is a double-execution hazard (N9).
- **MFA reuse.** It is framed as an edge case. Depending on how the maintainer gets the MFA session, credentials cached under the same OS user are reusable by an AI session for up to an hour after every legitimate grant.
- **Evidence and step text as a prompt-injection and secret-leak channel.**
- **Two Jobs can co-run on one block,** because cleanup is best-effort (N6).
- **UC1 is unverified on a live cell.**
- **Evidence overwrite** is listed as a residual but is fixable now (N3).

## 5. Factual corrections re-check

| Round-1 item | Round 2 |
| --- | --- |
| Chaining intersects policies | Corrected. |
| DynamoDB evaluates `now()` / server timestamp | Removed. `:now_iso` is still writer-supplied, which is acceptable only if the broker is the writer. |
| "Does not need to disclaim" fencing | Corrected. |
| CloudTrail records every DynamoDB call | Corrected. |
| Stream "straight to CloudWatch Logs" | Corrected. |
| `dynamodb:Attributes` coverage | Partly. PartiQL is still not denied. |
| `Stop` as a graceful-exit signal | Corrected. |
| `Notification` forwards "a task stalled" | **Not corrected.** Still in the Decision 7 table. |
| `SessionEnd` timeout raisable to 60 s | Unchanged and unverified, but no longer load-bearing. |
| Lock client vs schema | Absolute expiry is removed, but a new contradiction replaces it: no stored duration (N1). |
| "A Cohort's lifetime" | **Not corrected.** Still in Decision 1. |
| Argo Facts row | Corrected. The row exists and matches what I know. |
| "Verification, scenario …" cites a missing section | **Not corrected.** The RFC still cites "Verification, scenario `race`" and "`approval-gate`"; no such section exists and "Experiments needed" is in the future tense. |
| State names echo A2A | **Not corrected.** The claim is repeated and still false. |

New factual items to verify:
- I believe `aws:MultiFactorAuthPresent` is not populated for IAM Identity Center sessions. If the maintainer uses SSO, the grant fails closed and nobody can approve.
- The Lambda caller-identity point in N5.
- The Karpenter claim in N6 is wrong.

## 6. Is the prototype sufficient?

I was shown a summary of the run, not the code, the assertion list or raw output. Taking it as reported:

**Sufficient for these claims:**
- Single winner under concurrent CAS.
- Takeover only after a locally measured unchanged window, and a deposed holder's heartbeat rejected.
- Conditional grant and plan-change invalidation at the Ledger.
- The trust-policy boundary: the base role cannot assume the task role, and the attribute deny holds for the call shapes tested.

Catching and fixing the two-winner bug shows the test can fail, and the teardown check is done properly.

**Still unverified:**
- That a caller cannot skip or shorten the wait (N1). The fix closed a flag in one client, not the property.
- "My own retry already won". This needs fault injection; a clean 8-way race never produces it, so the acceptance criterion is ill-formed.
- Any self-fencing or sleep behaviour.
- The broker as a real Lambda: identity, wait enforcement, re-vend, GitHub and Kubernetes.
- The MFA condition itself. "Maintainer-equivalent" is not MFA.
- Kind policy, hash verification, whole-item and PartiQL denial.
- Attempt and deadline behaviour under graceful release and park.
- Everything involving Kueue.

## 7. Minimum for round 3

1. One write model: broker-only (N3). Give pseudo-code for every transition.
2. Stored lease duration and a broker-enforced wait (N1). Hashed token (N2).
3. Go condition inside `claim()`, kind-to-profile policy, hash recomputation, Go expiry (N4).
4. Broker protection, authorisation, identity mechanism and a base-credential migration plan (N5).
5. Step-deterministic names, enforced time limit, cleanup with real cluster access (N6).
6. Attempt accounting, deadline and missing edges (N7, N8).
7. Synchronous pre-step fencing and short credentials (N9).
8. A real Verification section (assertions, commit, output). Fix the four uncorrected factual items.
9. Complete the residual list per section 4. Run or honestly descope UC1.

VERDICT: CHANGES NEEDED