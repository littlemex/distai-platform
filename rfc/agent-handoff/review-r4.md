# Round 4 review: RFC "Task handoff between AI agent sessions"

**Bottom line.** Round 4 is not yet approvable. Decision 9 still contains the sentence that R5 was about, and the new `claim()` charges an attempt on every park/resume, which contradicts Decisions 3 and 9 and one acceptance criterion. The adversarial pass also found five defects in the new pseudo-code. All of it is line-level editing with no new architecture.

Your list of eight follows my round-2 numbering, not section 6. I have answered against section 6, as you asked, and folded your claims in.

## 1. Section 6 items, one by one

| # | Item | Status | What remains |
| --- | --- | --- | --- |
| 1 | Pseudo-code for missing transitions; every write bumps `version` | **PARTIALLY FIXED** | `complete`, `fail`, `park`, `abandon`, `force_release`, `grant_go`, `AppendEvidence` and `create_child` are written. `replan()` and `reap()` are prose only. The version rule is stated, but the scratch write in `claim()` breaks it (P2). |
| 2 | Two-observation takeover; client-generated token | **FIXED in structure** | Two defects in the code (P1, P2). |
| 3 | `claim()` checks Go, expiry and current policy; cap only where an attempt is charged | **PARTIALLY FIXED** | Go, expiry and the policy re-read are in. The cap and the charge both apply to `parked` (D2). An expired Go cannot be renewed (P3). |
| 4 | One path for maintainer and reaper writes; MFA point; break-glass | **MOSTLY FIXED** | The MFA-gated `grant_go` endpoint is right. Who may call `abandon` and `force_release` is not stated (P6). The break-glass path is still the broker; say whether it is a separate function. |
| 5 | No live holder's task becomes instantly claimable | **NOT FIXED in text** | `force_release()` and `heartbeat()` are right. Decision 9 still says the opposite (D1). |
| 6 | Renewal that re-checks lease and Go | **FIXED** | One overclaim: credentials are never *renewed* past a lost lease or Go, but an issued set stays valid for up to an hour. |
| 7 | Who may change a plan; parent-lease proof for children | **PARTIALLY FIXED** | The rule is stated and `create_child` checks the parent's token. `replan()` has no code (P5). A child is not tied to its parent after creation (P7). |
| 8 | Text fixes | **MOSTLY FIXED** | Overclaim bullet, boundary, "Breaking changes" and the retry criterion are fixed. `create()` is half-fixed: a retry with the same `task_id` still fails the task `Put`. Experiment 1 still detects retries via `ReturnValuesOnConditionCheckFailure`. "N11" is still cited. |

## 2. Decision 9 against the code

**D1. The reaper still bounces a healthy holder to `pending`.**
- Decision 9 says the reaper moves "a healthy but overdue `claimed` task back to `pending` (consuming one attempt)".
- The `heartbeat()` comment says the deadline is enforced there, "never through a shortcut to `pending`".
- With no `reap()` pseudo-code, an implementer will build whichever one they read first. This is R5, unchanged in the prose.

**D2. Park/resume is charged.**
- Decisions 3 and 9 and the acceptance criterion all say park-then-resume never increments `attempt_count`.
- `claim()` sets `is_takeover = True` for `state in ('claimed', 'parked')`, so every resume increments it.
- The cap then rejects a resume at `max_retries`. A deliberately paused task at the cap is stuck (use case 11).
- Decision 9 also contradicts itself: it charges "a takeover from a stale `claimed`/`parked` state" in the same sentence.

**D3. Exhausted takeover.**
- Decision 3 says a takeover that finds the cap reached surfaces the task as `abandoned`. `claim()` only rejects, and the task stays `claimed`.
- `abandon()` is "called by the reaper once `attempt_count >= max_retries` is observed", with no staleness condition.
- A holder on its last permitted attempt has exactly that count. As written, the reaper abandons live work.

**D4. Deadline rules that exist only in prose.**
- `claim()` never checks `deadline_at`. An overdue task is still claimed, charged and issued credentials before its first heartbeat fails. That repeats until attempts run out.
- The Capacity Block cap on `deadline_at` and the `created_at + timebox` rule for unclaimed tasks appear in no code or schema.
- The `max_cost_usd` gate "at claim time" is also not in `claim()`.

## 3. Defects in the pseudo-code

**P1. `ALREADY_OWNED` is checked before state.**
- `park()` keeps `lease_holder_hash`. The parked holder's `claim()` with its own token returns `ALREADY_OWNED` and writes nothing.
- The task stays `parked`, so every later `heartbeat()`, `complete()` and `release()` fails on `#s = 'claimed'`.
- If `replan()` also keeps the hash, the holder gets `ALREADY_OWNED` on an `awaiting_approval` task. That return skips the hash, policy and Go checks.
- If `ALREADY_OWNED` returns credentials, as a lost-response retry needs, that is an approval bypass.

**P2. Any new claimant resets the wait.**
- The scratch fields are per task. Every call with `since_version=None` overwrites `wait_started_at`.
- Each new session's `handoff reap`, or a second claimant, restarts the clock. A dead task may never be reclaimed.
- The scratch write also does not bump `version`. That is necessary, but it contradicts the "without exception" rule; state the exemption.
- A failed "best-effort" scratch write leaves `wait_started_at` null, and the second call then does arithmetic on it.
- The `LOST_RACE` comment is wrong: a renewal is caught one branch earlier and returns `WAIT`.

**P3. A missing or expired Go cannot be recovered.**
- `grant_go` requires `state = 'awaiting_approval'`.
- A task whose Go expired is `pending`, `failed` or stale `claimed`. A task whose kind was tightened after creation never entered `awaiting_approval`.
- `claim()` rejects both forever and nothing can re-approve them.

**P4. Any holder write renews the lease.**
- "Version unchanged" is the death signal, and every write bumps `version`.
- `AppendEvidence` and `park` have no deadline check, and `AppendEvidence` has no state check.
- A holder past its deadline can keep the lease indefinitely by appending evidence. The deadline is then only cooperative.

**P5. `replan()` is unspecified.** The prose does not say:
- whether the new plan passes `KIND_POLICY`, or whether the caller supplies the whole plan, including `lease_seconds` and `max_retries`;
- whether `kind` may change;
- whether `lease_holder_hash` is cleared;
- what a no-approval kind does.

**P6. `abandon()` takes no token.** If it sits behind the ordinary allow-list, any registered session can abandon any task. Name the principals for `abandon` and `force_release`.

**P7. Child outlives parent.** Nothing re-checks the parent when a child is claimed or renewed. A child created just before the parent's Go expires keeps the parent's profile for its own full timebox.

## 4. Smaller leftovers, not blocking

- **Stale prose.**
  - Decision 1's diagram still shows sessions writing the Ledger.
  - Decision 11 still says "admin-write access".
  - Decisions 2 and 6 say `ttl` is written only by the reaper, but `complete()` and `abandon()` write it.
  - Decision 6 says "`grant_go` (and no other action)" has the MFA route, then routes maintainer `replan` through it.
  - Decision 8 calls the parameter `lease_token`.
- **State diagram.**
  - It lacks `[*] → awaiting_approval` and `claimed → pending`.
  - It shows `failed → pending`, but the code goes `failed → claimed`.
- **Unspecified.**
  - Evidence trimming still has no code.
  - Nothing sets a minimum entropy for `client_token`, though its hash is readable by every session.
  - R10 is unanswered: the supervisor cannot tell "lease lost" from "broker unreachable".

## 5. Edits that would close this

This skeleton covers D2, D3, D4 and P1–P3. It drops `since_version`, because the broker's own record is enough.

```
claim(task_id, client_token):
  item = GetItem task_id; plan = GetItem item.plan_ref
  if item.state in ('completed','abandoned','awaiting_approval'): reject
  if item.deadline_at exists and broker_now() > item.deadline_at:
      abandon(task_id, 'deadline'); reject
  owned = item.state == 'claimed' and sha256(client_token) == item.lease_holder_hash
  if not owned and item.state in ('claimed','parked'):
      if item.wait_started_version != item.version:   # first observer starts the clock
          UpdateItem SET wait_started_at = :now, wait_started_version = :v
            Condition: version = :v AND (attribute_not_exists(wait_started_version)
                                         OR wait_started_version <> :v)
          return WAIT(plan.lease_seconds)             # exempt from the version rule
      if broker_now() - item.wait_started_at < plan.lease_seconds: return WAIT(remaining)
  charge = not owned and item.state in ('claimed','failed')   # parked never charges
  verify plan hash; re-read KIND_POLICY (reject if kind is gone)
  if Go required and (missing, wrong hash, or expired):
      UpdateItem SET #s = 'awaiting_approval', version = version + 1
        Condition: version = :item.version; reject
  if charge and item.attempt_count >= plan.max_retries:
      abandon(task_id, 'retries exhausted') conditional on version; reject
  if owned: return ALREADY_OWNED(credentials)
  UpdateItem ... attempt_count + (1 if charge else 0) ... Condition: version = :item.version
```

Also needed:
1. Delete the "back to `pending`" sentence in Decision 9 and write `reap()`. It should be a `claim()` attempt plus a notification, with no transitions of its own.
2. Write `replan()` with the same inputs and checks as `create()`. State that it clears the hash.
3. Add the deadline and state check to `AppendEvidence` and `park`.
4. Store `parent_task_id` on a child and re-check the parent in the child's `claim()` and renewal.
5. Name the principals for `abandon` and `force_release`.
6. Make a `create()` retry succeed: on cancellation, read the task and return success if `plan_ref` matches.

Once D1–D4 and P1–P7 are resolved in text, I would approve, with experiments 1–4 as the gate before first use. The section 4 items can ride along.

VERDICT: CHANGES NEEDED