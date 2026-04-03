# Temporalex — Roadmap

Everything that needs to happen after v0.1.0.

## v0.2 — Architecture Rewrite

Full spec: [architecture.md](architecture.md) (programming model), [SDK specification](https://gist.github.com/hansihe/2dc9caea2b193086532f183b12330793) (Core SDK protocol).

Goal: production-grade NIF lifecycle, executor-owns-activation model, push-based poll loops, structured concurrency (`receive` + `parallel`), three-state model, update protocol, and a step-by-step test API.

### Design Principles

1. **Workflows are functions.** A workflow is a module with a `run/1` function. It calls activities, sleeps, waits for signals, and returns a result. There is no implicit event loop or background message processing.
2. **Concurrency is scoped and explicit.** The only way to introduce concurrent execution is by entering a `receive` or `parallel` block. `{:async, fn, state}` must be explicitly returned. Nothing is concurrent by default.
3. **State is what you make it.** No framework-managed "workflow state". `receive` has reducer state. Queries see only what you `publish_state`. These are separate concerns.
4. **Structure determines validity.** Which updates and signals a workflow accepts is determined by which `receive` block it's currently in. Outside `receive`, updates are rejected.
5. **The executor is the only coordination point.** All workflow runtime state lives in the executor GenServer. Runner/handler processes hold exactly one process dictionary key: the executor PID.
6. **OTP conventions over custom protocols.** Process linking for lifecycle, exit reasons for termination semantics, telemetry for observability, supervision for fault tolerance.
7. **No test infrastructure in production code paths.** Testing is achieved by substituting the executor, not by sprinkling stubs into the runtime dispatch.
8. **The Tokio runtime is the owner of all async work, Elixir processes are notified via messages.** NIF functions never block schedulers for extended periods.

---

### NIF Layer

#### N1: TaskGuard — guaranteed message delivery

Every spawned Tokio task creates a `TaskGuard` that guarantees exactly one message is sent to the Elixir process — either a success result or an error notification via `Drop`. Eliminates the failure mode where a task panic causes a message to never arrive, leaving the Elixir process hanging forever.

```rust
struct TaskGuard {
    pid: LocalPid,
    tag: Atom,
    runtime_handle: Handle,
}

impl TaskGuard {
    fn complete<F>(self, builder: F) { /* consume guard, send success, suppress Drop */ }
}

impl Drop for TaskGuard {
    fn drop(&mut self) { /* task panicked or cancelled — send error to Elixir */ }
}
```

- One-shot tasks (completions, connect): guard sends tagged result or error
- Poll loops: guard sends `{:poll_loop_exited, :workflow | :activity, :shutdown | :crashed}`
- Server treats unexpected poll loop exit as fatal -> crashes -> supervisor restarts

**Impact:** Critical. **Effort:** Medium.

#### N2: Resource monitors — WorkerResource monitors Server PID via `down/3`

`WorkerResource` monitors the Elixir process (Server PID) that owns it. When that process dies for any reason — including `Process.exit(pid, :kill)` which skips `terminate/2` callbacks — the monitor fires and the worker shuts down immediately.

```rust
impl Resource for WorkerResource {
    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        self.worker.initiate_shutdown();
    }
}
```

Why this is better than `terminate/2`:
- `terminate/2` is skipped on `:kill` exits and during certain supervisor shutdown sequences
- GC-triggered `Drop` has unpredictable timing — poll loops may spin sending messages to a dead process
- Resource monitors fire deterministically and immediately, regardless of how the process died

**Impact:** Critical. **Effort:** Medium.

#### N3: Push-based poll loops

Poll loops are long-lived Tokio tasks, not per-call NIF invocations. When `start_worker` is called, two tasks are spawned:

1. **Workflow poll loop**: calls `worker.poll_workflow_activation()` in a loop, sending `{:workflow_activation, bytes}` to the Server PID on each activation. Exits on `PollError::ShutDown`.
2. **Activity poll loop**: calls `worker.poll_activity_task()` in a loop, sending `{:activity_task, bytes}` to the Server PID on each task. Exits on `PollError::ShutDown`.

The Elixir process simply receives messages — it never calls a poll NIF. Eliminates per-poll NIF call overhead on the hot path.

**Impact:** High. **Effort:** Large.

#### N4: Singleton RuntimeResource

Three resource types cross the NIF boundary as opaque `ResourceArc` handles:

- **`RuntimeResource`** — singleton per BEAM node. Owns `CoreRuntime` + Tokio runtime. Started as `Temporalex.Runtime` GenServer in the Temporalex OTP app (like Logger — starts automatically, no user config).
- **`ClientResource`** — wraps a `Connection`. Holds `ResourceArc<RuntimeResource>` to prevent GC.
- **`WorkerResource`** — wraps `Arc<Worker>` for sharing across concurrent Tokio tasks. Holds `ResourceArc<RuntimeResource>`.

`_runtime` references on Client/Worker prevent premature runtime garbage collection.

**Impact:** Medium. **Effort:** Medium.

#### N5: Direct executor completions

Executor holds the `WorkerResource` handle (received from Server at spawn time) and calls `complete_workflow_activation(worker, bytes, self())` directly. No round-trip through the Server.

This is enabled by the executor-owns-activation model. Since the executor handles the entire activation — including queries and updates — there are no "inline commands" that need merging. One process, one completion.

The `WorkerResource` is `Arc<Worker>` in Rust — multiple Elixir processes can hold handles and call NIFs concurrently. The Core SDK handles internal synchronization.

**Impact:** High. **Effort:** Medium.

#### NIF Interface

All NIFs except `create_runtime()` are async — spawn a task on the Tokio runtime and return `:ok` immediately.

| NIF | Message to PID |
|-----|----------------|
| `create_runtime()` | Sync — returns `{:ok, runtime}` |
| `connect(runtime, url, api_key, headers, pid)` | `{:connected, client}` or `{:connect_error, reason}` |
| `start_worker(runtime, client, task_queue, ns, max_wf, max_act, pid)` | `{:worker_started, worker}` or `{:worker_error, reason}`, then continuous `{:workflow_activation, bytes}` and `{:activity_task, bytes}` |
| `complete_workflow_activation(worker, bytes, pid)` | `{:workflow_completion, :ok \| {:error, msg}}` |
| `complete_activity_task(worker, bytes, pid)` | `{:activity_completion, :ok \| {:error, msg}}` |
| `record_activity_heartbeat(worker, task_token, details_bytes)` | Fire-and-forget, Core SDK throttles |
| `initiate_shutdown(worker)` | Sync, non-blocking. Poll loops exit. |
| `shutdown_worker(worker, pid)` | `{:shutdown_complete, :ok}` |
| `start_workflow(client, ns, wf_id, wf_type, tq, input, req_id, pid)` | `{:start_workflow_result, {:ok, run_id} \| {:error, reason}}` |
| `signal_workflow(client, ns, wf_id, run_id, signal, input, req_id, pid)` | `{:signal_workflow_result, :ok \| {:error, reason}}` |
| `query_workflow(client, ns, wf_id, run_id, query_type, args, pid)` | `{:query_workflow_result, {:ok, bytes} \| {:error, reason}}` |
| `cancel_workflow(client, ns, wf_id, run_id, reason, req_id, pid)` | `{:cancel_workflow_result, :ok \| {:error, reason}}` |
| `terminate_workflow(client, ns, wf_id, run_id, reason, pid)` | `{:terminate_workflow_result, :ok \| {:error, reason}}` |
| `get_workflow_result(client, ns, wf_id, run_id, pid)` | `{:get_result_result, {:ok, bytes} \| {:error, reason}}` |
| `describe_workflow(client, ns, wf_id, run_id, pid)` | `{:describe_workflow_result, {:ok, map} \| {:error, reason}}` |
| `list_workflows(client, ns, query, page_size, pid)` | `{:list_workflows_result, {:ok, [map]} \| {:error, reason}}` |

---

### Supervision Tree

#### Temporalex OTP Application (library, auto-starts)

```
Temporalex.Supervisor
+-- Temporalex.Runtime (GenServer)
      Owns: RuntimeResource (NIF handle to CoreRuntime + Tokio runtime)
      No user configuration required
```

#### User Application (one per task queue)

```
MyApp.Temporal (Supervisor, strategy: :rest_for_one)
+-- MyApp.Temporal.Server (GenServer)
|     On init: obtains RuntimeResource, connects via NIF, creates worker via NIF
|     Owns: ClientResource, WorkerResource
|     Receives: {:workflow_activation, bytes}, {:activity_task, bytes}
|     Pure dispatch — forwards activations to executors, spawns activity tasks
|
+-- MyApp.Temporal.ExecutorSupervisor (DynamicSupervisor)
|     Executors receive WorkerResource handle at spawn time
|     Call completion NIFs directly — no round-trip through Server
|
+-- MyApp.Temporal.ActivitySupervisor (Task.Supervisor)
```

`rest_for_one` ensures Server death restarts executor and activity supervisors. Runtime is separate and unaffected.

---

### Server

Responsibilities:

1. **Activation dispatch**: receives activations from NIF poll loops, forwards entire activation to executor
2. **Activity execution**: spawns activity tasks via `Task.Supervisor`, tracks by task token
3. **Activity completion**: encodes activity results as protobuf, sends to NIF
4. **Executor lifecycle**: spawns (via DynamicSupervisor), monitors, tracks, cleans up

The Server does NOT:
- Call poll NIFs (push-based)
- Build workflow completions (executor does this directly)
- Handle queries (executor does this)
- Handle updates or reject updates (executor does this — Server has no knowledge of receive state)
- Merge inline_commands (no longer exists)

#### S1: Workflow activation flow

1. NIF poll loop sends `{:workflow_activation, bytes}` to Server
2. Server decodes, identifies `run_id`
3. For evictions: stop and remove executor
4. For everything else: forward entire activation to executor
5. Executor handles all job types, calls NIF directly for completion

**Impact:** High. **Effort:** Medium.

#### S2: Activity task flow

1. NIF poll loop sends `{:activity_task, bytes}` to Server
2. **Start variant**: Server looks up activity, creates `Activity.Context` (with WorkerResource handle + `:atomics` ref), spawns via `Task.Supervisor.async_nolink/3`
3. Activity returns `{:ok, value}` or `{:error, reason}`
4. Server encodes result, calls `complete_activity_task` NIF
5. **Cancel variant**: Server sets `:atomics` flag on context. For non-heartbeating activities, falls back to `Process.exit(pid, :shutdown)`

**Impact:** High. **Effort:** Medium.

---

### Executor (WorkflowTaskExecutor)

The executor is the heart of v2. It owns all workflow runtime state, handles activations, dispatches to runners/handlers, serves queries, manages the `receive` loop, and calls completion NIFs directly.

#### E1: Executor under DynamicSupervisor

Executors are children of `ExecutorSupervisor` (DynamicSupervisor). Server monitors each executor via `Process.monitor/1`. When an executor crashes, Server receives `{:DOWN, ...}`, cleans up registry, fails pending activation.

**Impact:** High. **Effort:** Medium.

#### E2: Executor state

```elixir
%WorkflowTaskExecutor{
  # Identity
  server_pid: pid(),
  worker: reference(),               # NIF WorkerResource for direct completion
  run_id: String.t(),
  task_queue: String.t(),
  workflow_module: module(),

  # Runner
  runner_pid: pid() | nil,
  runner_monitor: reference() | nil,

  # Replay
  replay_log: [replay_entry()],      # ordered list, sequence-keyed
  seq: non_neg_integer(),             # global sequence counter across all concurrent processes
  pending_calls: %{seq => GenServer.from()},

  # State model (three separate concerns)
  published_state: term(),            # set by API.publish_state, read by queries
  receive_state: term() | nil,       # reducer accumulator, only exists during API.receive
  receive_opts: keyword() | nil,     # handler maps + timeout, only exists during API.receive

  # Concurrency tracking
  async_handlers: MapSet.t(pid()),   # in-flight async handler processes within current receive
  parallel_waiters: %{ref => {index, from}},  # parallel branch tracking

  # Signals (dual-mode: buffered outside receive, dispatched inside)
  signal_buffer: [{name, payload}],
  signal_waiters: %{name => GenServer.from()},

  # Updates (only valid inside receive)
  update_handlers: %{name => handler},
  update_validators: %{name => validator},

  # Workflow metadata
  patches: MapSet.t(),
  cancelled: boolean(),
  commands: [command],
  status: :idle | :running | :yielded | :in_receive | :done
}
```

**Impact:** High. **Effort:** Medium.

#### E3: Activation handling — executor owns everything

The Server becomes pure dispatch. The executor handles ALL job types from an activation:

```elixir
def handle_info({:activation, activation}, state) do
  jobs = categorize_jobs(activation.jobs)

  state = apply_resolutions(jobs, state)        # resolve activities, timers, child workflows
  state = dispatch_signals(jobs.signals, state)  # buffer or dispatch to receive handlers
  state = dispatch_updates(jobs.updates, state)  # run validators, dispatch or reject
  query_cmds = handle_queries(jobs.queries, state)  # serve from published_state
  state = %{state | commands: query_cmds ++ state.commands}
  state = maybe_start_or_resume_runner(jobs, state)
  maybe_flush_commands(state)
end
```

Key behaviors:
- **Signals outside `receive`**: buffered in `signal_buffer`, consumed by `API.wait_for_signal`
- **Signals inside `receive` with matching handler**: dispatched to handler (sync or async)
- **Signals inside `receive` with no matching handler**: buffered in `signal_buffer` (signals are never lost)
- **Updates inside `receive` with matching handler**: validator runs inline in executor, then handler dispatched
- **Updates inside `receive` with no matching handler**: rejected with error
- **Updates outside `receive`**: rejected with error (structure determines validity)
- **Queries**: always served from `published_state` via `handle_query/3` callback
- **Resolutions**: unblock the correct pending process (runner, handler, or parallel branch) by sequence number

**Impact:** High. **Effort:** Large.

#### E4: Sequence number allocation across concurrent processes

The executor maintains a global `seq` counter. Every blocking operation (activity, timer, sleep, side_effect, child workflow) from any process (runner, sync handler, async handler, parallel branch) gets a unique sequence number via `GenServer.call(executor, {:next_seq, ...})`.

This enables the executor to route `Resolve*` jobs back to the correct process. The Core SDK sees a flat stream of commands and has no knowledge of the concurrency model.

**Impact:** High. **Effort:** Medium.

#### E5: Command flushing

Executor accumulates commands in a list (prepended). On runner yield/done, or when all sync/async handlers complete for a receive dispatch cycle: reverse, encode as protobuf `WorkflowActivationCompletion`, call `complete_workflow_activation(worker, bytes, self())` directly.

Commands from all concurrent processes (runner, async handlers, parallel branches) are collected by the executor and flushed as a single completion.

**Impact:** Medium. **Effort:** Small.

---

### Runner

The runner is a spawned process that executes `run/1`. It communicates with the executor exclusively via `GenServer.call` (blocks runner, executor stays free).

#### R1: Runner lifecycle and exit reasons

Runner communicates outcome to executor through exit reasons (caught by `handle_info({:DOWN, ...})`):

| Exit reason | Executor action |
|---|---|
| `{:workflow_result, {:ok, result}}` | Build `CompleteWorkflowExecution` command |
| `{:workflow_result, {:error, reason}}` | Build `FailWorkflowExecution` command |
| `{:workflow_result, {:continue_as_new, args}}` | Build `ContinueAsNewWorkflowExecution` command |
| `:normal` | Runner yielded (blocked on activity/timer/signal/receive) |
| Other (crash) | Build `FailWorkflowExecution` with crash message |

Runner process dictionary contains exactly one key: `Process.put(:__temporal_executor__, executor_pid)`.

**Impact:** Medium. **Effort:** Small.

#### R2: Runner blocking protocol

Every blocking API call from the runner follows the same pattern:

```elixir
# In the runner process (inside run/1, handler, or parallel branch):
def execute_activity(type, input, opts) do
  executor = Process.get(:__temporal_executor__)
  GenServer.call(executor, {:execute_activity, type, input, opts}, :infinity)
end
```

The executor receives the call, allocates a sequence number, checks replay log:
- **Replay hit** (head matches): reply immediately with recorded result
- **Replay miss** (head doesn't match): nondeterminism error, fail workflow
- **Log empty** (first execution): emit command, store `from` in `pending_calls`, return `{:noreply, state}`

Runner stays blocked until the resolution arrives in a future activation.

**Impact:** Medium. **Effort:** Small.

---

### Workflow API (`Temporalex.Workflow.API`)

These are the functions available to workflow code. All implemented as `GenServer.call` to the executor.

#### W1: Sequential primitives

Available anywhere in workflow code (run/1, handlers, parallel branches):

| Function | Executor behavior | Core SDK mapping |
|---|---|---|
| `API.sleep(duration_ms)` | `StartTimer` command, block caller | `StartTimer` -> `FireTimer` |
| `API.wait_for_signal(name)` | Check buffer, block if empty | No command (executor buffers `SignalWorkflow` jobs) |
| `API.side_effect(fn)` | Execute once, record result; on replay return recorded value | `SideEffect` marker event |
| `API.publish_state(state)` | Replace `published_state` in executor, no command | No command |
| `API.patched?(patch_id)` | `SetPatchMarker` command or check `NotifyHasPatch` | `SetPatchMarker` |
| `API.deprecate_patch(patch_id)` | `SetPatchMarker` with deprecated flag | `SetPatchMarker` |
| `API.cancelled?()` | Read `cancelled` boolean from executor state | No command |

**Impact:** High. **Effort:** Medium.

#### W2: `API.receive` — structured concurrency host for messages

The central construct for message-driven workflow phases. Blocks the caller, processes incoming signals and updates, returns when a handler signals `{:stop, ...}` or timeout expires.

```elixir
result = API.receive(initial_state,
  signal: %{
    "name" => fn args, state -> {:noreply, new_state} end,
    "done" => fn _args, state -> {:stop, state} end,
  },
  update: %{
    "name" => fn args, state -> {:reply, response, new_state} end,
    "name" => {&handler/2, validator: &validator/2},
  },
  timeout: :timer.hours(24)
)
```

Executor behavior when runner calls `API.receive`:
1. Store `receive_state`, handler maps, and timeout in executor state
2. Set `status: :in_receive`
3. Start timeout as a durable timer (`StartTimer` command) if specified — must survive replay
4. Begin dispatching buffered signals that have matching handlers
5. Block runner (return `{:noreply, state}`)
6. On `{:stop, ...}`: wait for all async handlers to complete, reply to runner with final state
7. On timeout: reply to runner with `{:timeout, state}`

Signal handler return values:
- `{:noreply, new_state}` — update receive state, continue
- `{:stop, state}` — exit receive loop
- `{:async, fn, state}` — spawn async handler, continue dispatching

Update handler return values:
- `{:reply, response, new_state}` — reply to update caller, update state, continue
- `{:stop, response, new_state}` — reply to update caller, exit receive loop
- `{:async, fn, state}` — accept update, spawn async handler; fn return value becomes update reply

Update validators:
- Run inline in executor process (synchronous, never spawned)
- Return `:ok` or `{:error, reason}`
- Rejection means no history event, caller gets error

**Impact:** Critical. **Effort:** Large.

#### W3: `API.parallel` — structured fan-out

Executes a list of functions concurrently. Each function runs in its own process with `Process.put(:__temporal_executor__, executor_pid)`. Blocks until all complete.

```elixir
results = API.parallel([fn1, fn2, fn3])
```

Executor behavior:
1. Spawn one process per function, each linked to executor
2. Each branch can call activities, sleep, side_effect, publish_state, nest further parallel calls
3. Collect results in order, wrapping exceptions as `{:error, reason}`
4. Reply to caller with results list when all branches complete
5. Branches produce commands with unique sequence numbers allocated by executor

Error semantics: all branches run to completion. No early cancellation on failure.

**Impact:** High. **Effort:** Medium.

#### W4: `API.start_child_workflow` — child workflow execution

Starts a child workflow from within a workflow. Blocks until the child completes or fails. Same blocking protocol as activities — executor allocates sequence number, emits `StartChildWorkflowExecution` command, blocks caller until `ResolveChildWorkflowExecution` arrives.

```elixir
{:ok, result} = API.start_child_workflow(MyApp.Workflows.SubProcess, args, opts)
```

Options: `workflow_id`, `task_queue`, `cancellation_type`, `parent_close_policy`.

On child failure, raises `ChildWorkflowFailure` with `workflow_type`, `workflow_id`, and `cause`.

Note: not defined in architecture.md — extracted from v0.1 behavior and Core SDK protocol. Needed because child workflows are referenced in replay log (RP1), testing (T2), and error types.

**Impact:** High. **Effort:** Medium.

#### W5: `API.update_state` — async handler state access

Only available inside async handler processes (spawned by `{:async, fn, state}` within `receive`).

```elixir
result = API.update_state(fn state -> {return_value, new_state} end)
```

Executor behavior:
1. Receive `{:update_state, fn, from}` call
2. Execute fn with current `receive_state`
3. Replace `receive_state` with new value
4. Reply with return_value

Serialized through executor mailbox — concurrent async handlers' `update_state` calls are never interleaved.

**Impact:** Medium. **Effort:** Small.

#### W6: Sync handler execution

Default handler mode inside `receive`. When a signal/update matches a handler:

1. Executor spawns a process for the handler function
2. Handler process gets `Process.put(:__temporal_executor__, executor_pid)` — can call activities, parallel, sleep, side_effect, publish_state
3. Receive loop **waits** for handler to complete before dispatching next message
4. Handler return value updates receive state (and optionally replies to update caller)

**Impact:** Medium. **Effort:** Medium.

#### W7: Async handler execution

When handler returns `{:async, fn, state}`:

1. Executor spawns a new process for `fn`
2. Process gets `Process.put(:__temporal_executor__, executor_pid)`
3. Process is tracked in `async_handlers` MapSet
4. Receive loop continues dispatching immediately (concurrent)
5. Process can call activities, parallel, sleep, side_effect, publish_state, update_state
6. Cannot spawn further async handlers or enter nested receive
7. For updates: fn return value becomes the update reply (`UpdateResponse{completed}`)
8. For signals: fn return value is ignored
9. On raise in update handler: update fails, workflow continues
10. On raise in signal handler: error logged, workflow continues
11. When receive exits (`{:stop, ...}`): wait for all async_handlers to complete before replying to runner

**Impact:** High. **Effort:** Large.

---

### Workflow Module

#### M1: `use Temporalex.Workflow`

Generates:
- `__temporal_workflow_type__/0` returning module name as string
- Imports `Temporalex.Workflow.API` as `API`
- Validates `run/1` is defined at compile time
- Optional `handle_query/3` callback (default: no-op)

```elixir
defmodule MyApp.Workflows.Checkout do
  use Temporalex.Workflow

  def handle_query("status", _args, state), do: {:reply, state.phase}

  def run(args) do
    # ...
  end
end
```

`run/1` return values:
- `{:ok, result}` -> `CompleteWorkflowExecution`
- `{:error, reason}` -> `FailWorkflowExecution`
- `{:continue_as_new, args}` -> `ContinueAsNewWorkflowExecution`

**Impact:** Medium. **Effort:** Small.

### Activity Definition

#### A1: `defactivity` macro

Generates two functions per activity:

1. **`charge_payment(amount)`** — dispatch function. Calls `GenServer.call(executor, {:execute_activity, type, input, opts}, :infinity)` where executor comes from `Process.get(:__temporal_executor__)`.
2. **`__charge_payment__/1`** — implementation function. Contains the `defactivity` body. Called by Server when activity task arrives. Public so it can be called directly in tests.

Module generates `__temporal_activities__/0` returning `[{name, opts}]` for registration.

Activity type string format: `"MyApp.Activities.Orders.charge_payment"` (module + function).

Context detection: when `defactivity` head includes `ctx` as first parameter, runtime passes an `Activity.Context` struct. Otherwise no context is passed.

```elixir
# Without context:
defactivity charge(amount), timeout: 30_000 do
  Stripe.charge(amount)
end

# With context (for heartbeating):
defactivity process_file(ctx, path), timeout: 60_000, heartbeat_timeout: 10_000 do
  File.stream!(path)
  |> Enum.each(fn line ->
    process(line)
    Temporalex.Activity.Context.heartbeat(ctx, %{progress: line})
  end)
end
```

**Impact:** Medium. **Effort:** Small.

#### A2: Activity context with WorkerResource handle

Activity context holds the `WorkerResource` handle for direct heartbeat NIF calls — fire-and-forget, no round-trip through Server.

```elixir
%Temporalex.Activity.Context{
  activity_id: String.t(),
  activity_type: String.t(),
  task_token: binary(),
  workflow_id: String.t(),
  run_id: String.t(),
  task_queue: String.t(),
  attempt: non_neg_integer(),
  heartbeat_timeout: non_neg_integer() | nil,
  is_local: boolean(),
  worker: reference(),           # NIF WorkerResource handle
  cancelled: :atomics.ref()      # Set by Server on Cancel task
}
```

**Impact:** Medium. **Effort:** Small.

#### A3: Atomics for activity cancellation

Activity context contains an `:atomics` ref. Server sets the flag when a Cancel task arrives. Activity checks it at each `heartbeat/2` call — zero overhead when not cancelled.

Cancellation flow:
1. Activity calls `heartbeat(ctx, details)` — sends details to NIF, returns immediately
2. Core SDK sends heartbeat to Temporal server. If server responds with cancel, Core SDK queues a cancel.
3. Next `poll_activity_task()` returns `ActivityTask` Cancel variant
4. Server sets the `:atomics` flag on the activity's context
5. Next `heartbeat/2` checks flag, returns `{:cancelled, reason}` instead of `:ok`

Activities that don't heartbeat: cancelled via `Process.exit(pid, :shutdown)`.

**Impact:** Medium. **Effort:** Small.

---

### Replay

#### RP1: Replay log as sequence-keyed ordered list

The replay log is an ordered list of entries, keyed by sequence number. When any process (runner, handler, parallel branch) makes a blocking call:

1. Executor allocates next sequence number
2. Check replay log head:
   - **Head matches** (same seq + operation type): reply immediately with recorded result
   - **Head doesn't match**: nondeterminism error, fail workflow
   - **List empty**: first execution, emit command, block caller

With concurrent processes (`parallel`, async handlers), the sequence numbers establish a deterministic total order. Replay produces the same interleaving because the same activations arrive in the same order, and each process blocks at the same points.

```elixir
# Replay log entries (examples):
{:activity, seq, result}
{:timer, seq, :ok}
{:side_effect, seq, value}
{:child_workflow, seq, result}
```

**Impact:** High. **Effort:** Medium.

#### RP2: Determinism enforcement

All workflow code must be deterministic. The same inputs (activity results, signal payloads, timer fires, update arrivals) must produce the same sequence of commands.

What is deterministic:
- Activity calls: replayed from recorded results
- Timer fires: replayed from history
- Signal arrival order: replayed from history
- Update arrival order: replayed from history
- `API.side_effect` return values: recorded in history
- `API.update_state` closures: re-executed (deterministic because inputs are deterministic)
- `API.parallel` ordering: unique sequence numbers per branch

What is NOT deterministic (use side effects or activities):
- `DateTime.utc_now()` -> `API.side_effect(fn -> DateTime.utc_now() end)`
- `:rand.uniform()` -> `API.side_effect(fn -> :rand.uniform() end)`
- `System.get_env("FOO")` -> `API.side_effect(fn -> System.get_env("FOO") end)`
- Network calls -> use an activity

**Impact:** High. **Effort:** Medium.

---

### Data Conversion

#### D1: ETF converter (default)

ETF-based serialization as default. `application/x-erlang-etf` encoding via `:erlang.term_to_binary/1`.

Preserves full Elixir term fidelity (atoms, tuples, structs, MapSets). Faster than JSON. Payloads appear as opaque binaries in Temporal UI — codec server can be added for readability.

JSON converter kept as fallback for cross-language interop.

**Impact:** Medium. **Effort:** Small.

---

### Error Types

| Type | Meaning | Key fields |
|---|---|---|
| `ActivityFailure` | Activity returned `{:error, _}` or crashed | `activity_type`, `cause` |
| `ChildWorkflowFailure` | Child workflow failed | `workflow_type`, `workflow_id`, `cause` |
| `ApplicationError` | Application-level, optionally non-retryable | `type`, `non_retryable` |
| `TimeoutError` | Timeout exceeded | `timeout_type` |
| `CancelledError` | Workflow or activity cancelled | `details` |
| `Nondeterminism` | Replay divergence detected | `message` |

---

### Observability

Standard `:telemetry` events. No custom interceptor abstraction.

| Event | Measurements | Metadata |
|---|---|---|
| `[:temporalex, :workflow, :start]` | `system_time` | `workflow_id`, `workflow_type`, `run_id`, `task_queue` |
| `[:temporalex, :workflow, :stop]` | `duration` | + `result` |
| `[:temporalex, :workflow, :exception]` | `duration` | + `kind`, `reason` |
| `[:temporalex, :activity, :start]` | `system_time` | `activity_type`, `activity_id`, `task_queue` |
| `[:temporalex, :activity, :stop]` | `duration` | + `result` |
| `[:temporalex, :activity, :exception]` | `duration` | + `kind`, `reason` |
| `[:temporalex, :worker, :activation]` | `duration`, `job_count`, `command_count` | `run_id`, `task_queue` |

Optional OpenTelemetry via `Temporalex.OpenTelemetry.setup/1`.

---

### Ownership & Monitoring

Every component has a clear owner. Every failure has a defined propagation path. **No failure is silent.**

| Component | Owner | Mechanism |
|---|---|---|
| RuntimeResource | `Temporalex.Runtime` process | Process state; dropped on process death |
| ClientResource | Server process | Process state; dropped on process death |
| WorkerResource | Server process | Monitors Server via `down/3` |
| Workflow poll loop | Tokio runtime | TaskGuard -> Server PID |
| Activity poll loop | Tokio runtime | TaskGuard -> Server PID |
| Completion tasks | Tokio runtime (one-shot) | TaskGuard -> caller PID |
| Server | User supervisor | OTP child, `rest_for_one` |
| Executor | ExecutorSupervisor (DynamicSupervisor) | OTP child; Server monitors each executor |
| Runner | Executor process | `spawn_link`; exits propagate to executor |
| Sync handler | Executor process | `spawn_link`; executor waits for completion |
| Async handler | Executor process | `spawn_link`; tracked in `async_handlers` MapSet |
| Parallel branch | Executor process | `spawn_link`; tracked in `parallel_waiters` |
| Activity task | ActivitySupervisor (Task.Supervisor) | `async_nolink`; Server monitors task ref |

| Watcher | Watched | Mechanism | On death |
|---|---|---|---|
| WorkerResource | Server PID | Rustler resource monitor (`down/3`) | `initiate_shutdown()` -> poll loops exit |
| Server | Each Executor | `Process.monitor/1` | Clean registry, fail pending activation |
| Executor | Runner | `spawn_link` | `handle_info({:DOWN, ...})` -> build completion command |
| Executor | Sync handler | `spawn_link` | Handler crash -> fail activation |
| Executor | Async handlers | `spawn_link` | Handler crash -> log error (signal) or fail update |
| Executor | Parallel branches | `spawn_link` | Branch crash -> wrap as `{:error, reason}` in results |
| Server | Activity tasks | `Task.Supervisor.async_nolink` | `handle_info({:DOWN, ref, ...})` -> encode failure result |
| Tokio TaskGuard | (self) | `Drop` impl | Send error message to target PID |
| OTP Supervisor | Server | OTP supervision (`rest_for_one`) | Restart Server + supervisors |

### Failure Propagation Scenarios

**Server crashes:** Server dies -> `rest_for_one` kills ExecutorSupervisor + ActivitySupervisor -> WorkerResource monitor fires `down/3` -> `initiate_shutdown()` -> poll loops exit -> supervisor restarts Server -> reconnect -> new worker -> new polls. Clean cascade.

**Poll loop crashes:** TaskGuard Drop sends `{:poll_loop_exited, :crashed}` to Server -> Server crashes itself -> cascades as above. Clean cascade.

**Executor crashes:** DynamicSupervisor handles it -> runner + handlers are linked, die too -> Server receives `{:DOWN, ...}` -> removes executor from registry -> sends failure completion. Clean cascade.

**Runner crashes:** Linked to executor -> executor receives `{:DOWN, ...}` -> builds `FailWorkflowExecution` from crash reason -> sends completion to NIF directly. Clean cascade.

**Sync handler crashes:** Linked to executor -> executor receives `{:DOWN, ...}` -> fail activation. Clean cascade.

**Async handler crashes (signal):** Linked to executor -> executor receives `{:DOWN, ...}` -> remove from `async_handlers`, log error. Workflow continues.

**Async handler crashes (update):** Linked to executor -> executor receives `{:DOWN, ...}` -> remove from `async_handlers`, send `UpdateResponse{failed}`. Workflow continues.

**Parallel branch crashes:** Linked to executor -> executor receives `{:DOWN, ...}` -> record `{:error, reason}` for that branch index. Other branches continue.

**Activity task crashes:** `async_nolink` -> Server receives `{:DOWN, ...}` -> encodes failure as `ActivityExecutionResult` -> sends completion to NIF. Clean cascade.

**Completion Tokio task panics:** TaskGuard Drop sends error to caller PID -> caller handles error. Clean via TaskGuard.

**Runtime process crashes:** RuntimeResource dropped -> Tokio runtime drops -> all tasks cancelled -> TaskGuards fire -> Servers crash -> supervisors restart -> `Temporalex.Runtime.get()` returns new runtime. Clean cascade.

---

### Testing

#### T1: Test executor — same GenServer.call protocol as production

`Temporalex.Testing.WorkflowExecutor` is a GenServer implementing the same `GenServer.call` protocol as the production executor. Runner/handler processes have `:__temporal_executor__` set to the test executor — they can't tell the difference.

Operates in step-by-step mode. When the workflow calls any blocking API, the runner blocks and the test executor reports what it's waiting for.

Must support the full API surface: activities, sleep, wait_for_signal, side_effect, publish_state, patched?, receive, parallel, update_state.

**Impact:** Critical. **Effort:** Large.

#### T2: Incremental API — `start_workflow/2`, `next/1`, `resolve/2`

```elixir
test "checkout calls payment then email" do
  {:ok, exec} = Temporalex.Testing.start_workflow(MyApp.Workflows.Checkout, %{"order_id" => "123"})

  assert {:activity, call} = Temporalex.Testing.next(exec)
  assert call.type == "MyApp.Activities.Payment.perform"

  assert {:activity, call} = Temporalex.Testing.resolve(exec, {:ok, "charge_123"})
  assert call.type == "MyApp.Activities.Email.send_receipt"

  assert {:ok, result} = Temporalex.Testing.resolve(exec, {:ok, :sent})
  assert result == %{charge_id: "charge_123"}
end
```

`next/1` returns:
- `{:activity, %{type, input, opts}}`
- `{:child_workflow, %{...}}`
- `{:sleep, duration}`
- `{:signal, name}` (from `wait_for_signal` outside receive)
- `{:receive, %{signals: [...], updates: [...], timeout: ...}}` (workflow entered a receive block)
- `{:ok, result}`
- `{:error, reason}`
- `{:continue_as_new, args}`

`resolve/2` provides the result and advances to the next blocking point or completion.

**Impact:** Critical. **Effort:** Medium.

#### T3: Signal and update delivery

```elixir
# Signal delivery (outside receive — consumed by wait_for_signal):
assert {:signal, "approval"} = Temporalex.Testing.next(exec)
assert {:activity, call} = Temporalex.Testing.send_signal(exec, "approval", %{approved: true})

# Signal delivery (inside receive — dispatched to handler):
assert {:receive, _} = Temporalex.Testing.next(exec)
assert {:noreply, state} = Temporalex.Testing.send_signal(exec, "increment", %{})

# Update delivery (inside receive):
assert {:receive, _} = Temporalex.Testing.next(exec)
assert {:reply, response, state} = Temporalex.Testing.send_update(exec, "add_item", [%{sku: "ABC"}])

# Update with validation rejection:
assert {:error, "invalid SKU"} = Temporalex.Testing.send_update(exec, "add_item", [%{sku: ""}])
```

**Impact:** High. **Effort:** Medium.

#### T4: Cancel — `cancel/1`

```elixir
Temporalex.Testing.cancel(exec)
# Next cancelled?() call returns true
```

**Impact:** Low. **Effort:** Small.

#### T5: `run_workflow/3` convenience — pre-loaded operation log

```elixir
{:ok, result} = Temporalex.Testing.run_workflow(MyApp.Workflows.Checkout, %{"order_id" => "123"},
  log: [
    {:activity, "MyApp.Activities.Payment.perform", {:ok, "charge_123"}},
    {:activity, "MyApp.Activities.Email.send_receipt", {:ok, :sent}}
  ]
)
```

Mismatches (wrong type, wrong activity name, extra/missing calls) fail with clear error. Built on top of incremental API.

**Impact:** Medium. **Effort:** Small.

#### T6: Activity test context

```elixir
# Basic:
{:ok, charge_id} = Temporalex.Testing.run_activity(MyApp.Activities.Orders, :charge_payment, %{amount: 100})

# With heartbeat collection:
{:ok, result, ctx} = Temporalex.Testing.run_activity(MyApp.Activities.Files, :process_file, %{path: path})
assert length(Temporalex.Testing.heartbeats(ctx)) > 0

# With cancellation:
ctx = Temporalex.Testing.activity_context(cancel_after: 3)
{:error, {:cancelled, _}} = Temporalex.Testing.run_activity(MyApp.Activities.Files, :process_file, %{path: path}, ctx: ctx)

# With overrides:
Temporalex.Testing.run_activity(MyApp.Activities.Retry, :perform, input, ctx: [attempt: 3])
```

**Impact:** Medium. **Effort:** Small.

#### T7: Testing `receive` blocks

```elixir
test "counter entity workflow" do
  {:ok, exec} = Temporalex.Testing.start_workflow(MyApp.Workflows.Counter, %{})

  # Workflow enters receive
  assert {:receive, info} = Temporalex.Testing.next(exec)
  assert "increment" in info.signals
  assert "done" in info.signals

  # Send signals into the receive loop
  Temporalex.Testing.send_signal(exec, "increment", %{})
  Temporalex.Testing.send_signal(exec, "increment", %{})

  # Query published state
  assert {:ok, 0} = Temporalex.Testing.query(exec, "value")

  # Stop the receive
  Temporalex.Testing.send_signal(exec, "done", %{})

  # Workflow continues after receive, returns result
  assert {:ok, 2} = Temporalex.Testing.next(exec)
end
```

**Impact:** High. **Effort:** Medium.

#### T8: Testing `parallel`

```elixir
test "fan-out processes all items concurrently" do
  {:ok, exec} = Temporalex.Testing.start_workflow(MyApp.Workflows.BatchProcess, %{"items" => [1, 2, 3]})

  # Parallel emits multiple activities at once
  assert {:parallel, activities} = Temporalex.Testing.next(exec)
  assert length(activities) == 3

  # Resolve all branches
  results = Enum.map(activities, fn _ -> {:ok, :processed} end)
  assert {:ok, %{processed: 3}} = Temporalex.Testing.resolve_parallel(exec, results)
end
```

**Impact:** Medium. **Effort:** Medium.

#### T9: Testing async handlers

```elixir
test "async update handler calls activity then updates state" do
  {:ok, exec} = Temporalex.Testing.start_workflow(MyApp.Workflows.Inventory, %{})

  assert {:receive, _} = Temporalex.Testing.next(exec)

  # Send update — triggers async handler
  Temporalex.Testing.send_update(exec, "restock", [%{sku: "ABC", quantity: 10}])

  # Async handler calls an activity
  assert {:activity, call} = Temporalex.Testing.next(exec)
  assert call.type == "MyApp.Activities.Pricing.current_price"

  # Resolve activity — handler completes, update_state runs
  Temporalex.Testing.resolve(exec, {:ok, 9.99})

  # Verify state was updated
  assert {:ok, stock} = Temporalex.Testing.query(exec, "stock")
  assert stock["ABC"].quantity == 10
end
```

**Impact:** Medium. **Effort:** Medium.

#### T10: Testing queries via `publish_state`

```elixir
test "queries reflect published state" do
  {:ok, exec} = Temporalex.Testing.start_workflow(MyApp.Workflows.Onboarding, %{"user_id" => "u1"})

  # First activity — published state should be :creating_account
  assert {:activity, _} = Temporalex.Testing.next(exec)
  assert {:ok, %{step: :creating_account}} = Temporalex.Testing.query(exec, "status")

  # Resolve and check next state
  assert {:activity, _} = Temporalex.Testing.resolve(exec, {:ok, %{id: "acc_1"}})
  assert {:ok, %{step: :sending_welcome}} = Temporalex.Testing.query(exec, "status")
end
```

**Impact:** Medium. **Effort:** Small.

---

### Core SDK Protocol Mapping

| Temporalex Construct | Core SDK Commands |
|---|---|
| `Activities.Foo.bar()` | `ScheduleActivity` -> `ResolveActivity` |
| `API.sleep(ms)` | `StartTimer` -> `FireTimer` |
| `API.start_child_workflow(mod, args)` | `StartChildWorkflowExecution` -> `ResolveChildWorkflowExecution` |
| `API.wait_for_signal(name)` | No command (executor buffers `SignalWorkflow` jobs) |
| `API.side_effect(fn)` | Records result as `SideEffect` marker event |
| `API.receive` | No command (executor dispatches `SignalWorkflow` and `DoUpdate` jobs) |
| `{:async, fn, state}` (update) | `UpdateResponse{accepted}` immediately, then handler's commands, then `UpdateResponse{completed}` |
| `{:async, fn, state}` (signal) | No protocol-level tracking — handler's commands are regular commands |
| `API.parallel(fns)` | Multiple commands in one activation (e.g. multiple `ScheduleActivity`) |
| `API.publish_state` | No command (executor state for query serving) |
| `API.update_state` | No command (executor-internal state transformation) |
| `{:continue_as_new, args}` | `ContinueAsNewWorkflowExecution` |
| `API.patched?(id)` | `SetPatchMarker` (or reads `NotifyHasPatch` from activation) |
| `API.deprecate_patch(id)` | `SetPatchMarker` with deprecated flag |

---

### Implementation Order

#### Phase 1: NIF Safety (N1, N2)
TaskGuard + resource monitors. Independent, immediate safety win. No Elixir runtime changes needed.

##### Verification (Phase 1) — 7 tests

All new — no v0.1 tests exist for these primitives:

| # | Test | What it verifies |
|---|------|-----------------|
| P1-1 | TaskGuard sends tagged success message on normal completion | `complete()` consumes guard, sends `{tag, result}` to PID |
| P1-2 | TaskGuard Drop sends tagged error when task panics | Panic triggers Drop, PID receives `{tag, {:error, _}}` |
| P1-3 | TaskGuard Drop sends tagged error when guard is dropped | Cancellation/early-drop still notifies PID |
| P1-4 | Resource monitor fires `down/3` when owning process exits normally | Process exit → `down/3` callback invoked |
| P1-5 | Resource monitor fires `down/3` on `Process.exit(pid, :kill)` | Hard kill still triggers monitor (unlike `terminate/2`) |
| P1-6 | Worker `initiate_shutdown()` called when monitor fires | `down/3` → `initiate_shutdown()` → poll loops exit |
| P1-7 | Multiple TaskGuards in flight don't interfere | N guards → N independent messages, no cross-talk |

#### Phase 2: NIF Infrastructure (N4, N3)
Singleton runtime, then push-based poll loops. N4 is prerequisite for N3. This gives us the full NIF layer.

##### Verification (Phase 2) — 17 tests

From TESTS.md (v0.1 Connection tests):

| # | Test | Source |
|---|------|--------|
| P2-1 | Missing :name raises ArgumentError | TESTS.md #166 |
| P2-2 | Rejects garbage address | TESTS.md #167 |
| P2-3 | Rejects address without scheme | TESTS.md #168 |
| P2-4 | Accepts http address | TESTS.md #169 |
| P2-5 | Accepts https address | TESTS.md #170 |
| P2-6 | Returns not_connected when runtime is nil | TESTS.md #171 |
| P2-7 | Address defaults to localhost:7233 | TESTS.md #172 |

New tests for NIF interface and push-based architecture:

| # | Test | What it verifies |
|---|------|-----------------|
| P2-8 | `create_runtime()` returns `{:ok, runtime_resource}` | Sync NIF creates RuntimeResource successfully |
| P2-9 | Runtime GenServer starts, holds resource, `Runtime.get()` returns it | Singleton lifecycle in OTP app |
| P2-10 | `connect()` sends `{:connected, client}` to caller | Async NIF → success message |
| P2-11 | `connect()` with bad URL sends `{:connect_error, reason}` | Async NIF → error message |
| P2-12 | `start_worker()` sends `{:worker_started, worker}` | Worker creation success path |
| P2-13 | Workflow poll loop sends `{:workflow_activation, bytes}` | Push-based activation delivery |
| P2-14 | Activity poll loop sends `{:activity_task, bytes}` | Push-based task delivery |
| P2-15 | Poll loops exit cleanly on `initiate_shutdown()` | Graceful shutdown path |
| P2-16 | Poll loop crash delivers error via TaskGuard to Server PID | TaskGuard integration with poll loops |
| P2-17 | WorkerResource monitors Server PID (integration with N2) | Monitor fires on Server death → worker shuts down |

#### Phase 3: Core Executor (E1, E2, E3, R1, R2, RP1, RP2)
Executor GenServer under DynamicSupervisor. Activation handling, runner lifecycle, replay log. Sequential-only workflows work after this phase.

##### Verification (Phase 3) — 37 tests

From TESTS.md (v0.1 executor tests, adapted for v2 model):

| # | Test | Source |
|---|------|--------|
| P3-1 | Pure workflow completes immediately with result | TESTS.md #120 |
| P3-2 | Error workflow sends fail command | TESTS.md #121 |
| P3-3 | Runner blocks on activity, executor sends schedule command, resolve completes | TESTS.md #122 |
| P3-4 | Runner gets replay results immediately (no schedule commands) | TESTS.md #123 |
| P3-5 | Partial replay — first replayed, second scheduled | TESTS.md #124 |
| P3-6 | Activity where timer expected → nondeterminism error | TESTS.md #125 |
| P3-7 | Timer where activity expected → nondeterminism error | TESTS.md #126 |
| P3-8 | Crashed runner sends fail command with error message | TESTS.md #127 |
| P3-9 | Signals are forwarded to runner process | TESTS.md #128 |

From TESTS.md (v0.1 Workflow.Context — executor/runner context management):

| # | Test | Source |
|---|------|--------|
| P3-10 | Allocates incrementing sequence numbers | TESTS.md #68 |
| P3-11 | Prepend + flush returns commands in order | TESTS.md #69 |
| P3-12 | Returns nil when no timestamp set | TESTS.md #70 |
| P3-13 | Returns the workflow time when set | TESTS.md #71 |
| P3-14 | Returns false by default (replaying?) | TESTS.md #72 |
| P3-15 | Returns true when replaying | TESTS.md #73 |
| P3-16 | Returns a float between 0 and 1 (random) | TESTS.md #74 |
| P3-17 | Is deterministic for same run_id and seq (random) | TESTS.md #75 |
| P3-18 | Returns a string that looks like a UUID | TESTS.md #76 |
| P3-19 | replay_results defaults to empty map | TESTS.md #77 |
| P3-20 | worker_pid and workflow_module default to nil | TESTS.md #78 |
| P3-21 | randomness_seed defaults to nil | TESTS.md #79 |
| P3-22 | next_seq increments monotonically (bugfix) | TESTS.md #80 |
| P3-23 | flush_commands returns in correct order and clears (bugfix) | TESTS.md #81 |
| P3-24 | replaying? reflects context state (bugfix) | TESTS.md #82 |
| P3-25 | random is deterministic for same run_id and seq (bugfix) | TESTS.md #83 |
| P3-26 | uuid4 is deterministic for same run_id and seq (bugfix) | TESTS.md #84 |

New tests for v2 executor architecture:

| # | Test | What it verifies |
|---|------|-----------------|
| P3-27 | Executor starts under DynamicSupervisor | OTP integration |
| P3-28 | Executor state initializes correctly (all fields from E2) | Struct defaults |
| P3-29 | Runner exit `{:workflow_result, {:ok, result}}` → CompleteWorkflowExecution | Exit reason mapping (R1) |
| P3-30 | Runner exit `{:workflow_result, {:error, reason}}` → FailWorkflowExecution | Exit reason mapping (R1) |
| P3-31 | Runner exit `{:workflow_result, {:continue_as_new, args}}` → ContinueAsNewWorkflowExecution | Exit reason mapping (R1) |
| P3-32 | Runner crash (unexpected exit) → FailWorkflowExecution | Crash handling (R1) |
| P3-33 | Sequence number allocation is monotonic across calls | Executor seq counter (E4) |
| P3-34 | Replay log consumes head entry on match | RP1 head-match |
| P3-35 | Replay log mismatch → nondeterminism failure | RP2 enforcement |
| P3-36 | Commands accumulated and flushed in correct order | E5 command flushing |
| P3-37 | Runner process dictionary has `:__temporal_executor__` set | R2 protocol |

#### Phase 4: Server + Activities (S1, S2, A1, A2, A3)
Server dispatch, activity task flow, defactivity macro, activity context, cancellation. Full sequential workflows with activities work after this phase.

##### Verification (Phase 4) — 50 tests

From TESTS.md (v0.1 Server, Activity, DSL, Supervisor, Validation tests):

| # | Test | Source |
|---|------|--------|
| P4-1 | task_queue as child_spec ID | TESTS.md #129 |
| P4-2 | Shutdown timeout 35,000ms | TESTS.md #130 |
| P4-3 | Missing task_queue → ArgumentError | TESTS.md #131 |
| P4-4–9 | Activity compile-time (6 tests) | TESTS.md #93–98 |
| P4-10–19 | DSL/defactivity (10 tests) | TESTS.md #99–108 |
| P4-20–22 | DSL bugfixes (3 tests) | TESTS.md #109–111 |
| P4-23–27 | Supervisor structure & child specs (5 tests) | TESTS.md #183–187 |
| P4-28–37 | Validation — workflow/activity registration, config (10 tests) | TESTS.md #188–197 |
| P4-38–42 | Server race conditions (5 tests) | TESTS.md #237–241 |

New tests for v2 server model:

| # | Test | What it verifies |
|---|------|-----------------|
| P4-43 | Server receives `{:workflow_activation, bytes}`, decodes, forwards to executor | S1 dispatch |
| P4-44 | Server receives `{:activity_task, bytes}`, spawns via Task.Supervisor | S2 activity spawn |
| P4-45 | Activity completion encodes result, calls `complete_activity_task` NIF | S2 completion path |
| P4-46 | Activity failure encodes error, calls `complete_activity_task` NIF | S2 failure path |
| P4-47 | Activity cancellation sets atomics flag | A3 cancellation |
| P4-48 | `heartbeat(ctx, details)` returns `{:cancelled, reason}` after atomics flag set | A3 heartbeat cancel |
| P4-49 | Eviction activation stops and removes executor | S1 eviction handling |
| P4-50 | Server monitors executor, cleans up on DOWN | S1 executor lifecycle |

#### Phase 5: Workflow API (W1, W4, M1, D1)
Sequential primitives (sleep, wait_for_signal, side_effect, publish_state, patched?, cancelled?), child workflows, workflow module macro, ETF converter. Publishable sequential SDK after this phase.

##### Verification (Phase 5) — 165 tests

From TESTS.md (v0.1 pure-logic unit tests):

| # | Test | Source |
|---|------|--------|
| P5-1–25 | Converter (25 tests) | TESTS.md #1–25 |
| P5-26–33 | Codec (8 tests) | TESTS.md #26–33 |
| P5-34–55 | Error types & FailureConverter (22 tests) | TESTS.md #34–55 |
| P5-56–67 | RetryPolicy (12 tests) | TESTS.md #56–67 |
| P5-68–75 | Workflow behaviour (8 tests) | TESTS.md #85–92 |
| P5-76–83 | Workflow API (8 tests) | TESTS.md #112–119 |
| P5-84–99 | Features — continue_as_new, child_workflow, patched?, cancelled? (16 tests) | TESTS.md #132–147 |
| P5-100–104 | random/uuid4 (5 tests) | TESTS.md #148–152 |
| P5-105–111 | Bugfix verifications (7 tests) | TESTS.md #153–159 |
| P5-112–117 | Signal & cancel handling (6 tests) | TESTS.md #160–165 |
| P5-118–127 | Client — resolve_connection, validation, ID generation (10 tests) | TESTS.md #173–182 |
| P5-128–135 | Interceptor — chain, short-circuit, workflow/activity wrapping (8 tests) | TESTS.md #198–205 |
| P5-136–139 | Telemetry — workflow/activity events, activation, OTel setup (4 tests) | TESTS.md #221–224 |
| P5-140–151 | Ease of use — sleep validation, signals, child workflow stubs, from_payload! (12 tests) | TESTS.md #225–236 |

New tests for v2 API + programming model:

| # | Test | What it verifies |
|---|------|-----------------|
| P5-152 | `API.publish_state` makes state visible to queries | PM35 |
| P5-153 | `handle_query/3` reads published state | PM36 |
| P5-154 | `patched?` returns true on first execution | PM47 |
| P5-155 | `patched?` returns true on replay when marker exists | PM48 |
| P5-156 | `patched?` returns false on replay when no marker | PM49 |
| P5-157 | `API.sleep` emits StartTimer command, resumes on FireTimer | W1 |
| P5-158 | `API.wait_for_signal` blocks, returns on signal arrival | W1 |
| P5-159 | `API.wait_for_signal` returns immediately if signal already buffered | W1 |
| P5-160 | `API.side_effect` executes once, returns recorded value on replay | W1 |
| P5-161 | Child workflow command built and resolved correctly | W4 |
| P5-162 | ETF converter round-trips Elixir terms (atoms, tuples, structs, MapSets) | D1 |
| P5-163 | `use Temporalex.Workflow` generates `__temporal_workflow_type__/0` | M1 |
| P5-164 | `use Temporalex.Workflow` imports API module | M1 |
| P5-165 | `run/1` validation at compile time | M1 |

#### Phase 6: Direct Completions (N5, E4, E5)
Executor calls NIF directly. Sequence number allocation. Command flushing. Performance optimization.

##### Verification (Phase 6) — 4 tests

Integration tests for the direct-completion path:

| # | Test | What it verifies |
|---|------|-----------------|
| P6-1 | Executor calls `complete_workflow_activation` NIF directly (no Server round-trip) | N5 |
| P6-2 | Sequence numbers unique across runner + handler processes | E4 |
| P6-3 | Commands from multiple concurrent processes collected into single completion | E5 |
| P6-4 | WorkerResource `Arc<Worker>` allows concurrent NIF calls from multiple Elixir processes | N5 thread safety |

#### Phase 7: Structured Concurrency + Testing Framework (W2, W3, W5, W6, W7, T1–T10)
`API.receive` with sync handlers, then async handlers. `API.parallel`. `API.update_state`. The full programming model. Testing framework built alongside to verify it.

##### Verification (Phase 7) — 73 tests

Programming model tests (from TESTS.md Part 3):

| # | Test | Source |
|---|------|--------|
| P7-1–10 | API.receive (blocks, dispatches, timeout, stop, multi-message, no-match, nested-error, state, mixed handlers, async completion) | PM1–10 |
| P7-11–20 | Async handlers (spawn, return-as-reply, concurrent dispatch, update_state atomic, multi-concurrent, activities, parallel-in-async, nested-async-error, receive-in-async-error, drain-before-exit) | PM11–20 |
| P7-21–28 | API.parallel (executes all, ordered results, branch-fail-captured, activities-per-branch, nested, no-receive, no-async, empty-list) | PM21–28 |
| P7-29–34 | Updates (reply+state, validator-accept, validator-reject, reject-outside-receive, sync-completion, async-handler) | PM29–34 |
| P7-35–38 | Published state (persists across receives, independent from receive state) | PM37–38 |
| P7-39–41 | State model three-layer independence (local private, receive scoped, all three independent) | PM39–41 |
| P7-42–46 | Nesting rules enforcement (receive in run, parallel in run, async-in-run-error, receive-in-parallel-error, async-in-parallel-error) | PM42–46 |

Testing framework (from TODO.md T1–T10):

| # | Test | Source |
|---|------|--------|
| P7-47 | Test executor — same GenServer.call protocol as production | T1 |
| P7-48 | Incremental API — `start_workflow`, `next`, `resolve` | T2 |
| P7-49 | Signal and update delivery in test executor | T3 |
| P7-50 | Cancel in test executor | T4 |
| P7-51 | `run_workflow` convenience with pre-loaded operation log | T5 |
| P7-52 | Activity test context (basic, heartbeat, cancellation, overrides) | T6 |
| P7-53 | Testing `receive` blocks | T7 |
| P7-54 | Testing `parallel` | T8 |
| P7-55 | Testing async handlers | T9 |
| P7-56 | Testing queries via `publish_state` | T10 |

From TESTS.md (v0.1 testing utility tests):

| # | Test | Source |
|---|------|--------|
| P7-57–75 | Testing utilities — run_workflow, run_activity, workflow_context, stubs, assertions (19 tests) | TESTS.md #206–220 |

#### E2E Integration (after Phase 5+, requires Temporal dev server)

These tests run against a real Temporal server and validate full-stack behavior. Run incrementally as phases complete.

##### Verification (E2E) — 78 tests

From TESTS.md (v0.1 E2E tests, adapted for v2):

| # | Test | Source |
|---|------|--------|
| E2E-1–27 | Full stack E2E (pure workflow, activities, timers, signals, continue-as-new, client API, concurrent workflows, supervisor, timeout, retry, cancel, query, heartbeat, shutdown, ID reuse, fan-out, child workflow, saga, non-retryable) | TESTS.md #242–268 |

From TESTS.md Part 2 — E2E gaps (new tests):

| # | Test | Source |
|---|------|--------|
| E2E-28 | Workflow with complex args (nested maps, lists, nil) | E2 |
| E2E-29 | Workflow panic/unhandled exception returns failure | E4 |
| E2E-30 | Workflow execution timeout fires | E6 |
| E2E-31 | Workflow run timeout fires | E7 |
| E2E-32 | Start workflow with explicit ID | E10 |
| E2E-33 | Describe workflow (status, type) after start | E11 |
| E2E-34 | Workflow with empty args (nil input) | E12 |
| E2E-35 | Activity schedule-to-close timeout fires | E16 |
| E2E-36 | Activity schedule-to-start timeout fires | E17 |
| E2E-37 | Activity retry with custom backoff coefficient | E21 |
| E2E-38 | Activity heartbeat timeout detection | E23 |
| E2E-39 | Activity heartbeat preserves details across retries | E24 |
| E2E-40 | Local activity execution | E26 |
| E2E-41 | Local activity timeout | E27 |
| E2E-42 | Multiple sequential sleeps | E29 |
| E2E-43 | Sleep(0) or very short sleep | E30 |
| E2E-44 | Signal sent before workflow reaches wait_for_signal | E33 |
| E2E-45 | Multiple signals of different types | E34 |
| E2E-46 | Signal with complex payload | E35 |
| E2E-47 | Signal to completed workflow | E36 |
| E2E-48 | Query with arguments | E38 |
| E2E-49 | Query to unregistered handler name | E39 |
| E2E-50 | Query while workflow is processing | E40 |
| E2E-51 | Cancel workflow, workflow performs cleanup then exits | E44 |
| E2E-52 | Terminate workflow (hard kill) | E45 |
| E2E-53 | Cancel workflow waiting on signal | E46 |
| E2E-54 | Continue-as-new with different args | E48 |
| E2E-55 | Continue-as-new preserves task_queue | E49 |
| E2E-56 | Continue-as-new with override task_queue | E50 |
| E2E-57 | Child workflow fails, parent gets error | E52 |
| E2E-58 | Cancel parent, child also cancelled | E53 |
| E2E-59 | Parent sends signal to child | E54 |
| E2E-60 | Workflow with patched? takes new path | E55 |
| E2E-61 | Replay of pre-patch workflow takes old path | E56 |
| E2E-62 | deprecate_patch allows cleanup | E57 |
| E2E-63 | signal_workflow delivers to running workflow | E59 |
| E2E-64 | query_workflow returns handler result | E60 |
| E2E-65 | cancel_workflow stops running workflow | E61 |
| E2E-66 | terminate_workflow hard-kills | E62 |
| E2E-67 | get_result on already-completed workflow | E63 |
| E2E-68 | get_result with timeout | E64 |
| E2E-69 | Connection dies, server restarts and reconnects | E66 |
| E2E-70 | Server crash during workflow, workflow retried | E67 |
| E2E-71 | Shutdown with in-flight workflow completes cleanly | E69 |
| E2E-72 | Telemetry events fire for workflow start/stop (E2E) | E71 |
| E2E-73 | Telemetry events fire for activity start/stop (E2E) | E72 |
| E2E-74 | Logger metadata includes workflow_id, run_id | E73 |
| E2E-75 | Long-running workflow: sleep(days) + signal to wake | E75 |
| E2E-76 | Fan-out/fan-in with parallel | E76 |
| E2E-77 | Retry storm respects max_attempts | E77 |
| E2E-78 | DSL workflow runs end-to-end | E78 |

#### Unit Test Gaps (from TESTS.md Part 2, distributed across phases)

These fill coverage gaps identified in v0.1 cross-SDK comparison. Implement as you build each phase.

##### Phase 3 additions — 10 tests

| # | Test | Source |
|---|------|--------|
| UG-1 | Multiple activities chained (A -> B -> done) | U99 |
| UG-2–3 | Timer command + timer replay | U100–U101 |
| UG-4–5 | build_schedule_activity encodes timeouts + retry_policy | U102–U103 |
| UG-6–8 | build_complete/fail/continue_as_new | U104–U106 |
| UG-9 | ContinueAsNew exception caught, command built | U108 |
| UG-10 | Nondeterminism: child workflow where activity expected | U110 |

##### Phase 4 additions — 17 tests

| # | Test | Source |
|---|------|--------|
| UG-11–12 | build_activity_map (DSL + legacy) | U114–U115 |
| UG-13–22 | dispatch_activation, handle_queries, reject_updates, extract results | U117–U126 |
| UG-23–27 | defactivity option handling (timeouts, retry, task_queue) | U134–U138 |
| UG-28–31 | Activity.Context parsing, heartbeat encoding, dead worker | U151–U154 |

##### Phase 5 additions — 43 tests

| # | Test | Source |
|---|------|--------|
| UG-32 | Encode/decode float | U3 |
| UG-33 | Encode/decode boolean | U4 |
| UG-34 | Nested map (3 levels deep) | U6 |
| UG-35 | List of maps | U7 |
| UG-36–37 | Empty map/list | U8–U9 |
| UG-38 | Large payload (1MB+) | U10 |
| UG-39–40 | UTF-8 vs non-UTF-8 binary | U11–U12 |
| UG-41–43 | Unknown encoding, empty data, no metadata | U16–U18 |
| UG-44 | Mixed success/failure in from_payloads | U19 |
| UG-45 | Unicode round-trip (emoji, CJK) | U20 |
| UG-46 | TimeoutError all 4 timeout types | U22 |
| UG-47–48 | ApplicationError non_retryable + type flags | U25–U26 |
| UG-49 | Nondeterminism error encoding | U28 |
| UG-50 | Nested failure chain | U29 |
| UG-51 | Failure with nil/empty message | U32 |
| UG-52 | ActivityFailure with nil fields | U34 |
| UG-53 | ContinueAsNew preserves all fields | U37 |
| UG-54 | Errors implement Exception protocol (raise/rescue) | U40 |
| UG-55–56 | random different for different seq, boundary check | U55–U56 |
| UG-57–58 | uuid4 v4 format validation, different for different seq | U58–U59 |
| UG-59–61 | from_init parsing (all fields, missing parent, timestamp) | U60–U62 |
| UG-62 | execute_activity merges module defaults with call-site opts | U65 |
| UG-63 | execute_local_activity uses local flag | U67 |
| UG-64 | get_executor! raises with helpful message | U85 |
| UG-65–74 | Client: ID generation, encode_args, resolve_connection, decode_query | U158–U166 |

#### Cross-SDK Conformance (after Phase 7) — 33 tests

Must-pass core conformance from `temporalio/features` repo:

| # | Test | Source |
|---|------|--------|
| C1–4 | Activity basic, cancel, retry; Child workflow result | Core |
| C5–6 | Child workflow signal; Continue-as-new same type | Core |
| C7–11 | Data converter (binary, protobuf, json, empty, failure) | Core |
| C12–16 | Query (successful, timeout, bad args, bad type, bad return) | Core |
| C17–20 | Signal (basic, signal-with-start, external, activities in handler) | Core |
| C21–27 | Updates (basic, activities, async, dedup, reject, replay, restart) | Future |
| C28–32 | Schedules (basic, cron, pause, trigger, backfill) | Future |
| C33 | Telemetry metrics | Future |

#### Stress / Load (after Phase 7) — 8 tests

| # | Test | Notes |
|---|------|-------|
| S1 | 100 concurrent workflows | No resource leaks |
| S2 | 50 sequential activities | Long history |
| S3 | 10 workflows x 10 parallel activities | Fan-out pressure |
| S4 | 100 signals in 1 second | Mailbox pressure |
| S5 | 1MB payload round-trip | Serialization perf |
| S6 | 10 continue-as-new chains | CAN chain |
| S7 | Shutdown under 50 in-flight activities | Graceful drain |
| S8 | Connection drop + reconnect during workflow | Network resilience |

#### Test Count Summary

| Phase | Unit | E2E | Gap | Total |
|-------|------|-----|-----|-------|
| Phase 1: NIF Safety | 7 | — | — | 7 |
| Phase 2: NIF Infrastructure | 17 | — | — | 17 |
| Phase 3: Core Executor | 37 | — | 10 | 47 |
| Phase 4: Server + Activities | 50 | — | 17 | 67 |
| Phase 5: Workflow API | 165 | — | 43 | 208 |
| Phase 6: Direct Completions | 4 | — | — | 4 |
| Phase 7: Structured Concurrency + Testing | 73 | — | — | 73 |
| E2E Integration | — | 78 | — | 78 |
| Cross-SDK Conformance | — | 33 | — | 33 |
| Stress / Load | — | 8 | — | 8 |
| **Total** | **353** | **119** | **70** | **542** |

---

## v0.3 — Missing Features

Moved from the original v0.2 plan. These build on the v0.2 architecture.

### Features

| # | Item | Impact | Effort | Notes |
|---|------|--------|--------|-------|
| F1 | Signal-with-start — atomic start + signal in one client call | High | Small | New NIF + Client wrapper |
| F2 | Async activity completion — activity completes externally via token | High | Medium | New NIF + Activity.Context API |
| F3 | Workflow replayer — replay from JSON history without a server | High | Medium | New module, uses Core SDK replay |
| F4 | Schedules API — create, pause, trigger, backfill schedules | Medium | Medium | New NIFs + Client wrappers |
| F5 | Core SDK metrics bridge — expose Rust Prometheus metrics via :telemetry | Medium | Medium | Rust metric callback + Elixir bridge |

### Polish

| # | Item | Impact | Effort |
|---|------|--------|--------|
| P1 | Telemetry: add payload size measurements to workflow/activity events | Low | Small |
| P2 | `ApplicationError.type` empty string vs nil — normalize on encode/decode | Low | Small |
| P3 | Error types: add optional `stacktrace` field to ActivityFailure/ApplicationError | Medium | Small |
| P4 | FailureConverter: preserve `details` field on round-trip | Low | Small |

### Test Coverage

| # | Item | Status |
|---|------|--------|
| T15 | Start conformance suite against `temporalio/features` repo | TODO |

---

## Done (v0.1.0)

All completed during architecture review sessions:

### Bugs (11)
- [x] BUG-1: NIF send_and_clear silent failures (12 sites)
- [x] BUG-3: ChildWorkflowFailure missing from FailureConverter
- [x] BUG-4: NIF resource lifetime not enforced
- [x] BUG-5: defactivity silently drops multi-arg
- [x] BUG-6: OTel span lookup silent failure
- [x] FIX-1: side_effect/1 crashes executor
- [x] FIX-2: Activity cancel duplicate completion
- [x] FIX-3: completing_run_id global attribution
- [x] FIX-4: Telemetry duration always zero
- [x] FIX-5: connect_client DirtyCpu -> DirtyIo
- [x] FIX-6: Activity failures missing ApplicationFailureInfo (Temporal server rejects bare Failure protos)

### Reliability (5)
- [x] Poll failure exponential backoff with jitter
- [x] Config validation (max_concurrent, address format)
- [x] Async NIF timeouts on completions + client ops
- [x] shutdown_worker 30s timeout
- [x] Connection retry with backoff (3 attempts)

### Ease of Use (6)
- [x] sleep/1 docs, guards, :timer examples, max bound
- [x] Signal simulation in Testing (send_signal, :signals opt)
- [x] Child workflow stubs in Testing (stub_child_workflow, :child_workflows opt)
- [x] from_payload! includes encoding + data_bytes in errors
- [x] README updated with all undocumented features
- [x] random/0 and uuid4/0 exposed in Workflow.API

### Naming & Conventions (4)
- [x] max_concurrent_activities -> max_concurrent_activity_tasks
- [x] start_workflow vs execute_workflow documented
- [x] Removed unused _namespace param from connect_client NIF
- [x] Standardized NIF error format ({e} not {e:?})

### Features (5)
- [x] API key auth + custom headers on Connection
- [x] describe_workflow and list_workflows on Client
- [x] OpenTelemetry trace context propagation (inject/extract, typed span names, linking)
- [x] Payload Codec behaviour (encryption/compression)
- [x] Interceptor framework

### Tests (v0.1.0 additions)
- [x] T1-T6: Unit tests (RetryPolicy, Activity compile, Connection, Client, cancel race, completion attribution)
- [x] T7-T14: E2E tests (ID reuse, fan-out, child workflow, saga, retry exhausted, non-retryable, signal ordering, query after complete)
- [x] Child workflow dispatch fix (Server now handles resolve_child_workflow_execution)
- [x] 268 tests total (241 unit + 27 E2E), 0 failures

### Docs & Infra
- [x] README rewrite — billboard + checkout flow quickstart + badges
- [x] 16 guide pages (installation, workflows, activities, signals, timers, child workflows, errors, DSL, testing, observability, config, production, 4 recipes)
- [x] GitHub repo (cgreeno/temporalex)
- [x] CI workflow (lint + unit tests + E2E with Temporal dev server)
- [x] Hex release workflow (tag-triggered + manual dispatch)
- [x] GitHub issue templates (bug report, feature request)
