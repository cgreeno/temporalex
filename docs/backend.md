# Backend Boundary

The backend boundary is the interface between Temporalex and an external workflow backend.

For v1, the backend behaviour combines client transport, worker transport, and protocol translation. This keeps the server tests durable: tests can use a backend that sends core structs directly, while the real backend can use Rustler, Temporal Core, protobuf, and ETF payload conversion internally.

The detailed Temporal Core mapping is documented in [temporal_core_mapping.md](temporal_core_mapping.md).

## Design Rule

The server talks in core structs. It does not know about protobuf bytes, Rustler resources, Temporal Core worker objects, or network protocol details.

The backend owns those details.

## Behaviour Shape

The exact callback names may evolve during implementation, but the contract should look like this:

```elixir
defmodule Temporalex.Backend do
  @type client_state :: term()
  @type worker_state :: term()

  @callback start_client(opts :: keyword(), owner_pid :: pid()) ::
              {:ok, client_state()} | {:error, term()}

  @callback shutdown_client(client_state()) ::
              :ok | {:error, term()}

  @callback start_worker(client_state(), opts :: keyword(), owner_pid :: pid()) ::
              {:ok, worker_state()} | {:error, term()}

  @callback start_workflow(client_state(), workflow_type :: binary(), input :: term(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback get_workflow_result(client_state(), workflow_id :: binary(), run_id :: binary() | nil, opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback signal_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              signal_name :: binary(),
              args :: list(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @callback query_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              query_name :: binary(),
              args :: list(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @callback update_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              update_name :: binary(),
              args :: list(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @callback cancel_workflow(client_state(), workflow_id :: binary(), run_id :: binary() | nil, opts :: keyword()) ::
              :ok | {:error, term()}

  @callback terminate_workflow(client_state(), workflow_id :: binary(), run_id :: binary() | nil, opts :: keyword()) ::
              :ok | {:error, term()}

  @callback describe_workflow(client_state(), workflow_id :: binary(), run_id :: binary() | nil, opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback complete_workflow_activation(
              worker_state(),
              Temporalex.Core.Completion.t()
            ) :: :ok | {:error, term()}

  @callback complete_activity_task(
              worker_state(),
              Temporalex.Core.ActivityCompletion.t()
            ) :: :ok | {:error, term()}

  @callback record_activity_heartbeat(
              worker_state(),
              task_token :: binary(),
              details :: term()
            ) :: :ok | {:error, term()}

  @callback shutdown_worker(worker_state()) ::
              :ok | {:error, term()}
end
```

`Temporalex.Client` owns `client_state`. Workers require an explicit client, resolve that state once at startup, and hold a backend worker state derived from it. Client operations use the client state directly; they do not route through a worker.

## Backend Messages

The backend sends already-decoded core structs to the server:

```elixir
send(owner_pid, {:workflow_activation, %Temporalex.Core.Activation{}})
send(owner_pid, {:activity_task, %Temporalex.Core.ActivityTask{}})
send(owner_pid, {:backend_error, reason})
send(owner_pid, {:backend_worker_shutdown, reason})
```

If a real backend internally receives protobuf bytes, it decodes them before sending messages to the server.

## Completion Submission

The executor builds workflow completions, but the server submits them:

```elixir
{:workflow_activation_completion, run_id, %Temporalex.Core.Completion{}}
```

The server validates the completion against its pending activation registry and calls:

```elixir
backend.complete_workflow_activation(backend_state, completion)
```

Workflow completions are status-bearing. The backend maps `{:ok, commands}` to Temporal Core's successful activation completion and `{:failed, reason, opts}` to Temporal Core's activation failure completion.

For activity tasks, the server runs the activity and builds `%Temporalex.Core.ActivityCompletion{}` before calling:

```elixir
backend.complete_activity_task(backend_state, completion)
```

## Test Backend

`Temporalex.Backend.Test` should be able to drive server integration tests without Temporal.

It can:

- start with plain Elixir state
- send `%Temporalex.Core.Activation{}` messages directly to the server
- collect completions for assertions
- simulate backend errors and worker shutdown
- avoid all bytes and NIF calls

Example test shape:

```elixir
{:ok, _client} =
  start_supervised({Temporalex.Client,
    name: MyApp.TemporalClient,
    backend: Temporalex.Backend.Test
  })

{:ok, worker} =
  start_supervised({Temporalex.Worker,
    name: MyApp.Temporal,
    client: MyApp.TemporalClient,
    workflows: [MyWorkflow],
    activities: []
  })

Backend.Test.send_activation(worker, %Core.Activation{...})

assert %Core.Completion{} =
  Backend.Test.fetch_workflow_completion(worker, run_id)
```

These tests should remain valid when `Temporalex.Backend.TemporalCore` exists.

Implementation status:

- `Temporalex.Backend` is implemented as the server-facing behaviour.
- `Temporalex.Backend.Test` is implemented and stores workflow/activity completions in memory for assertions.
- `Temporalex.Backend.TemporalCore` is implemented through Rustler and Temporal Core.
- `test/temporalex/backend_conformance_test.exs` exercises the backend contract against the test backend and verifies Temporal Core codec encoding for core completions.
- `test/temporalex/integration/temporal_core_integration_test.exs` exercises the real backend against a Temporal dev server.
- `test/temporalex/integration/temporal_worker_restart_test.exs` exercises worker restart and real-history replay against a Temporal dev server.

## Temporal Core Backend

`Temporalex.Backend.TemporalCore` implements the same behaviour using the real native layer.

Responsibilities:

- create the native runtime resource
- connect to Temporal
- start a Temporal Core worker
- run native poll loops
- decode workflow activation protobuf bytes into `%Temporalex.Core.Activation{}`
- decode activity task protobuf bytes into `%Temporalex.Core.ActivityTask{}`
- encode `%Temporalex.Core.Completion{}` into workflow activation completion bytes
- encode `%Temporalex.Core.ActivityCompletion{}` into activity completion bytes
- submit completions through Rustler NIFs
- submit activity heartbeats through Rustler NIFs
- shut workers down from explicit terminate paths, resource monitor `DOWN`, and resource drop
- convert payloads with `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1`

The codec modules live under the real backend:

```elixir
Temporalex.Backend.TemporalCore.Codec
Temporalex.Backend.TemporalCore.PayloadConverter
Temporalex.Backend.TemporalCore.Proto.Schema
```

Those modules can have direct unit tests with protobuf fixtures, but they are not the main server boundary.

## Boundary Checks

Backend implementations must not leak backend-specific structs past the boundary.

Allowed server-facing data:

- `%Temporalex.Core.Activation{}`
- `%Temporalex.Core.ActivityTask{}`
- `%Temporalex.Core.Completion{}`
- `%Temporalex.Core.ActivityCompletion{}`
- plain error terms

Not allowed past the boundary:

- protobuf structs
- raw activation bytes
- Rustler resources
- Temporal Core worker/client handles
- task tokens except as fields of core activity structs where activity semantics require them

## Failure Semantics

Backend failures should become server messages or callback errors.

Examples:

- poll loop crash sends `{:backend_error, reason}`
- completion submission failure returns `{:error, reason}` or sends a tagged completion result
- worker shutdown sends `{:backend_worker_shutdown, reason}`

The server decides whether a backend error is fatal to the worker tree.
