# Review: RFC "Task handoff between AI agent sessions"

**Bottom line.** The split of resource admission (Kueue) from task ownership (Ledger), and hooks as an accelerant only, are sound. The mechanisms built on them do not deliver the stated guarantees:

- Takeover as written cannot succeed.
- Nothing fences a deposed owner.
- Permission scoping and the human Go are enforced by the cooperating client, not against a non-cooperating one.

One caveat on my own checking: I cannot verify documentation as of the RFC's 2026-11-19 date. Factual statements below are from AWS/Kubernetes/Kueue/Claude Code behaviour as I know it, and I say where I am unsure.

## 1. Core findings (referenced from the use-case walk)

**F1. Takeover is impossible as written (stuck).** `claim()` requires `state IN ('pending')`. A crashed holder's task is `claimed`, and Decision 3 says no other transition exists, so the condition is false forever. Decision 4's sentence "the same ConditionExpression… now evaluates true" is wrong. Experiment 2 would catch this, which suggests the prototype has not been run.

**F2. Lease time is the caller's clock.** DynamoDB has no server-side `now()` in expressions; `:now` is supplied by the claimant.
- Sequence: B's clock runs 3 minutes fast (a Mac just woken, a container without time sync). B sees `lease_expiry < now()` and claims while A is validly mid-step. Both act until A's next heartbeat.
- The RFC's own Facts row says the lock client stores only a relative duration to avoid exactly this, then the schema stores an absolute `lease_expiry`.
- Fix: follow the lock client (observe an unchanged version for a full lease duration, then write conditionally on that version), or derive time from the AWS response `Date` header plus a safety margin.

**F3. No fencing; lease loss is learned late and stops nothing.** The conditional write makes Ledger ownership atomic; it does not make side effects exclusive. The RFC criticises client-go for disclaiming fencing and says DynamoDB "does not need to disclaim" it. That is false: `amazon-dynamodb-lock-client` has the same property.
- Sequence 1: A starts a 40-minute `terraform apply` in one tool call, or the Mac lid closes. The lease expires and B claims. A wakes and finishes the in-flight call before any heartbeat tells it to stop.
- Sequence 2: A submitted a Kueue Job and died. The Job runs on without A. B sees step `in_progress`, effect "not complete", and submits a second Job.
- Sequence 3: A loses the lease but its STS credentials stay valid for up to an hour (minimum 15 minutes, not individually revocable). "Stop work immediately" is voluntary.
- Fix:
  - Add a `lease_epoch`, incremented on every claim, and condition every Ledger write on it.
  - The holder self-fences on its monotonic clock: no side-effecting step unless the last successful renewal is younger than lease minus margin.
  - Carry the epoch into side effects: deterministic Job names per task and step so B adopts rather than duplicates, an epoch label for cleanup, and the Terraform state lock.
  - State the real guarantee: one Ledger owner, at-least-once execution, idempotent steps.

**F4. Owner identity is a self-asserted string, and half the writes are unspecified.**
- `lease_holder = session_id` proves nothing. IAM can restrict attribute names, not values, so any session with `UpdateItem` can heartbeat, release or complete as another session.
- Session IDs are not unique per process: resume or fork, and sub-agents sharing the parent's ID.
- `heartbeat()` checks neither state nor epoch.
- `create()`, `complete()`, `fail()`, force-release and abandon have no pseudo-code. An unconditional `create()` on a deterministic ID like `cb-2026w47-lane2` overwrites a live record.
- SDK retry after a lost response: the claim succeeded, the retry gets `ConditionalCheckFailed`, and the caller concludes it lost. The task is held by a session that does not know it.
- Fix: a random per-claim lease token, `ReturnValuesOnConditionCheckFailure` to detect "it was me", and `attribute_not_exists(task_id)` on create.

**F5. The `Stop` hook wiring releases a live lease.** In Claude Code, `Stop` fires when the agent finishes a response turn, not when the session ends. Wiring it to `release()` hands the task back after every turn while the session and its background shells are still running. `SessionEnd` with reason `clear` has the same shape. This creates double execution.
- Fix: put the lease in a supervisor (`handoff run -- claude …`) that claims, heartbeats, kills the child on lease loss and releases on exit. For interactive sessions add a `PreToolUse` guard that blocks tool calls when the local lease deadline has passed.

**F6. Permission scoping is advisory.**
- The session policy is passed by the claimant in its own `AssumeRole` call. A principal that can assume the role with the task's policy can assume it with none and get the full per-kind union. It can also skip the Ledger and use its base credentials (the maintainer's on the Mac, `AdministratorAccess` on the runner).
- `permissions` is written by whoever creates or edits the record, including an AI. Session X can write role, policy, `secrets_refs`, queue and steps into a task that honest session B, on a wider base identity, picks up at `reap`. That is a confused deputy and a prompt-injection channel.
- Kubernetes is not narrowed at all. EKS maps the role ARN to RBAC; a session policy does not change the cluster identity.
- `github_scopes` is enforced by nothing. The SSM token has whatever scopes it has.
- Fix: a credential broker (a small IAM-authenticated Lambda; no standing compute, reachable identically from Mac, EC2 and pod).
  - AI base principals may only invoke the broker and read the Ledger.
  - The broker performs state transitions, binds the lease to the caller's IAM identity, and vends credentials from maintainer-owned permission profiles.
  - It vends STS with the profile's policy, a GitHub App installation token restricted to the declared permissions and repositories, and a per-kind role bound to namespace-scoped RBAC.
  - The RFC's "exactly one primitive, nothing else" claim is what has to give.

**F7. Role chaining does not intersect session policies (factual error and escalation).** A chained `AssumeRole` yields the target role's policies intersected with the policy passed in that call. The parent's session policy only decides whether the call is allowed. Once `sts:AssumeRole` is allowed, the child can pass no policy and hold more than the parent.
- Fix: sub-tasks are child records and the broker mints the child policy as the parent policy plus explicit Deny statements, which is provably narrower.

**F8. The human Go is forgeable or bypassable in several ways.**
1. `human_go.plan_hash = current_plan_hash`: the record has no plan and no plan-hash attribute, so the right-hand side is a claimant-supplied value. Copy the stored hash and the check is a tautology.
2. `requires_human_go` is AI-writable and AI-set at creation. Set it to `false` and the gate is gone.
3. Nothing defines what the hash covers. `permissions`, `resource_binding`, `steps`, budgets and `max_retries` can be edited after the Go and nothing re-hashes.
4. Approval race: the maintainer reviews plan P1 with `handoff show`; an AI edits to P2; `grant-go <id>` approves whatever is current. The Go write is unconditional.
5. The "maintainer's principal" is reachable. On the Mac the AI session runs with the maintainer's credentials and can run `handoff grant-go` itself. The admin runner can remove the Deny or assume anything.
6. `PutItem`, `DeleteItem`, `BatchWriteItem` and transactional puts replace or delete whole items. AWS's own fine-grained-access guidance excludes them for this reason. Delete and recreate with `requires_human_go=false` is one route; an AI-set `ttl` is another, since TTL deletes are performed by the service.
7. Post-claim invalidation is a convention ("must treat… as awaiting_approval"). The RFC itself says a convention is not a gate.
- Fix:
  - Store plans as immutable, content-addressed items containing permissions, binding, budgets and steps.
  - The Go names `task_id`, plan hash and an expiry, and is written with a condition on the hash the maintainer reviewed (`grant-go <id> --plan-hash <h>`).
  - The Go is produced by something the AI cannot exercise: an MFA-gated role or a hardware-backed signature.
  - The broker verifies it at vend time and at every renewal.
  - Put Ledger, broker and approval in an account where no AI task holds admin.

**F9. The name-only Kueue link means Ledger outcomes stop nothing in the cluster.** Abandon, timebox, failure and takeover change a DynamoDB row. The Workloads keep their quota and nodes.
- Kueue's `maximumExecutionTimeSeconds` is in the RFC's own Facts table and unused. It is the one timebox that works with every session dead.
- `AdmissionCheck`, Kueue's sanctioned external gate, is never considered as the fence. At minimum the RFC should say why not.

**F10. Timers and counters do not work.**
- There is no `claimed_at`, so "claim time plus timebox" is uncomputable.
- The timebox resets on every claim.
- Only timebox release and `failed` increment `retry_count`. Crash, expire, re-claim loops forever.
- All counters and budgets are AI-writable.
- The reaper runs only when a session starts. The scheduled one is "optional".
- Fix: count attempts in `claim()` itself (`attempt < max_attempts` in the condition), set an absolute `deadline_at` at approval, and make the scheduled reaper with a push notification mandatory for capacity-bound tasks.

**F11. Evidence is fragile.**
- It is attached only at `release()`/`complete()`. A crash or timebox release records nothing.
- A deposed holder's release fails its condition and its evidence is dropped.
- `list_append` fails if the attribute is absent, inside a 1.5 s no-retry hook.
- Any writer can `SET evidence = :x` and overwrite the list.
- URLs are mutable keys with no version ID or digest.
- `ttl` deletes the record, and the list is bounded by the 400 KB item limit.
- Completion is self-certified.

## 2. Use case by use case

**UC1, hand the Capacity Block and evidence from A to B: fails.**
- The lease move works only on graceful release (F1).
- "Kueue was never holding A's seat" is correct, and it means nothing is handed over. Between lane 1 finishing and B's submission the quota is free, so any other Workload in that ClusterQueue or cohort can take the block, and Karpenter may consolidate the empty nodes. This needs a dedicated ClusterQueue for the block with no lending, or reserved priority.
- If A crashes mid-lane, F3 sequence 2 puts two Jobs on one block.
- Evidence: lane 2 is its own task (`cb-2026w47-lane2`) with no `depends_on` or predecessor field, so "B reads A's evidence list" has no defined record to read. F11 applies.
- The record carries the block ID but not its end time.
- Experiment 5, the only test of this use case, is deferred.

**UC2, crash or hook never fires: fails.**
- F1 means the task stays stuck in `claimed` forever.
- Once that is fixed, F2 and F3 give double execution, and partial evidence is lost (F11).
- Detection needs another session to start. A crash at 01:00 with no session until 09:00 idles a paid block for eight hours unnoticed.

**UC3, two agents race: holds for the simple case.**
- A `pending` task with two distinct claimants resolves to one winner. That part is sound.
- Holes: forged or shared session IDs, create-overwrite and retry ambiguity (F4).
- The post-claim read must come from the claim's `ALL_NEW` return or a consistent read, or the winner can act on stale `steps`.

**UC4, human Go, no self-approval: fails.** F8 items 1, 2, 5 and 6 each independently let an AI session get a task treated as approved. The gate also guards only `claim()`; a session that skips the Ledger is not gated (F6).

**UC5, claimant gets only the declared scope; secrets never in the record: fails.**
- The scope is self-applied for AWS and unenforced for Kubernetes and GitHub (F6).
- Secret values are correctly kept out of the record. But `secrets_refs` is AI-authored, and evidence logs (Terraform output, environment dumps) are an unguarded exfiltration path readable by every session.
- Session policies are capped at 2,048 characters inline plus a packed-size limit, which "least-privilege JSON" for a verify run may not fit.

**UC6, partial work and resumability: partial.**
- Checking the effect rather than the `status` field is the right instinct.
- Check-then-act is not atomic across overlapping owners (F3). Prefer natively idempotent operations: deterministic names, client tokens, state locks.
- A Terraform state lock held by a crashed A blocks B until a manual `force-unlock`. This is a stuck path specific to this repo.
- "Done" cannot be enforced by a DynamoDB condition and the schema has no acceptance-criteria field, so `completed` is whatever the session writes.
- There is no handoff note or working-state pointer. Uncommitted work in A's Mac worktree is unreachable from EC2. Require a push to a task branch at each checkpoint and record the SHA.

**UC7, cost and time boxes; a block ending: fails.**
- F10 covers the timebox and retry problems.
- `max_cost_usd` is a self-computed estimate, per attempt or per task unspecified.
- "A block ending" is not addressed anywhere in Decision 9. As I recall, EC2 begins terminating Capacity Block instances about 30 minutes before the end, with an EventBridge warning shortly before that. Verify this.
- Needed: a claim-time check that `now + timebox` fits before block end minus margin, an evidence flush before termination, and a notification.
- A block is prepaid, so the cost failure there is idle time, not continued spend. The RFC does not distinguish this from `light` capacity, where stopping does save money.

**UC8, audit: partial.**
- `by` and `at` are client-supplied; there is no server-side timestamp.
- CloudTrail does not record DynamoDB item-level calls by default. They are data events that must be enabled, are not returned by `LookupEvents`, and I believe redact non-key values.
- Stream fan-out needs a Lambda or Pipe and loses records after 24 hours if the consumer is broken.
- Sessions on one box share a role session name. Require `sts:RoleSessionName` or source identity equal to the lease token.

**UC9, one place to see and steer: partial.**
- There is `list`, `show` and `grant-go`, but no cancel, deny, force-release, reassign, pause or abandon. That is viewing, not steering.
- It is pull-only. Nothing tells the maintainer a task is stalled, awaiting a Go, or abandoned.
- `grant-go` "usable identically from… EC2 or a pod" is exactly what must not be true (F8.5).
- The dashboard renders untrusted task text and must escape it.
- The GitHub "view" has no designed writer.

**UC10, Mac, EC2, in-cluster pods: partial.**
- Reachability holds. Trust does not: the three environments hold very different base credentials (F6), and trust policies are unspecified.
- A laptop that sleeps is structurally a bad heartbeater.
- Per the RFC's own facts, headless `claude -p` kills async hooks at teardown. The supervisor in F5 is the cross-environment answer.

**UC11, deliberately paused session must not be treated as stalled: fails, by redefinition.**
- The RFC declares that a suspended session being taken over "is a feature". That is the opposite of the requirement, and a resumed session then double-executes (F3).
- "Still heartbeats on its own schedule" has no designed mechanism. Hooks fire on events, not timers, so this needs a separate process.
- A daemon heartbeat then makes a dead or idle agent look healthy for hours while holding a block.
- Needed: an explicit `park()` (checkpoint, state `parked`, resume by fresh conditional claim), a `progress_at` separate from `heartbeat_at`, and a cap on parking capacity-bound tasks.

**UC12, plan changes after Go: fails.**
- F8 items 1, 3, 4 and 7 apply. The lease holder can edit the plan itself and continue.
- The state machine has no `claimed → awaiting_approval` edge.
- A cooperative holder that releases leaves the task `pending` but unclaimable, which is a silent stuck state.

**UC13, sub-agent narrower than parent: fails.**
- F7 makes chaining an escalation path, not a narrowing.
- In-process sub-agents share the parent's environment and credentials. STS narrowing applies only to sub-agents launched as separate processes.

**UC14, Ledger not a forgeable side channel: fails.**
- Approval forgery is F8. Permission forgery by record authorship is F6.
- Free-text `steps` and `evidence` are instructions to the next LLM session.
- Evidence can leak secrets (UC5).
- Sound part: no credential values are stored.

**UC15, abandoned tasks stop consuming capacity: fails.**
- A crash loop never reaches `max_retries` (F10).
- A never-claimed task has no clock: "timebox exceeded with nobody claiming" is undefined and needs a reaper to run.
- A wrong-capability claimant can burn all retries.
- `failed` with retries exhausted has no outgoing edge.
- `abandoned` deletes no Workload (F9).

## 3. Adversarial angles, indexed

| Angle | Sequences found | Use cases |
| --- | --- | --- |
| Double execution | Clock skew (F2); pause, sleep, long tool call (F3); orphan Job plus resubmission (F3); credentials outliving lease (F3); `Stop` hook release (F5); shared or forged session ID (F4); timebox release not stopping the holder (F9) | 1, 2, 3, 6, 7, 11 |
| Stuck tasks | Expired `claimed` unclaimable (F1); unknowing holder after SDK retry (F4); zombie heartbeat with no `claimed_at` (F10); `pending` with stale Go; `awaiting_approval` with no deadline or notification; missing `requires_human_go` fails closed silently; Terraform lock; `failed` with no exit | 2, 4, 6, 11, 12, 15 |
| Privilege escalation | Self-applied session policy and base credentials (F6); AI-authored or edited `permissions`, queue and `secrets_refs` consumed by another session (F6); role chaining (F7); Kubernetes and GitHub unscoped (F6); admin runner | 5, 10, 13, 14 |
| Approval bypass | Tautological hash; writable `requires_human_go`; unhashed fields; review/grant race; reachable maintainer principal; whole-item writes and TTL; unenforced mid-flight invalidation (all F8) | 4, 12, 14 |
| Lost evidence | Release-only attachment; dropped deposed-holder evidence; `list_append` failure; overwrite; mutable URLs; TTL; node logs gone at block end; no lane linkage (F11, UC1, UC7) | 1, 2, 6, 7, 8 |

## 4. Factual check, separate from design gaps

| Claim in the RFC | Assessment |
| --- | --- |
| A second `AssumeRole` session policy "intersects with the first automatically" | Wrong (F7). |
| Effective permission is "provably the intersection… auditable from the task record alone" | Only if the caller chooses to pass that policy; nothing forces it. |
| `lease_expiry < now()` evaluated by DynamoDB; writes carry a "server-side timestamp" | Wrong. DynamoDB supplies neither. |
| DynamoDB's conditional write "does not need to disclaim" fencing | Wrong for side effects. Correct only for the Ledger row. |
| CloudTrail "records… every DynamoDB API call" | Wrong by default. Data events are opt-in and not in `LookupEvents`. |
| Stream "straight to CloudWatch Logs" | Needs a Lambda or EventBridge Pipe; 24-hour retention. |
| `dynamodb:Attributes` makes `human_go` AI-unwritable on `PutItem`/`UpdateItem` | The key is real. It covers names, not values; I believe it works at top-level-attribute granularity. It only holds if `PutItem`, `DeleteItem`, batch and transactional writes are denied; I could not confirm PartiQL coverage, so deny that too. Test nested paths, expression attribute names and `REMOVE`. |
| `Stop` hook as a graceful-exit signal | Wrong: it is per-turn (F5). |
| `Notification` hook forwards "a task stalled" | It fires on Claude Code's own notifications, not Ledger events. |
| `SessionEnd` timeout "raisable per-hook to 60s" | Unverified. I recall the 1.5 s default being changed by an environment variable. |
| Lock client stores relative duration only | Correct, and the schema contradicts it. |
| Kueue fields, `labelKeysToCopy`, MultiKueue, admission conditions | Consistent with what I know; recent fields are version-dependent. "A Cohort's lifetime" is not a Kueue concept. |
| "Argo Workflows… (Facts checked)" | No Argo row exists in either Facts table. |
| "Tested directly in the prototype (Verification, scenario 2/4)" | No Verification section exists, only "Experiments needed". Asserted as done; not evidenced. |
| State names "deliberately echo" A2A | They do not (`pending`/`claimed` against `submitted`/`working`; no `input-required`). |
| MCP spec `2026-07-28`, A2A and framework survey, `SessionEnd` reason enum | Cannot verify at that date. The enum matches my recollection. |

## 5. Do the five chosen design elements hold?

- **DynamoDB conditional writes as Ledger:** yes as the atomicity primitive. No as the whole mechanism: it needs the epoch, a shared time basis, and a trusted writer.
- **Kueue untouched, linked by name:** holds for ownership. Fails for "hand over the block" and "stop consuming capacity" (F9, UC1).
- **Hooks as accelerant:** the principle holds. The specific wiring is harmful (F5).
- **STS session policies for per-task scoping:** only behind a broker (F6). Not through chaining (F7). Not for Kubernetes or GitHub.
- **`dynamodb:Attributes` for `human_go`:** necessary but nowhere near sufficient (F8).

## 6. Minimum changes for approval

1. Fix `claim()` (F1) and add `lease_epoch`, a time basis and holder self-fencing (F2, F3). Restate the guarantee honestly.
2. Specify every write with conditions, and replace `session_id` with a per-claim token (F4).
3. Move the lease into a supervisor and drop the `Stop` wiring (F5).
4. Add the broker. If the maintainer refuses any new component, relabel UC5, 13 and 14 as cooperative, not enforced. Delete the chaining claim (F6, F7).
5. Redesign the Go as in F8: immutable hashed plan, conditional grant, non-AI-exercisable approval, separate account.
6. Bind Ledger outcomes to Kueue: deterministic names, epoch labels, `maximumExecutionTimeSeconds`, cleanup on takeover and abandon, a dedicated queue for the block, and block-end handling (F9, UC1, UC7).
7. Make timers real (F10) and add `park()` (UC11).
8. Per-step, append-only, digest-pinned evidence with a deterministic prefix per task and attempt. Results are written by the Job's identity, not the reporting session. Remove `ttl` from live records (F11).
9. Add experiments for sleep and resume, clock skew, orphan Job adoption, the review/grant race, whole-item write paths, chaining, and UC1 on a live cell. Acceptance criteria currently cover only UC2–5, 12 and 14.

VERDICT: CHANGES NEEDED