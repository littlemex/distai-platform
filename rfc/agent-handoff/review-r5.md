# Round 5 review: RFC "Task handoff between AI agent sessions"

**Bottom line.** Not yet approvable. The `claim()` rewrite does what round 4 asked: D1, D3, P1, P2, P3, P4 and P7 are fixed in code, and D2 is fixed in code but not in Decision 9's prose. This round's edits introduce three new defects: a `create()` retry that resets a live task, a reaper that takes ownership of what it scans, and a maintainer `replan()` with no state guard. The reaper defect follows from my own round-4 instruction, which did not say what happens when the reaper's claim succeeds. D4 is only one-third done.

## 1. D1–D4 and P1–P7 against the text

| Item | Status | What remains |
| --- | --- | --- |
| D1 | **Fixed** | Decision 9 now matches the code, and `reap()` is stated to have no transition. The residual-risks bullet still says "the deadline folded into `heartbeat()`". |
| D2 | **Fixed in code, not in prose** | `charge` excludes `parked`. Decision 9 still says `attempt_count` increments "on a takeover from a stale `claimed`/`parked` state". Decision 3 and the acceptance criterion still say "`failed -> pending` retry". B2 below breaks this again in practice. |
| D3 | **Fixed, one condition missing** | See B5. |
| D4 | **Partly fixed** | The stored-deadline check is in `claim()`. The other two-thirds are still prose only; see B3. |
| P1 | **Fixed** | State is checked before `owned`, and `ALREADY_OWNED` returns after the hash, policy and Go checks. |
| P2 | **Fixed** | The stale comment under the wait block still mentions `is_takeover` and a fall-through. A version change actually restarts the clock and returns `WAIT`. |
| P3 | **Fixed** | The diagram lacks the `pending`, `failed` and `parked` → `awaiting_approval` edges. |
| P4 | **Fixed** | Side effect: a holder whose step ends just past the deadline can no longer append. State that its final evidence goes through `release()` or `fail()`, which have no deadline check. |
| P5 | **Mostly fixed** | See B4. |
| P6 | **Mostly fixed** | See S1. |
| P7 | **Fixed in substance** | See S2. |

## 2. Blocking findings

**B1. A `create()` retry resets the live task.**
- The task `Put` condition is `attribute_not_exists(task_id) OR plan_ref matches`. When the second half is true, the `Put` succeeds and replaces the whole item. It is not a no-op.
- The replaced item has `version: 0`, `attempt_count: 0`, and no `lease_holder_hash`, `deadline_at`, `evidence` or `human_go`.
- The plan hash is deterministic from `kind`, profile and binding, so any allow-listed session can reproduce it for any `task_id`.
- Consequences:
  - A live holder's task becomes `pending` and claimable with no wait (double execution).
  - A `completed` task re-runs.
  - The deadline and retry budget reset (use case 15).
  - Evidence is wiped.
- Fix: keep the condition as `attribute_not_exists(task_id)`. On cancellation, `GetItem`; if the existing `plan_ref` matches, return success and write nothing.
- `create_child` inherits this, since it "proceeds as `create()`".

**B2. The reaper becomes the holder of everything it reaps.**
- `reap()` calls the real `claim()` with its own token. Once the wait elapses the claim succeeds.
- The reaper then holds the lease, is issued work credentials for the task's profile, and never heartbeats.
- The next scan finds its own claim stale and takes over again, charging another attempt. With `max_retries: 2` and a 600-second lease, an unattended crashed task is `abandoned` after about three wait-plus-scan cycles, roughly 45 minutes. `abandoned` is terminal, so use case 2 fails for exactly the tasks that have the mandatory reaper.
- A `parked` task is taken by the reaper without charge, then cycles the same way. The original session's resume is then a charged takeover of a `claimed` task. This breaks use case 11 and the park/resume acceptance criterion.
- The `SessionStart` `handoff reap` has the same shape: a new session would claim every stale task it sees.
- Fix: give the reaper its own broker action that shares `claim()`'s checks but never writes ownership:

```
sweep(task_id):                       # reaper principal; mints nothing, never owns
  terminal or awaiting_approval       -> skip
  past effective deadline             -> abandon
  claimed/parked: start or read the wait clock; not elapsed -> return
  claimed, elapsed, attempt_count >= max_retries -> abandon (version-conditioned)
  otherwise -> notify "reclaimable"; write nothing
```

- Also add `failed` to the scan, or a never-retried `failed` task is never abandoned.

**B3. A never-claimed task has no deadline in code (the rest of D4).**
- `claim()` checks `deadline_at (if set)`, and `deadline_at` is set only at first claim. The `created_at + timebox_minutes` rule in Decisions 2 and 9 is not implemented.
- `reap()` selects "`pending` and `deadline_at` has passed", which is never true for an unclaimed task. If it were selected, `claim()` would skip the check and claim it with a fresh full timebox.
- `pending → abandoned` therefore never fires. A `pending` child whose parent has completed is stuck forever.
- Fix: `deadline = item.deadline_at if set else item.created_at + plan.timebox_minutes`. Decide whether time spent in `awaiting_approval` counts. If it does, a task approved the next morning is abandoned on its first claim.
- The Capacity Block cap on `deadline_at` and the `max_cost_usd` gate are still in no code. Either add them to `claim()` or say "not enforced in v1".

**B4. The maintainer path of `replan()` has no state guard.**
- It never reads `item`, yet its condition uses `:item.version`.
- It accepts a `completed` or `abandoned` task and sets it to `pending`. The `ttl` stays set, so DynamoDB deletes the revived task mid-flight.
- On a live `claimed` task with a no-approval kind it writes `pending` immediately. That is the instant-claimable shape Decision 4 refuses for `force_release()`.
- Decision 6 item 6 says a replan "forces `state: awaiting_approval`", but the code does not for no-approval kinds. Its signature there also differs from the pseudocode.
- Fix:
  - Read the item in both paths and reject terminal states.
  - For a maintainer replan of a `claimed`/`parked` task, clear the hash but keep the state, as `force_release()` does.
  - Also remove `human_go`.

**B5. The retries-exhausted `abandon()` is not conditioned on version.**
- My skeleton had "conditional on version"; the text dropped it. `abandon()` only checks that the state is not terminal.
- If the holder heartbeats or releases between the claimant's read and its `abandon()`, a live or gracefully released task is abandoned.
- Fix: pass the expected version on this path. The deadline path does not need it.

## 3. One-sentence clarifications still needed

- **S1 (P6).**
  - "The maintainer" is not defined for `abandon` and `force_release`. On the Mac the AI runs under the maintainer's own credentials, as Decision 6 itself notes, so name the route. The MFA-gated endpoint is the obvious one.
  - `force_release` is called "maintainer-only" and "same restricted callers as `abandon()`", which includes the reaper. Pick one.
  - With `sweep`, the reaper needs no external `abandon` right.
- **S2 (P7).**
  - State where the child check sits in `claim()`: after the deadline check, before the `ALREADY_OWNED` return.
  - `replan()` on a child builds a plan without `parent_task_id`, which silently drops the re-check. Preserve it or forbid replanning a child.
- **S3.** `KIND_POLICY[item.plan.kind]` is dereferenced with no check for a removed kind.

## 4. Smaller leftovers, not blocking

- **Stale prose and formatting.**
  - The code fences around the Decision 4 pseudocode are inverted: the round-3 history paragraph is fenced and the code is not.
  - Decision 4 says the `abandon`/`force_release`/`replan` pseudocode is "in Decision 5's own action list below". It is above, in Decision 4.
  - The "without exception" action list omits `replan` and `RenewWorkCredentials`.
  - Decision 5 still says work credentials are "never valid past" a lost lease or Go. An issued set lasts up to an hour.
  - Decision 9 says a block ending forces "an evidence flush and release", but the mechanism is now `abandon`.
- **Code gaps.**
  - The `AppendEvidence` write has no state condition.
  - Evidence trimming still has no code.
  - Workload cleanup is assigned to "the reaper", but `abandon` now also happens inside any session's `claim()`.
  - Say that `ALREADY_OWNED` returns credentials.
  - A stale `claimed` task moved to `awaiting_approval` by the Go check is never charged for the crash.
  - A child's `kind`, and whether it needs its own Go, is still unspecified.
- **Experiment 1** still detects a retry via `ReturnValuesOnConditionCheckFailure`. The `owned` check now does that.

## 5. What closes this

1. Replace the `create()` task condition with read-on-cancel (B1).
2. Replace `reap()`'s call to `claim()` with `sweep` (B2).
3. Compute the effective deadline for unclaimed tasks, and resolve the block cap and cost gate (B3).
4. Add the read, terminal-state guard and keep-state rule to `replan()`'s maintainer path, and align Decision 6 item 6 (B4).
5. Condition the retries-exhausted `abandon()` on version (B5).
6. Fix the Decision 9 "`claimed`/`parked`" sentence (D2) and add S1–S3.

These are all line-level edits. With them in the text I would approve, with experiments 1–4 as the gate before first use. Add two cases to experiment 2: a `create()` retry against a claimed task, and a reaper scan over a crashed task and a parked task.

VERDICT: CHANGES NEEDED