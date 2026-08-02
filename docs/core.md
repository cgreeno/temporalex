# Temporalex Core

The core is the deterministic workflow kernel. It is pure Elixir and independent of Temporal Core, Rustler, protobuf, task tokens, worker handles, and network transport.

The core exists to make one thing true:

> Given the same workflow code, input, and ordered activation transcript, the executor emits the same ordered command decisions or fails with nondeterminism.

Scheduler rounds and replay matching are specified in [scheduler_and_replay.md](scheduler_and_replay.md).

## Responsibilities

The core owns:

- `Temporalex.Core.Executor`, one GenServer per workflow execution.
- Optional workflow safe-mode tracing through `Temporalex.Core.TraceGuard`.
- Runner process lifecycle.
- The workflow operation protocol used by `Temporalex.Workflow.API` and activity dispatch functions.
- Replay command matching against activation transcripts.
- Command sequencing.
- Signal and update buffering.
- Published state for query handlers.
- Deterministic scheduling for `parallel` branches and phase handlers.
- Workflow completion, failure, and continue-as-new semantics.

The core does not own:

- worker polling
- protobuf encoding or decoding
- Rustler resources
- Temporal Core handles
- activity task execution
- server supervision
- client operations

## Core Structs

Core structs are the stable boundary between the deterministic kernel and the outer layers.

### Activation

```elixir
%Temporalex.Core.Activation{
  run_id: String.t(),
  timestamp: DateTime.t() | nil,
  is_replaying: boolean(),
  history_length: non_neg_integer(),
  history_size_bytes: non_neg_integer() | nil,
  continue_as_new_suggested: boolean(),
  available_internal_flags: [non_neg_integer()],
  deployment_version: term() | nil,
  jobs: [Temporalex.Core.Job.t()]
}
```

Activations are delivered to an executor by the server. They represent external workflow work already translated into Temporalex terms.

This shape intentionally follows Temporal Core's `WorkflowActivation`: `run_id` is the activation key, and workflow identity appears in the initialize job. There is only one outstanding activation for a run at a time.

Common jobs:

```elixir
%Temporalex.Core.Job.InitializeWorkflow{
  workflow_type: String.t(),
  workflow_id: String.t(),
  arguments: [term()],
  headers: map(),
  workflow_info: map(),
  randomness_seed: non_neg_integer()
}

%Temporalex.Core.Job.UpdateRandomSeed{randomness_seed: non_neg_integer()}
%Temporalex.Core.Job.ActivityResolved{
  seq: non_neg_integer(),
  result: {:ok, term()} | {:error, term()} | {:cancelled, term()} | {:backoff, term()}
}
%Temporalex.Core.Job.TimerFired{seq: non_neg_integer()}
%Temporalex.Core.Job.SignalReceived{name: String.t(), args: [term()], headers: map(), identity: String.t() | nil}
%Temporalex.Core.Job.UpdateReceived{
  id: String.t(),
  protocol_instance_id: String.t(),
  name: String.t(),
  args: [term()],
  headers: map(),
  meta: term(),
  run_validator: boolean()
}
%Temporalex.Core.Job.QueryReceived{query_id: String.t(), query_type: String.t(), args: [term()], headers: map()}
%Temporalex.Core.Job.CancelWorkflow{reason: term()}
%Temporalex.Core.Job.NotifyPatch{id: String.t()}
%Temporalex.Core.Job.RemoveFromCache{reason: term(), message: String.t() | nil}
```

### Completion

```elixir
%Temporalex.Core.Completion{
  run_id: String.t(),
  status:
    {:ok, [Temporalex.Core.Command.t()]}
    | {:failed, term(), keyword()}
}
```

Completions are emitted by executors and submitted by the server through the configured backend.

A successful completion contains workflow commands. A failed completion means the activation itself could not be processed, for example because of nondeterminism or an unhandled workflow-task failure. This is distinct from `%Temporalex.Core.Command.FailWorkflow{}`, which is a successful activation command that fails the workflow execution.

## Workflow Safe Mode

Executors can run with `safe_mode: :fail | :warn | :off`. Safe mode is hosted by a per-executor `Temporalex.Core.TraceGuard` process which owns an OTP trace session. Only workflow runner and handler processes are traced; trace traffic is consumed by the guard and reduced to structured violations before the executor sees it.

In `:fail` mode, a violation fails the current activation and tears down workflow-owned runner processes through the normal runtime abort path. The core test harness enables this mode by default. Worker/server execution defaults to `:off`; pass `workflow_safe_mode: :fail` or `:warn` to a worker to enable it for real worker executions.

The first guard pass catches:

- unexpected sends from workflow runner processes
- unexpected receives by workflow runner processes
- common unsafe calls for time, randomness, filesystem, environment/config, tasks/process spawning, ETS-like mutable stores, ports, OS access, and sleeps

The guard allows the executor protocol, runner completion/failure messages, operation replies, runner start messages, and narrow code-server traffic needed for lazy module loading. Safe mode is a development and test guardrail, not a formal determinism proof.

Common commands:

```elixir
%Temporalex.Core.Command.RetryPolicy{
  initial_interval_ms: non_neg_integer() | nil,
  backoff_coefficient: float() | nil,
  maximum_interval_ms: non_neg_integer() | nil,
  maximum_attempts: non_neg_integer(),
  non_retryable_error_types: [String.t()]
}

%Temporalex.Core.Command.ScheduleActivity{
  seq: integer(),
  thread_id: list(),
  activity_id: String.t(),
  type: String.t(),
  task_queue: String.t() | nil,
  input: [term()],
  headers: map(),
  schedule_to_close_timeout_ms: non_neg_integer(),
  schedule_to_start_timeout_ms: non_neg_integer() | nil,
  start_to_close_timeout_ms: non_neg_integer(),
  heartbeat_timeout_ms: non_neg_integer() | nil,
  retry_policy: Temporalex.Core.Command.RetryPolicy.t() | nil,
  cancellation_type: :wait_cancellation_completed | :try_cancel | :abandon,
  do_not_eagerly_execute: boolean()
}

%Temporalex.Core.Command.StartTimer{seq: integer(), thread_id: list(), duration_ms: non_neg_integer()}
%Temporalex.Core.Command.CancelTimer{seq: integer()}
%Temporalex.Core.Command.RequestCancelActivity{seq: integer()}
%Temporalex.Core.Command.SetPatchMarker{id: String.t(), deprecated: boolean()}
%Temporalex.Core.Command.CompleteWorkflow{result: term()}
%Temporalex.Core.Command.FailWorkflow{reason: term()}
%Temporalex.Core.Command.ContinueAsNew{
  input: term(),
  workflow_type: String.t(),
  task_queue: String.t() | nil,
  workflow_run_timeout_ms: non_neg_integer() | nil,
  workflow_task_timeout_ms: non_neg_integer() | nil,
  memo: map(),
  headers: map(),
  search_attributes: map() | nil,
  retry_policy: Temporalex.Core.Command.RetryPolicy.t() | nil,
  versioning_intent: :unspecified | :compatible | :default,
  initial_versioning_behavior: :unspecified | :auto_upgrade | :use_ramping_version
}

%Temporalex.Core.Command.CancelWorkflow{reason: term()}
%Temporalex.Core.Command.RespondToUpdate{protocol_instance_id: String.t(), response: :accepted | {:completed, term()} | {:rejected, term()}}
%Temporalex.Core.Command.RespondToQuery{query_id: String.t(), result: {:ok, term()} | {:error, term()}}
%Temporalex.Core.Command.UpsertSearchAttributes{attrs: map()}
```

Workflow operations still accept user-facing option keywords, but the executor normalizes those options into canonical command fields before the backend sees them.

### Activity Task And Completion

Activity execution is orchestrated by the server, but the backend/server boundary still uses core structs so tests do not depend on Temporal protobufs.

```elixir
%Temporalex.Core.ActivityTask{
  task_token: binary(),
  activity_id: String.t(),
  activity_type: String.t(),
  workflow_id: String.t(),
  run_id: String.t(),
  workflow_type: String.t(),
  namespace: String.t(),
  task_queue: String.t(),
  input: [term()],
  attempt: non_neg_integer(),
  heartbeat_timeout: non_neg_integer() | nil,
  is_local: boolean(),
  headers: keyword(),
  variant: :start | :cancel,
  cancel_reason: term() | nil
}

%Temporalex.Core.ActivityCompletion{
  task_token: binary(),
  result: {:ok, term()} | {:error, term()} | {:cancelled, term()}
}
```

These structs are not part of deterministic workflow replay. They live in the core namespace because they are stable internal SDK data crossing the backend/server boundary.

### Operations

Workflow code calls the executor with operations:

```elixir
%Temporalex.Core.Op.ExecuteActivity{type: String.t(), input: [term()], opts: keyword()}
%Temporalex.Core.Op.Sleep{duration_ms: non_neg_integer()}
%Temporalex.Core.Op.WaitForSignal{name: String.t()}
%Temporalex.Core.Op.PublishState{state: term()}
%Temporalex.Core.Op.Patched{id: String.t()}
%Temporalex.Core.Op.DeprecatePatch{id: String.t()}
%Temporalex.Core.Op.WorkflowInfo{}
%Temporalex.Core.Op.Cancelled{}
%Temporalex.Core.Op.Cancellation{}
%Temporalex.Core.Op.EnterNonCancellable{}
%Temporalex.Core.Op.ExitNonCancellable{}
%Temporalex.Core.Op.UpsertSearchAttributes{attrs: map()}
%Temporalex.Core.Op.Now{}
%Temporalex.Core.Op.Random{}
%Temporalex.Core.Op.UUID4{}
%Temporalex.Core.Op.Parallel{funs: [function()]}
%Temporalex.Core.Op.Phase{initial_state: term(), opts: keyword()}
%Temporalex.Core.Op.UpdateState{fun: (term() -> {term(), term()})}
```

All workflow API calls use one protocol shape:

```elixir
GenServer.call(executor, {:workflow_op, thread_id, op}, :infinity)
```

Executor replies to workflow operation calls are always wrapped as an internal envelope:

```elixir
{:temporalex_op_reply, :ok, value}
{:temporalex_op_reply, :cancelled, %Temporalex.Failure.CancelledError{}}
{:temporalex_op_reply, :error, reason}
```

The public workflow API turns those envelopes into non-bang return values or bang-variant
exceptions. User payloads are never used as control sentinels.

## Workflow Context

Every process running workflow code carries exactly one process dictionary key:

```elixir
Process.put(:__temporal_context__, %Temporalex.Core.Context{
  executor: executor_pid,
  thread_id: []
})
```

Parallel branches and handlers inherit the executor PID and extend the thread ID.

Thread IDs are hierarchical paths:

```elixir
[]                 # root runner
[{:p, 0}]          # first parallel branch
[{:p, 1}, {:p, 0}] # nested parallel branch
[{:h, 2}]          # third handler dispatch
```

The executor uses thread IDs to order command emission deterministically.

## Executor State

The executor state should stay focused on deterministic workflow behavior:

```elixir
%Temporalex.Core.Executor.State{
  server_pid: pid(),
  runner_pid: pid() | nil,
  run_id: String.t(),
  workflow_id: String.t(),
  workflow_type: String.t(),
  task_queue: String.t(),
  run_fn: (term() -> term()),
  workflow_info: map(),
  timestamp: DateTime.t() | nil,
  is_replaying: boolean(),
  history_length: non_neg_integer(),
  randomness_seed: non_neg_integer(),
  published_state: term(),
  signal_buffer: [{String.t(), term()}],
  signal_waiters: %{String.t() => GenServer.from()},
  update_buffer: list(),
  patches: MapSet.t(String.t()),
  cancelled: boolean(),
  next_seq: non_neg_integer(),
  commands: [Temporalex.Core.Command.t()],
  pending_calls: %{non_neg_integer() => {list(), GenServer.from(), Temporalex.Core.Op.t()}},
  threads: %{list() => :ready | :running | {:blocked, term()} | :done | {:failed, term()}},
  scheduler: term(),
  phase_state: term() | nil,
  async_handlers: [pid()],
  status: :idle | :running | :yielded | :done | :failed
}
```

The executor does not store backend worker handles.

## Activation Turn Protocol

Each activation is one deterministic turn for a workflow run:

1. The server delivers one `%Temporalex.Core.Activation{}` to the executor.
2. The executor applies all jobs to deterministic state first: initialize workflow metadata, patch notifications, random seed updates, signal/update/query messages, cancellations, and command resolutions.
3. If the activation is eviction-only, the executor does not run workflow code and replies with an empty successful completion.
4. If the activation is query-only, the executor runs query handlers and replies with query response commands without advancing workflow threads.
5. Otherwise the executor drains deterministic scheduler rounds for all runnable workflow units.
6. The executor emits exactly one `%Temporalex.Core.Completion{}` for the activation.

This mirrors Temporal Core's rule that every workflow activation must be completed, and there can only be one outstanding activation per run.

## Replay Rules

Replay is activation-based, not a separate executor-only event log. During replay, workflow code still runs and still emits the same command decisions it emitted originally. Those commands are returned in the activation completion so the backend or test harness can match them against history; they are not new user-visible effects.

For every durable workflow operation:

1. If the current replay transcript expects a matching command, the executor emits that command decision and suspends or resumes according to the matching activation jobs.
2. If the expected command does not match, the executor fails the activation with nondeterminism.
3. If the activation is not replaying, the executor emits a new command decision and suspends the caller until a matching resolution job arrives in a later activation.

Replay matching must include the operation type and any fields that affect determinism, such as activity type, input, timer duration, child workflow type, patch ID, and options that affect Temporal command semantics.

## Command Sequencing

Commands receive monotonically increasing sequence numbers from the executor.

The sequence number is assigned when the executor decides to emit a durable command, not when an Elixir process happens to arrive in the mailbox. Sequence numbers are zero-based non-negative integers, matching Temporal Core's language operation identifiers. They are local to one workflow run and do not reset at activation boundaries.

Core invariants:

- Every durable command has a unique sequence number.
- Sequence numbers are monotonic inside one workflow run.
- Every command that blocks workflow code has exactly one pending caller.
- Every resolution job wakes at most one pending caller.
- Replay transcript entries are consumed exactly once and in order.

## Runner Lifecycle

The executor traps exits and starts the root workflow runner with `spawn_link/1`.

The runner wrapper calls `run/1` and exits with:

```elixir
{:workflow_result, {:ok, result}}
{:workflow_result, {:error, reason}}
```

Continue-as-new is not a return shape. Workflow code calls `Temporalex.Workflow.API.continue_as_new!/2`, which emits a terminal command and tears down workflow-owned processes without returning to user code.

Any other return shape is an invalid workflow return and becomes a workflow failure command.

If workflow code raises or throws unexpectedly, the runner exits with that failure reason and the executor converts it into a workflow failure command.

A blocked runner remains alive inside `GenServer.call/3`. Yielding is represented by an unreplied call and pending commands, not by runner process exit.

If the executor crashes, linked runners and workflow child processes are torn down. If a runner crashes, the executor receives `{:EXIT, runner_pid, reason}` and emits a failure completion.

## Signals

Signals are buffered by the executor.

Outside `API.phase/2`:

- matching `API.wait_for_signal/1` calls consume one buffered signal
- signals with no waiter remain buffered
- signals are never rejected

Inside `API.phase/2`:

- matching signal handlers run in the current phase scope
- non-matching signals remain buffered
- signal handlers may return `{:noreply, state}`, `{:stop, state}`, or `{:async, fun, state}`

## Updates

Updates are accepted only while the workflow is inside an `API.phase/2` with a matching update handler.

For each update:

1. If `run_validator` is true, the validator runs synchronously in the executor if one is configured.
2. If `run_validator` is false, the update has already been accepted in history and validation is not re-run.
3. Rejected updates emit a rejected update response in the same activation.
4. Accepted updates emit an accepted response in the same activation.
5. The handler result emits the completed update response in the same or a later activation.

Outside a matching phase scope, updates are rejected.

Update responses use `protocol_instance_id`, not the user-facing update id. The user-facing id is useful for logs and application correlation, but Temporal Core tracks protocol messages with `protocol_instance_id`.

## Queries

Queries read only `published_state`, which is set by `API.publish_state/1`.

Query handlers are module functions on the workflow module and must be read-only. They do not run inside the runner process.

Query-only activations do not advance workflow threads. They produce only query response commands.

## Structured Concurrency

`API.parallel/1` creates child workflow processes. Each branch has its own deterministic thread ID and can call normal workflow operations.

`API.phase/2` creates a message-processing scope. Sync handlers serialize message processing. Async handlers explicitly returned as `{:async, fun, state}` run concurrently and are bound to the phase scope.

The executor must not rely on BEAM scheduling or mailbox arrival order for command ordering. When multiple workflow units are runnable, it runs deterministic scheduler rounds as described in [scheduler_and_replay.md](scheduler_and_replay.md).

## Completion Contract

The executor builds `%Temporalex.Core.Completion{}` and sends it to the server:

```elixir
send(server_pid, {:workflow_activation_completion, run_id, completion})
```

For v1, only the server submits completions through the backend. This keeps worker/backend ownership centralized and lets the server maintain the pending activation registry.

## Implementation Order

The detailed implementation order is [implementation_slice.md](implementation_slice.md).

At a high level:

1. Build the sequential root-runner core and replay harness.
2. Review and correct the implemented design before adding concurrency.
3. Add deterministic scheduler rounds, `parallel`, `phase`, signals, updates, and queries.
4. Review the full core before adding server/backend integration.
