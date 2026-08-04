# RFC 0001 — Workflow Versioning, Rollout, and Recovery

| | |
|---|---|
| **Status** | Draft — for review |
| **Author** | Chris Greeno |
| **Date** | 2026-08-04 |
| **Scope** | An opinionated Fresha library layered over `temporalex` (working name `Fresha.Workflow`). Elixir only. |
| **Depends on** | Temporal Server with Worker Deployment Versioning and post-reset operations (≈ 1.28+; see [Appendix A](#appendix-a--verified-api-surface)) |

## 1. Summary

Four operational scenarios drive this design:

1. Upgrade a workflow and roll it back.
2. Canary a new workflow version to a percentage or cohort.
3. Recover when a deploy introduces a bug and in-flight executions are stuck.
4. Force saga steps to declare whether they mutate state, so any step can be safely re-attempted or unwound.

The proposal resolves them into **five invariants** enforced across three places — the Elixir library (compile time), a control-plane CLI (`houston`), and one new database table (the *pivot ledger*).

The central design decision: **workflows are pinned to a worker version at rest, and `auto_upgrade` is a transient, cohort-scoped operation applied to one change at a time.** This means no engineer is required to promise replay compatibility on every deploy, while in-flight work can still be migrated deliberately when someone has actually reviewed the diff.

The second central decision: **side-effecting activities are classified at compile time, and their idempotency keys are derived from business facts rather than from workflow-internal state.** This is what makes a step re-attemptable by *any* workflow — a different version, or a different workflow type entirely — which is what turns recovery from archaeology into a batch command.

## 2. Motivation

Temporal gives us the primitives (Worker Deployment Versioning, ramping, reset, reset-with-move, post-reset operations, activity operations) but no policy. Left unopinionated, each team picks a different combination, and the failure mode is discovered during an incident. Specifically:

- **`auto_upgrade` looks like the convenient default and is a trap.** Rolling the Current Version back replays new-code-authored history under old code. Temporal's own docs: *"If you made a version-incompatible change to your Workflow, and you want to roll back to an earlier version, it's not possible to patch it."* The failure is a silent mass stall of in-flight executions, not an error at deploy time.
- **A ramp does not de-risk what you think.** The ramp percentage applies **only to new workflow executions**. Promoting a version exposes 100% of the in-flight `auto_upgrade` population at once, no matter what the ramp says.
- **Reset re-runs activities.** Every recovery path re-executes side effects. Without a shared, business-keyed ledger, recovery is unsafe by construction, so teams avoid it and stuck workflows get terminated instead.

## 3. Non-goals

- **Detecting wrong values.** Compensation exists for *incompleteness*, not *incorrectness*. A step that writes £50 instead of £5 is an ordinary bug owned by tests, review, and the service that owns the table. This library takes no position on it.
- **Behavioural stability of downstream services.** Pinning freezes our workflow and activity code. It does nothing about the version of the service an activity calls. Pinned v1 calling today's payments service is *not* "running the old system."
- **Wrapping the whole SDK.** Client calls pass through to `temporalex` by thin delegation. Every wrapped function is one we must chase upstream forever.
- **Long-running workflows.** See Invariant 1: 24h is a hard cap.

## 4. Invariants

### Invariant 1 — Two routable versions; execution capped at 24 hours

- **Routable versions: exactly two** (Current and previous). This is what policy reasons about and what a rollback can target.
- **Alive worker versions: as many as have live pinned executions.** Under pinning this is a routing contract, not conservatism: a pinned workflow's workflow *and* activity tasks route to its version. Kill the worker and the execution stalls, because the task queue has no pollers for that version.
- Released versions are **immutable**.

The 24h cap is what makes this cheap. Versions with live pinned executions ≤ (deploys in 24h) + 1, which at our cadence is two or three. Version reaping becomes a timer — *reapable 24h + margin after it stops being Current* — rather than a drainage state machine.

**The cap must be enforced, not assumed.** The library sets `workflow_execution_timeout = 24h`, which per the API is the *"total workflow execution timeout including retries and continue as new"* — the only knob that genuinely caps a continue-as-new chain. Overriding it requires the loud escape hatch (§8).

**Consequence to accept up front:** anything legitimately long-lived (a reminder three weeks out) is modelled as a *fresh workflow started later by a scheduler*, never as a long-lived execution or a continue-as-new chain.

### Invariant 2 — The library pins at start

Every start sets an explicit `versioning_override`. The workflow declares its intent:

```elixir
use Fresha.Workflow, versioning: :pinned, max_lifetime: {:hours, 24}
```

```elixir
# caller side — evaluated once, outside the workflow, never replayed
version = Fresha.Rollout.version_for(BookingWorkflow, salon_id)
Fresha.Workflow.start(BookingWorkflow, args, versioning_override: {:pinned, version})
```

Pinned overrides are **inherited by child workflows, retries, continue-as-new, and cron workflows**, so one decision at the top propagates through the whole tree with no per-child plumbing.

Rules:

- **The policy lookup must never fail a start.** If the rollout/flag service is unavailable, fail closed to Current Version and start the workflow.
- **Never read a feature flag inside workflow code.** The flag flips mid-execution, replay takes the other branch, nondeterminism. Enforced at compile time (§8).
- **Activity code is free; workflow code is frozen.** Any dynamic config read belongs in an activity, whose result is recorded in history.

Two known leaks, both accepted:

- **Schedules** carry a *static* `versioning_override` fixed at schedule-create time. A reconciliation job updates schedules when the routable pair moves.
- **Ops-initiated starts** (CLI/UI) bypass the library. Mitigation: Current Version is always the safe default, so a bypass lands somewhere sane.

### Invariant 3 — Three activity classes

Every activity answers one question: *how do we make this safe to attempt twice?*

| Class | Answer | Requirement |
|---|---|---|
| **`:read`** | Nothing needed | — |
| **`:pivot`** | Idempotency key **or** undo | `pivot_key/1`, plus `undo/2` where a wrong value is plausible and consequential (money, availability slots) |
| **`:irreversible`** | Neither exists | Ordered last; must consult the ledger before acting |

Keyed and compensatable writes collapse into one class because they are two answers to the same question. `:irreversible` stays separate because it has no answer, only a constraint.

**`:read` carries one caveat.** Reads are safe to *execute* again, but on reset a read may return a *different value* than it did originally, so the workflow can take a different branch than the run we are trying to recreate. Reads are idempotent; decisions derived from reads are not stable across reset. Where the plan must not change, snapshot the read into the pivot's arguments instead of re-reading.

**`:irreversible` must exist as its own class.** Card capture is keyable but not undoable — a refund is a new, customer-visible event, not an undo. An SMS to a client is neither. With only two options someone will attach a key to the SMS activity and consider it solved.

### Invariant 4 — Business-scoped keys and a shared pivot ledger

```elixir
def pivot_key(%{booking_id: id}), do: "deposit_capture:booking:#{id}"
```

**Keys are derived from business facts, never from workflow-internal state.** Not `workflow_id`, not a replay step counter, not a run ID, not a generated UUID, not a timestamp.

Why this specific rule: a workflow-scoped key is reset-safe but fails cross-workflow recovery — a different workflow type has a different step sequence and possibly a different workflow ID, so the same business action produces a different key and we double-charge. Business-scoped keys satisfy both cases. It also means **there is nothing to pass at recovery time**: any workflow, any version, any type, given the same `booking_id`, computes the same key. Derivation beats transmission, because a transmission channel can break or be forgotten.

Corollary: **pivots are named by business intent, not by call site.** `deposit_capture` and `final_capture` are different pivots on the same booking; two call sites of the same code path are not.

Keys make the question askable. **The ledger answers it.** New table, owner TBD (§10):

| Column | Purpose |
|---|---|
| `pivot_key` | unique index — the enforcement point |
| `completed_at` | audit |
| `operator_id`, `reason` | set only for operator overrides (§7) |

Rules:

- **Dedup is enforced by the database's unique index, not by workflow state.** After a reset the workflow has genuinely forgotten it ever did the write. The DB is the only thing that remembers.
- **An undo shares its forward action's key**, so compensation can answer "did this specific thing happen?" when the write committed but the activity result was lost.
- **Emit a metric when the ledger skips a pivot.** Not for correctness — to know the dedup path is exercised at all. A key that never dedupes is a key we cannot trust in an incident.

### Invariant 5 — Recovery is a ladder, cheapest rung first

| What's broken | Tool | Cost |
|---|---|---|
| Activity failing on bad input or a bad downstream | `activity pause` / `complete` / `fail` | No rewind |
| Pivot already done out of band | Ledger pre-mark, then reset | Re-runs activities after the reset point |
| Workflow took the wrong path / stalled | Reset-with-move | Re-runs activities after the reset point |
| Unrecoverable | Terminate + compensate + restart | Full |

Two facts that shape every rung:

- **Reset rewinds; it cannot skip.** It copies a history *prefix* — the only degree of freedom is prefix length. There is no "resume at event 45, omitting 41–44." A skip must come from the code or state we land on.
- **Reset does not run compensations.** It discards history; it never executes undo logic. Compensation from within the workflow is normal and correct when the workflow can still make decisions — an activity failing does not imply its undo will fail. It is unavailable only when the failure is in the workflow's own decision logic (a nondeterminism stall, or a bug in the compensation branch itself), which is the rare case.

Because pivots are keyed, the standard recovery is **re-run forward, not compensate**: reset to before the bad step, re-execute, and let the ledger no-op whatever already happened. Undos are the fallback for abandoning a partially-completed sequence (slot held, payment failed, release the slot), not the primary path.

## 5. Rollout

Two independent canaries, because they de-risk different things.

### 5.1 Canary of starts — deterministic cohort

A caller-side flag chooses the pinned version at start. Preferred over Temporal's ramp because selection is **deterministic**: a canary salon is *always* on the new version, so a support ticket is reproducible and attributable. A 10% dice roll produces bug reports we cannot reproduce.

|  | Temporal ramp | Flag + pinned start |
|---|---|---|
| Selection | random % of starts | deterministic cohort (salon, country, plan) |
| Granularity | whole Deployment | per workflow type, per caller |
| Reproducible | no | yes |

**Stamp the cohort as a search attribute at start** (`FreshaCanaryCohort`). Every later control-plane operation is then a one-line visibility query instead of an explicit ID list assembled under time pressure.

**Deployment boundary = blast-radius boundary.** A ramp or a version promotion applies to a whole Deployment, so high-risk, high-value workflow types (payment capture, booking) get their own Deployment and task queue. This cannot be retrofitted.

### 5.2 Canary of migration — cohort-scoped `auto_upgrade`

The gap the ramp cannot fill: existing executions follow *Current*, not *Ramping*, so there is no percentage canary for the migration event itself. We build one:

1. Everything is pinned at rest. Promote v2 to Current — **nothing in-flight moves**.
2. Pull a wave forward:

```
temporal workflow update-options \
  --query 'TemporalWorkerDeploymentVersion = "fresha-bookings:v1"
           AND FreshaCanaryCohort = "wave-1"
           AND ExecutionStatus = "Running"' \
  --versioning-override-behavior auto_upgrade
```

3. Watch `TemporalReportedProblems` and per-version workflow-task failure rate. Clean → widen to wave-2. Stalling → stop and reset that wave back.
4. **Conclude the canary explicitly.** The override is sticky, so a wave left on `auto_upgrade` silently migrates again at the next promotion. Setting `--versioning-override-behavior unspecified` clears the override; the worker then reports `pinned` and the execution pins wherever it landed.

Ordering is a policy choice, not a dice roll: migrate low-value work before high-value work.

**The asymmetry:** this controls *entry*, not *exit*. Once an execution has written v2-authored history, flipping back to pinned-v1 does not rescue it — a config change cannot un-write history. Exit is always reset-with-move plus activity re-runs plus the ledger.

### 5.3 The backward replay gate

- **Forward** — new version replayed against a corpus of production histories. Standard.
- **Backward** — *current* version replayed against histories produced by the new version. Almost nobody does this, and it is the only thing that certifies rollback is available.

The gate runs **before wave-1 of a migration canary**, not on every CI build. Green means rollback is a lever we can pull; red means we learn now, not at 2am, that reset-with-move is the only path.

## 6. Recovery playbook

### 6.1 Bad version, new starts only (pinned population)

```
temporal worker deployment set-current-version \
  --deployment-name fresha-bookings --build-id v1
```

Stops the bleeding immediately. In-flight executions pinned to v2 are unaffected — they keep running coherently, which buys time to decide.

**Price of pinning, stated plainly:** a hotfix does not reach in-flight executions. Deploying v3 helps nobody currently pinned to v2. Remediation is always a batch operation — either pull them forward (§5.2) once someone has asserted the change is replay-safe, or reset them (§6.2).

### 6.2 Downgrade in-flight executions

Same workflow type, contaminated by a bad version:

```
temporal workflow reset \
  --query 'TemporalUsedWorkerDeploymentVersions = "fresha-bookings:v2"
           AND ExecutionStatus = "Running"' \
  --type BuildId --build-id v2 --reason "rollback v2" \
  with-workflow-update-options \
    --versioning-override-behavior pinned \
    --versioning-override-build-id v1 \
    --versioning-override-deployment-name fresha-bookings
```

- `--type BuildId` rewinds to before the *first workflow task processed by that build*, discarding all v2-authored history so v1 replays only v1-authored history. Only activities after that point re-run.
- **Pin to v1 — do not leave them `auto_upgrade`.** Otherwise the next promotion walks them straight back onto the code we just rescued them from.
- Footgun: per the CLI, a `BuildId` reset *"may be in a prior run, earlier than a Continue as New point."* Low risk for us given Invariant 1, but real if continue-as-new chains appear.
- For a cohort pinned from event 1, `--type FirstWorkflowTask` is always a valid reset point but re-runs **everything**. A mid-flight migration reset (`--type BuildId`) is the more surgical of the two.

### 6.3 Skipping a bad step

There is no skip primitive. Three ways to get the effect, cheapest first:

1. **Activity operations — no rewind.** `activity complete --result '{...}'` feeds a synthetic result and the workflow proceeds; `activity fail` pushes it down the saga's error path; `activity pause --reason` freezes retries while we decide. Caveat: this forges a result, and whatever the activity was supposed to do to the world *did not happen*. Only defensible when the effect does not matter or was applied out of band.
2. **Ledger pre-mark, then reset.** Insert the ledger row (operator ID + reason), reset, and the activity re-runs, consults the ledger, and no-ops. **This is our skip primitive and it lives in our own database.** It works identically across versions and across workflow types, because keys are business-scoped.
3. **Reset-with-move onto code that does not have the step.** The skip is a property of the code we land on. `post_reset_operations` + `SignalWorkflow` can flip a branch atomically before the first new workflow task — but **the branch must already exist** in the version we land on. We cannot invent one at rescue time.

**Escape hatches are built in advance or not at all.** The library ships exactly one: an `operator_override` signal marking **named** pivots as satisfied — the ledger mechanism with an audit trail, cheap because pivots are already named by business intent.

**No generic "skip step N".** Arbitrary skips are arbitrary corruption, and under pressure it will be used by someone who does not know what that step guarded. Overrides are restricted to named pivots, require a reason, record the operator, and increment an alertable metric.

### 6.4 Cross-type migration (WorkflowA → WorkflowB → back to A)

Reset **cannot change workflow type** — it is baked into `WorkflowExecutionStarted` and copied verbatim. So "go back to A" for in-flight B executions is: terminate B, start A, and let A skip what B already did via the shared ledger.

This works only because keys are business-scoped. It is the single strongest argument for Invariant 4.

## 7. Ownership

| Concern | Owner | Why |
|---|---|---|
| Versioning declaration, `max_lifetime`, 24h timeout | **Library** (compile time) | Properties of the workflow code |
| Activity classes, `pivot_key` generation, ordering lint, flag-in-workflow ban | **Library** (compile time) | Only enforceable where the code is |
| Telemetry tagged with deployment version; ledger-skip metric | **Library** | Feeds the promote/rollback decision |
| `create-version`, ramp, gated promote, rollback, batch reset-with-move, wave migration, version reaping, schedule reconciliation | **`houston` CLI** | The rollback path must work when the Elixir app is broken. Recovery must not depend on booting the thing that is on fire. |
| Pivot ledger | **New table + service owner (TBD)** | The one artifact that makes cross-version and cross-type recovery possible |
| Backward replay gate | **CI**, run before wave-1 | Certifies that rollback is available |

## 8. Compile-time enforcement

All checks are `@behaviour` + `@after_compile` AST scans. No runtime cost; failures land in CI, not at 2am.

1. Every activity declares `:read`, `:pivot`, or `:irreversible`.
2. A `:pivot` exports `pivot_key/1`, and `undo/2` where required by review.
3. `pivot_key/1` references only business arguments — never step counters, `UUID`, timestamps, run IDs, or workflow IDs.
4. No `:irreversible` activity precedes a `:pivot` in a saga definition.
5. Workflow modules do not reference the flag client.
6. `workflow_execution_timeout` is not overridden above 24h.

**The opinionated path must be the shortest path.** If compliance costs ceremony, engineers will call `temporalex` directly and we will have two standards. The escape hatch is therefore loud rather than absent — `@fresha_unsafe reason: "..."`, greppable and reviewable. Missing escape hatches produce forks.

## 9. Guarantees — for the README

> The library guarantees **at-most-once effect per business key** and **correct unwinding of incomplete sequences**. It guarantees nothing about whether the values were right.

Also true and worth stating: **pinning guarantees determinism, not behavioural stability.** Downstream services are not versioned by this design.

## 10. Open questions

1. **Who owns the pivot ledger?** It needs a service owner, a schema review, and a retention policy. Nothing else in this RFC works without it.
2. **Where does the backward replay corpus come from?** Downloading histories from the canary wave is straightforward; storing them, refreshing them, and keeping them out of a data-protection problem is not. Real customer data in a CI fixture needs a decision.
3. **Deployment sharding.** Which workflow types get their own Deployment and task queue? Blast-radius boundaries cannot be retrofitted, so this is needed before the first version is cut.
4. **Do we use Schedules?** If yes, the reconciliation job in Invariant 2 is in scope for v1.
5. **`temporalex` gaps.** The SDK currently only decodes `reset_workflow_failure_info` (`lib/temporalex/backend/temporal_core/codec.ex`). Required client surface: `versioning_override` on start and signal-with-start, `ResetWorkflowExecution` including `post_reset_operations`, `UpdateWorkflowExecutionOptions`, and activity operations. Which of these land in `temporalex` versus the wrapper?

## 11. Rejected alternatives

**`auto_upgrade` as the default.** Its prize is real — fixes propagate to running executions without a reset. Its price is that every engineer must keep every change replay-compatible with every in-flight history, forever, and they will pay it unevenly. The failure mode (mass stall of in-flight executions at the instant of promotion) is worse and more sudden than pinning's (old code runs for at most a day). **Compatibility is asserted per-change by whoever reviewed the diff, not promised per-deploy by everyone.** §5.2 buys the hotfix property back as a deliberate operation.

**Workflow-scoped idempotency keys** (`workflow_id` + replay step counter). Reset-safe, but they break cross-type recovery, which is scenario 4's entire point.

**Passing keys forward at reset time.** Reset cannot change workflow input — the copied prefix includes `WorkflowExecutionStarted` with the original payload. Keys *could* be injected via `post_reset_operations` + `SignalWorkflow`, but business-scoped derivation makes the transmission unnecessary.

**Payload fingerprinting in the ledger** to catch "already done with a different value." Scope creep: it puts the library in the data-correctness business to catch a bug class that ordinary tests and review own. See §3.

**An external compensator workflow as the standard path.** Over-engineered. Compensation from within the workflow is fine whenever the workflow can still make decisions, which is the common case. Keep it as the rare fallback for a broken orchestrator.

**A generic "skip step N" facility.** See §6.3.

**Wrapping the full `temporalex` API.** Every wrapped function is an upstream migration we own forever. Temporal's versioning surface has already churned once (Build-ID versioning → Worker Deployment Versioning). Keep the library to declarations, generation, and lint; keep API calls in tooling we can rewrite in an afternoon.

---

## Appendix A — Verified API surface

Checked against `temporalio/api`, `temporalio/temporal`, and the local `temporal` CLI on 2026-08-04. Server-side post-reset operations landed in [temporalio/temporal#7719](https://github.com/temporalio/temporal/pull/7719) (merged May 2025), so a reasonably recent server (≈1.28+) is required.

### Protos

| Field | Location | Note |
|---|---|---|
| `versioning_override = 25` | `StartWorkflowExecutionRequest`, `SignalWithStartWorkflowExecutionRequest` | Pin at start |
| `versioning_override = 15` | `NewWorkflowExecutionInfo` | Valid in `ScheduleAction` (which excludes only `workflow_id_reuse_policy` and `cron_schedule`) — so scheduled starts *can* be pinned, statically |
| `VersioningOverride.override` | `workflow/v1` | oneof `pinned` \| `auto_upgrade` \| `one_time`. Pinned overrides are inherited by child workflows, retries, continue-as-new, and cron |
| `post_reset_operations = 8` | `ResetWorkflowExecutionRequest` | Applied to the **new** run, **in order**, **all before the first new workflow task is generated** |
| `post_reset_operations = 5` | `BatchOperationReset` | Same semantics, batched |
| `PostResetOperation.variant` | `workflow/v1` | oneof `SignalWorkflow` \| `UpdateWorkflowOptions`. **No durable Workflow Update variant** — see [#7551](https://github.com/temporalio/temporal/issues/7551), open since Dec 2024 |
| `versioning_behavior = 8`, `worker_deployment_name = 10`, `deployment_version = 11` | `WorkflowTaskCompletedEventAttributes` | Per-task version stamping; makes mixed-version histories inspectable |
| `workflow_execution_timeout = 5` | `NewWorkflowExecutionInfo` | *"Total workflow execution timeout including retries and continue as new"* |

### Search attributes

From `common/searchattribute/sadefs/constants.go`:

- `TemporalWorkerDeploymentVersion` — current version of the execution.
- `TemporalWorkerDeployment` — current deployment.
- `TemporalWorkflowVersioningBehavior` — `pinned` or `auto_upgrade`.
- `TemporalUsedWorkerDeploymentVersions` — **KeywordList** of *every* version that has completed a workflow task for this execution, `"<deployment_name>:<build_id>"` per entry. This is how the contaminated set is selected in §6.2.
- `TemporalReportedProblems` — last workflow-task failure cause after successive failures, cleared on success. Primary stall alert source.

### CLI

- `temporal workflow reset` — `--type FirstWorkflowTask|LastWorkflowTask|LastContinuedAsNew|BuildId`, `--build-id`, `--event-id`, `--reapply-exclude All|Signal|Update`, `-q/--query`, `-y`. Valid reset points are workflow-task boundaries (`WorkflowTaskStarted`/`Completed`/`Failed`/`TimedOut`). Signals are re-applied by default.
- `temporal workflow reset with-workflow-update-options` — the docs call this **Reset-with-Move**: *"allows you to atomically Reset your Workflow and set a Versioning Override on the newly reset Workflow."* Flags: `--versioning-override-behavior pinned|auto_upgrade`, `--versioning-override-build-id`, `--versioning-override-deployment-name`.
- `temporal workflow update-options` — `-q/--query` (batched), `--versioning-override-behavior pinned|auto_upgrade|unspecified`.
- `temporal worker deployment` — `set-current-version`, `set-ramping-version --percentage` / `--delete` / `--ignore-missing-task-queues` (do not blanket-override this protection), `describe-version` (drainage), `delete-version`.
- `temporal activity` — `pause --reason` / `unpause`, `complete --activity-id --result`, `fail`, `reset`, `update-options`.

### Documented behaviour relied on

- The ramp percentage applies to **new workflow executions only** — *"a configurable percentage of Workflows are routed to it unless they were previously pinned on a different version."*
- *"If you made a version-incompatible change to your Workflow, and you want to roll back to an earlier version, it's not possible to patch it."*
- For batch resets, limit to `FirstWorkflowTask`, `LastWorkflowTask`, or `BuildId`.
