# Native Backend

The native backend is the Rustler and Temporal Core implementation of `Temporalex.Backend`.

This is an outer layer. It should not be built before the core executor/runner protocol and replay tests are solid.

The worker-facing proto mapping is documented in [temporal_core_mapping.md](temporal_core_mapping.md).

## Resource Model

Three opaque resources cross the NIF boundary:

```rust
struct RuntimeResource {
    core: CoreRuntime,
}

struct ClientResource {
    connection: Connection,
    runtime_handle: tokio::runtime::Handle,
    _runtime: ResourceArc<RuntimeResource>,
}

struct WorkerResource {
    worker: Arc<Worker>,
    runtime_handle: tokio::runtime::Handle,
    _runtime: ResourceArc<RuntimeResource>,
}
```

`RuntimeResource` owns the Temporal Core runtime and its Tokio runtime.

`ClientResource` owns a Temporal client connection and keeps the runtime alive.

`WorkerResource` owns a Temporal Core worker and keeps the runtime alive. Poll loops and completion tasks share the worker through `Arc<Worker>`.

## Async NIF Pattern

Only `create_runtime/0` is synchronous. Other NIFs should return quickly and run async work on the Tokio runtime.

Pattern:

1. NIF receives arguments and target Elixir PID.
2. NIF spawns a Tokio task.
3. NIF returns `:ok`.
4. Tokio task sends a tagged message back to Elixir.

This keeps BEAM scheduler threads free.

## TaskGuard

Every spawned Tokio task should use a guard that sends exactly one result or failure message to Elixir.

If the task completes successfully, it consumes the guard and sends the success message. If the task panics or is cancelled before completion, the guard's `Drop` implementation sends an error message.

Poll loops use loop-specific exit messages:

```elixir
{:poll_loop_exited, :workflow, :shutdown | :crashed}
{:poll_loop_exited, :activity, :shutdown | :crashed}
```

Unexpected poll loop exit is fatal to the server.

## Poll Loops

The native backend starts long-lived Tokio poll loops:

- workflow poll loop calls `worker.poll_workflow_activation()`
- activity poll loop calls `worker.poll_activity_task()`

The Rust poll loops send raw Temporal Core protobuf bytes to the Elixir poller bridge. The bridge decodes them through `Temporalex.Backend.TemporalCore.Codec` and forwards core structs to the server:

```elixir
{:workflow_activation, %Temporalex.Core.Activation{}}
{:activity_task, %Temporalex.Core.ActivityTask{}}
```

The server should never call a per-poll NIF.

## Process Monitoring

`WorkerResource` monitors the owning server process. When the server dies, the Rustler resource monitor fires and schedules `worker.initiate_shutdown()` on the stored Tokio runtime handle. This matters because Temporal Core shutdown uses Tokio APIs internally and must not be called directly from a BEAM scheduler thread.

This handles cases where Elixir `terminate/2` is skipped, including `Process.exit(pid, :kill)`.

`WorkerResource::drop` also schedules `initiate_shutdown()` as a safety net.

## NIF Interface

The native functions are implementation details of `Temporalex.Backend.TemporalCore`.

Runtime:

```elixir
create_runtime() :: {:ok, runtime} | {:error, term()}
```

Connection:

```elixir
connect(runtime, url, api_key, headers, pid) :: :ok
# sends {:connected, client} | {:connect_error, reason}
```

Worker:

```elixir
start_worker(runtime, client, task_queue, namespace, max_wf, max_act, pid, poll_pid) :: :ok
# sends {:worker_started, worker} | {:worker_error, reason}
```

Completions:

```elixir
complete_workflow_activation(worker, bytes, pid) :: :ok
# sends {:workflow_completion, :ok | {:error, reason}}

complete_activity_task(worker, bytes, pid) :: :ok
# sends {:activity_completion, :ok | {:error, reason}}
```

Heartbeat:

```elixir
record_activity_heartbeat(worker, heartbeat_bytes) :: :ok
```

Shutdown:

```elixir
initiate_shutdown(worker) :: :ok
shutdown_worker(worker, pid) :: :ok
# sends {:shutdown_complete, :ok | {:error, reason}}
```

Client operations:

```elixir
start_workflow(client, namespace, workflow_id, workflow_type, task_queue, input, opts, pid, ref) :: :ok
# sends {:workflow_started, ref, {:ok, info} | {:error, reason}}

get_workflow_result(client, namespace, workflow_id, run_id, pid, ref) :: :ok
# sends {:workflow_result, ref, {:ok, result} | {:error, reason}}

signal_workflow(client, namespace, workflow_id, run_id, signal_name, args, opts, pid, ref) :: :ok
# sends {:workflow_signalled, ref, {:ok, :ok} | {:error, reason}}

query_workflow(client, namespace, workflow_id, run_id, query_name, args, opts, pid, ref) :: :ok
# sends {:workflow_queried, ref, {:ok, result} | {:error, reason}}

update_workflow(client, namespace, workflow_id, run_id, update_name, args, opts, pid, ref) :: :ok
# sends {:workflow_updated, ref, {:ok, result} | {:error, reason}}

cancel_workflow(client, namespace, workflow_id, run_id, reason, request_id, pid, ref) :: :ok
# sends {:workflow_cancelled, ref, {:ok, :ok} | {:error, reason}}

terminate_workflow(client, namespace, workflow_id, run_id, reason, details, pid, ref) :: :ok
# sends {:workflow_terminated, ref, {:ok, :ok} | {:error, reason}}

describe_workflow(client, namespace, workflow_id, run_id, pid, ref) :: :ok
# sends {:workflow_described, ref, {:ok, description} | {:error, reason}}
```

Immediate validation failures send through the NIF caller environment. Tokio tasks use `OwnedEnv::send_and_clear`; managed NIF threads must not.

## Payload Conversion

The native backend uses ETF payloads:

```elixir
:erlang.term_to_binary(term)
:erlang.binary_to_term(binary)
```

No `[:safe]` option is used in v1. No pluggable converter layer exists in v1.

## Codec Placement

Temporal Core worker protobuf conversion lives inside the real backend, on the Elixir side:

```elixir
Temporalex.Backend.TemporalCore.Codec
Temporalex.Backend.TemporalCore.PayloadConverter
Temporalex.Backend.TemporalCore.Proto.Schema
```

These modules translate:

```text
Temporal Core protobuf bytes -> Temporalex.Core structs
Temporalex.Core completions -> Temporal Core protobuf bytes
```

The Rust NIF still decodes completion and heartbeat bytes into Temporal Core SDK structs at the final call boundary because the core crate APIs accept typed Rust values, not opaque bytes. It should not own the Elixir core-struct mapping.

The core and server should not depend on protobuf modules directly.
