# RFC 0001 — Workflow Versioning, Rollout, and Recovery

| | |
|---|---|
| **Status** | Draft — for review |
| **Author** | Chris Greeno |
| **Date** | 2026-08-04 |
| **Scope** | An opinionated Fresha library layered over `temporalex` (working name `Fresha.Workflow`). Elixir only. |
| **Supersedes** | The pinned-worker-version approach in this RFC's first draft (see [§12](#12-rejected-alternatives)) |

## 1. Summary

Four operational scenarios drive this design:

1. Upgrade a workflow and roll it back.
2. Canary a new workflow version to a percentage or cohort.
3. Recover when a deploy introduces a bug and in-flight executions are stuck.
4. Force saga steps to declare whether they mutate state, so any step can be safely re-attempted or unwound.

The proposal resolves them with **type-based versioning** rather than Temporal's Worker Deployment Versioning:

> **A behaviour change ships as a new workflow *type*, not as a new version of an existing type. Released types and their steps are immutable. Only new executions route to the new type; existing executions keep running code that has not changed.**

This gives the property we actually want — **the rules do not change mid-booking** — by construction rather than by configuration, and it does so without pinning, ramping, version reaping, or drainage tracking. Replay incompatibility becomes a non-issue for behaviour changes, because there is no old history for new code to replay.

Two supporting decisions carry the rest of the weight:

- **Side-effecting activities are classified at compile time**, and their idempotency keys derive from **business facts** rather than workflow-internal state, so any step is re-attemptable by any workflow type.
- **Executions move between types in either direction** via continue-as-new with a different workflow type, reusing those keys. Forward for a deliberate in-flight upgrade, backward as a fallback when a type breaks — but only past steps declared safe to skip. The compiler refuses fallback routes that would bypass a protective step.

Together those close the whole matrix with no versioning subsystem:

| | New starts | In-flight executions |
|---|---|---|
| **Upgrade** | `route/2` selects the new type | Continue-as-new forward into the new type |
| **Rollback** | `route/2` selects the previous type | Continue-as-new back into the previous type |
| **Hotfix** | One worker fleet — edit in place | Same; propagates at the next workflow task |

## 2. Motivation

Temporal supplies primitives and no policy. Left unopinionated, every team picks a different combination and discovers the failure mode during an incident. The two specific traps:

**`auto_upgrade` looks like the convenient default and is not.** Replay always restarts from event 1, so a change to an early step breaks executions that are 90% complete and semantically unaffected. Adding one activity near the top of a workflow stalls the entire in-flight population — silently, since workflow-task failures retry indefinitely rather than failing anything. Rolling the Current Version back rescues most of them but breaks whatever started on the new version.

**A canary of *starts* cannot de-risk a *migration*.** Temporal's ramp percentage applies only to new workflow executions. Promoting a version moves 100% of the in-flight `auto_upgrade` population at once, whatever the ramp says. Nothing except a replay test covers that, and a replay test is a discipline rather than a mechanism.

**Reset re-runs activities.** Every recovery path re-executes side effects, so without a business-keyed ledger, recovery is unsafe by construction — teams therefore avoid it and terminate stuck workflows instead.

Type-based versioning removes the first two problems rather than managing them. The third is unavoidable and is addressed directly in [§4.5](#45-invariant-5--business-scoped-keys-and-a-shared-pivot-ledger).

## 3. Non-goals

- **Detecting wrong values.** Compensation exists for *incompleteness*, not *incorrectness*. A step that writes £50 instead of £5 is an ordinary bug owned by tests, review, and the service that owns the table.
- **Behavioural stability of downstream services.** Freezing a type freezes our orchestration and our activity code. It says nothing about the version of the service an activity calls.
- **Wrapping the whole SDK.** Client calls delegate thinly to `temporalex`. Every wrapped function is one we chase upstream forever.
- **Long-running workflows.** 24h is a hard cap ([§4.6](#46-invariant-6--24-hour-execution-cap)).
- **Using Worker Deployment Versioning.** Deliberately unused; justified in [Appendix B](#appendix-b--deliberately-unused).

## 4. Invariants

### 4.1 Invariant 1 — Two live types per family; released types and steps are immutable

A **family** is a business process (`booking`). A **type** is one released implementation of it (`booking.v1`, `booking.v2`).

- A behaviour change ships as a **new type**. The previous type is not edited.
- **Two types live per family**: current and previous. The previous type drains within 24h ([§4.6](#46-invariant-6--24-hour-execution-cap)) and is then deleted.
- **Released step modules are immutable.** `Booking.Steps.CaptureDeposit.V1` is frozen once released; a change to capture behaviour introduces `V2` and only the new workflow type references it.

The last point is the real cost of this design, and it is easy to miss. Types share step implementations ([§4.2](#42-invariant-2--workflows-are-declarative-step-compositions)), so **editing a shared step changes the frozen type's behaviour through the back door** without touching either workflow module. The immutability discipline does not disappear under type versioning — it relocates from whole workflow versions down to step modules, where the unit is small, obviously frozen, and mechanically checkable ([§9](#9-compile-time-enforcement)).

### 4.2 Invariant 2 — Workflows are declarative step compositions

```elixir
defworkflow Booking.V1,
  family: :booking,
  steps: [:hold_slot, :capture_deposit, :send_confirmation, :remind]

defworkflow Booking.V2,
  family: :booking,
  steps: [:hold_slot, :check_fraud, :capture_deposit, :send_confirmation, :remind],
  fallback_to: Booking.V1
```

This is a hard requirement, not a style preference. If branching a type means copying a 400-line procedural module to change three lines, the strategy collapses: bugfixes get applied twice, and reviewers cannot see what differs. **Type versioning is only viable if branching a type is a one-line diff.**

### 4.3 Invariant 3 — One worker fleet; in-place edits must be replay-safe

There is a single, unversioned worker fleet. Both live types are registered in it. No `set-current-version`, no ramping, no drainage, no reaping timer.

The consequence to be explicit about: **an in-place edit propagates to in-flight executions immediately.** That is desirable for its intended use and dangerous otherwise, so:

| Change | Where it goes | Replay risk |
|---|---|---|
| Behaviour change, new/removed/reordered step, changed customer-visible terms | **New type** | None — no old history exists |
| Bugfix to a released type | **In place** | **Yes** — must be replay-safe, or gated with `patched?` |

Bugfixes propagate to every in-flight execution of that type at its next workflow task, which is exactly what a hotfix should do. The price is that they carry replay risk, so:

- **CI runs a forward replay gate**: the edited type replayed against a corpus of production histories. Blocking.
- Where a bugfix cannot be made replay-safe, gate it with `Temporalex.Workflow.API.patched?/1`. On replay of a history without the marker it returns `false`, so pre-existing executions keep the old path while new ones take the new one. With a 24h cap the patch branch can be deleted a day later.

A *backward* replay gate is not needed: there are no worker versions to roll back to.

### 4.4 Invariant 4 — Three activity classes, two step kinds

Every activity answers one question: *how do we make this safe to attempt twice?*

| Class | Answer | Requirement |
|---|---|---|
| **`:read`** | Nothing needed | — |
| **`:pivot`** | Idempotency key **or** undo | `pivot_key/1`; plus `undo/2` where a wrong value is plausible and consequential (money, availability) |
| **`:irreversible`** | Neither exists | Ordered last; consults the ledger before acting |

`:read` carries one caveat: reads are safe to *execute* again, but on reset a read may return a *different value*, so the workflow can take a different branch than the run we are recreating. Reads are idempotent; decisions derived from reads are not stable across reset. Where the plan must not change, snapshot the read into the pivot's arguments.

`:irreversible` must stay its own class. A card capture is keyable but not undoable — a refund is a new, customer-visible event. An SMS is neither. With only two options someone attaches a key to the SMS activity and considers it handled.

Independently, every step declares a **kind**, which governs fallback ([§6](#6-fallback)):

| Kind | Meaning |
|---|---|
| **`:skippable`** | A fallback may route around this step |
| **`:gate`** | A fallback may **never** route around this step |

The test for a gate is **remediability, not importance**:

> A step is a gate **iff** skipping it causes harm that cannot be remediated after the fact.

A fraud check is *not* a gate. It is important, but its outcome is recoverable after the booking — we can cancel, flag the account, hold the payout, or require ID before the appointment. Irrevocably sending money out is a gate. So is anything where the customer has already been told something we cannot then undo.

This test matters because the intuitive definition ("its purpose is to block something") classifies nearly every control as a gate, and a taxonomy where everything is a gate protects nothing.

#### Skipped is not forgotten

A step that is skipped because its dependency was unavailable records a **debt**:

```elixir
step :check_fraud,
  class: :read,
  kind: :skippable,
  on_unavailable: {:proceed, owe: :fraud_review}
```

`on_unavailable: {:proceed, owe: ...}` writes a pending-review row keyed to the business entity. A sweeper evaluates the backlog once the dependency recovers and can still act post-hoc. This is the standard fail-open-then-reconcile pattern: the customer is unaffected, and the control is deferred rather than lost.

`on_unavailable:` is **required** on any step whose dependency can be unavailable. There is no implicit default — either `{:proceed, owe: ...}` or `:fail`.

#### Unavailable, rejected, and approved are three states

| Dependency says | Proceed? | Debt recorded |
|---|---|---|
| unavailable / timeout | **yes** | yes |
| reject | **no** | no — it was checked |
| approve | yes | no |

**Fail open on unavailability; fail closed on rejection.** If those two ever collapse into one error path — a broad `rescue`, or a rejection modelled as an exception — then triggering an error becomes a way through the control, and a deliberate fail-open policy turns into a documented bypass. Business rejections are return values, never exceptions. This is enforced at compile time ([§9](#9-compile-time-enforcement)) and is the load-bearing rule of this section.

### 4.5 Invariant 5 — Business-scoped keys and a shared pivot ledger

```elixir
def pivot_key(%{booking_id: id}), do: "deposit_capture:booking:#{id}"
```

Keys derive from business facts — never `workflow_id`, a replay step counter, a run ID, a generated UUID, or a timestamp.

Why this exact rule: a workflow-scoped key is reset-safe but fails cross-*type* recovery, and cross-type recovery is now the **only** mechanism available for moving work off a broken type. A different type has a different step sequence, so a workflow-scoped key produces a different value for the same business action and we double-charge. Business-scoped keys also mean **there is nothing to transmit at recovery time**: any type, given the same booking, computes the same key. Derivation beats transmission, because a transmission channel can break or be forgotten.

Corollary: **pivots are named by business intent, not by call site.** `deposit_capture` and `final_capture` are distinct pivots on one booking; two call sites of the same code path are not.

Keys make the question askable. **The ledger answers it.** New table, owner TBD ([§11](#11-open-questions)):

| Column | Purpose |
|---|---|
| `pivot_key` | unique index — the enforcement point |
| `completed_at` | audit |
| `operator_id`, `reason` | set only for operator overrides ([§7.3](#73-skipping-a-bad-step)) |

- **Dedup is enforced by the unique index, not by workflow state.** After a reset or a fallback the workflow has genuinely forgotten it ever did the write. The database is the only thing that remembers.
- **An undo shares its forward action's key**, so compensation can answer "did this specific thing happen?" when a write committed but the activity result was lost.
- **Emit a metric when the ledger skips a pivot.** Not for correctness — to know the dedup path is exercised. A key that never dedupes is a key we cannot trust in an incident.

### 4.6 Invariant 6 — 24-hour execution cap

The library sets `workflow_execution_timeout = 24h`, which per the API is the *"total workflow execution timeout including retries and continue as new"* — the only knob that caps a continue-as-new chain. Overriding it requires the loud escape hatch ([§9](#9-compile-time-enforcement)).

This is what makes Invariant 1 cheap: the previous type drains within a day, so exactly two types are ever live and deletion is a timer rather than a query.

**Consequence to accept up front:** anything legitimately long-lived (a reminder three weeks out) is a *fresh workflow started later by a scheduler*, never a long-lived execution or a continue-as-new chain.

### 4.7 Invariant 7 — Types are re-enterable from any step boundary

This is the deepest requirement in the RFC and the one that carries the most engineering.

A cross-type transition ([§6](#6-fallback)) does not *resume* an execution — continue-as-new starts a **fresh run** of the target type. Pending timers, in-flight activities, and every workflow-local variable are gone. So a type cannot assume it begins at step 1 with nothing done; it must be able to start mid-process, discover what has already happened, and continue.

Three rules follow:

- **Workflow-local state must be reconstructible from durable business state at any step boundary.** A booking's appointment time, its deposit status, and its reminder schedule live in the booking record and the ledger — never only in a workflow variable. If a value exists solely in workflow state, that step boundary is not a legal transition point.
- **Every type is idempotent from the top.** Entering at step 1 with the ledger already showing `hold_slot` and `deposit_capture` complete must skip them and land on the correct next step. This is not an optimisation; it is what makes a transition legal at all.
- **Timers are recomputed, not inherited.** A reminder wait is re-established from the appointment time, not carried across.

Two caveats that follow from continue-as-new's mechanics:

- **Transition only at a quiescent point.** Continue-as-new does not wait for in-flight activities; an abandoned activity can still complete into a dead run. Pivot keys make the resulting double-effect safe, which is the whole reason [§4.5](#45-invariant-5--business-scoped-keys-and-a-shared-pivot-ledger) is a hard requirement rather than a nicety.
- **Signals racing a transition need care.** A signal arriving as the transition commits can land on the closing run. Signal handlers must be re-derivable from business state, or the signal must be re-sent.

The practical upshot: **the remaining hard work is not versioning, it is making workflow state reconstructible.** That work lives in our programming model, not in Temporal.

## 5. Rollout

### 5.1 Routing is a flag, and it lives in one function

```elixir
# the ONLY place in the codebase that names a workflow type
def route(:booking, salon_id) do
  if Flags.enabled?(:booking_v2, salon_id), do: Booking.V2, else: Booking.V1
end
```

Rules:

- **Nothing else names a type** — not callers, not child-workflow starts, not tests.
- **The flag is read by the caller, outside the workflow.** Never inside workflow code: the value flips mid-execution, replay takes the other branch, nondeterminism. Enforced at compile time.
- **A routing lookup must never fail a start.** If the flag service is unavailable, fail closed to the previous type and start the workflow.

Preferred over a percentage ramp because selection is **deterministic**: a canary salon is always on V2, so a support ticket is reproducible and attributable. A dice roll produces bug reports that cannot be reproduced.

|  | Percentage ramp | Flag-selected type |
|---|---|---|
| Selection | random % of starts | deterministic cohort (salon, country, plan) |
| Granularity | whole Deployment | per family, per caller |
| Reproducible | no | yes |
| Rollback of new starts | server API call | flag flip |

### 5.2 Visibility must key off the family, not the type

This is the operational tax of type versioning and it must be paid **before** the first branch, not during an incident.

- Stamp `FreshaWorkflowFamily = "booking"` and `FreshaCanaryCohort` as search attributes at start.
- Every dashboard, alert, and batch query keys off **`FreshaWorkflowFamily`**, never `WorkflowType`. Otherwise every branch forks every dashboard.
- **Signal and query contracts are stable across a family.** An external service sending `booking_confirmed` must work whichever type is running. A type may add handlers; it may not rename or remove them.

## 6. Fallback

### 6.1 Mechanism

A failing type hands off to its declared predecessor using continue-as-new **with a different workflow type** — supported by the API (`ContinueAsNewWorkflowExecutionCommandAttributes.workflow_type`) and already available in `temporalex` via the `:workflow_type` option on `continue_as_new!`:

```elixir
rescue
  e in Fresha.Workflow.FallbackError ->
    Workflow.fallback!(reason: e)   # → continue_as_new!(input, workflow_type: fallback_to)
```

Properties, all free:

- **Same workflow ID, new run.** Callers holding the workflow ID keep working; the execution chain is linked.
- **B's closure records why**, in history, next to the failure.
- **Nothing needs passing.** The successor derives the same `pivot_key`s from the same booking and the ledger skips what already happened. What *is* passed is **provenance** — source type, source run ID, error — as an audit breadcrumb.

One budget note: `workflow_execution_timeout` spans continue-as-new, so a fallback inherits the *remaining* 24h. Falling back at hour 20 leaves four hours. Correct behaviour, worth knowing.

### 6.2 A fallback may never skip a gate

This is the load-bearing safety rule. "The fraud check errored" is three different events:

1. **Transient** — the fraud service is down. The retry policy's job. Falling back here means every dependency blip silently disables fraud checking.
2. **Deterministic bug** — nil crash, contract mismatch, bad payload. Fallback is correct.
3. **The check works and returns "reject."** A business outcome, not an error.

Case 1 is not a fallback at all — it is `on_unavailable: {:proceed, owe: :fraud_review}` ([§4.4](#44-invariant-4--three-activity-classes-two-step-kinds)). The booking proceeds, the check becomes a debt, and the type does not change. Reaching for a fallback here would be using a structural mechanism to paper over a dependency blip.

Case 2 is what fallback is for.

**Case 3 must never reach the fallback handler.** If a rejection is modelled as an exception and caught by a slightly-too-broad `rescue`, we have built a **bypass**: fail the check, fall back to the type without the check, booking proceeds. That is a plausible coding mistake, not an exotic one, and it is what someone probing the booking flow would look for. Only a narrow, explicitly-typed `FallbackError` triggers a fallback; retryable failures exhaust their retry policy first, and business rejections are return values.

Enforcement is at compile time. A fallback target must contain every `:gate` its source contains:

```elixir
defworkflow Payout.V2, steps: [..., :verify_beneficiary, ...], fallback_to: Payout.V1
# ** (CompileError) Payout.V2 declares gate :verify_beneficiary;
#    fallback target Payout.V1 does not contain it
```

A fraud check is deliberately *not* a gate under the remediability test in [§4.4](#44-invariant-4--three-activity-classes-two-step-kinds), so `Booking.V2 → Booking.V1` compiles. Beneficiary verification before an irrevocable payout is a gate, so that route does not.

### 6.3 Rules

- **Compensate source-only steps before handing off.** The predecessor does not contain the source's extra steps, so any *partial* state they wrote is orphaned and nothing will ever resolve it. Fallback runs undos for steps that exist only in the source type.
- **Debts survive the transition.** A row written by `on_unavailable: {:proceed, owe: ...}` is keyed to the business entity, not the workflow, so it is not orphaned and must **not** be compensated away — the sweeper still owes that review whichever type finishes the booking. Distinguishing a deliberate debt from orphaned partial state is the reason debts are recorded through one declared mechanism rather than by ad-hoc writes inside steps.
- **Single hop.** The predecessor failing too pages a human. No chaining, no ping-pong under load.
- **Fallback count is page-worthy**, not a dashboard tile. One fallback is an incident; forty thousand is a different incident.
- **The trigger defaults to manual** (an operator command or signal), opt-in to automatic per family.

The reason for that last rule is an asymmetry worth stating plainly: **stuck is visible and recoverable; silently degraded is neither.** Forty thousand stuck bookings is loud, contained, and fixable. Forty thousand bookings that quietly took the older path at 3am because a dependency flickered is something discovered weeks later in a chargeback report. Auto-fallback converts a visible failure into an invisible degradation, which reads as more resilient and can be less safe. The gate check bounds that risk — but gate declarations are a human judgement the compiler can enforce and cannot make, so manual default buys evidence that the declarations are honest.

## 7. Recovery playbook

| What's broken | Tool | Cost |
|---|---|---|
| Activity failing on bad input or a bad downstream | `activity pause` / `complete` / `fail` | No rewind |
| Bug in a released type, replay-safe fix | Edit in place; propagates at next workflow task | None |
| Pivot already done out of band | Ledger pre-mark, then reset | Re-runs activities after the reset point |
| Type is structurally broken for this execution | **Fallback** ([§6](#6-fallback)) | Compensates source-only steps; ledger skips the rest |
| Unrecoverable | Terminate + compensate + restart | Full |

Two facts shape every rung:

- **Reset rewinds; it cannot skip.** It copies a history *prefix* — the only freedom is prefix length. There is no "resume at event 45, omitting 41–44."
- **Reset cannot change workflow type**, and **reset does not run compensations.** It discards history; it never executes undo logic. Compensation from within the workflow is normal and correct whenever the workflow can still make decisions — an activity failing does not imply its undo will fail. It is unavailable only when the failure is in the workflow's own decision logic.

Because pivots are keyed, the standard recovery is **re-run forward, not compensate**: reset or fall back, re-execute, and let the ledger no-op whatever already happened. Undos are for abandoning a partially-completed sequence (slot held, payment failed, release the slot).

### 7.1 Stall detection

`TemporalReportedProblems` records the last workflow-task failure cause after successive failures and clears on success. It is the primary alert source: workflow-task failures retry indefinitely, so a stalled execution never *fails* and will not appear in error dashboards.

### 7.2 Same-type reset

```
temporal workflow reset \
  --query 'FreshaWorkflowFamily = "booking" AND ExecutionStatus = "Running"' \
  --type LastWorkflowTask --reason "unstick after 7c3a1 fix"
```

Valid reset points are workflow-task boundaries. Signals are re-applied by default. Reset cannot change workflow input, but `post_reset_operations` with the `SignalWorkflow` variant injects state atomically — the signal lands before the first new workflow task, so the workflow sees it on its very first task with no race.

### 7.3 Skipping a bad step

There is no skip primitive. Three ways to get the effect, cheapest first:

1. **Activity operations — no rewind.** `activity complete --result '{...}'` feeds a synthetic result; `activity fail` pushes it down the saga's error path; `activity pause --reason` freezes retries while we decide. Caveat: this forges a result, and whatever the activity was meant to do to the world *did not happen*. Only defensible when the effect does not matter or was applied out of band.
2. **Ledger pre-mark, then reset.** Insert the ledger row (operator ID + reason), reset, and the activity re-runs, consults the ledger, and no-ops. **This is our skip primitive and it lives in our own database.** It works identically across types.
3. **Fallback** to a type that does not contain the step — subject to [§6.2](#62-a-fallback-may-never-skip-a-gate).

**Escape hatches are built in advance or not at all.** The library ships exactly one: an `operator_override` signal marking **named** pivots as satisfied — the ledger mechanism with an audit trail, cheap because pivots are already named by business intent.

**No generic "skip step N".** Arbitrary skips are arbitrary corruption, and under pressure it gets used by someone who does not know what that step guarded. Overrides are restricted to named pivots, require a reason, record the operator, and increment an alertable metric.

## 8. Ownership

| Concern | Owner | Why |
|---|---|---|
| Type/step declarations, immutability fingerprints, activity classes, step kinds, `pivot_key` generation, fallback-target gate check, flag-in-workflow ban, 24h timeout | **Library** (compile time) | Only enforceable where the code is |
| Telemetry by family and type; ledger-skip and fallback counters | **Library** | Feeds rollout and incident decisions |
| Forward replay gate | **CI**, blocking | Certifies in-place edits are replay-safe |
| Batch reset, activity operations, operator overrides, type retirement | **`houston` CLI** | Recovery must not depend on booting the app that is on fire |
| Pivot ledger | **New table + service owner (TBD)** | The only mechanism for moving work between types |

## 9. Compile-time enforcement

All checks are `@behaviour` plus `@after_compile` AST scans, or a fingerprint manifest checked in CI. No runtime cost; failures land in review, not at 2am.

1. Every activity declares `:read`, `:pivot`, or `:irreversible`.
2. A `:pivot` exports `pivot_key/1`, plus `undo/2` where review requires it.
3. `pivot_key/1` references only business arguments — never step counters, `UUID`, timestamps, run IDs, or workflow IDs.
4. No `:irreversible` step precedes a `:pivot` in a step list.
5. Every step declares `:skippable` or `:gate`.
6. **A `fallback_to:` target contains every `:gate` its source contains.**
7. Every step whose dependency can be unavailable declares `on_unavailable:` — `{:proceed, owe: ...}` or `:fail`. No implicit default.
8. **A step's rejection path does not raise.** A business "no" is a return value; only infrastructure failure raises. This is what keeps fail-open-on-unavailability from becoming a bypass.
9. A `:gate` is not reachable by the `operator_override` signal. Gates are fixed or the execution parks for review; there is no per-execution gate skip.
10. **A released step module's fingerprint has not changed.** This is the mechanical form of Invariant 1 and the reason the freeze lives at step level: a step is small enough to fingerprint meaningfully, a whole workflow is not.
11. Workflow modules do not reference the flag client.
12. Only `Fresha.Workflow.route/2` names a workflow type.
13. `workflow_execution_timeout` is not raised above 24h.

**The opinionated path must be the shortest path.** If compliance costs ceremony, engineers will call `temporalex` directly and we will have two standards. The escape hatch is therefore loud rather than absent — `@fresha_unsafe reason: "..."`, greppable and reviewable. Missing escape hatches produce forks.

## 10. Guarantees — for the README

> The library guarantees **at-most-once effect per business key**, **correct unwinding of incomplete sequences**, that **an execution's behaviour cannot change mid-flight except by an explicitly replay-safe bugfix**, and that **a control skipped for unavailability is recorded as a debt rather than lost**. It guarantees nothing about whether the values were right, and it cannot guarantee that a debt is ever paid — that needs a named owner per `owe:` tag.

Also true and worth stating: freezing a type freezes our orchestration, not the downstream services our activities call.

## 11. Open questions

1. **Who owns the pivot ledger?** It needs a service owner, schema review, and a retention policy. Under type versioning it is now the *only* mechanism for moving work between types, so nothing else here works without it.
2. **Where does the forward replay corpus come from?** Downloading production histories is easy; storing and refreshing them without creating a data-protection problem is not. Real customer data in a CI fixture needs a sign-off.
3. **Do we use Schedules?** If so, scheduled starts must route through `route/2` — which means a reconciliation job when the current type changes, since a schedule's action names a type statically.
4. **Step granularity.** Invariant 1's fingerprint check is only as useful as the step decomposition. Too coarse and every change branches a step; too fine and the step library sprawls. Needs a worked example on `booking` before v1.
5. **`temporalex` gaps.** Available today: `patched?/1` (`lib/temporalex/workflow/api.ex:264`) and `continue_as_new!` with `:workflow_type` (`lib/temporalex/core/command_builder.ex:21`). Missing: a client-side `ResetWorkflowExecution` including `post_reset_operations`, and activity operations. The SDK currently only decodes `reset_workflow_failure_info` (`lib/temporalex/backend/temporal_core/codec.ex:59`). Which of these land in `temporalex` versus the wrapper?
6. **Bounds on fail-open.** Two follow-ups to the decision in [§12](#12-rejected-alternatives), both open: (a) should we fail closed above a booking-value threshold, on the same asymmetric-risk logic that justifies failing open in the first place; (b) at what debt-backlog volume do we page, so that continuing to operate without a control stays a conscious choice rather than a discovery in next month's chargebacks?
7. **Who owns each debt sweeper?** `on_unavailable: {:proceed, owe: ...}` creates an obligation. The library can record it; it cannot evaluate it. Every `owe:` tag needs a named owner and an SLA before the step ships, or debts accumulate unread.

## 12. Rejected alternatives

**Worker Deployment Versioning with pinned workflows** — the first draft of this RFC. Pinning gives the same mid-flight stability property, but pays for it with a Temporal subsystem: versioning behaviour declarations, ramping, drainage status, reaping timers, reset-with-move for rollback, and `TemporalUsedWorkerDeploymentVersions` queries for remediation. Type versioning gets the property by construction, keeps one worker fleet, and *keeps the hotfix path open* — a bugfix propagates to in-flight executions immediately, where a pinned population needs a batch reset or a batch `auto_upgrade` override. Rejected as strictly more machinery for the same guarantee.

**`auto_upgrade` as the default.** Its prize is real: fixes propagate without a reset. Its price is that every engineer keeps every change replay-compatible with every in-flight history, forever, and pays it unevenly. Type versioning keeps the prize for the case that wants it (in-place bugfixes, §4.3) and removes the risk for the case that does not (behaviour changes become new types).

**Patching as the primary strategy.** `patched?` works, and `temporalex` implements it correctly. But it only gates *structural* divergence: a change to the deposit percentage from 20% to 25% has nothing to gate, replays cleanly, and silently charges an in-flight booking at a rate the customer was never quoted. Patching is retained as the tool for replay-hostile bugfixes, not as the versioning strategy.

**Workflow-scoped idempotency keys** (`workflow_id` + step counter). Reset-safe, but they break cross-type recovery, which is now the entire fallback mechanism.

**Passing keys forward at fallback or reset.** Reset cannot change workflow input; continue-as-new can, so this is *possible* on the fallback path. It is still rejected: business-scoped derivation makes the transmission unnecessary, and a channel that exists is a channel that can break.

**Payload fingerprinting in the ledger**, to catch "already done with a different value." Scope creep — it puts the library in the data-correctness business to catch a bug class that tests and review own. See [§3](#3-non-goals).

**Failing closed when a control is unavailable.** Rejected as a business decision, recorded here because a future reader will question it: blocking bookings across the marketplace to avoid fraud exposure on a fraction of them is the worse trade. Fresha accepts bookings when the fraud service is down, records the check as a debt, and reconciles post-hoc ([§4.4](#44-invariant-4--three-activity-classes-two-step-kinds)). Decision owner: CTO. Two bounds remain open for a follow-up ([§11](#11-open-questions)): failing closed above a booking-value threshold, and paging when the debt backlog crosses a volume threshold so that continuing stays a conscious choice.

**Automatic fallback by default.** See [§6.3](#63-rules). The mechanism is built; the trigger starts manual.

**A generic "skip step N" facility.** See [§7.3](#73-skipping-a-bad-step).

**Wrapping the full `temporalex` API.** Every wrapped function is an upstream migration we own forever. Keep the library to declarations, generation, and lint; keep API calls in tooling we can rewrite in an afternoon.

---

## Appendix A — Verified API surface

Checked against `temporalio/api`, `temporalio/temporal`, the local `temporal` CLI, and this repository on 2026-08-04.

### Protos

| Field | Location | Used for |
|---|---|---|
| `workflow_type = 1`, `input = 3` | `ContinueAsNewWorkflowExecutionCommandAttributes` | Fallback: continue-as-new into a different type ([§6.1](#61-mechanism)) |
| `workflow_execution_timeout = 5` | `NewWorkflowExecutionInfo` | *"Total workflow execution timeout including retries and continue as new"* — the 24h cap ([§4.6](#46-invariant-6--24-hour-execution-cap)) |
| `post_reset_operations = 8` | `ResetWorkflowExecutionRequest` | Atomic state injection at reset. Applied to the **new** run, **in order**, **all before the first new workflow task is generated** |
| `PostResetOperation.variant` | `workflow/v1` | oneof `SignalWorkflow` \| `UpdateWorkflowOptions`. No durable Workflow Update variant — [#7551](https://github.com/temporalio/temporal/issues/7551), open since Dec 2024. Server support merged in [#7719](https://github.com/temporalio/temporal/pull/7719) (May 2025), so ≈1.28+ |

### `temporalex` surface in use

- `Temporalex.Workflow.API.patched?/1` — `lib/temporalex/workflow/api.ex:264`. Replay semantics in `lib/temporalex/core/executor.ex:2363`: on replay, a patch ID absent from history returns `false`.
- `continue_as_new!` with `:workflow_type` — options list at `lib/temporalex/core/command_builder.ex:21`, resolution at `:87`.

### Search attributes

- `TemporalReportedProblems` — last workflow-task failure cause after successive failures, cleared on success. Primary stall alert ([§7.1](#71-stall-detection)).
- Custom: `FreshaWorkflowFamily`, `FreshaCanaryCohort` — stamped at start, and the key for every dashboard and batch query ([§5.2](#52-visibility-must-key-off-the-family-not-the-type)).

### CLI

- `temporal workflow reset` — `--type FirstWorkflowTask|LastWorkflowTask|LastContinuedAsNew|BuildId`, `--event-id`, `--reapply-exclude All|Signal|Update`, `-q/--query`, `-y`. Valid reset points are workflow-task boundaries (`WorkflowTaskStarted`/`Completed`/`Failed`/`TimedOut`). For batch resets, limit to `FirstWorkflowTask`, `LastWorkflowTask`, or `BuildId`.
- `temporal activity` — `pause --reason` / `unpause`, `complete --activity-id --result`, `fail`, `reset`, `update-options`.

## Appendix B — Deliberately unused

Temporal's documentation states that *"Worker Versioning is the recommended default for safely deploying new Workflow code."* This RFC does not use it. The deviation is deliberate and worth recording, because a future reader will ask.

Unused: Worker Deployments and Deployment Versions, `pinned` / `auto_upgrade` versioning behaviours, `VersioningOverride` on start and signal-with-start, ramping versions, `set-current-version`, drainage status, version reaping, reset-with-move (`reset with-workflow-update-options`), and the `TemporalWorkerDeployment*` search attributes.

Reasons:

1. **The guarantee we want is mid-flight behavioural stability, and type versioning provides it by construction.** No configuration can be misapplied, no override can be forgotten, no promotion can move an execution unexpectedly.
2. **It requires no coordination between deploy tooling and workflow code.** Worker versioning puts the safety property in the control plane, so a correct codebase can still be broken by a mis-sequenced deploy.
3. **It preserves in-place hotfixes.** One worker fleet means a replay-safe bugfix reaches in-flight executions at their next workflow task, with no batch operation.
4. **The residual risk is narrower and mechanically checkable.** Only in-place bugfixes carry replay risk, covered by a blocking forward replay gate plus `patched?` where needed.

Reconsider this decision if any of the following becomes true: the 24h cap is relaxed (types would stop draining, so more than two would be live); workflow families need to differ by *worker* dependency rather than by orchestration; or step-level immutability proves unenforceable in practice, in which case pinning's coarser freeze becomes the cheaper discipline.
