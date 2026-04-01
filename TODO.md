# Temporalex — Roadmap

Everything that needs to happen after v0.1.0.

## v0.2 — Architecture Rewrite

Full spec: [SDK specification](https://gist.github.com/hansihe/2dc9caea2b193086532f183b12330793).

Goal: production-grade NIF lifecycle, executor-owns-activation model, push-based poll loops, and a step-by-step test API.

### Design Principles

1. **The executor is the only coordination point.** All workflow runtime state lives in the executor GenServer. The runner process holds exactly one process dictionary key: the executor PID. Everything else is a `GenServer.call` or an exit reason.
2. **Activities are activities.** Whether you define one per module or ten per module, the compiled output is the same: a dispatch function that calls into the executor, and an implementation function that holds the business logic.
3. **OTP conventions over custom protocols.** Process linking for lifecycle, exit reasons for termination semantics, telemetry for observability, supervision for fault tolerance.
4. **No test infrastructure in production code paths.** Testing is achieved by substituting the executor, not by sprinkling stubs into the runtime dispatch.
5. **The Tokio runtime is the owner of all async work, Elixir processes are notified via messages.** NIF functions never block schedulers for extended periods.

### NIF Layer Rewrite

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
- Server treats unexpected poll loop exit as fatal → crashes → supervisor restarts

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

This is enabled by the executor-owns-activation model (see R6 below). Since the executor handles the entire activation — including queries — there are no "inline commands" that need merging. One process, one completion.

The `WorkerResource` is `Arc<Worker>` in Rust — multiple Elixir processes can hold handles and call NIFs concurrently. The Core SDK handles internal synchronization.

**Impact:** High. **Effort:** Medium.

### NIF Interface

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

### Supervision Tree

#### Temporalex OTP Application (library, auto-starts)

```
Temporalex.Supervisor
└── Temporalex.Runtime (GenServer)
      Owns: RuntimeResource (NIF handle to CoreRuntime + Tokio runtime)
      No user configuration required
```

#### User Application (one per task queue)

```
MyApp.Temporal (Supervisor, strategy: :rest_for_one)
├── MyApp.Temporal.Server (GenServer)
│     On init: obtains RuntimeResource, connects via NIF, creates worker via NIF
│     Owns: ClientResource, WorkerResource
│     Receives: {:workflow_activation, bytes}, {:activity_task, bytes}
│     Pure dispatch — forwards activations to executors, spawns activity tasks
│
├── MyApp.Temporal.ExecutorSupervisor (DynamicSupervisor)
│     Executors receive WorkerResource handle at spawn time
│     Call completion NIFs directly — no round-trip through Server
│
└── MyApp.Temporal.ActivitySupervisor (Task.Supervisor)
```

`rest_for_one` ensures Server death restarts executor and activity supervisors. Runtime is separate and unaffected.

### Elixir Runtime Changes

#### R1: Executor under DynamicSupervisor

Executors are children of `ExecutorSupervisor` (DynamicSupervisor). Server monitors each executor via `Process.monitor/1`. When an executor crashes, Server receives `{:DOWN, ...}`, cleans up registry, fails pending activation.

**Impact:** High. **Effort:** Medium.

#### R2: Runner exit reasons for termination semantics

Runner communicates outcome to executor through exit reasons (caught by `handle_info({:DOWN, ...})`):

| Exit reason | Executor action |
|---|---|
| `{:workflow_result, {:ok, result}}` | Build `CompleteWorkflowExecution` command |
| `{:workflow_result, {:error, reason}}` | Build `FailWorkflowExecution` command |
| `{:continue_as_new, args, opts}` | Build `ContinueAsNewWorkflowExecution` command |
| `:normal` | Runner yielded (blocked on activity/timer/signal) |
| Other (crash) | Build `FailWorkflowExecution` with crash message |

Runner process dictionary contains exactly one key: `Process.put(:__temporal_executor__, executor_pid)`.

**Impact:** Medium. **Effort:** Small.

#### R3: Atomics for activity cancellation

Activity context contains an `:atomics` ref. Server sets the flag when a Cancel task arrives. Activity checks it at each `heartbeat/2` call — zero overhead when not cancelled.

Cancellation flow:
1. Activity calls `heartbeat(ctx, details)` — sends details to NIF, returns immediately
2. Core SDK sends heartbeat to Temporal server. If server responds with cancel, Core SDK queues a cancel.
3. Next `poll_activity_task()` returns `ActivityTask` Cancel variant
4. Server sets the `:atomics` flag on the activity's context
5. Next `heartbeat/2` checks flag, returns `{:cancelled, reason}` instead of `:ok`

Activities that don't heartbeat: cancelled via `Process.exit(pid, :shutdown)`.

**Impact:** Medium. **Effort:** Small.

#### R4: Activity context with WorkerResource handle

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

#### R5: Replay log as ordered list

The replay log is a list (not a map), ordered by sequence. When the runner makes a call:

- Head matches operation type → reply immediately with recorded result (replay)
- Head doesn't match → nondeterminism error, fail workflow
- List empty → first execution, schedule command, block runner

This is the key architectural change that enables the executor-owns-activation model. With a list, the executor processes the entire activation in strict order. No partial replay, no split between Server and executor.

**Impact:** Medium. **Effort:** Small.

#### R6: Executor owns entire activation (queries, signals, everything)

The Server becomes pure dispatch. The executor handles ALL job types from an activation:

```elixir
# Server — just dispatch:
def handle_info({:workflow_activation, bytes}, state) do
  activation = decode(bytes)
  executor = get_or_spawn_executor(activation.run_id, state)
  send(executor, {:activation, activation})
end

# Executor — owns everything:
def handle_info({:activation, activation}, state) do
  jobs = categorize_jobs(activation.jobs)
  state = apply_resolutions(jobs, state)
  state = buffer_signals(jobs.signals, state)
  query_cmds = handle_queries(jobs.queries, state)  # executor is free while runner blocks
  state = %{state | commands: query_cmds ++ state.commands}
  state = maybe_start_or_resume_runner(jobs, state)
  state
end
```

This eliminates `inline_commands`, `pending_activations`, and the command-merge bookkeeping. One process generates all commands, encodes protobuf, calls NIF. No stitching.

Why queries work: the runner blocks on `GenServer.call(executor, ...)`. The executor returns `{:noreply, state}` and goes back to its message loop. The **runner** is blocked, the **executor** is free to handle queries immediately.

**Impact:** High. **Effort:** Medium.

### Activity Definition

`defactivity` generates two functions per activity:

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

### Server

Responsibilities after rewrite:

1. **Activation dispatch**: receives activations from NIF poll loops, forwards entire activation to executor
2. **Activity execution**: spawns activity tasks via `Task.Supervisor`, tracks by task token
3. **Activity completion**: encodes activity results as protobuf, sends to NIF
4. **Executor lifecycle**: spawns (via DynamicSupervisor), monitors, tracks, cleans up

The Server does NOT:
- Call poll NIFs (push-based)
- Build workflow completions (executor does this directly)
- Handle queries (executor does this)
- Merge inline_commands (no longer exists)

#### Workflow activation flow

1. NIF poll loop sends `{:workflow_activation, bytes}` to Server
2. Server decodes, identifies `run_id`
3. For evictions: stop and remove executor
4. For everything else: forward entire activation to executor
5. Executor handles all job types, calls NIF directly for completion

#### Activity task flow

1. NIF poll loop sends `{:activity_task, bytes}` to Server
2. **Start variant**: Server looks up activity, creates `Activity.Context` (with WorkerResource handle + `:atomics` ref), spawns via `Task.Supervisor.async_nolink/3`
3. Activity returns `{:ok, value}` or `{:error, reason}`
4. Server encodes result, calls `complete_activity_task` NIF
5. **Cancel variant**: Server sets `:atomics` flag on context. For non-heartbeating activities, falls back to `Process.exit(pid, :shutdown)`

### Executor (WorkflowTaskExecutor)

#### State

```elixir
%WorkflowTaskExecutor{
  server_pid: pid(),
  worker: reference(),               # NIF WorkerResource for direct completion
  runner_pid: pid() | nil,
  monitor_ref: reference() | nil,
  run_id: String.t(),
  task_queue: String.t(),
  run_fn: (term() -> term()),
  workflow_info: map(),
  workflow_state: term(),
  pending_calls: %{seq => GenServer.from()},
  replay_log: [{:activity, result} | {:timer, :ok} | ...],   # ordered list, not map
  signal_buffer: [{name, payload}],
  signal_waiters: %{name => GenServer.from()},
  patches: MapSet.t(),
  cancelled: boolean(),
  seq: non_neg_integer(),
  commands: [command],
  status: :idle | :running | :yielded | :done
}
```

#### Signal handling

- **Signal arrives**: add `{name, payload}` to `signal_buffer`, check `signal_waiters` — if match, reply immediately
- **`wait_for_signal(name)` called**: check `signal_buffer` for match — if found, pop and reply. Otherwise add to `signal_waiters`, runner blocks

No raw `receive` loops. No process dictionary buffering. Executor owns all signal state.

#### Command flushing

Executor accumulates commands in a list (prepended). On yield/done: reverse, encode as protobuf `WorkflowActivationCompletion`, call `complete_workflow_activation(worker, bytes, self())` directly.

### Data Conversion

ETF-based serialization as default. `application/x-erlang-etf` encoding via `:erlang.term_to_binary/1`.

Preserves full Elixir term fidelity (atoms, tuples, structs, MapSets). Faster than JSON. Payloads appear as opaque binaries in Temporal UI — codec server can be added for readability.

JSON converter kept as fallback for cross-language interop.

### Error Types

| Type | Meaning | Key fields |
|---|---|---|
| `ActivityFailure` | Activity returned `{:error, _}` or crashed | `activity_type`, `cause` |
| `ChildWorkflowFailure` | Child workflow failed | `workflow_type`, `workflow_id`, `cause` |
| `ApplicationError` | Application-level, optionally non-retryable | `type`, `non_retryable` |
| `TimeoutError` | Timeout exceeded | `timeout_type` |
| `CancelledError` | Workflow or activity cancelled | `details` |
| `Nondeterminism` | Replay divergence detected | `message` |

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

### Testing Rewrite

#### T1: Test executor — same GenServer.call protocol as production

`Temporalex.Testing.WorkflowExecutor` is a GenServer implementing the same protocol as the production executor. Runner process has `:__temporal_executor__` set to the test executor — it can't tell the difference.

Operates in step-by-step mode. When the workflow calls any blocking API, the runner blocks and the test executor reports what it's waiting for.

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

`next/1` returns: `{:activity, %{type, input, opts}}`, `{:child_workflow, %{...}}`, `{:sleep, duration}`, `{:signal, name}`, `{:ok, result}`, or `{:error, reason}`.

`resolve/2` provides the result and advances to the next blocking point or completion.

#### T3: Signal delivery — `send_signal/3`

```elixir
assert {:signal, "approval"} = Temporalex.Testing.next(exec)
assert {:activity, call} = Temporalex.Testing.send_signal(exec, "approval", %{approved: true})
```

If workflow is waiting for this signal, unblocks. Otherwise buffered for future `wait_for_signal`.

#### T4: Cancel — `cancel/1`

```elixir
Temporalex.Testing.cancel(exec)
# Next cancelled?() call returns true
```

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

### Ownership & Monitoring

Every component has a clear owner. Every failure has a defined propagation path. **No failure is silent.**

| Component | Owner | Mechanism |
|---|---|---|
| RuntimeResource | `Temporalex.Runtime` process | Process state; dropped on process death |
| ClientResource | Server process | Process state; dropped on process death |
| WorkerResource | Server process | Monitors Server via `down/3` |
| Workflow poll loop | Tokio runtime | TaskGuard → Server PID |
| Activity poll loop | Tokio runtime | TaskGuard → Server PID |
| Completion tasks | Tokio runtime (one-shot) | TaskGuard → caller PID |
| Server | User supervisor | OTP child, `rest_for_one` |
| Executor | ExecutorSupervisor (DynamicSupervisor) | OTP child; Server monitors each executor |
| Runner | Executor process | `spawn_link`; exits propagate to executor |
| Activity task | ActivitySupervisor (Task.Supervisor) | `async_nolink`; Server monitors task ref |

| Watcher | Watched | Mechanism | On death |
|---|---|---|---|
| WorkerResource | Server PID | Rustler resource monitor (`down/3`) | `initiate_shutdown()` → poll loops exit |
| Server | Each Executor | `Process.monitor/1` | Clean registry, fail pending activation |
| Executor | Runner | `spawn_link` | `handle_info({:DOWN, ...})` → build completion command |
| Server | Activity tasks | `Task.Supervisor.async_nolink` | `handle_info({:DOWN, ref, ...})` → encode failure result |
| Tokio TaskGuard | (self) | `Drop` impl | Send error message to target PID |
| OTP Supervisor | Server | OTP supervision (`rest_for_one`) | Restart Server + supervisors |

### Failure Propagation Scenarios

**Server crashes:** Server dies → `rest_for_one` kills ExecutorSupervisor + ActivitySupervisor → WorkerResource monitor fires `down/3` → `initiate_shutdown()` → poll loops exit → supervisor restarts Server → reconnect → new worker → new polls. Clean cascade.

**Poll loop crashes:** TaskGuard Drop sends `{:poll_loop_exited, :crashed}` to Server → Server crashes itself → cascades as above. Clean cascade.

**Executor crashes:** DynamicSupervisor handles it → runner is linked, dies too → Server receives `{:DOWN, ...}` → removes executor from registry → sends failure completion. Clean cascade.

**Runner crashes:** Linked to executor → executor receives `{:DOWN, ...}` → builds `FailWorkflowExecution` from crash reason → sends completion to NIF directly. Clean cascade.

**Activity task crashes:** `async_nolink` → Server receives `{:DOWN, ...}` → encodes failure as `ActivityExecutionResult` → sends completion to NIF. Clean cascade.

**Completion Tokio task panics:** TaskGuard Drop sends error to caller PID → caller handles error. Clean via TaskGuard.

**Runtime process crashes:** RuntimeResource dropped → Tokio runtime drops → all tasks cancelled → TaskGuards fire → Servers crash → supervisors restart → `Temporalex.Runtime.get()` returns new runtime. Clean cascade.

### Implementation Order

1. **N1 + N2** — TaskGuard + resource monitors (independent, immediate safety win)
2. **N4** — Singleton runtime (prerequisite for N3)
3. **N3** — Push-based poll loops (biggest NIF change)
4. **R5 + R6** — List-based replay log + executor-owns-activation (Elixir-only, can prototype first)
5. **N5 + R1** — Direct executor completions + DynamicSupervisor
6. **R2-R4** — Runner exit reasons, atomics cancellation, activity context (incremental)
7. **D1** — ETF converter
8. **T1-T6** — Testing rewrite (can develop in parallel with NIF work)

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
| P5 | Consolidate `bugfix_test.exs` into relevant test files | Low | Small |

### Test Coverage

| # | Item | Status |
|---|------|--------|
| T15 | Start conformance suite against `temporalio/features` repo | TODO |

See [test_cases.md](test_cases.md) for the full cross-SDK gap analysis (22 gaps in existing features, 20 gaps in future features).

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
