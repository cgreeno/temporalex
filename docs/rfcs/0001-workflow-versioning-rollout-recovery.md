# RFC 0001 — Workflow Versioning, Rollout, and Recovery

| | |
|---|---|
| **Status** | Draft — for review |
| **Author** | Chris Greeno |
| **Date** | 2026-08-04 |
| **Scope** | A Fresha library over `temporalex` (working name `Fresha.Workflow`). Elixir only. |

## 1. The rule

> **A behaviour change ships as a new workflow *type*, not a new version of an existing type. Released types are immutable. Only new executions route to the new type.**

Everything else in this RFC follows from that, and the property we get is:

> **The rules do not change mid-booking.**

An in-flight execution runs code that has not changed, so the quote a customer saw and the charge they get come from the same implementation.

## 2. Why not Worker Versioning

Temporal's docs call Worker Versioning the recommended default. We are not using it. The reason is that replay always restarts from event 1, so adding one activity near the top of a workflow breaks *every* in-flight execution — including ones that are 90% complete and semantically unaffected. Under `auto_upgrade` that stalls the whole population silently, because workflow-task failures retry forever rather than failing anything. Under `pinned` it doesn't, but you buy that with a subsystem: ramping, drainage, reaping, and batch resets to fix in-flight work.

Type versioning gets the same guarantee by construction — new code has no old history to replay — with one worker fleet and no versioning configuration at all.

**Reconsider if:** the 24h cap (§3.1) is relaxed, so old types stop draining and more than two are live.

## 3. Invariants

### 3.1 Two live types per family, capped at 24 hours

A *family* is a business process (`booking`); a *type* is one released implementation (`booking.v1`). Two are live: current and previous. The previous drains and is deleted.

The library sets `workflow_execution_timeout = 24h` — per the API, the *"total workflow execution timeout including retries and continue as new"*, so it caps a continue-as-new chain too. This is what makes deletion a timer rather than a drainage query.

**Consequence:** anything longer-lived (a reminder three weeks out) is a fresh workflow started later by a scheduler, never a long execution.

### 3.2 One worker fleet; in-place edits are for replay-safe bugfixes only

| Change | Where | Replay risk |
|---|---|---|
| New/removed/reordered step, changed customer-visible terms | New type | None |
| Bugfix | In place | **Yes** — must be replay-safe |

Bugfixes reach in-flight executions at their next workflow task, which is what a hotfix should do. CI runs a **forward replay gate** (the edited type replayed against production histories) as a blocking check. Where a fix can't be made replay-safe, gate it with `Temporalex.Workflow.API.patched?/1`; with a 24h cap the branch can be deleted the next day.

### 3.3 Workflows are declarative step lists

Not a style preference. If branching a type means copying a 400-line module to change three lines, the strategy collapses — bugfixes get applied twice and reviewers can't see the diff.

### 3.4 Released step modules are immutable

Types share step implementations, so **editing a shared step changes a frozen type's behaviour through the back door.** The freeze therefore lives at step level: `CaptureDeposit.V1` is frozen once released, and a change introduces `V2` that only the new type references.

Immutability doesn't disappear under type versioning — it relocates somewhere small enough to fingerprint and enforce in CI.

### 3.5 Idempotency keys derive from business facts

```elixir
def pivot_key(%{booking_id: id}), do: "deposit_capture:booking:#{id}"
```

Never `workflow_id`, a step counter, a run ID, a UUID, or a timestamp. A workflow-scoped key would produce a different value in a different type for the same business action, and we'd double-charge — and moving work between types is the only recovery mechanism this design has.

It also means **nothing needs passing at recovery time**: any type, given the same booking, computes the same key.

Corollary: pivots are named by business intent, not call site. `deposit_capture` and `final_capture` are distinct; two call sites of one code path are not.

### 3.6 The ledger answers "did this happen?"

Keys make the question askable; a table answers it. Columns: `pivot_key` (**unique index — the enforcement point**), `completed_at`, and `operator_id`/`reason` for overrides.

- **Dedup is enforced by the unique index, not workflow state.** After a reset or a type transition the workflow has genuinely forgotten. The database is the only thing that remembers.
- An undo shares its forward action's key, so it can tell whether the write committed when the result was lost.
- Ledger-skip count is a metric. A key that never dedupes is one we can't trust in an incident.

### 3.7 Types are re-enterable from any step boundary

The deepest requirement, and most of the remaining engineering.

A type transition (§5) does not resume an execution — continue-as-new starts a **fresh run**. Pending timers, in-flight activities, and every workflow-local variable are gone. So:

- **Workflow-local state must be reconstructible from durable business state.** If a value exists only in a workflow variable, that boundary is not a legal transition point.
- **Every type is idempotent from the top.** Entering at step 1 with the ledger showing two steps done must skip them and land on the right next step.
- **Timers are recomputed**, not inherited.
- **Transition only at a quiescent point.** Continue-as-new doesn't wait for in-flight activities; an abandoned activity can still complete into a dead run. Pivot keys are what make that safe.

**The remaining hard work is not versioning — it is making state reconstructible.** That lives in our programming model, not in Temporal.

## 4. Declaring a workflow

```elixir
defworkflow Booking.V2,
  family: :booking,
  fallback_to: Booking.V1,
  steps: [
    step(:hold_slot,         class: :pivot,        kind: :skippable),
    step(:check_fraud,       class: :read,         kind: :skippable,
                             on_unavailable: {:proceed, owe: :fraud_review}),
    step(:capture_deposit,   class: :pivot,        kind: :skippable),
    step(:send_confirmation, class: :irreversible, kind: :skippable),
    step(:remind,            class: :read,         kind: :skippable)
  ]
```

**`class`** answers *how do we make this safe to attempt twice?*

| Class | Answer |
|---|---|
| `:read` | Nothing needed — but a re-read after reset may return a different value, so snapshot it into a pivot's arguments where the plan must not change |
| `:pivot` | An idempotency key, or an undo where a wrong value is plausible and consequential (money, availability) |
| `:irreversible` | Neither exists. Ordered last; checks the ledger before acting. A card capture is keyable but not undoable; an SMS is neither. |

**`kind`** governs fallback, and the test is **remediability, not importance**:

> A step is a `:gate` **iff** skipping it causes harm that cannot be remediated after the fact.

A fraud check is *not* a gate — we can still cancel, flag the account, hold the payout, or require ID. Irrevocably sending money out is. The intuitive definition ("it exists to block something") makes everything a gate, and a taxonomy where everything is a gate protects nothing.

**`on_unavailable`** is required wherever a dependency can be down. Three states, not two:

| Dependency says | Proceed? | Debt |
|---|---|---|
| unavailable / timeout | **yes** | recorded |
| reject | **no** | none — it was checked |
| approve | yes | none |

**Fail open on unavailability; fail closed on rejection.** A skipped control becomes a debt (`owe: :fraud_review`), swept once the dependency recovers — deferred, not lost.

The load-bearing rule: **a business rejection must never raise.** If "reject" and "unavailable" collapse into one error path, triggering an error becomes a way through the control and a deliberate fail-open policy turns into a bypass.

## 5. Moving executions between types

One primitive, both directions: continue-as-new with a different workflow type (`ContinueAsNewWorkflowExecutionCommandAttributes.workflow_type`, available in `temporalex` as the `:workflow_type` option on `continue_as_new!`).

```elixir
rescue
  e in Fresha.Workflow.FallbackError -> Workflow.fallback!(reason: e)
```

Same workflow ID, new run, chain linked, the reason recorded in history. Nothing needs passing but provenance — the successor derives the same keys and the ledger skips what's done. Note the 24h budget spans the chain, so a late fallback inherits what's left.

| | New starts | In-flight |
|---|---|---|
| **Upgrade** | `route/2` picks the new type | Continue-as-new forward (operator-initiated, by cohort) |
| **Rollback** | `route/2` picks the previous type | Continue-as-new back — a fallback |
| **Hotfix** | One fleet, edit in place | Same; propagates next workflow task |

Rules:

- **A fallback target must contain every `:gate` its source has** — checked at compile time, so `Booking.V2 → V1` compiles and a payout type dropping beneficiary verification does not.
- Only a narrow, typed `FallbackError` triggers a fallback. Retryable failures exhaust their retry policy first.
- **Compensate source-only steps** before handing off, or their partial state is orphaned.
- **Debts survive the transition.** An `owe:` row is keyed to the booking, not the workflow, so it must *not* be compensated away — the review is still owed.
- Single hop. The predecessor failing too pages a human.
- **The trigger defaults to manual.** Stuck is visible and recoverable; silently degraded is neither. Auto-fallback converts a loud failure into a quiet one, which reads as more resilient and can be less safe. Opt in per family once the gate declarations have proven honest.

## 6. Routing and rollout

```elixir
# the ONLY place in the codebase that names a workflow type
def route(:booking, salon_id) do
  if Flags.enabled?(:booking_v2, salon_id), do: Booking.V2, else: Booking.V1
end
```

- **The flag is read by the caller**, never inside workflow code — a mid-execution flip would diverge on replay.
- **A routing lookup must never fail a start.** Fail closed to the previous type.
- Deterministic cohorts beat a percentage ramp: a canary salon is *always* on V2, so a support ticket is reproducible.
- **Dashboards and batch queries key off `FreshaWorkflowFamily`, never `WorkflowType`** — otherwise every branch forks every dashboard. Stamp it at start, along with `FreshaCanaryCohort`.
- **Signal and query contracts are stable across a family.** A type may add handlers; it may not rename or remove them.

## 7. Recovery

| What's broken | Tool |
|---|---|
| Activity failing on bad input or a bad downstream | `activity pause` / `complete` / `fail` — no rewind |
| Bug in a released type, replay-safe fix | Edit in place; propagates next workflow task |
| A pivot already happened out of band | Pre-mark the ledger, then reset — the step re-runs and no-ops |
| The type is structurally wrong for this execution | Fallback (§5) |
| Unrecoverable | Terminate, compensate, restart |

Two facts shape all of it:

- **Reset rewinds; it cannot skip.** It copies a history prefix — the only freedom is prefix length. It also cannot change workflow type, and it does not run compensations.
- Because pivots are keyed, the default recovery is **re-run forward, not compensate.** Undos are for abandoning a partially-complete sequence (slot held, payment failed, release the slot).

Stall detection: `TemporalReportedProblems` records the last workflow-task failure cause after successive failures. Workflow-task failures retry forever, so a stalled execution never *fails* and won't appear in error dashboards.

Operator overrides mark **named** pivots as satisfied, with a reason and an operator recorded. There is no generic "skip step N" — arbitrary skips are arbitrary corruption, and under pressure it gets used by someone who doesn't know what that step guarded. Gates are not overridable at all: fix it, or the execution parks for review.

## 8. Enforcement

Compile-time (`@after_compile` AST scans) or a fingerprint manifest in CI. No runtime cost; failures land in review.

1. Every step declares `class`, `kind`, and — where a dependency can be down — `on_unavailable`.
2. A `:pivot` exports `pivot_key/1`, referencing only business arguments.
3. No `:irreversible` step precedes a `:pivot`.
4. A `fallback_to:` target contains every `:gate` its source has.
5. A step's rejection path does not raise.
6. A released step module's fingerprint hasn't changed.
7. Workflow modules don't reference the flag client, and only `route/2` names a type.
8. `workflow_execution_timeout` is not raised above 24h.

The opinionated path has to be the *shortest* path, or engineers will call `temporalex` directly and we'll have two standards. So the escape hatch is loud rather than absent: `@fresha_unsafe reason: "..."`, greppable and reviewable.

## 9. Guarantees — for the README

> The library guarantees **at-most-once effect per business key**, **correct unwinding of incomplete sequences**, that **behaviour cannot change mid-flight except by a replay-safe bugfix**, and that **a control skipped for unavailability is recorded as a debt rather than lost**.
>
> It guarantees nothing about whether the values were right, and it cannot guarantee a debt is ever paid.

Freezing a type freezes our orchestration, not the downstream services our activities call.

## 10. Open questions

1. **Who owns the pivot ledger?** It's the only mechanism for moving work between types. Nothing else here works without it.
2. **Who owns each debt sweeper?** Every `owe:` tag needs a named owner and an SLA. An unread debt table is worse than no fail-open policy, because it looks like coverage.
3. **Step granularity.** The fingerprint check is only as good as the decomposition. Needs a worked example on `booking`.
4. **Replay corpus.** Production histories in a CI fixture needs a data-protection sign-off.
5. **Bounds on fail-open.** Fail closed above a booking-value threshold? Page at what debt volume?
6. **`temporalex` gaps.** Have: `patched?/1` (`workflow/api.ex:264`), `continue_as_new!` with `:workflow_type` (`core/command_builder.ex:21`). Need: client-side reset (incl. `post_reset_operations`) and activity operations — the SDK only decodes `reset_workflow_failure_info` today.

## 11. Rejected alternatives

**Worker Deployment Versioning with pinned workflows.** Same guarantee, far more machinery: versioning declarations, ramping, drainage, reaping, reset-with-move. It also *closes* the hotfix path — a pinned population needs a batch reset to receive a fix.

**`auto_upgrade` as the default.** Requires every engineer to keep every change replay-compatible with every in-flight history, forever, and they'll pay it unevenly. Type versioning keeps auto-upgrade's prize for the case that wants it (in-place bugfixes) and removes the risk for the case that doesn't.

**Patching as the *strategy*.** `patched?` only gates structural divergence. Changing the deposit from 20% to 25% has nothing to gate, replays cleanly, and silently charges an in-flight booking at a rate the customer was never quoted. Kept as a tool, rejected as the strategy.

**Failing closed when a control is unavailable.** A business decision, recorded because a reviewer will question it: blocking bookings across the marketplace to avoid fraud exposure on a fraction of them is the worse trade. Decision owner: CTO. Bounds open as question 5.

**Workflow-scoped idempotency keys.** Reset-safe, but they break cross-type recovery, which is the whole mechanism here.

## Appendix — API surface used

Verified against `temporalio/api`, the `temporal` CLI, and this repository on 2026-08-04.

- `ContinueAsNewWorkflowExecutionCommandAttributes.workflow_type` — transitions between types (§5).
- `NewWorkflowExecutionInfo.workflow_execution_timeout` — *"including retries and continue as new"*; the 24h cap.
- `ResetWorkflowExecutionRequest.post_reset_operations` — applied to the new run, in order, **before the first new workflow task**, so injected state has no race. `SignalWorkflow` or `UpdateWorkflowOptions` only; no durable Update variant ([#7551](https://github.com/temporalio/temporal/issues/7551)). Server support merged May 2025 ([#7719](https://github.com/temporalio/temporal/pull/7719)), so ≈1.28+.
- `Temporalex.Workflow.API.patched?/1` — `workflow/api.ex:264`; on replay, a patch ID absent from history returns `false` (`core/executor.ex:2363`).
- `temporal workflow reset` — valid reset points are workflow-task boundaries; signals re-applied by default; batch resets limited to `FirstWorkflowTask` / `LastWorkflowTask` / `BuildId`.
- `temporal activity` — `pause` / `unpause` / `complete` / `fail` / `reset` / `update-options`.
- `TemporalReportedProblems` — stall alerting. Custom: `FreshaWorkflowFamily`, `FreshaCanaryCohort`.

**Deliberately unused:** Worker Deployments and Versions, `pinned`/`auto_upgrade` behaviours, `VersioningOverride`, ramping, `set-current-version`, drainage, reset-with-move, and the `TemporalWorkerDeployment*` search attributes. See §2.
