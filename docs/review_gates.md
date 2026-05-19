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

## Runtime Abort Follow-Up Review

Status: completed.

Review date: May 8, 2026.

Findings:

- Scheduler violations, replay nondeterminism, unknown command resolutions, missing replay commands, thread-yield timeouts, unexpected runner exits, and executor-only invariant failures now share the same runtime abort path.
- Runtime aborts fail the activation and tear down executor-owned workflow processes instead of replying to blocked workflow API calls with ordinary values.
- Eviction-only activations continue to use normal teardown and return successful empty completions.
- Blocked operations, signal waiters, phase state, parallel scopes, scheduler rounds, and running-thread state are cleared when runtime abort or eviction teardown runs.
- Pending runtime failures detected outside an activation are preserved until the next non-eviction activation reports the failure.

Test evidence:

- `mix test test/temporalex/core_executor_test.exs`: 53 tests, 0 failures.
- `mix test`: 77 tests, 0 failures, 2 external tests excluded.
- `mix test --only external`: 2 tests, 0 failures.
- `mix format --check-formatted`: success.
- `cargo test --manifest-path native/temporalex_nif/Cargo.toml`: success.
- `cargo fmt --manifest-path native/temporalex_nif/Cargo.toml --check`: success.

## Workflow Safe Mode Review

Status: completed.

Review date: May 8, 2026.

Findings:

- Workflow safe mode is hosted in `Temporalex.Core.TraceGuard`, a per-executor process with its own OTP trace session.
- Only executor-owned workflow runner and handler pids are traced. Trace messages are consumed by the guard and converted to `%Temporalex.Core.TraceGuard.Violation{}` before reaching the executor.
- The executor checks the guard before accepting workflow operations and terminal runner events, so unsafe calls made immediately before a yield or completion fail the same activation.
- Safe-mode violations use the existing runtime abort path in `:fail` mode. Worker/server execution defaults to `:off`; the core test harness defaults to `:fail`.
- Message tracing allows only the executor protocol, runner result messages, operation replies, runner start messages, and code-server traffic needed for lazy module loading.
- Call tracing catches common nondeterminism hazards for time, randomness, filesystem, environment/config access, mutable external stores, process/task spawning, sleeps, ports, and OS access.
- `:persistent_term.get/1` is not call-traced because OTP/Elixir internals can use it during normal traced workflow execution; trace sessions do not expose enough caller context to distinguish those runtime reads from user reads.

Test evidence:

- `mix test test/temporalex/core_executor_test.exs`: 59 tests, 0 failures.
- `mix test`: 83 tests, 0 failures, 2 external tests excluded.
- `mix test --only external`: 2 tests, 0 failures.
- `mix format --check-formatted`: success.
- `cargo test --manifest-path native/temporalex_nif/Cargo.toml`: success.
- `cargo fmt --manifest-path native/temporalex_nif/Cargo.toml --check`: success.

## Continue-As-New Review

Status: completed.

Review date: May 8, 2026.

Findings:

- Continue-as-new is now an explicit terminal workflow operation, `Temporalex.Workflow.API.continue_as_new!/2`, rather than a workflow return tuple.
- The executor accepts continue-as-new only from the running root workflow thread when it is the only live workflow thread and no phase, parallel scope, or workflow operation is pending.
- After accepting the terminal command, the executor tears down workflow-owned processes without replying to the blocked caller, so user code after `continue_as_new!/2` does not run.
- The core command carries input, workflow type, task queue, and options. Replay identity includes all of those fields.
- Temporal Core command encoding covers the continue-as-new fields currently exposed locally: run timeout, task timeout, memo, headers, typed Search Attributes, retry policy, versioning intent, and initial versioning behavior.
- Workflow info now exposes activation timestamp, replay flag, history length, history size, and `continue_as_new_suggested`.
- Temporal API's `backoff_start_interval` is not exposed by the local Temporal Core command proto, so Temporalex does not expose that option yet.

Test evidence:

- `mix test test/temporalex/core_executor_test.exs`: 59 tests, 0 failures.
- `mix test test/temporalex/backend_conformance_test.exs`: 6 tests, 0 failures.
- `mix test`: 83 tests, 0 failures, 2 external tests excluded.
- `mix test --only external`: 2 tests, 0 failures.
- `mix format --check-formatted`: success.
- `cargo test --manifest-path native/temporalex_nif/Cargo.toml`: success.
- `cargo fmt --manifest-path native/temporalex_nif/Cargo.toml --check`: success.

## Explicit Client Ownership Review

Status: completed.

Review date: May 8, 2026.

Findings:

- `Temporalex.Client` now owns backend client resources independently from workers.
- `Temporalex.Worker` requires a `:client` option and does not create internal client resources.
- Workers resolve and hold the native backend handles they need, but monitor the client owner pid and stop on client exit.
- Worker-local supervision uses `:one_for_all` so the server, executor supervisor, and activity supervisor restart together.
- Public workflow handles retain a client reference, not a worker reference.
- Client operations resolve backend handles and call the backend directly instead of proxying through the client process or a worker.
- Backend state is split into client state and worker state. Worker shutdown stops pollers without shutting down the shared client.
- The backend behaviour explicitly includes the client-operation callbacks that `Temporalex.Client` calls.

Test evidence:

- `mix test test/temporalex/backend_conformance_test.exs test/temporalex/server_integration_test.exs`: 17 tests, 0 failures.
- `mix test`: 84 tests, 0 failures, 2 external tests excluded.
- `mix test --only external`: 2 tests, 0 failures.
- `mix compile --warnings-as-errors`: success.
- `mix format --check-formatted`: success.
- `cargo test --manifest-path native/temporalex_nif/Cargo.toml`: success.
- `cargo fmt --manifest-path native/temporalex_nif/Cargo.toml --check`: success.

## Workflow Testing Surface Review

Status: completed.

Review date: May 8, 2026.

Findings:

- `Temporalex.Testing` is a public, explicit helper API rather than an ExUnit case-template macro.
- Workflow tests run through the real core executor with safe mode defaulting to `:fail`.
- `start_workflow/3` returns a process-backed run handle that owns the executor, queued commands, unresolved operation handles, terminal state, and replay transcript.
- Activity and timer assertions consume commands in deterministic emission order and return handles containing sequence, thread id, and Temporal-visible identity.
- New activations and operation resolutions are rejected while prior emitted commands remain unconsumed, so tests must acknowledge the full side-effect set from each activation.
- Activity/timer completions resolve exact handles, allowing out-of-order completion after all emitted commands have been consumed.
- Signals, updates, queries, and workflow cancellation are explicit workflow inputs. Update responses remain observable commands; query responses are returned as `{:ok, value}` or `{:error, reason}`.
- `assert_replay/1` replays the recorded activation transcript against the same workflow module and checks command decisions.
- Consumer-style workflow behavior tests now cover signal waits, continue-as-new, non-cancellable cleanup, blocked cancellable cleanup, activity cancellation modes, parallel cancellation, async signal handlers, async update handlers, update rejection, and safe-mode failures through the public testing API.

Test evidence:

- `mix test test/temporalex/testing_test.exs test/temporalex/testing_workflow_behavior_test.exs`: 20 tests, 0 failures.
- `mix test`: 104 tests, 0 failures, 3 external tests excluded.
- `mix test --only external`: 3 tests, 0 failures.
- `mix compile --warnings-as-errors`: success.
- `mix format --check-formatted`: success.
- `cargo test --manifest-path native/temporalex_nif/Cargo.toml`: success.
- `cargo fmt --manifest-path native/temporalex_nif/Cargo.toml --check`: success.

## Native Integration Review

Status: completed.

Findings:

- The server-facing backend boundary still uses core structs for activations, activity tasks, workflow completions, and activity completions. Protobuf structs and Rustler resources stay inside `Temporalex.Backend.TemporalCore`, `Temporalex.Native`, and the native crate.
- The native NIF interface follows the documented async pattern. `create_runtime/0` is synchronous; connect, worker start, completion submission, shutdown, and client workflow operations return quickly and send tagged messages back to Elixir.
- Rust owns the long-lived poll loops and sends raw task protobuf bytes to the Elixir poller bridge. The server receives `{:workflow_activation, %Activation{}}` and `{:activity_task, %ActivityTask{}}`; it does not call per-poll NIFs and does not see protobuf bytes.
- Completion submission is asynchronous and failure-bearing. The server handles `{:workflow_completion, :ok | {:error, reason}}` and `{:activity_completion, :ok | {:error, reason}}` messages as fatal backend submission failures when needed.
- Activity heartbeats flow from `Temporalex.Activity.Context.heartbeat/2` through `Temporalex.Server.record_activity_heartbeat/3` to the backend, where details are encoded as ETF payload bytes and submitted through Temporal Core.
- Worker shutdown is covered by explicit server termination, the Rustler resource monitor, and resource drop. Shutdown initiation is scheduled on the Temporal Core Tokio runtime handle rather than called directly from BEAM scheduler threads.
- The client path starts workflows, awaits workflow results, signals, queries, updates, cancels, terminates, and describes executions through the standalone `Temporalex.Client` owner process and its backend client state.
- Workflow start options cover task queue selection, headers, search attributes, workflow timeouts, retry policy, id reuse/conflict policies, and static metadata. Query options cover query reject condition. Activity command encoding covers retry policy and activity cancellation type. Invalid negative duration/retry values are rejected instead of cast into oversized durations.
- `test/temporalex/integration/temporal_core_integration_test.exs` verifies a real Temporal dev-server run covering client start, invalid start option handling, worker polling, timer command/resolution, activity task execution, heartbeat submission, activity completion, workflow completion, signal/query/update/describe, termination, and result decoding.
- `test/temporalex/integration/temporal_worker_restart_test.exs` verifies worker restart and real-history replay against a Temporal dev server for timer completion while no worker is running, activity retry after worker shutdown, signal handling while the worker is down, continue-as-new after restart, explicit client survival across worker restarts, and reuse of the same task queue by restarted workers.

Outcome:

- No native/backend boundary shortcut is known that blocks beta evaluation of workflow start/result, signal/query/update/describe/terminate, worker polling, timers, activities, heartbeats, completions, shutdown, workflow/activity option encoding, and ETF payload conversion.

## Public Client Error Surface Review

Status: completed.

Findings:

- Public client operations now return `{:ok, value}`, `:ok`, or `{:error, exception_struct}`. They no longer expose native workflow-result tags such as `{:failed, failure}` or raw transport strings as their documented surface.
- Workflow execution outcomes are represented by `Temporalex.WorkflowFailedError`, `Temporalex.WorkflowCancelledError`, `Temporalex.WorkflowTerminatedError`, `Temporalex.WorkflowTimedOutError`, and `Temporalex.WorkflowContinuedAsNewError`.
- Start conflicts, missing executions, query rejections, update failures, client-owner loss, and transport/payload/option/RPC failures have stable structs with operation context.
- Temporal failure protos still decode into `Temporalex.Failure.*` trees. Client operation errors that wrap Temporal failures store those trees in `cause`.
- The Rust NIF now sends structured low-level reasons for known client errors, including `:not_found`, `{:already_started, run_id}`, `{:payload_conversion, message}`, `{:invalid_options, message}`, and `{:rpc, message}`. Elixir owns the public error shaping.

Validation:

- `test/temporalex/client_error_test.exs` covers client-side normalization for start conflicts, workflow result outcomes, query rejection, update failure, not found, client unavailability, and transport errors.
- Real-server integration tests assert the public error structs for invalid start options, workflow termination, cancellation, workflow failure, activity failure, workflow ID conflicts, not-found operations, query rejection, and update rejection.

## Temporal Core Codec Placement Review

Status: completed.

Review date: May 19, 2026.

Findings:

- `Temporalex.Backend.TemporalCore.Codec` owns worker-facing Temporal Core protobuf translation through MiniPB. Workflow activations and activity tasks decode from raw protobuf bytes into core structs before reaching the server.
- Workflow completions, activity completions, and activity heartbeats encode to Temporal Core protobuf bytes in Elixir. The Rust NIF only decodes those bytes at the final Temporal Core API call boundary where the Rust crate requires typed SDK structs.
- `Temporalex.Backend.TemporalCore.PollerBridge` is the only process that receives raw poll-loop bytes. Worker lifecycle messages and Rustler resource monitoring still target the owning worker server process directly.
- Obsolete Rust conversion code for core activations, activity tasks, workflow commands, completion terms, and core-specific atoms has been removed instead of retained as fallback paths.
- Decode failures from malformed payloads propagate as backend errors; failure details are not silently dropped.

Validation:

- `mix test test/temporalex/backend/temporal_core/codec_test.exs test/temporalex/backend_conformance_test.exs`: 9 tests, 0 failures.
- `cargo test --manifest-path native/temporalex_nif/Cargo.toml`: success.
- `cargo fmt --manifest-path native/temporalex_nif/Cargo.toml --check`: success.

## Beta Limits

These are known beta limits, not review-gate blockers for the implemented native execution path:

- Workflow cancellation propagation is implemented for the current workflow primitives. Temporal Core's local terminal cancel command does not yet expose cancellation details, so real-server canceled results may have empty details.
- Some less common Temporal failure proto variants still decode as `Temporalex.Failure.UnknownError` until the corresponding SDK primitives exist.
- Child workflows, local activities, and Nexus operations are outside the implemented beta scope.
