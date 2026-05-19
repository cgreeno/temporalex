# Implementation Slices

This document defines the first implementation slices. They are intentionally core-only: build the deterministic workflow kernel and replay harness before server, backend, Rustler, or Temporal Core integration.

Use this with [implementation_principles.md](implementation_principles.md), [core.md](core.md), [scheduler_and_replay.md](scheduler_and_replay.md), and [core_testing.md](core_testing.md).

## Current Status

The repository has implemented the core through Slice 2 and the first server/backend integration layer:

- `Temporalex.Core.Executor` owns activation turns, scheduler rounds, replay matching, runner lifecycle, command sequencing, `parallel`, `phase`, signals, updates, and queries.
- `Temporalex.Workflow.API`, `Temporalex.Workflow`, and `Temporalex.Activity` provide the core-facing public workflow and activity surface for these slices.
- `Temporalex.Core.TestHarness` drives pure core activation transcripts and replay tests without server/backend/Rustler dependencies.
- `test/temporalex/core_executor_test.exs` verifies the mandatory Slice 1 and Slice 2 scenarios that are in scope for the core.
- `Temporalex.Worker`, `Temporalex.Server`, `Temporalex.Backend`, and `Temporalex.Backend.Test` implement the server/test-backend phase after the core slices.
- `test/temporalex/server_integration_test.exs` and `test/temporalex/backend_conformance_test.exs` verify worker supervision, activation routing, executor registry cleanup, activity task supervision, completion submission, and the backend behaviour contract.
- `Temporalex.Backend.TemporalCore`, `Temporalex.Native`, and the Rust crate in `native/temporalex_nif` implement the real Temporal Core/Rustler backend with native poll loops, protobuf conversion, ETF payloads, async completion submission, heartbeats, shutdown, workflow start options, activity retry/cancellation options, and client start/result/signal/query/update/cancel/terminate/describe operations.
- `test/temporalex/integration/temporal_core_integration_test.exs` starts a Temporal dev server and verifies end-to-end workflows through the Rust NIF and Temporal Core, including activities, heartbeats, client operation RPCs, invalid client option handling, and termination result decoding.
- Slice 1 and Slice 2 review gates are complete and recorded in [review_gates.md](review_gates.md).

The next implementation work should focus on full workflow cancellation propagation, public error polish, child workflows, local activities, Nexus operations, packaging, and broader production hardening. Server/backend routing should not change executor scheduling semantics.

## Slice 1: Sequential Core

Goal:

> A single root workflow runner can execute, block on activities and timers, resume from activation jobs, emit stable command decisions, and fail replay on nondeterminism.

This slice is complete when the pure Elixir core test harness can record and replay simple workflows using only core structs.

## Included

- [ ] Core structs for the first workflow path:
  - [ ] `Activation`
  - [ ] `Completion`
  - [ ] `Job.InitializeWorkflow`
  - [ ] `Job.ActivityResolved`
  - [ ] `Job.TimerFired`
  - [ ] `Job.CancelWorkflow`
  - [ ] `Job.RemoveFromCache`
  - [ ] `Command.ScheduleActivity`
  - [ ] `Command.StartTimer`
  - [ ] `Command.CompleteWorkflow`
  - [ ] `Command.FailWorkflow`
  - [ ] `Command.ContinueAsNew`

- [ ] Executor process:
  - [ ] one executor per workflow run
  - [ ] one root runner with thread id `[]`
  - [ ] `spawn_link/1` runner lifecycle
  - [ ] `Process.flag(:trap_exit, true)` in executor
  - [ ] single process dictionary key, `:__temporal_context__`
  - [ ] one activation processed at a time
  - [ ] no backend handles or Temporal Core types in executor state

- [ ] Workflow operation protocol:
  - [ ] all workflow API calls use `GenServer.call(executor, {:workflow_op, thread_id, op}, :infinity)`
  - [ ] non-pausing operations reply immediately
  - [ ] pausing operations hold `from`, append command if needed, mark the runner blocked, and do not reply
  - [ ] resolution jobs wake at most one pending caller

- [ ] First pausing operations:
  - [ ] activity execution emits `ScheduleActivity`
  - [ ] generated activity ids are deterministic and included in command identity
  - [ ] activity success resumes the blocked runner
  - [ ] activity failure or cancellation resumes the blocked runner with a workflow-visible error result
  - [ ] sleep emits `StartTimer`
  - [ ] timer fire resumes the blocked runner

- [ ] First non-pausing operations:
  - [ ] workflow info
  - [ ] cancellation flag set by `Job.CancelWorkflow`
  - [ ] cancellation flag read
  - [ ] workflow time from activation timestamp

- [ ] Completion semantics:
  - [ ] `{:ok, result}` emits `CompleteWorkflow`
  - [ ] `{:error, reason}` emits `FailWorkflow`
  - [ ] `API.continue_as_new!/2` emits terminal `ContinueAsNew`
  - [ ] unsupported return shape emits `FailWorkflow`
  - [ ] unexpected runner exception/exit emits `FailWorkflow`
  - [ ] `RemoveFromCache` activation runs no workflow code and emits an empty successful completion
  - [ ] nondeterminism fails the activation, not the workflow

- [ ] Replay:
  - [ ] replay runs workflow code again
  - [ ] replay emits command decisions
  - [ ] emitted decisions match the transcript in order
  - [ ] missing, extra, reordered, or changed decisions fail with nondeterminism
  - [ ] replay resolution jobs resume the pending caller for the matched sequence number

- [ ] Internal errors:
  - [ ] `%Temporalex.Core.Nondeterminism{}`
  - [ ] `%Temporalex.Core.SchedulerViolation{}`
  - [ ] clear activation failure shape for executor-to-harness/server reporting

- [ ] Core test harness:
  - [ ] start workflow with an initialize activation
  - [ ] collect yielded commands
  - [ ] deliver activity and timer resolution jobs
  - [ ] record a command/job transcript
  - [ ] replay from a transcript
  - [ ] expose enough state for invariant tests without changing production code paths

## Excluded From Slice 1

- [ ] `API.parallel/1`
- [ ] `API.phase/2`
- [ ] signals
- [ ] updates
- [ ] queries
- [ ] async handlers
- [ ] patch markers
- [ ] deterministic random and UUID helpers
- [ ] child workflows
- [ ] local activities
- [ ] cancellation propagation beyond storing and reading a workflow cancellation flag
- [ ] server process
- [ ] backend behaviour implementation
- [ ] Rustler
- [ ] Temporal Core protobuf conversion
- [ ] client API

## Failure Taxonomy For Slice 1

| Situation | Outcome |
|---|---|
| workflow returns `{:ok, result}` | successful activation with `CompleteWorkflow` |
| workflow returns `{:error, reason}` | successful activation with `FailWorkflow` |
| workflow calls `API.continue_as_new!/2` | successful activation with `ContinueAsNew` |
| workflow returns an unsupported shape | successful activation with `FailWorkflow` |
| workflow raises, throws, or exits unexpectedly | successful activation with `FailWorkflow` |
| emitted replay command does not match transcript | failed activation with `%Nondeterminism{}` |
| runner calls executor out of turn | failed activation with `%SchedulerViolation{}` |
| executor process crashes | process failure; server/harness concern |
| eviction activation | successful activation with no commands; teardown cached runner state |

Activation failure and workflow failure must remain distinct. `FailWorkflow` is a command in a successful activation completion. Nondeterminism and scheduler violations are activation failures.

## Command Identity For Slice 1

Replay matching compares deterministic command identity.

For `ScheduleActivity`, compare:

- command type
- sequence number
- thread id
- activity id
- activity type
- input terms
- options that affect Temporal activity command semantics

For `StartTimer`, compare:

- command type
- sequence number
- thread id
- duration

For terminal commands, compare:

- command type
- result or failure payload

Ignore backend-only fields such as task tokens, worker handles, protobuf metadata, and transport state.

## Blocking Protocol

Pausing operation flow:

1. Runner calls executor with a workflow operation.
2. Executor verifies the caller is the currently running thread.
3. Executor assigns the next sequence number if the operation emits a command.
4. Executor appends the command decision.
5. Executor records `%Pending{seq, thread_id, from, op}`.
6. Executor marks the thread blocked.
7. Executor does not reply to the caller.
8. A later activation delivers a matching resolution job.
9. Executor stores the result and marks the thread runnable.
10. When the scheduler grants the thread a turn, executor replies to the held caller.

For Slice 1 there is only the root thread, but the protocol should already use thread ids so `parallel` can slot in later.

## Test Checklist

- [ ] workflow completion emits `CompleteWorkflow`
- [ ] workflow explicit error emits `FailWorkflow`
- [ ] workflow `API.continue_as_new!/2` emits `ContinueAsNew`
- [ ] unsupported workflow return emits `FailWorkflow`
- [ ] workflow exception emits `FailWorkflow`
- [ ] activity call emits `ScheduleActivity` with seq `0`
- [ ] generated activity id is deterministic and stable on replay
- [ ] activity result resumes runner and workflow completes
- [ ] activity error or cancellation resumes runner with a workflow-visible error result
- [ ] timer call emits `StartTimer` with seq `0`
- [ ] timer fire resumes runner and workflow completes
- [ ] activity followed by timer emits stable seq `0`, then `1`
- [ ] replay of matching activity transcript succeeds
- [ ] replay of matching timer transcript succeeds
- [ ] replay with wrong command type fails nondeterminism
- [ ] replay with wrong activity input fails nondeterminism
- [ ] replay with wrong timer duration fails nondeterminism
- [ ] replay with extra or missing command fails nondeterminism
- [ ] blocked runner remains alive while waiting for resolution
- [ ] executor crash tears down linked runner
- [ ] runner carries only `:__temporal_context__`
- [ ] `Job.CancelWorkflow` sets the cancellation flag read by `API.cancelled?/0`
- [ ] eviction activation does not run workflow code

## Exit Criteria

Slice 1 is done when:

- [ ] all tests in this document pass
- [ ] command order is stable across repeated runs
- [ ] replay tests fail for every intentional mismatch case
- [ ] no implementation code depends on backend, Rustler, protobuf, or Temporal Core types
- [ ] the next slice can add deterministic scheduler rounds without rewriting the blocking protocol

## Intermission: Slice 1 Review

Do not start Slice 2 immediately after the Slice 1 checklist turns green.

First, review the implemented core in depth against [implementation_principles.md](implementation_principles.md), [core.md](core.md), [scheduler_and_replay.md](scheduler_and_replay.md), and [temporal_core_mapping.md](temporal_core_mapping.md).

The goal is to find design impedance before adding concurrency. If Slice 1 made any invariant awkward to uphold, fix the design while the surface area is still small.

Review checklist:

- [ ] compare implemented executor state to the documented ownership boundaries
- [ ] confirm blocking calls, pending calls, and held `GenServer.from()` values generalize cleanly to multiple workflow units
- [ ] confirm command identity and replay matching are precise enough for branch and handler commands
- [ ] confirm activation failure and workflow failure are impossible to confuse in code and tests
- [ ] confirm runner lifecycle, linked processes, and teardown behavior will work for child workflow units
- [ ] confirm test harness transcripts can represent scheduler rounds, branches, handlers, queries, and updates
- [ ] compare implemented activation/completion structs against the Temporal Core mapping
- [ ] remove or redesign any shortcut that would become unsafe under `parallel` or `phase`
- [ ] update Slice 2 if the Slice 1 implementation revealed a better boundary or missing prerequisite
- [ ] add missing Slice 1 tests before starting Slice 2

Exit criteria:

- [ ] documented invariants still match the implementation
- [ ] Slice 2 checklist has been corrected for anything learned in Slice 1
- [ ] no known design mismatch is being carried forward just because tests currently pass

## Slice 2: Structured Concurrency Core

Goal:

> The pure Elixir core supports deterministic scheduler rounds, `API.parallel/1`, `API.phase/2`, signals, updates, and queries without making command order depend on BEAM scheduling.

This slice is complete when the test harness can drive concurrent workflow units with activation jobs and replay the resulting command transcript deterministically.

Slice 2 builds on Slice 1. It must not rewrite the Slice 1 blocking protocol; it generalizes it from the root runner to multiple workflow units.

## Included

- [ ] Scheduler state:
  - [ ] `threads` keyed by stable thread id
  - [ ] scheduler round counter
  - [ ] current-round queue
  - [ ] next-round queue
  - [ ] currently running thread id
  - [ ] ready, running, blocked, done, and failed thread states

- [ ] Deterministic scheduler rounds:
  - [ ] one workflow unit runs at a time
  - [ ] runnable units are snapshotted at round start
  - [ ] each runnable unit gets at most one step per round
  - [ ] units that become runnable during a round are deferred to the next round
  - [ ] paused units do not constrain progress until their awaited event arrives
  - [ ] out-of-turn workflow calls fail as scheduler violations

- [ ] `API.parallel/1`:
  - [ ] branches get stable thread ids using input order
  - [ ] branch commands are emitted in scheduler order
  - [ ] parent blocks until all branches finish
  - [ ] results are returned in input order
  - [ ] one branch can continue after its awaited event resolves without waiting for unresolved siblings
  - [ ] nested `parallel` preserves hierarchical thread ids

- [ ] Signals:
  - [ ] `Job.SignalReceived`
  - [ ] signal buffering outside `phase`
  - [ ] `API.wait_for_signal/1`
  - [ ] buffered signals consumed in arrival order
  - [ ] signal handlers dispatched inside matching phase scopes

- [ ] Queries:
  - [ ] `Job.QueryReceived`
  - [ ] `Command.RespondToQuery`
  - [ ] `API.publish_state/1`
  - [ ] query handlers read only published state
  - [ ] query-only activations do not advance workflow units

- [ ] Updates:
  - [ ] `Job.UpdateReceived`
  - [ ] `Command.RespondToUpdate`
  - [ ] accepted, rejected, and completed responses
  - [ ] accepted response is emitted before any commands produced by the update handler
  - [ ] `protocol_instance_id` used for responses
  - [ ] `run_validator: false` skips validator execution during replay
  - [ ] updates outside matching phase scopes are rejected

- [ ] `API.phase/2`:
  - [ ] `Command.CancelTimer`
  - [ ] phase installs matching signal/update handlers
  - [ ] sync handlers serialize message processing
  - [ ] phase state is separate from published query state
  - [ ] handlers may call blocking workflow operations
  - [ ] phase exits only through documented stop/timeout/cancellation paths
  - [ ] phase timeout uses a durable timer
  - [ ] phase stop before timeout emits `CancelTimer`
  - [ ] async handler spawning via explicit `{:async, fun, state}`
  - [ ] async handlers are bound to the phase and must finish before the phase returns
  - [ ] `API.update_state/1` serializes async handler state mutations inside the executor
  - [ ] `API.update_state/1` closures cannot call workflow APIs or block on workflow operations

- [ ] Replay:
  - [ ] command matching includes thread id
  - [ ] replay preserves scheduler-round command order
  - [ ] signal/update/query activation job order drives dispatch order
  - [ ] replay mismatch in any branch or handler fails the activation with nondeterminism

## Excluded From Slice 2

- [ ] server process
- [ ] backend behaviour implementation
- [ ] Rustler
- [ ] Temporal Core protobuf conversion
- [ ] client API
- [ ] activity worker supervision
- [ ] child workflows
- [ ] local activities
- [ ] Nexus operations
- [ ] search attributes
- [ ] patch/version APIs unless pulled in as a small prerequisite
- [ ] deterministic random and UUID helpers unless pulled in as a small prerequisite
- [ ] full cancellation propagation beyond phase/parallel lifecycle cleanup required by tests

## Scheduler Scenarios For Slice 2

These scenarios are mandatory:

- [ ] initial `parallel([A, B])` schedules branch `A`'s first command, then branch `B`'s first command
- [ ] if only branch `A` resolves, branch `A` may continue without waiting for branch `B`
- [ ] if branches `A` and `B` resolve in the same activation, their next commands are emitted in stable branch order
- [ ] newly runnable units are deferred to the next round
- [ ] non-pausing APIs do not end the current scheduler step
- [ ] included command-emitting non-pausing APIs append commands without yielding the turn
- [ ] nested parallel branches produce stable hierarchical thread ids
- [ ] repeated runs never change command order under BEAM scheduling pressure

## Phase Scenarios For Slice 2

These scenarios are mandatory:

- [ ] signal before phase is buffered, then consumed by matching phase handler
- [ ] signal inside phase dispatches matching handler
- [ ] non-matching signal inside phase remains buffered
- [ ] sync handlers serialize message processing
- [ ] async signal handler can block on activity while phase dispatches later messages
- [ ] async update handler emits accepted response before completion response
- [ ] sync update handler that blocks on activity emits accepted response before the activity command
- [ ] rejected update emits rejected response and does not run handler
- [ ] update outside matching phase emits rejected response
- [ ] `run_validator: false` does not run validator during replay
- [ ] `API.update_state/1` mutations are serialized and deterministic
- [ ] `API.update_state/1` rejects or fails executor-side closures that try to perform workflow operations
- [ ] phase timeout returns `{:timeout, state}` when its timer fires
- [ ] phase stop before timeout emits `CancelTimer`
- [ ] phase does not return until bound async handlers finish

## Query Scenarios For Slice 2

These scenarios are mandatory:

- [ ] `API.publish_state/1` updates query-visible state
- [ ] query activation returns `RespondToQuery`
- [ ] query handler cannot emit workflow commands
- [ ] query-only activation does not advance root, branch, or handler units
- [ ] query failures become query responses, not workflow failures

## Exit Criteria

Slice 2 is done when:

- [ ] all Slice 1 tests still pass
- [ ] scheduler-round tests pass repeatedly
- [ ] `parallel` command order is stable across repeated runs
- [ ] phase signal/update/query tests pass as activation transcripts
- [ ] replay mismatch tests cover root, branch, sync handler, and async handler command changes
- [ ] no implementation code depends on backend, Rustler, protobuf, or Temporal Core types
- [ ] the next slice can add server/backend integration without changing executor scheduling semantics

## Intermission: Slice 2 Review

Do not start server/backend integration immediately after Slice 2 turns green.

First, review the full core concurrency model against [scheduler_and_replay.md](scheduler_and_replay.md), [programming_model.md](programming_model.md), [core_testing.md](core_testing.md), and [temporal_core_mapping.md](temporal_core_mapping.md).

The goal is to prove that the Elixir core now preserves Temporal's model under branching, handlers, queries, and replay before any outer layer is allowed to depend on it.

Review checklist:

- [ ] confirm scheduler rounds are explicit in executor state and not emergent from mailbox timing
- [ ] confirm every workflow unit has a stable thread id and lifecycle state
- [ ] confirm command sequence assignment is executor-owned across root, branches, and handlers
- [ ] confirm `parallel` provides overlapping durable waits without nondeterministic command races
- [ ] confirm `phase` handler dispatch matches activation job order and documented phase rules
- [ ] confirm async handlers cannot mutate phase state except through serialized `API.update_state/1`
- [ ] confirm query-only activations cannot advance root, branch, or handler units
- [ ] confirm update validation respects `run_validator`
- [ ] confirm replay mismatch tests cover branch and handler command order, not only root commands
- [ ] confirm failures in handlers, branches, queries, and updates map to the documented failure surface
- [ ] confirm process teardown covers root, branches, handlers, blocked calls, phase exit, and eviction
- [ ] confirm test harness transcripts are close enough to the backend contract for server tests to reuse
- [ ] update the server/backend docs if the implemented core requires a different integration shape
- [ ] add missing Slice 2 tests before starting the next slice

Exit criteria:

- [ ] documented concurrency semantics still match the implementation
- [ ] no scheduler, replay, phase, update, or query ambiguity is known but unresolved
- [ ] backend conformance tests can be written against stable core structs
- [ ] the next slice can focus on server/backend integration rather than repairing core semantics

## After The Core Slices

If both core slices and both review gates are complete, implementation moves outward.

The next work should be server/backend integration, not new workflow semantics:

1. [x] Server process and supervision shape.
2. [x] Executor registry and pending activation registry.
3. [x] Test backend that delivers core structs and captures completions.
4. [x] Server-to-executor activation routing.
5. [x] Activity task supervision and activity completion submission.
6. [x] Backend conformance tests for the stable backend behaviour, exercised by the test backend and Temporal Core codec checks.
7. [x] Temporal Core/Rustler backend that translates protobuf/Core messages into the same core structs.
8. [x] External integration test against `temporal server start-dev` covering worker polling, timers, activity execution, heartbeats, workflow completion, client start, and result retrieval.

The rule for this phase:

> Server and backend work may route, supervise, translate, and submit. It must not change executor scheduling, replay matching, command identity, or workflow API semantics.

If server/backend work reveals a core semantic mismatch, stop and return to the Slice 2 review criteria before continuing outward.
