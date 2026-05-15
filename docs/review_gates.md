# Review Gates

This document records the core review gates required by `docs/implementation_slice.md`.

## Scope

Review date: May 7, 2026.

Reviewed implementation:

- `Temporalex.Core.Executor`
- `Temporalex.Core.TestHarness`
- `Temporalex.Workflow.API`
- `Temporalex.Workflow`
- `Temporalex.Activity`
- `Temporalex.Worker`
- `Temporalex.Server`
- `Temporalex.Backend`
- `Temporalex.Backend.Test`
- `Temporalex.Backend.TemporalCore`
- `Temporalex.Backend.TemporalCore.Codec`
- `Temporalex.Backend.TemporalCore.PayloadConverter`
- `Temporalex.Native`
- `Temporalex.Client`
- `native/temporalex_nif`

Test evidence:

- `CARGO_HOME=$(pwd)/.cargo-home cargo check --manifest-path native/temporalex_nif/Cargo.toml`: success.
- `CARGO_HOME=$(pwd)/.cargo-home mix compile`: success.
- `CARGO_HOME=$(pwd)/.cargo-home mix test --exclude external`: 51 tests, 0 failures, 2 external tests excluded.
- `CARGO_HOME=$(pwd)/.cargo-home mix test --only external`: 2 tests, 0 failures.

## Slice 1 Review

Status: completed.

Findings:

- Executor state stays inside the deterministic core. Backend worker handles, task tokens, protobuf structs, and Rustler resources are absent from `Temporalex.Core.Executor.State`.
- Blocking calls generalize through `%Temporalex.Core.Pending{seq, thread_id, from, op}`. Held `GenServer.from()` values are keyed by command sequence and carry thread ids, so the same protocol supports root, branch, and handler workflow units.
- Command identity is matched in `append_command/2` through deterministic command fields. Activity, timer, terminal, update, query, cancel-timer, and search-attribute commands are compared without backend transport fields.
- Activation failure and workflow failure are distinct in code and tests. Nondeterminism and scheduler violations produce `%Temporalex.Core.Completion{status: {:failed, reason, opts}}`; application workflow failures produce `%Temporalex.Core.Command.FailWorkflow{}` inside successful completions.
- Runner lifecycle is executor-owned. Runners are linked to the executor, the executor traps exits, blocked runners remain alive, eviction tears down cached threads, and executor shutdown tears down linked runners.
- The test harness drives the same `%Temporalex.Core.Activation{}` and `%Temporalex.Core.Completion{}` structs used by the server/backend boundary.
- The implemented activation, job, command, and completion structs follow the documented Temporal Core mapping for the current core-slice scope.

Outcome:

- No Slice 1 design mismatch was found that requires executor rework before or after adding structured concurrency.

## Slice 2 Review

Status: completed.

Findings:

- Scheduler rounds are explicit in executor state through `round`, `current_round`, `next_round`, `running`, and `in_round?`. Runnable units are snapshotted, sorted by stable thread id, and newly runnable units are deferred to the next round.
- Every workflow unit has a stable thread id and lifecycle state in `threads`. Root, parallel branches, phase dispatches, and async handlers all use hierarchical ids.
- Command sequence assignment remains executor-owned across root, branches, and handlers through the shared `next_seq` counter.
- `parallel` provides overlapping durable waits without command races. Branches are spawned by input order, command emission follows scheduler order, and parent completion waits for all branch results in input order.
- `phase` dispatch is driven by activation job order and phase queue order. Sync handlers serialize; async handlers are bound to the phase and must finish before phase return.
- Async handlers mutate phase state only through serialized `API.update_state/1`. Closures that attempt workflow APIs fail through the async handler response path.
- Query-only activations respond from published state and do not advance root, branch, or handler workflow units.
- Update validation respects `run_validator`; replay-style updates with `run_validator: false` skip validator execution and still emit accepted/completed responses.
- Replay mismatch tests cover root commands, branch command order, and handler command changes.
- Handler, branch, query, update, and workflow failures map to the documented failure surfaces covered by the core tests.
- Process teardown covers root runners, blocked calls, phase exit, async handlers, executor shutdown, and eviction for the implemented core-slice scope.
- The server/backend integration reuses the same core structs, and backend conformance tests now exercise the stable boundary with `Temporalex.Backend.Test`.

Outcome:

- No scheduler, replay, phase, update, or query ambiguity is known that blocks native backend integration.
- Server/backend integration can proceed without changing executor scheduling semantics. The server implementation already routes, supervises, and submits without owning deterministic workflow state.

## Native Integration Review

Status: completed.

Findings:

- The server-facing backend boundary still uses core structs for activations, activity tasks, workflow completions, and activity completions. Protobuf structs and Rustler resources stay inside `Temporalex.Backend.TemporalCore`, `Temporalex.Native`, and the native crate.
- The native NIF interface follows the documented async pattern. `create_runtime/0` is synchronous; connect, worker start, completion submission, shutdown, and client workflow operations return quickly and send tagged messages back to Elixir.
- Rust owns the long-lived poll loops. The server receives `{:workflow_activation, %Activation{}}` and `{:activity_task, %ActivityTask{}}`; it does not call per-poll NIFs.
- Completion submission is asynchronous and failure-bearing. The server handles `{:workflow_completion, :ok | {:error, reason}}` and `{:activity_completion, :ok | {:error, reason}}` messages as fatal backend submission failures when needed.
- Activity heartbeats flow from `Temporalex.Activity.Context.heartbeat/2` through `Temporalex.Server.record_activity_heartbeat/3` to the backend, where details are encoded as ETF payload bytes and submitted through Temporal Core.
- Worker shutdown is covered by explicit server termination, the Rustler resource monitor, and resource drop. Shutdown initiation is scheduled on the Temporal Core Tokio runtime handle rather than called directly from BEAM scheduler threads.
- The client path starts workflows, awaits workflow results, signals, queries, updates, cancels, terminates, and describes executions through the Temporal Core connection kept in backend state.
- Workflow start options cover task queue selection, headers, search attributes, workflow timeouts, retry policy, id reuse/conflict policies, and static metadata. Activity command encoding covers retry policy and activity cancellation type. Invalid negative duration/retry values are rejected instead of cast into oversized native durations.
- `test/temporalex/integration/temporal_core_integration_test.exs` verifies a real Temporal dev-server run covering client start, invalid start option handling, worker polling, timer command/resolution, activity task execution, heartbeat submission, activity completion, workflow completion, signal/query/update/describe, termination, and result decoding.

Outcome:

- No native/backend boundary shortcut is known that blocks beta evaluation of workflow start/result, signal/query/update/describe/terminate, worker polling, timers, activities, heartbeats, completions, shutdown, workflow/activity option encoding, and ETF payload conversion.

## Beta Limits

These are known beta limits, not review-gate blockers for the implemented native execution path:

- Full workflow cancellation propagation is not implemented yet. The client cancellation RPC is wired and `Job.CancelWorkflow` updates the workflow cancellation flag, but cancellation scopes and automatic unblocking/cancellation of pending timers, activities, phases, and branches need a dedicated design pass.
- Public error structs are still planned. Client/native errors currently return stable tagged terms for common workflow states plus strings for lower-level transport failures.
- Child workflows, local activities, and Nexus operations are outside the implemented beta scope.
