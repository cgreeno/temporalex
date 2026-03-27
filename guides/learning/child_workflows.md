# Child Workflows

Child workflows let you compose complex business processes from smaller, reusable pieces. A parent workflow starts a child, waits for its result, and handles its failure.

## Starting a Child Workflow

```elixir
defmodule MyApp.Workflows.ProcessOrder do
  use Temporalex.Workflow

  def run(%{"order_id" => order_id}) do
    {:ok, payment} = execute_child_workflow(
      MyApp.Workflows.ChargePayment,
      %{order_id: order_id},
      id: "payment-#{order_id}"
    )

    {:ok, shipment} = execute_child_workflow(
      MyApp.Workflows.ShipOrder,
      %{order_id: order_id, payment_id: payment},
      id: "ship-#{order_id}"
    )

    {:ok, %{payment: payment, shipment: shipment}}
  end
end
```

`execute_child_workflow/3` blocks until the child completes and returns its result.

The `:id` option is required — it's the child's workflow ID and must be unique.

## Options

```elixir
execute_child_workflow(ChildModule, input,
  id: "child-123",                              # Required — unique child ID
  task_queue: "payments",                        # Default: parent's queue
  workflow_execution_timeout: 300_000,           # Max total time including retries
  workflow_run_timeout: 60_000,                  # Max single run time
  parent_close_policy: :terminate,               # What happens when parent completes
  retry_policy: [max_attempts: 3]                # Child retry config
)
```

### Parent Close Policies

When the parent workflow completes, what should happen to running children?

| Policy | Behavior |
|--------|----------|
| `:terminate` | Kill the child immediately (default) |
| `:abandon` | Let the child run independently |
| `:request_cancel` | Send a cancellation signal to the child |

## When to Use Child Workflows

**Use child workflows when:**
- You need a separate failure domain (child can fail without failing parent)
- You want to reuse a workflow across multiple parents
- The child process is independently meaningful (has its own ID, queryable, signalable)

**Use activities when:**
- The work is a single operation (API call, DB query)
- You don't need the child to be independently visible
- You want simpler code

## What's Next

Learn how to handle [errors and cancellation](error_handling.md).
