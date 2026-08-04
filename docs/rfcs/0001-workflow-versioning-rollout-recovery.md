# RFC 0001 — Workflow Versioning, Rollout, and Recovery

| | |
|---|---|
| **Status** | Draft — for review |
| **Author** | Chris Greeno |
| **Date** | 2026-08-04 |
| **Scope** | A Fresha library over `temporalex` (working name `Fresha.Workflow`). Elixir only. |

## 1. The rule

> **A behaviour change ships as a new workflow *type*, not a new version of an existing type. Released types are immutable. Only new executions route to the new type.**

Everything else follows from that, and what it buys is:

> **The rules do not change mid-booking.**

An in-flight execution runs code that has not changed, so the quote a customer saw and the charge they get come from the same implementation.

## 2. Why not Worker Versioning

Temporal's docs call Worker Versioning the recommended default. We are not using it.

Replay always restarts from event 1, so adding one activity near the top of a workflow breaks *every* in-flight execution — including ones that are 90% complete and semantically unaffected. Under `auto_upgrade` that stalls the whole population silently, because workflow-task failures retry forever rather than failing anything. `pinned` avoids the stall, but you buy that with a subsystem — ramping, drainage, reaping, batch resets — and it *closes* the hotfix path, since a pinned population needs a batch reset to receive a fix.

Type versioning gets the same guarantee by construction: new code has no old history to replay. One worker fleet, no versioning configuration.

**Reconsider if** a type needs different *worker-level* dependencies — a native library, a different runtime — so one fleet cannot serve both. That is a deployment boundary, which is what Worker Versioning is for. Also reconsider if step-level immutability (§3.3) proves unenforceable, since pinning's coarser freeze would then be the cheaper discipline.

## 3. Invariants

### 3.1 Executions are capped at 24 hours

A *family* is a business process (`booking`); a *type* is one released implementation (`booking.v1`).

The library sets `workflow_execution_timeout = 24h` — per the API, the *"total workflow execution timeout including retries and continue as new"*, so it caps a continue-as-new chain too. That buys two things:

- **A bounded replay-compatibility surface for in-place bugfixes** (§3.2). A fix must be replay-safe against every in-flight history of the type it touches; capped executions mean those histories are a day old at most.
- **A trivial answer to "can I delete this type?"** — no running executions after a day.

Live types cost nothing operationally: they all register in the same fleet (§3.2), so an extra type is a module in the repo. In practice a family has two, current and previous.

**Consequence:** anything longer-lived — a reminder three weeks out — is a fresh workflow started later by a scheduler, never a long execution or a continue-as-new chain.

### 3.2 One worker fleet; in-place edits are for replay-safe bugfixes only

| Change | Where | Replay risk |
|---|---|---|
| New, removed, or reordered step; changed customer-visible terms | New type | None |
| Bugfix | In place | **Yes** — must be replay-safe |

Bugfixes reach in-flight executions at their next workflow task, which is what a hotfix should do. CI runs a blocking **forward replay gate**: the edited type replayed against production histories. Where a fix cannot be made replay-safe, gate it with `Temporalex.Workflow.API.patched?/1` — with a 24h cap the branch is deletable the next day.

### 3.3 Step lists are names; behaviour lives in immutable step modules

A workflow declares an ordered list of step names and nothing else. Every property that governs safety — class, gate status, unavailability handling — is declared on the **step module**, because those are properties of the step itself, not of one workflow's use of it.

Released step modules are immutable. `CaptureDeposit.V1` is frozen once released; a change introduces `V2`, referenced only by the new type.

Both halves are load-bearing:

- **If branching a type meant copying a 400-line module to change three lines, the strategy collapses** — fixes get applied twice and reviewers cannot see the diff. Names-only lists make a branch a one-line diff.
- **Types share step implementations, so editing a shared step changes a frozen type's behaviour through the back door.** Immutability does not disappear under type versioning; it relocates to the step module, which is small enough to fingerprint and enforce in CI.

### 3.4 Idempotency keys derive from business facts

```elixir
def pivot_key(%{booking_id: id}), do: "deposit_capture:booking:#{id}"
```

Never `workflow_id`, a step counter, a run ID, a UUID, or a timestamp. A workflow-scoped key produces a different value in a different type for the same business action, and we double-charge — and moving an execution between types (§5) is the only way to get work off a broken type.

It also means **nothing needs passing at recovery time**: any type, given the same booking, computes the same key.

Corollary: pivots are named by business intent, not call site. `deposit_capture` and `final_capture` are distinct pivots; two call sites of one code path are not.

### 3.5 The ledger answers "did this happen?"

Keys make the question askable; a table answers it. Columns: `pivot_key` (**unique index — the enforcement point**), `completed_at`, and `operator_id`/`reason` for overrides.

- **Dedup is enforced by the unique index, not workflow state.** After a reset or a type transition the workflow has genuinely forgotten. The database is the only thing that remembers.
- An undo shares its forward action's key, so it can tell whether the write committed when the result was lost.
- Ledger-skip count is a metric. A key that never dedupes is one we cannot trust in an incident.

### 3.6 Types are re-enterable from any step boundary

The deepest requirement, and most of the remaining engineering.

A type transition (§5) does not resume an execution — continue-as-new starts a **fresh run**. Pending timers, in-flight activities, and every workflow-local variable are gone. So:

- **Workflow-local state must be reconstructible from durable business state.** If a value exists only in a workflow variable, that boundary is not a legal transition point.
- **Every type is idempotent from the top.** Entering at step 1 with the ledger showing two steps done must skip them and land on the right next step.
- **Timers are recomputed**, not inherited.
- **Transition only at a quiescent point.** Continue-as-new does not wait for in-flight activities; an abandoned activity can still complete into a dead run. Pivot keys are what make that safe.

**The remaining hard work is not versioning — it is making state reconstructible.** That lives in our programming model, not in Temporal.

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

A new type is a one-line diff. The steps it composes are declared once, and frozen:

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

### `class` — how do we make this safe to attempt twice?

| Class | Answer |
|---|---|
| `:read` | Nothing needed — but a re-read after reset may return a *different value*, so snapshot it into a pivot's arguments wherever the plan must not change |
| `:pivot` | An idempotency key, or an undo where a wrong value is plausible and consequential (money, availability) |
| `:irreversible` | Neither exists. Never precedes a pivot, and checks the ledger before acting. A card capture is keyable but not undoable; an SMS is neither. |

### `kind` — may a fallback route around this step?

Defaults to `:skippable`. The test for declaring `:gate` is **remediability, not importance**:

> A step is a `:gate` **iff** skipping it causes harm that cannot be remediated after the fact.

A fraud check is *not* a gate — we can still cancel, flag the account, hold the payout, or require ID before the appointment. Irrevocably sending money out is. The intuitive definition ("it exists to block something") makes everything a gate, and a taxonomy where everything is a gate protects nothing.

Gates are opt-in rather than mandatory because remediability is a property of the step, decided once by whoever reviews that step module — not re-decided by every workflow that composes it.

### `on_unavailable` — required wherever a dependency can be down

Three states, not two:

| Dependency says | Proceed? | Debt |
|---|---|---|
| unavailable / timeout | **yes** | recorded |
| reject | **no** | none — it was checked |
| approve | yes | none |

**Fail open on unavailability; fail closed on rejection.** A skipped control becomes a debt (`owe: :fraud_review`), swept once the dependency recovers — deferred, not lost.

The load-bearing rule: **a business rejection must never raise.** If "reject" and "unavailable" collapse into one error path, triggering an error becomes a way through the control, and a deliberate fail-open policy turns into a bypass.

## 5. Moving executions between types

One primitive, both directions: continue-as-new with a different workflow type (`ContinueAsNewWorkflowExecutionCommandAttributes.workflow_type`, exposed in `temporalex` as the `:workflow_type` option on `continue_as_new!`).

| | New starts | In-flight |
|---|---|---|
| **Upgrade** | `route/2` picks the new type | Transition forward, operator-initiated by cohort |
| **Rollback** | `route/2` picks the previous type | Transition back — a *fallback* |
| **Hotfix** | One fleet, edit in place | Same; propagates at the next workflow task |

Forward transitions are an operator action against a cohort query, used to pull running executions onto a type that has a fix or a control the old one lacks. Backward transitions are a fallback, triggered by the execution itself:

```elixir
rescue
  e in Fresha.Workflow.FallbackError -> Workflow.fallback!(reason: e)
```

Either way: same workflow ID, new run, chain linked, reason recorded in history. Nothing is passed but provenance — the successor derives the same keys and the ledger skips what is already done. The 24h budget spans the chain, so a late transition inherits what is left of it.

Rules:

- **A fallback target must contain every `:gate` its source has**, checked at compile time. `Booking.V2 → V1` compiles because the fraud check is not a gate; a payout type that dropped beneficiary verification would not.
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
- **Dashboards and batch queries key off `FreshaWorkflowFamily`, never `WorkflowType`** — otherwise every branch forks every dashboard. Stamp it at start, with `FreshaCanaryCohort`.
- **Signal and query contracts are stable across a family.** A type may add handlers; it may not rename or remove them.

## 7. Recovery

| What's broken | Tool |
|---|---|
| An activity failing on bad input or a bad downstream | `activity pause` / `complete` / `fail` — no rewind |
| A bug in a released type, replay-safe fix | Edit in place; propagates at the next workflow task |
| A pivot already happened out of band | Pre-mark the ledger, then reset — the step re-runs and no-ops |
| The type is structurally wrong for this execution | Transition to another type (§5) |
| Unrecoverable | Terminate, compensate, restart |

Two facts shape all of it:

- **Reset rewinds; it cannot skip.** It copies a history prefix — the only freedom is prefix length. It cannot change workflow type, and it does not run compensations.
- Because pivots are keyed, the default recovery is **re-run forward, not compensate.** Undos are for abandoning a partially-complete sequence: slot held, payment failed, release the slot.

**Stall detection.** `TemporalReportedProblems` records the last workflow-task failure cause after successive failures. Workflow-task failures retry forever, so a stalled execution never *fails* and will not appear in error dashboards.

**Operator overrides** mark **named** pivots as satisfied, with a reason and an operator recorded. There is no generic "skip step N" — arbitrary skips are arbitrary corruption, and under pressure it gets used by someone who does not know what that step guarded. Gates are not overridable at all: fix it, or the execution parks for review.

## 8. Enforcement

Compile-time (`@after_compile` AST scans) or a fingerprint manifest checked in CI. No runtime cost; failures land in review.

1. Every step module declares `class`, and `on_unavailable` where its dependency can be down.
2. A `:pivot` exports `pivot_key/1`, referencing only business arguments.
3. No `:irreversible` step precedes a `:pivot` in a step list.
4. A `fallback_to:` target contains every `:gate` its source has.
5. A step's rejection path does not raise.
6. A released step module's fingerprint has not changed.
7. Workflow modules do not reference the flag client, and only `route/2` names a type.
8. `workflow_execution_timeout` is not raised above 24h.

The opinionated path has to be the *shortest* path, or engineers will call `temporalex` directly and we will have two standards. So the escape hatch is loud rather than absent: `@fresha_unsafe reason: "..."`, greppable and reviewable.

## 9. Guarantees — for the README

> The library guarantees **at-most-once effect per business key**, **correct unwinding of incomplete sequences**, that **behaviour cannot change mid-flight except by a replay-safe bugfix**, and that **a control skipped for unavailability is recorded as a debt rather than lost**.
>
> It guarantees nothing about whether the values were right, and it cannot guarantee a debt is ever paid.

Freezing a type freezes our orchestration, not the downstream services our activities call.

## 10. Open questions

1. **Who owns the pivot ledger?** It is the only way to move work off a broken type. Nothing else here works without it.
2. **Who owns each debt sweeper?** Every `owe:` tag needs a named owner and an SLA. An unread debt table is worse than no fail-open policy, because it looks like coverage.
3. **Step granularity.** The fingerprint check is only as good as the decomposition, and step lists are only readable if steps are the right size. Needs a worked example on `booking`.
4. **Replay corpus.** Production histories in a CI fixture needs a data-protection sign-off.
5. **Bounds on fail-open.** Fail closed above a booking-value threshold? Page at what debt volume?
6. **`temporalex` gaps.** Have: `patched?/1` (`workflow/api.ex:264`) and `continue_as_new!` with `:workflow_type` (`core/command_builder.ex:21`). Need: a client-side reset call and activity operations — the SDK only decodes `reset_workflow_failure_info` today.

## 11. Rejected alternatives

**Worker Deployment Versioning with pinned workflows.** Same guarantee, far more machinery, and it closes the hotfix path. See §2.

**`auto_upgrade` as the default.** Requires every engineer to keep every change replay-compatible with every in-flight history, forever, and they will pay it unevenly. Type versioning keeps auto-upgrade's prize for the case that wants it — in-place bugfixes — and removes the risk for the case that does not.

**Patching as the *strategy*.** `patched?` only gates structural divergence. Changing the deposit from 20% to 25% has nothing to gate, replays cleanly, and silently charges an in-flight booking at a rate the customer was never quoted. Kept as a tool, rejected as the strategy.

**Failing closed when a control is unavailable.** A business decision, recorded because a reviewer will question it: blocking bookings across the marketplace to avoid fraud exposure on a fraction of them is the worse trade. Decision owner: CTO. Bounds open as question 5.

**Workflow-scoped idempotency keys.** Reset-safe, but they break cross-type recovery, which is the whole mechanism here.

**Per-workflow step annotations.** Declaring `class` and `kind` in each step list would let two types disagree about the same step's safety properties, and would make a type branch a multi-line diff. Properties belong to the step.

## Appendix — API surface used

Verified against `temporalio/api`, the `temporal` CLI, and this repository on 2026-08-04.

- `ContinueAsNewWorkflowExecutionCommandAttributes.workflow_type` — transitions between types (§5).
- `NewWorkflowExecutionInfo.workflow_execution_timeout` — *"including retries and continue as new"*; the 24h cap.
- `Temporalex.Workflow.API.patched?/1` — `workflow/api.ex:264`; on replay, a patch ID absent from history returns `false` (`core/executor.ex:2363`).
- `temporal workflow reset` — valid reset points are workflow-task boundaries; signals are re-applied by default; batch resets are limited to `FirstWorkflowTask` / `LastWorkflowTask` / `BuildId`.
- `temporal activity` — `pause` / `unpause` / `complete` / `fail` / `reset` / `update-options`.
- `TemporalReportedProblems` — stall alerting. Custom: `FreshaWorkflowFamily`, `FreshaCanaryCohort`.

**Deliberately unused:** Worker Deployments and Versions, `pinned` / `auto_upgrade` behaviours, `VersioningOverride`, ramping, `set-current-version`, drainage status, reset-with-move, and the `TemporalWorkerDeployment*` search attributes. See §2.
