# Recipe: Safe Deployments with Versioning

## The Problem

You have running workflows in production. You need to change the workflow logic — add a step, remove a step, change the order. But existing executions are mid-flight with recorded history. If the new code produces different commands on replay, Temporal detects a nondeterminism error and the workflow fails.

## The Solution: `patched?/1`

`patched?/1` creates a version gate. Old executions (replay) take the else branch. New executions take the if branch.

## Step-by-Step Walkthrough

### Before: Original Code

```elixir
defmodule MyApp.Workflows.ProcessOrder do
  use Temporalex.Workflow

  def run(%{"order_id" => order_id}) do
    {:ok, charge} = execute_activity(ChargePayment, %{order_id: order_id})
    {:ok, _} = execute_activity(ShipOrder, %{order_id: order_id})
    {:ok, charge}
  end
end
```

### Step 1: Add the New Logic Behind a Patch

You want to add a fraud check before charging. Wrap it:

```elixir
def run(%{"order_id" => order_id}) do
  if patched?("add-fraud-check") do
    # New path: fraud check first
    {:ok, _} = execute_activity(FraudCheck, %{order_id: order_id})
    {:ok, charge} = execute_activity(ChargePayment, %{order_id: order_id})
  else
    # Old path: charge directly (existing executions replay this)
    {:ok, charge} = execute_activity(ChargePayment, %{order_id: order_id})
  end

  {:ok, _} = execute_activity(ShipOrder, %{order_id: order_id})
  {:ok, charge}
end
```

Deploy this. Old running workflows replay the else branch. New workflows take the if branch.

### Step 2: Wait for Old Executions to Complete

Check the Temporal UI or use the list API:

```elixir
{:ok, running} = Temporalex.Client.list_workflows(conn,
  ~s(WorkflowType = "MyApp.Workflows.ProcessOrder" AND ExecutionStatus = "Running")
)
```

When `running` is empty, all old executions have finished.

### Step 3: Remove the Patch Guard

```elixir
def run(%{"order_id" => order_id}) do
  deprecate_patch("add-fraud-check")

  {:ok, _} = execute_activity(FraudCheck, %{order_id: order_id})
  {:ok, charge} = execute_activity(ChargePayment, %{order_id: order_id})
  {:ok, _} = execute_activity(ShipOrder, %{order_id: order_id})
  {:ok, charge}
end
```

`deprecate_patch/1` tells Temporal this patch is no longer needed. After another round of old executions completing, you can remove the `deprecate_patch` call entirely.

## Multiple Patches

Patches compose. Each is independent:

```elixir
def run(args) do
  if patched?("v2-pricing") do
    {:ok, price} = execute_activity(NewPricing, args)
  else
    {:ok, price} = execute_activity(OldPricing, args)
  end

  if patched?("add-audit-log") do
    execute_activity(AuditLog, %{price: price})
  end

  {:ok, price}
end
```

## Testing Patches

```elixir
test "new path with fraud check" do
  result = run_workflow(MyApp.Workflows.ProcessOrder, %{"order_id" => "1"},
    patches: ["add-fraud-check"],
    activities: %{
      MyApp.Activities.FraudCheck => fn _ -> {:ok, "clear"} end,
      MyApp.Activities.ChargePayment => fn _ -> {:ok, "ch-1"} end,
      MyApp.Activities.ShipOrder => fn _ -> {:ok, "shipped"} end
    }
  )

  assert {:ok, "ch-1"} = result
  assert_activity_called(MyApp.Activities.FraudCheck)
end

test "old path without fraud check" do
  result = run_workflow(MyApp.Workflows.ProcessOrder, %{"order_id" => "1"},
    patches: [],
    activities: %{
      MyApp.Activities.ChargePayment => fn _ -> {:ok, "ch-1"} end,
      MyApp.Activities.ShipOrder => fn _ -> {:ok, "shipped"} end
    }
  )

  assert {:ok, "ch-1"} = result
  calls = get_activity_calls()
  refute Enum.any?(calls, fn {mod, _} -> mod == MyApp.Activities.FraudCheck end)
end
```
