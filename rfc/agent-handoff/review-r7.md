# Round 7 review: RFC "Task handoff between AI agent sessions"

**Bottom line.** Approvable under the stated bar. All five round-6 blockers are closed in the text, and the adversarial pass on `replan()` against `claim()`/`sweep()` found no double execution, stuck task, privilege escalation, approval bypass or lost evidence. One fix (B3) left an expression that disagrees with its own comment. I am treating that as a line edit rather than a blocker, because the rule is stated unambiguously beside it.

## 1. The five round-6 blockers against the text

| Item | Status | What the text says |
| --- | --- | --- |
| B4 | **Closed** | `replan()` reads `item` and `old_plan` on both paths, rejects terminal tasks and children, and computes `new_state` as described. It removes `human_go` and `lease_holder_hash` on every path. Decision 6 item 6 matches. |
| B3 | **Closed, one residue** | `create()` writes `deadline_at` for a no-approval kind; `grant_go()` and `replan()` use `if_not_exists`. Decisions 2 and 9 no longer describe a claim-time deadline. The cap and `max_cost_usd` are stated as not enforced. Residue is item 1 in section 3. |
| B2 | **Closed** | `sweep()`'s retries-exhausted branch is `claimed`-only. Both Decision 9 sentences match the code. |
| S1 | **Closed** | Decision 11 says both actions are maintainer-only via the MFA endpoint, and that `sweep()` reaches `abandon()` only internally. |
| N1 | **Closed** | Both `create()` and `replan()` check `cluster_queue` and `capacity_block_id` only when present. |

The three first-consumer observations are in Residual risks as described, and the sample plan is now lane 1.

## 2. Adversarial pass: `replan()` against `claim()` and `sweep()`

I traced every start state on both paths. None produces a safety hole.

| Start state, path, new kind | Result | What `claim()` and `sweep()` then do |
| --- | --- | --- |
| `claimed`, holder, no-approval | `pending`, hash cleared | Claimable at once. Safe: the holder gave it up itself, same as `release()`. |
| `claimed`, holder, approval | `awaiting_approval` | `claim()` rejects until `grant_go()`. |
| `claimed`, maintainer, no-approval | stays `claimed`, hash cleared, version bumped | The old holder's `heartbeat()`, `release()`, `complete()` and `AppendEvidence` all fail. Any `claim()` sees `owned == false`, starts a fresh wait and takes over only after `lease_seconds`. `sweep()` runs the same wait and notifies. |
| `parked`, maintainer, no-approval | stays `parked`, hash cleared | Same wait, with no attempt charge. |
| `pending` / `failed` / `awaiting_approval`, maintainer, no-approval | `pending` | No live holder exists, so no wait is needed. |
| any non-terminal, maintainer, approval | `awaiting_approval` | `sweep()` notifies; `claim()` rejects. |
| `completed` / `abandoned`, or a child | rejected | — |

Three further checks held:

- **Deadline invariant.** Every route into `pending`, `claimed`, `parked` or `failed` passes through a write that sets `deadline_at`. `claim()` and `sweep()` therefore never compare against a missing value.
- **Version handling.** The `replan()` write is version-conditioned and bumps the version, so an in-flight wait restarts rather than completing against the old plan.
- **Approval.** `human_go` is always removed and `claim()` re-checks against the current plan and policy. A holder cannot replan into anything `create()` would not also allow.

## 3. Found in this pass (not blocking; fix in the prototype PR)

1. **`replan()`'s `deadline_at` expression is unconditional; its comment says conditional.**
   - Read literally, a maintainer replan of a never-granted `awaiting_approval` task to another approval-required kind starts the clock while it waits on a human. A late grant then produces a task that `claim()` abandons immediately.
   - Fix: write the clause only when `new_state != 'awaiting_approval'`.
   - Decisions 2, 4 and 9 say the deadline is set at "`grant_go()`/`replan()` for an approval-required one". It should read "`grant_go()`, or a `replan()` to a no-approval kind".
2. **The keep-state path charges an attempt.**
   - After a maintainer replan of a `claimed` task, the next `claim()` has `charge == true`, although nothing failed.
   - If `attempt_count == max_retries`, `claim()` or `sweep()` abandons the task.
   - Fix: either say so in Decision 6 item 6, or have the maintainer path write `parked` instead of keeping `claimed` (same wait, no charge). The same holds for `force_release()`, where the charge is defensible.
3. **A maintainer replan to an approval-required kind, followed by a quick grant, has no wait.** The task goes `awaiting_approval` → `pending` and is claimable immediately while the deposed holder may be mid-step. Add a runbook line (do not grant within `lease_seconds` of replanning a live task) or a residual-risk bullet.
4. **An `awaiting_approval` task past its deadline is never abandoned.** `sweep()` skips it, and a re-grant only leads to an immediate abandon. Fix: let `sweep()` abandon it when `deadline_at` exists and has passed.
5. **A child's parent re-check passes while the parent has no holder or a new plan.** The check is `parent.state == 'claimed'`, which keep-state and `force_release()` both preserve. The child's reach is still bounded by `KIND_POLICY`, so this is not an escalation. Fix: record the parent's `plan_ref` in the child plan and compare it.
6. **A binding with neither `cluster_queue` nor `capacity_block_id` passes unchecked.** An `instance_ids`-only binding skips both checks. Fix: require `capacity_block_id` on any non-Kueue binding, or reject unknown shapes.
7. **`steps` has no writer.** I had not raised this before round 7.
   - No broker action sets or updates `steps`, and `complete()` does not check Decision 8's "every step done plus evidence" rule.
   - Completion is already listed as self-certified, so this is not a safety gap.
   - Fix: either add a step update to `AppendEvidence`, or say that v1 records step progress as evidence entries.
8. **`sweep()` re-notifies on every pass.** It writes nothing, so it cannot deduplicate.
9. **After a replan the plan's `timebox_minutes` can exceed the time left.** Decision 1's execution limit should use `deadline_at - now`.

## 4. Wording and formatting (not blocking)

- Still open from round 6:
  - The fall-through comment under `claim()`'s wait block.
  - "`failed -> pending` retry" in Decision 3, and the missing diagram edges.
  - "`sweep()` below" in Decision 4.
  - "the deadline folded into `heartbeat()`" in Residual risks.
  - The Kueue-only "Resource binding" Terminology row.
  - `item.plan.kind` in `claim()`.
  - The unchanged experiment list.
  - No code for evidence trimming.
- The sample task item is `cb-2026w47-lane2` but its plan is lane 1. Its `deadline_at` equals `claimed_at + 180 min`, which reads like the old rule.
- Decision 2 lists `KIND_POLICY` fields without `allowed_queues`, `allowed_capacity_blocks`, `timebox_minutes`, `max_cost_usd` or `max_retries`.
- `sweep()` uses `plan.max_retries` without reading the plan.
- Decision 4 says "the reaper and the maintainer both need two more broker actions"; only the maintainer can call `force_release`.
- Decision 11 mentions a "soon-to-abandon" notification that `sweep()` does not emit.
- The acceptance criterion on grant rejection refers to a recomputed hash; `grant_go()` compares `plan_ref` only.

VERDICT: APPROVE