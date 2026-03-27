# Signals and Queries

Workflows aren't black boxes. You can send data into them (signals) and read their state (queries) while they're running.

## Signals

A signal is a one-way async message to a running workflow. The workflow receives it and can act on it.

### Waiting for a Signal

```elixir
defmodule MyApp.Workflows.Approval do
  use Temporalex.Workflow

  def run(%{"request_id" => request_id}) do
    set_state(%{status: "waiting_for_approval"})

    {:ok, decision} = wait_for_signal("approve")

    set_state(%{status: "approved", approved_by: decision["by"]})
    {:ok, %{approved_by: decision["by"]}}
  end
end
```

`wait_for_signal/1` blocks the workflow until a signal with that name arrives. The workflow is durable — it can wait for hours, days, or weeks.

### Sending a Signal

From anywhere in your app:

```elixir
conn = Temporalex.connection_name(MyApp.Temporal)

Temporalex.Client.signal_workflow(
  conn,
  "approval-req-42",
  "approve",
  %{by: "manager@company.com"}
)
```

The signal is delivered to the workflow. `wait_for_signal("approve")` unblocks and returns `{:ok, %{by: "manager@company.com"}}`.

### Multiple Signals

Signals are buffered. If a signal arrives before the workflow reaches `wait_for_signal`, it's queued and delivered immediately when the workflow is ready.

```elixir
def run(_args) do
  {:ok, step1} = wait_for_signal("step1_complete")
  {:ok, step2} = wait_for_signal("step2_complete")
  {:ok, %{step1: step1, step2: step2}}
end
```

Different signal types are independent. Signals meant for `"step2_complete"` won't be consumed by `wait_for_signal("step1_complete")`.

## Queries

A query reads the workflow's current state without mutating it. Queries are synchronous — they return a value immediately.

### Handling Queries

Implement `handle_query/3` in your workflow:

```elixir
defmodule MyApp.Workflows.OrderProcessor do
  use Temporalex.Workflow

  def run(%{"order_id" => order_id}) do
    set_state(%{status: "charging", order_id: order_id})
    {:ok, _} = execute_activity(ChargePayment, %{order_id: order_id})

    set_state(%{status: "shipping"})
    {:ok, _} = execute_activity(ShipOrder, %{order_id: order_id})

    set_state(%{status: "complete"})
    {:ok, "done"}
  end

  @impl Temporalex.Workflow
  def handle_query("status", _args, state) do
    {:reply, state}
  end

  @impl Temporalex.Workflow
  def handle_query("order_id", _args, state) do
    {:reply, state[:order_id]}
  end
end
```

`handle_query/3` receives:
1. The query name (string)
2. Optional arguments from the caller
3. The current workflow state (set via `set_state/1`)

Return `{:reply, result}` — the result is sent back to the caller.

### Sending a Query

```elixir
{:ok, status} = Temporalex.Client.query_workflow(conn, "order-42", "status")
# => {:ok, %{status: "shipping", order_id: "order-42"}}
```

If no `handle_query/3` is defined, queries return the raw workflow state.

## Signals vs Queries

| | Signals | Queries |
|---|---------|---------|
| Direction | Into the workflow | Out of the workflow |
| Mutating? | Yes — workflow can change state | No — read-only |
| Blocking? | Workflow can block on them | Returns immediately |
| Async? | Yes — fire and forget | No — synchronous RPC |

## What's Next

Learn about [durable timers and continue-as-new](timers_and_scheduling.md).
