# RFC 0001 — Workflow Versioning, Rollout, and Recovery

| | |
|---|---|
| **Status** | Draft — for review |
| **Author** | Chris Greeno |
| **Date** | 2026-08-04 |
| **Scope** | A Fresha library over `temporalex` (working name `Fresha.Workflow`). Elixir only. |

## The rule

> A behaviour change ships as a new workflow *type*, not a new version of an existing type. Released types are immutable. Only new executions route to the new type.

What it buys: **the rules do not change mid-booking.** An in-flight execution runs code that has not changed, so the quote a customer saw and the charge they get come from the same implementation.

## 1. The four scenarios

### Scenario 1 — Upgrade, and roll back

A change ships as `Booking.V2`. `route/2` sends new bookings there; bookings already running stay on `V1`, whose code has not changed, and finish on it. Rollback for new starts is a flag flip — no server call.

Executions already running move between types with continue-as-new (§3), in either direction.

### Scenario 2 — Canary

The same flag picks the type per cohort, so canary salons are *always* on V2 and a support ticket is reproducible. Blast radius is "new bookings for these salons", not "10% of everything, non-reproducibly".

### Scenario 3 — Bad deploy, executions stuck

Cheapest rung first:

| Situation | Action |
|---|---|
| An activity is failing | `temporal activity pause` / `complete` / `fail` — no rewind |
| The fix is replay-safe | Edit the type in place; it reaches running executions at their next workflow task |
| A step already happened out of band | Pre-mark the ledger, then reset — the step re-runs and no-ops |
| The type is structurally wrong for this execution | Fall back to the previous type (§3) |
| Unrecoverable | Terminate, compensate, restart |

Reset rewinds; it cannot skip, cannot change workflow type, and does not run compensations.

### Scenario 4 — Steps declare whether they change state

Each step declares a class:

| Class | Requirement |
|---|---|
| `:read` | None. But a re-read after reset may return a different value, so snapshot it into a pivot's arguments where the plan must not change. |
| `:pivot` | An idempotency key, or an undo where a wrong value is plausible and consequential (money, availability). |
| `:irreversible` | Neither is possible. Never precedes a pivot, and checks the ledger before acting. A card capture is keyable but not undoable; an SMS is neither. |

Keys derive from business facts — `"deposit_capture:booking:#{id}"` — never a workflow ID, step counter, run ID, UUID, or timestamp. So the same booking yields the same key in *any* type, and a ledger table with a unique index on that key answers "did this already happen?"

**Scenario 4 is the precondition for 1–3, not a peer of them.** Every recovery path re-executes side effects, so without the keys and the ledger the other three are unsafe to attempt.

## 2. Why not versioned workers

We use neither versioning mode. Both are rejected, for different reasons:

`auto_upgrade` cannot deliver the property in the rule above. Two distinct problems, and the second is the disqualifying one:

- *Without* `patched?`, replay restarts from event 1, so adding a step near the top of a workflow breaks every in-flight execution — including ones 90% complete and semantically unaffected. Workflow-task failures retry forever, so the population stalls silently rather than failing. This is a discipline failure, and `patched?` fixes it: on replay of a history lacking the marker it returns `false`, the new step is skipped, and replay is clean. With a 24h cap the patch branch is deletable the next day, so the discipline is cheap.
- *With* `patched?`, structural changes are safe — but patching gates structure, never values. Changing the deposit from 20% to 25% has nothing to gate: it replays cleanly and silently charges an in-flight booking at a rate the customer was never quoted. No marker can catch it, and no replay test fails.

That second case is the whole property we are buying, so `auto_upgrade` is out on capability, not on cost.

`pinned` is rejected on cost. It delivers the property, but it costs ramping, drainage tracking, version reaping, and version-aware remediation queries — and it closes the hotfix path, because a pinned population needs a batch reset to receive a fix. Type versioning gets the same guarantee with one worker fleet and no versioning configuration, since new code has no old history to replay.

Revisit only if a type needs different *worker-level* dependencies — a native library, a different runtime — so one fleet cannot serve both. That is a deployment boundary, which is what Worker Versioning is actually for.

## 3. Moving executions between types

One primitive, both directions: continue-as-new with a different workflow type (`ContinueAsNewWorkflowExecutionCommandAttributes.workflow_type`; in `temporalex`, the `:workflow_type` option on `continue_as_new!`).

- Forward is an operator action against a cohort query — pull running executions onto a type with a fix or a control the old one lacks.
- Backward is a fallback, triggered by the execution: `rescue e in FallbackError -> Workflow.fallback!(reason: e)`.

Same workflow ID, new run, chain linked, reason in history. Nothing is passed but provenance: the successor derives the same keys and the ledger skips what is done. The 24h budget spans the chain.

Rules:

- A fallback target must contain every gate its source has — checked at compile time.
- Only a narrow, typed `FallbackError` triggers a fallback; retryable failures exhaust their retry policy first.
- Compensate source-only steps before handing off, or their partial state is orphaned.
- Debts (§4) survive the transition. An `owe:` row is keyed to the booking, not the workflow, so it must not be compensated away.
- Single hop. The predecessor failing too pages a human.
- The trigger defaults to manual. Stuck is visible and recoverable; silently degraded is neither, so auto-fallback turns a loud failure into a quiet one. Opt in per family once gate declarations have proven honest.

## 4. Declaring a workflow

```elixir
defworkflow Booking.V1,
  family: :booking,
  steps: [:hold_slot, :capture_deposit, :send_confirmation]

defworkflow Booking.V2,
  family: :booking,
  fallback_to: Booking.V1,
  steps: [:hold_slot, :check_fraud, :capture_deposit, :send_confirmation]
```

A new type is a one-line diff. Step lists are bare names; everything governing safety is declared once, on the frozen step module:

```elixir
defstep Booking.Steps.HoldSlot.V1,         class: :pivot
defstep Booking.Steps.CaptureDeposit.V1,   class: :pivot
defstep Booking.Steps.SendConfirmation.V1, class: :irreversible

defstep Booking.Steps.CheckFraud.V1,
  class: :read,
  on_unavailable: {:proceed, owe: :fraud_review}

defstep Payout.Steps.VerifyBeneficiary.V1,
  class: :read,
  kind: :gate
```

Those properties belong to the step, not to one workflow's use of it — per-list annotation would let two types disagree about the same step's safety.

### `kind` — may a fallback route around this step?

Defaults to `:skippable`. The test for a gate is remediability, not importance:

> A step is a gate iff skipping it causes harm that cannot be remediated after the fact.

A fraud check is not a gate: we can still cancel, flag the account, hold the payout, or require ID. Irrevocably sending money out is. The intuitive definition — "it exists to block something" — makes everything a gate, and a taxonomy where everything is a gate protects nothing.

### `on_unavailable` — required wherever a dependency can be down

| Dependency says | Proceed? | Debt |
|---|---|---|
| unavailable / timeout | yes | recorded |
| reject | no | none — it was checked |
| approve | yes | none |

Fail open on unavailability, fail closed on rejection. A skipped control becomes a debt, swept once the dependency recovers — deferred, not lost.

**A business rejection must never raise.** If "reject" and "unavailable" collapse into one error path, triggering an error becomes a way through the control and a deliberate fail-open policy turns into a bypass.

## 5. Invariants

1. Executions are capped at 24 hours. `workflow_execution_timeout = 24h`, which per the API is the total "including retries and continue as new", so it caps a continue-as-new chain too. It bounds the replay-compatibility surface for in-place fixes, and makes "can I delete this type?" trivial. Anything longer-lived — a reminder three weeks out — is a fresh workflow started later by a scheduler.
2. One worker fleet. All live types register in it, so an extra type costs a module in the repo, nothing operational. In practice a family has two: current and previous.
3. In-place edits are for replay-safe bugfixes only. CI runs a blocking forward replay gate — the edited type replayed against production histories. Where a fix cannot be made replay-safe, gate it with `patched?/1`; with a 24h cap the branch is deletable the next day.
4. Released step modules are immutable. Types share step implementations, so editing a shared step changes a frozen type's behaviour through the back door. Immutability does not disappear under type versioning; it relocates to the step module, small enough to fingerprint in CI.
5. Dedup is enforced by the ledger's unique index, not by workflow state. After a reset or a transition the workflow has genuinely forgotten. An undo shares its forward action's key, so it can tell whether a write committed when the result was lost.
6. Types are re-enterable from any step boundary. A transition starts a fresh run — pending timers, in-flight activities and every workflow-local variable are gone. So workflow-local state must be reconstructible from durable business state; every type must be idempotent from the top; timers are recomputed, not inherited; and transitions happen only at a quiescent point, since continue-as-new does not wait for in-flight activities. *This is the deepest requirement and most of the remaining engineering — and it lives in our programming model, not in Temporal.*

## 6. Routing

```elixir
# the ONLY place in the codebase that names a workflow type
def route(:booking, salon_id) do
  if Flags.enabled?(:booking_v2, salon_id), do: Booking.V2, else: Booking.V1
end
```

- The flag is read by the caller, never inside workflow code — a mid-execution flip would diverge on replay.
- A routing lookup must never fail a start. Fail closed to the previous type.
- Dashboards and batch queries key off `FreshaWorkflowFamily`, never `WorkflowType`, or every branch forks every dashboard. Stamp it at start, with `FreshaCanaryCohort`.
- Signal and query contracts are stable across a family: a type may add handlers, never rename or remove them.

## 7. Enforcement

Compile-time AST checks, or a fingerprint manifest in CI. Failures land in review, not at 2am.

1. Every step module declares `class`, and `on_unavailable` where its dependency can be down.
2. A `:pivot` exports `pivot_key/1`, referencing only business arguments.
3. No `:irreversible` step precedes a `:pivot`.
4. A `fallback_to:` target contains every gate its source has.
5. A step's rejection path does not raise.
6. A released step module's fingerprint has not changed.
7. Workflow modules do not reference the flag client, and only `route/2` names a type.
8. `workflow_execution_timeout` is not raised above 24h.

Operator overrides mark named pivots as satisfied, with reason and operator recorded. There is no generic "skip step N" — under pressure it gets used by someone who does not know what that step guarded. Gates are not overridable at all: fix it, or the execution parks for review.

The opinionated path has to be the shortest path, or engineers will call `temporalex` directly and we will have two standards. So the escape hatch is loud rather than absent: `@fresha_unsafe reason: "..."`.

## 8. Guarantees — for the README

> Guaranteed: at-most-once effect per business key; correct unwinding of incomplete sequences; behaviour cannot change mid-flight except by a replay-safe bugfix; a control skipped for unavailability is recorded as a debt rather than lost.
>
> Not guaranteed: that the values were right, or that a debt is ever paid.

Freezing a type freezes our orchestration, not the downstream services our activities call.

## 9. Open questions

1. Who owns the pivot ledger? It is the only way to move work off a broken type. Nothing else here works without it.
2. Who owns each debt sweeper? Every `owe:` tag needs an owner and an SLA. An unread debt table is worse than no fail-open policy, because it looks like coverage.
3. Step granularity. Both the fingerprint check and the readability of step lists depend on it. Needs a worked example on `booking`.
4. Replay corpus. Production histories in a CI fixture needs a data-protection sign-off.
5. Bounds on fail-open. Fail closed above a booking-value threshold? Page at what debt volume?
6. `temporalex` gaps. Have `patched?/1` (`workflow/api.ex:264`) and `continue_as_new!` with `:workflow_type` (`core/command_builder.ex:21`). Need a client-side reset call and activity operations.

## 10. Rejected alternatives

`auto_upgrade` with patching as the strategy — works for structural change, and cannot cover a changed value, which is the property we need. `patched?` is kept as a tool for replay-hostile bugfixes (§5), rejected as the versioning strategy. See §2.

Failing closed when a control is unavailable — a business decision, recorded because a reviewer will question it: blocking bookings across the marketplace to avoid fraud exposure on a fraction of them is the worse trade. Decision owner: CTO. Bounds open as question 5.

Workflow-scoped idempotency keys — reset-safe, but they break cross-type recovery, which is the whole mechanism here.

## Appendix — API surface used

Verified against `temporalio/api`, the `temporal` CLI, and this repository on 2026-08-04.

- `ContinueAsNewWorkflowExecutionCommandAttributes.workflow_type` — transitions between types.
- `NewWorkflowExecutionInfo.workflow_execution_timeout` — "including retries and continue as new"; the 24h cap.
- `Temporalex.Workflow.API.patched?/1` — `workflow/api.ex:264`; on replay a patch ID absent from history returns `false` (`core/executor.ex:2363`).
- `temporal workflow reset` — valid reset points are workflow-task boundaries; signals re-applied by default.
- `temporal activity` — `pause` / `unpause` / `complete` / `fail` / `reset` / `update-options`.
- `TemporalReportedProblems` — stall alerting; workflow-task failures retry forever, so a stalled execution never *fails* and will not appear in error dashboards. Custom: `FreshaWorkflowFamily`, `FreshaCanaryCohort`.

Unused: Worker Deployments and Versions, `pinned` / `auto_upgrade`, `VersioningOverride`, ramping, `set-current-version`, drainage status, reset-with-move, `TemporalWorkerDeployment*` search attributes.
