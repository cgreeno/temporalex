# Server

The server is outside the deterministic core. It owns worker orchestration, backend state, executor registry, pending activations, and activity task supervision.

The server does not decide deterministic workflow behavior. That belongs to the core executor.

## Supervision Tree

Each user worker instance is a small supervision tree:

```elixir
MyApp.Temporal (Supervisor, strategy: :one_for_all)
├── MyApp.Temporal.Server
├── MyApp.Temporal.ExecutorSupervisor
└── MyApp.Temporal.ActivitySupervisor
```

`one_for_all` means that if the server dies, executor and activity supervisors are restarted with it. This keeps worker-local process state coherent after backend, client, or poller failures.

## Responsibilities

The server owns:

- backend worker startup and shutdown
- workflow and activity registration maps
- executor spawning and monitoring
- pending activation registry
- routing core activation jobs to executors
- receiving workflow completions from executors
- submitting completions through the backend
- activity task execution through `Task.Supervisor`
- worker-level failure handling

The server does not own:

- replay matching
- command sequencing
- signal/update state
- workflow deterministic scheduling
- workflow runner process dictionary

## Configuration

Worker configuration should include:

```elixir
{Temporalex.Worker,
  name: MyApp.Temporal,
  client: MyApp.TemporalClient,
  task_queue: "my-queue",
  workflows: [MyApp.Workflows.Checkout],
  activities: [MyApp.Activities.Payment],
  max_concurrent_workflow_tasks: 5,
  max_concurrent_activity_tasks: 5}
```

Workers never create an internal client. The user supervision tree should start a `Temporalex.Client` first, then one or more workers that depend on it. If the client exits, worker servers monitor it and stop instead of continuing with stale native handles.

## Registration

At init, the server builds:

```elixir
workflow_map = %{
  "MyApp.Workflows.Checkout" => {MyApp.Workflows.Checkout, &MyApp.Workflows.Checkout.run/1}
}

activity_map = %{
  "MyApp.Activities.Payment.charge" => {MyApp.Activities.Payment, :__charge__}
}
```

Activity modules expose registration data through `__temporal_activities__/0`.

Workflow modules expose type/default metadata through `use Temporalex.Workflow`.

## Workflow Activation Flow

1. Backend sends `{:workflow_activation, %Temporalex.Core.Activation{} = activation}`.
2. Server categorizes activation jobs.
3. Eviction jobs stop and remove affected executors.
4. Start jobs spawn a new executor under `ExecutorSupervisor`.
5. Server records the activation in `pending_activations` before routing work.
6. Resolution, signal, update, query, patch, and cancel jobs are routed to the executor for the activation run ID.
7. Executor eventually sends `{:workflow_activation_completion, run_id, completion}`.
8. Server validates the completion against `pending_activations`.
9. Server calls `backend.complete_workflow_activation(backend_state, completion)`.
10. Server clears the pending activation.

## Pending Activations

The pending activation registry prevents stale or duplicate completions:

```elixir
pending_activations: %{
  run_id => %{
    executor: pid(),
    is_replaying: boolean(),
    started_at: integer()
  }
}
```

Temporal Core does not expose an activation id. Its contract is one outstanding activation per run, keyed by `run_id`.

If an executor exits before returning a completion, the server removes the pending activation and submits an activation failure completion through the backend.

The backend or Temporal server may also time out a workflow task. The server should treat late completions as stale.

## Executor Monitoring

The server monitors every executor it starts:

```elixir
ref = Process.monitor(executor_pid)
```

On `{:DOWN, ref, :process, executor_pid, reason}`:

- remove the executor from the registry
- remove monitor mappings
- fail any pending activation owned by that executor
- let `DynamicSupervisor` handle process cleanup

The server does not link to executors. Executor crashes should not directly crash the server unless server policy decides the worker is unhealthy.

## Activity Task Flow

1. Backend sends `{:activity_task, %Temporalex.Core.ActivityTask{} = task}`.
2. Server looks up the activity type in `activity_map`.
3. Server builds an `Activity.Context` if the activity expects one.
4. Server starts work with `Task.Supervisor.async_nolink/3`.
5. Activity returns `{:ok, value}` or `{:error, reason}`.
6. Server converts exceptions and exits into activity failures.
7. Server builds `%Temporalex.Core.ActivityCompletion{}`.
8. Server calls `backend.complete_activity_task(backend_state, completion)`.

Activity cancellation is cooperative when the activity heartbeats. The server stores cancellation state in the activity context and sets it when a cancel task arrives.

## Failure Propagation

Server crash:

- supervision stops executor and activity supervisors
- backend worker state is dropped or shut down
- worker tree restarts cleanly

Executor crash:

- server monitor fires
- executor registry is cleaned
- pending activation is failed if needed

Runner crash:

- executor receives linked exit
- executor emits workflow failure completion
- server submits completion

Activity task crash:

- server receives task `DOWN`
- server encodes activity failure completion
- backend submits completion

Backend error:

- backend sends `{:backend_error, reason}` or returns `{:error, reason}`
- server policy decides whether to crash and restart the worker tree

## Shutdown

On worker shutdown:

1. stop accepting new backend work
2. ask backend to initiate worker shutdown
3. cancel in-flight activities
4. stop executors
5. drain backend worker if supported
6. return from server termination

## Implementation Status

The server layer is implemented with these modules:

- `Temporalex.Worker` starts the documented `:one_for_all` worker tree and requires an explicit `Temporalex.Client`.
- `Temporalex.Server` owns backend state, workflow/activity registration maps, executor monitors, pending activation tracking, activation routing, and activity task supervision.
- Executors are started under a `DynamicSupervisor` and activity tasks run under `Task.Supervisor`.
- Activity implementations are invoked through metadata generated by `use Temporalex.Activity`; activity context and cooperative heartbeat cancellation are available through `Temporalex.Activity.Context`.
- `Temporalex.Backend.Test` drives integration tests by sending core structs directly to the server and collecting submitted completions.

The implemented server remains backend-agnostic. It does not depend on Rustler, protobuf structs, Temporal Core worker handles, or Temporal server networking.
