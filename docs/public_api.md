# Public API

This document captures the intended public Elixir API. The deterministic behavior behind these APIs is specified in [core.md](core.md) and [programming_model.md](programming_model.md).

## Workflow Definition

A workflow is a module that uses `Temporalex.Workflow` and defines `run/1`.

```elixir
defmodule MyApp.Workflows.Checkout do
  use Temporalex.Workflow

  def handle_query("status", _args, state), do: {:reply, state}

  def run(%{"order_id" => order_id}) do
    {:ok, charge_id} = MyApp.Activities.Payment.charge(%{order_id: order_id})
    {:ok, %{charge_id: charge_id}}
  end
end
```

`use Temporalex.Workflow` generates:

```elixir
__workflow_type__/0
__workflow_defaults__/0
```

`run/1` returns:

```elixir
{:ok, result}
{:error, reason}
{:cancelled, reason}
```

Use `API.continue_as_new!/2` to continue as new. It is a terminal operation and does not return to workflow code after the executor accepts it.

`handle_query/3` is optional. It receives query name, query args, and the last state published by `API.publish_state/1`.

## Activity Definition

Activities are the workflow boundary for external work. Activity modules use `Temporalex.Activity` and define activities with `defactivity`.

```elixir
defmodule MyApp.Activities.Payment do
  use Temporalex.Activity

  defactivity charge(input), timeout: 30_000 do
    PaymentService.charge(input)
  end
end
```

Each `defactivity` generates:

1. A dispatch function with the declared name, for workflow code.
2. A bang dispatch function named `<activity_name>!/N`, for workflow code that should unwrap success and raise failures or cancellation.
3. An implementation function named `__<activity_name>__/N`, for server-side activity execution.
4. Module metadata through `__temporal_activities__/0`.

The dispatch function reads `:__temporal_context__` and calls the executor:

```elixir
GenServer.call(executor, {:workflow_op, thread_id, op}, :infinity)
```

If no workflow context exists, the dispatch function raises with a clear error explaining that activities must be called from workflow code.

## Activity Type Strings

Activity type strings are derived from module and function name:

```elixir
"MyApp.Activities.Payment.charge"
```

This string is used in core commands, backend mapping, server dispatch, and eventually Temporal UI visibility.

## Activity Context

Activities that need metadata, heartbeats, or cancellation can accept a context as the first argument.

```elixir
defactivity process_file(ctx, path), timeout: 60_000, heartbeat_timeout: 10_000 do
  File.stream!(path)
  |> Stream.with_index()
  |> Enum.each(fn {line, i} ->
    process(line)

    case Temporalex.Activity.Context.heartbeat(ctx, %{progress: i}) do
      :ok -> :continue
      {:cancelled, reason} -> throw({:cancelled, reason})
    end
  end)

  {:ok, :done}
end
```

Context shape:

```elixir
%Temporalex.Activity.Context{
  activity_id: String.t(),
  activity_type: String.t(),
  task_token: binary(),
  workflow_id: String.t(),
  workflow_type: String.t(),
  workflow_namespace: String.t(),
  run_id: String.t(),
  task_queue: String.t(),
  attempt: non_neg_integer(),
  heartbeat_timeout: non_neg_integer() | nil,
  is_local: boolean(),
  worker: term(),
  cancelled: :atomics.ref()
}
```

The server builds this context from `%Temporalex.Core.ActivityTask{}`.

## Activity Return Values

Activity implementation functions return:

```elixir
{:ok, value}
{:error, reason}
```

Any other return value or unhandled exception is treated as an activity failure.

## Workflow API

Workflow code uses `Temporalex.Workflow.API` for workflow primitives:

```elixir
API.sleep(duration_ms)
API.sleep!(duration_ms)
API.wait_for_signal(name)
API.wait_for_signal!(name)
API.publish_state(state)
API.patched?(patch_id)
API.deprecate_patch(patch_id)
API.phase(initial_state, opts)
API.phase!(initial_state, opts)
API.parallel(funs)
API.parallel!(funs)
API.update_state(fun)
API.continue_as_new!(input, opts)
API.workflow_info()
API.cancelled?()
API.cancellation()
API.non_cancellable(fn -> ... end)
API.upsert_search_attributes(attrs)
API.now()
API.random()
API.uuid4()
```

`API.update_state/1` is only valid inside async phase handlers.

Workflow cancellation is cooperative. Non-bang cancellable primitives return cancellation as
`{:cancelled, %Temporalex.Failure.CancelledError{}}`; bang variants raise the same error. Cleanup
that must perform durable work after cancellation should be wrapped in `API.non_cancellable/1`.

The detailed semantics are in [programming_model.md](programming_model.md).

## Client API

The implemented client API uses a supervised `Temporalex.Client` process that owns the backend connection resources. Workers depend on an explicit client; client operations do not route through a worker.

```elixir
{:ok, _client} =
  Temporalex.Client.start_link(
    name: MyApp.TemporalClient,
    backend: Temporalex.Backend.TemporalCore,
    target: "http://127.0.0.1:7233",
    namespace: "default",
    task_queue: "orders"
  )

{:ok, handle} =
  Temporalex.Client.start_workflow(MyApp.TemporalClient, MyApp.Workflows.Checkout, %{order_id: 123},
    workflow_id: "order-123"
  )

{:ok, result} = Temporalex.Client.get_result(handle)
```

Workflow operations are available through handles or `{client, workflow_id}`:

```elixir
:ok = Temporalex.Client.signal_workflow(handle, "approve", [%{approved_by: "alice"}])
{:ok, reply} = Temporalex.Client.update_workflow(handle, "add_item", [%{sku: "ABC"}])
{:ok, state} = Temporalex.Client.query_workflow(handle, "status")
{:ok, description} = Temporalex.Client.describe_workflow(handle)

:ok = Temporalex.Client.cancel_workflow(handle, reason: "user requested")
:ok = Temporalex.Client.terminate_workflow(handle, reason: "manual override")

:ok = Temporalex.Client.signal_workflow(MyApp.TemporalClient, "order-123", "approve", [])
{:ok, state} = Temporalex.Client.query_workflow(MyApp.TemporalClient, "order-123", "status", [])
```

Start options accepted by the native backend include:

```elixir
workflow_id: "order-123",
task_queue: "orders",
headers: %{"trace_id" => trace_id},
search_attributes: %{"CustomKeywordField" => "checkout"},
workflow_execution_timeout: 86_400_000,
workflow_run_timeout: 3_600_000,
workflow_task_timeout: 10_000,
retry_policy: [
  initial_interval: 1_000,
  backoff_coefficient: 2.0,
  maximum_interval: 60_000,
  maximum_attempts: 3,
  non_retryable_error_types: ["ValidationError"]
],
id_reuse_policy: :reject_duplicate,
id_conflict_policy: :fail,
static_summary: "Checkout workflow"
```

Signal/update/query options accept `:headers`. Signal and cancel also accept `:request_id`;
update accepts `:update_id`. Query accepts `:reject_condition` or `:query_reject_condition`
with `:none`, `:not_open`, or `:not_completed_cleanly`.

Client operations return `{:ok, value}` or `:ok` on success and `{:error, error}` on failure.
Client errors are public exception structs, so future bang variants can raise the same values
that non-bang variants return.

Common client error structs:

| Type | Meaning |
|---|---|
| `Temporalex.WorkflowAlreadyStartedError` | Start conflicted with an existing workflow execution. |
| `Temporalex.WorkflowNotFoundError` | The target workflow execution was not found. |
| `Temporalex.WorkflowFailedError` | `get_result/2` observed a failed workflow. The Temporal failure tree is in `cause`. |
| `Temporalex.WorkflowCancelledError` | `get_result/2` observed a cancelled workflow. |
| `Temporalex.WorkflowTerminatedError` | `get_result/2` observed a terminated workflow. |
| `Temporalex.WorkflowTimedOutError` | `get_result/2` observed a timed-out workflow. |
| `Temporalex.QueryRejectedError` | Temporal rejected a query because of workflow execution status. |
| `Temporalex.UpdateFailedError` | An update completed or was rejected with a Temporal failure. The failure tree is in `cause`. |
| `Temporalex.ClientUnavailableError` | The client owner process was not available. |
| `Temporalex.TransportError` | Transport, payload conversion, option validation, backend, or RPC failure. |

## Workflow Testing

Most application workflow tests should use `Temporalex.Testing` rather than a
Temporal dev server. The testing helpers run workflow code through the real
Temporalex executor, expose emitted commands in deterministic order, and let the
test decide when activities and timers complete.

```elixir
import Temporalex.Testing

{:ok, run} = start_workflow(MyApp.Workflows.Checkout, %{order_id: "ord_123"})

charge =
  assert_next_activity(run,
    type: {MyApp.Activities.Payment, :charge},
    input: [%{order_id: "ord_123"}]
  )

complete_activity(run, charge, {:ok, %{charge_id: "ch_123"}})

assert_completed(run, :complete)
assert_replay(run)
```

Temporalex does not provide an ExUnit case-template macro. Users can import the
helpers directly or wrap them in their own case templates.

See [testing.md](testing.md) for the testing model.

## Retry Policy

```elixir
%Temporalex.RetryPolicy{
  max_attempts: 0,
  initial_interval: 1_000,
  backoff_coefficient: 2.0,
  maximum_interval: nil,
  non_retryable_error_types: []
}
```

`max_attempts: 0` means unlimited attempts.

## Error Structs

Temporal failure trees use `Temporalex.Failure.*` structs. These structs are encoded to and
decoded from Temporal `Failure` protos and may appear as the `cause` of client operation
errors.

| Type | Meaning |
|---|---|
| `Temporalex.Failure.ApplicationError` | Application-level failure, with `type`, `details`, `retryable?`, and optional `cause`. |
| `Temporalex.Failure.CancelledError` | Temporal cancellation failure with details. |
| `Temporalex.Failure.TimeoutError` | Temporal timeout failure with timeout type and heartbeat details. |
| `Temporalex.Failure.ActivityError` | Activity failure wrapper with activity metadata and nested cause. |
| `Temporalex.Failure.WorkflowExecutionError` | Child workflow failure wrapper with workflow metadata and nested cause. |
| `Temporalex.Failure.UnknownError` | Fallback for Temporal failure variants not yet modeled directly. |
| `Temporalex.Core.Nondeterminism` | Activation failure when workflow replay diverges from history. |

Workflow activation failures such as nondeterminism are not workflow failure results. They fail
the workflow task so Temporal can retry the task with the same history.
