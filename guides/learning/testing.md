# Testing

Test your workflows without a Temporal server. Stub activities, simulate signals, and assert on behavior — all in pure Elixir.

## Setup

```elixir
defmodule MyApp.WorkflowTest do
  use ExUnit.Case
  use Temporalex.Testing
end
```

`use Temporalex.Testing` imports all test helpers into your module.

## Testing a Simple Workflow

```elixir
test "greeting workflow returns greeting" do
  result = run_workflow(MyApp.Workflows.GreetUser, %{"name" => "Alice"},
    activities: %{
      MyApp.Activities.Greet => fn %{name: name} -> {:ok, "Hello, #{name}!"} end
    }
  )

  assert {:ok, "Hello, Alice!"} = result
end
```

`run_workflow/3` runs the workflow's `run/1` function directly. Activity stubs replace real execution — no Temporal server, no NIF calls, no network.

## Asserting on Activity Calls

Track which activities were called and with what input:

```elixir
test "order workflow calls charge then ship" do
  run_workflow(MyApp.Workflows.ProcessOrder, %{amount: 100},
    activities: %{
      MyApp.Activities.Charge => fn _ -> {:ok, "charge-1"} end,
      MyApp.Activities.Ship => fn _ -> {:ok, "shipped"} end
    }
  )

  assert_activity_called(MyApp.Activities.Charge)
  assert_activity_called(MyApp.Activities.Charge, %{amount: 100})
  assert_activity_called(MyApp.Activities.Ship)

  # Check call order
  calls = get_activity_calls()
  assert [{MyApp.Activities.Charge, %{amount: 100}}, {MyApp.Activities.Ship, _}] = calls
end
```

## Testing with Signals

Pre-buffer signals so `wait_for_signal` returns immediately:

```elixir
test "approval workflow completes when approved" do
  result = run_workflow(MyApp.Workflows.Approval, %{},
    signals: [{"approve", %{by: "admin"}}]
  )

  assert {:ok, %{approved_by: "admin"}} = result
end
```

You can also send signals mid-test after setting up the context:

```elixir
test "approval workflow with manual signal" do
  workflow_context()
  send_signal("approve", %{by: "manager"})

  result = MyApp.Workflows.Approval.run(%{})
  assert {:ok, _} = result
end
```

## Testing Child Workflows

Stub child workflows the same way you stub activities:

```elixir
test "parent workflow delegates to child" do
  result = run_workflow(MyApp.Workflows.Parent, %{id: "42"},
    child_workflows: %{
      MyApp.Workflows.Child => fn %{id: id} -> {:ok, "processed-#{id}"} end
    }
  )

  assert {:ok, _} = result
  assert_child_workflow_called(MyApp.Workflows.Child)
end
```

## Testing Activities Directly

Test activity logic in isolation:

```elixir
test "send email activity" do
  assert {:ok, "sent"} = run_activity(MyApp.Activities.SendEmail, %{
    to: "user@example.com",
    subject: "Test",
    body: "Hello"
  })
end
```

For activities with heartbeat support (`perform/2`), `run_activity/2` builds a context automatically.

## Testing Patches

Pre-notify patches to test versioned code paths:

```elixir
test "v2 path when patched" do
  result = run_workflow(MyApp.Workflows.Versioned, %{},
    patches: ["v2-algorithm"],
    activities: %{
      MyApp.Activities.NewAlgorithm => fn _ -> {:ok, "v2-result"} end
    }
  )

  assert {:ok, "v2-result"} = result
end
```

## Testing Cancellation

```elixir
test "workflow handles cancellation" do
  workflow_context()
  Process.put(:__temporal_cancelled__, true)

  result = MyApp.Workflows.Cancellable.run(%{})
  assert {:ok, "gracefully stopped"} = result
end
```

## What's Next

Set up [observability](observability.md) with telemetry and OpenTelemetry.
