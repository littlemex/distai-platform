# Round 6 review: RFC "Task handoff between AI agent sessions"

**Bottom line.** Not approvable yet under the stated bar. B1, B5, S2 (claim side) and S3 are closed in the text. B4's pseudocode is unchanged from round 5, B3's fix exists only in prose, B2 and S1 each leave an incompatible rule elsewhere, and the new consumer material contradicts `create()`. All fixes are line-level.

## 1. B1–B5 and S1–S3 against the text

| Item | Status | What the text actually says |
| --- | --- | --- |
| B1 | **Closed** | The task `Put` condition is `attribute_not_exists(task_id)` only. On failure it does `GetItem` and returns success with no write if `plan_ref` matches, otherwise rejects. |
| B2 | **Closed in substance, two residues** | `sweep()` never calls `claim()` and never writes `lease_holder_hash`. Residues below. |
| B3 | **Not closed** | The rule is in Decision 4's prose only. No pseudocode sets `deadline_at`, and Decisions 2 and 9 still state the old rule. |
| B4 | **Not closed** | The `replan()` pseudocode is identical to round 5. None of the described changes is in it. |
| B5 | **Closed** | `abandon()` takes `expected_version`; the retries-exhausted call sites pass it. |
| S1 | **Closed in Decision 4, contradicted in Decision 11** | See below. |
| S2 | **Closed on the claim side** | The parent check sits after the deadline check and before `owned`. The refusal to replan a child is only a comment in `create_child`; see B4. |
| S3 | **Closed** | `if current_policy is None: reject`. |

## 2. Blocking findings

**B4. `replan()` still has no read, no state guard and no keep-state rule (double execution, stuck task).**
- The maintainer path still never reads `item` but conditions on `:item.version`.
- There is still no rejection of `completed`/`abandoned`. A revived task re-runs, and its `ttl` deletes it mid-flight.
- A maintainer replan of a live `claimed` task to a no-approval kind still writes `pending`, instantly claimable.
- The child refusal is not in `replan()`.
- Decision 6 item 6 still says a replan always "forces `state: awaiting_approval`" and uses a different signature.
- Fix:

```
replan(...):
  item = GetItem task_id; plan = GetItem item.plan_ref      # both paths
  if item.state in ('completed', 'abandoned'): reject
  if plan.parent_task_id exists: reject
  if requester_proof is a client_token: <existing holder check>
  <existing policy checks and new-plan Put>
  new_state = 'awaiting_approval' if policy.requires_approval
              else item.state if (maintainer path and item.state in ('claimed','parked'))
              else 'pending'
  UpdateItem SET plan_ref, #s = new_state, version = version + 1
    REMOVE lease_holder_hash
    ConditionExpression: version = :item.version
```

**B3. `deadline_at` is never written in any pseudocode (prose and code disagree, stuck task).**
- The prose says "`create()` above now sets `deadline_at`", but the `Put` lists only `task_id, plan_ref, version, attempt_count, state, created_at`.
- `grant_go()` and `replan()` do not set it either. `claim()`, `heartbeat()`, `park()` and `sweep()` all compare against it.
- Decision 2 still says it is set "at a task's first claim" with a `created_at + timebox_minutes` fallback. Decision 9 says `deadline_at = claimed_at + timebox_minutes` and "fixed at first claim". Decision 4 explicitly rejects that fallback.
- Two cases are undefined and change behaviour:
  - **Re-grant.** A task that returns to `awaiting_approval` and is granted again either keeps its deadline or gets a fresh one. Pick one.
  - **Holder replan.** If `replan()` sets `deadline_at` unconditionally, a holder can reset its own timebox by replanning (use case 15). It must be `if_not_exists`.
- Fix:
  - Add `deadline_at: now + policy.timebox_minutes` to the `create()` `Put` when no approval is required.
  - Add it to `grant_go()`'s `SET`, with your chosen re-grant rule.
  - Add `deadline_at = if_not_exists(deadline_at, ...)` to `replan()` when the new state is not `awaiting_approval`.
  - Replace the Decision 2 and Decision 9 sentences.
- The Capacity Block cap and `max_cost_usd` gate (Decision 9) are still in no code. Add the cap to the same expression or say "not enforced in v1". This matters now that the first consumer is a block.

**B2. `sweep()` abandons parked tasks that `claim()` would resume; Decision 9 still says the reaper calls `claim()`.**
- `sweep()` applies the retries-exhausted `abandon()` to `claimed` and `parked` alike. `claim()` never charges or abandons a parked task.
- A holder that parks with `attempt_count == max_retries` is therefore abandoned by the five-minute sweep after one lease window (use case 11).
- Fix: `if item.state == 'claimed' and item.attempt_count >= plan.max_retries: abandon(...)`.
- Decision 9 still says the reaper "is only a scheduled caller of `claim()`", which is the defect B2 removed.
- Decision 9 also still says `attempt_count` increments on a takeover from a stale "`claimed`/`parked`" state (round 5's D2, closing item 6). Fix both sentences.

**S1. Decision 11 gives a different caller set.**
- It says `force_release`/`abandon` are "restricted to the reaper's own service principal or the maintainer".
- Decision 4 says `force_release` is maintainer-only and external `abandon` is maintainer-only via the MFA endpoint.
- Fix: change the Decision 11 sentence to match Decision 4.

**N1 (new material). `create()` and `replan()` cannot accept a bare-EC2 lane.**
- Both run `if resource_binding.cluster_queue not in policy.allowed_queues: reject`.
- Decision 2 and the first-consumer section say lane 2's binding has no `cluster_queue`. Decision 4 also mentions tasks "with no `resource_binding`".
- As written, lane 2's task is either rejected or passes with no policy check on which block or instances a kind may name.
- Fix: check `cluster_queue` only when present, and add the equivalent check for the other shape (for example `capacity_block_id in policy.allowed_capacity_blocks`).

## 3. The first-consumer addition

Apart from N1, I found no new contradiction. The "must not depend on this mechanism" posture is consistent with the rest of the design. These three points are not wording, but I am not blocking on them:

- **Lane 2's deadline clock.** Under the new rule a no-approval lane-2 task created at block start burns its timebox while lane 1 runs. Say that lane 2's task is created when lane 1 completes, or make its kind approval-required.
- **Double execution on bare EC2.** Decision 1's protections (same-name Job adoption, `maximumExecutionTimeSeconds`, Workload cleanup) are Kueue-only. For lane 2, a dead session's experiment can keep running on the instance while a takeover starts a second copy. Name the equivalent (for example a lock or unit name keyed `task_id-step_id`) or add a residual-risk bullet.
- **Resource exclusivity.** Kueue arbitrates lane 1's resource. Nothing does for lane 2: two tasks with different `task_id`s can bind the same instances. State this as a limit.

Smaller, also not blocking:

- `sweep()` only notifies for a `failed` task with exhausted retries. The deadline eventually abandons it, but "reclaimable" is wrong.
- Decision 11 says the reaper notifies on awaiting-approval tasks; `sweep()` skips them.

## 4. Wording and formatting (not blocking)

- The comment under `claim()`'s wait block still describes a fall-through on version change; the code restarts the clock.
- Decision 3 still says "`failed -> pending` retry". The diagram lacks the `pending`/`failed`/`parked` → `awaiting_approval` edges.
- Decision 4 says "`sweep()` below" and "reaper fix, below"; both are above.
- Decision 2 says "First real consumer below"; it is in Decision 1.
- Residual risks still says "the deadline folded into `heartbeat()`".
- The sample plan item shows lane 2 with a `cluster_queue`. The Terminology row for "Resource binding" is still Kueue-only.
- `claim()` uses `item.plan.kind` where `plan.kind` is meant. The plan item's key in a table partitioned by `task_id` is unstated.
- Experiment 1 still detects a retry via `ReturnValuesOnConditionCheckFailure`. The two experiment-2 cases from round 5 (a `create()` retry against a claimed task; a sweep over a crashed and a parked task) are not added.
- Evidence trimming still has no code.

## 5. What closes this

1. Rewrite `replan()` per the B4 skeleton and align Decision 6 item 6.
2. Write `deadline_at` in `create()`, `grant_go()` and `replan()`; fix Decisions 2 and 9; resolve the block cap.
3. Restrict `sweep()`'s retries-exhausted branch to `claimed`; fix the two Decision 9 sentences.
4. Fix the Decision 11 caller sentence.
5. Make the `resource_binding` check in `create()`/`replan()` shape-aware.

With these five in the text I would approve.

VERDICT: BLOCK — B4, B3, B2, S1, N1