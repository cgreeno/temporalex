# Workflow Testing

`Temporalex.Testing` is the fast workflow test surface for application tests.
It runs workflow code through the real Temporalex executor without starting a
Temporal server.

Use this for the common test shape:

- start a workflow
- assert the Temporal-visible work it scheduled
- complete or fail that work explicitly
- send signals, updates, queries, or cancellation
- assert the terminal result
- replay the recorded activation transcript

This is different from Temporal dev-server integration tests. Dev-server tests
are still valuable for SDK/backend conformance, but most application workflow
tests should stay deterministic, local, and fast.

## Basic Shape

Temporalex does not provide an ExUnit case-template macro. Import the helpers
directly or from your own case template:

```elixir
defmodule MyApp.CheckoutWorkflowTest do
  use ExUnit.Case, async: true

  import Temporalex.Testing

  test "checkout charges the card" do
    {:ok, run} =
      start_workflow(MyApp.Workflows.Checkout, %{order_id: "ord_123"})

    charge =
      assert_next_activity(run,
        type: {MyApp.Activities, :charge_card},
        input: [%{order_id: "ord_123"}]
      )

    complete_activity(run, charge, {:ok, %{charge_id: "ch_123"}})

    assert_completed(run, :complete)
    assert_replay(run)
  end
end
```

## Linear Command Consumption

Each activation may emit one or more commands. Tests consume those commands in
deterministic emission order:

```elixir
first = assert_next_activity(run, input: [:first])
second = assert_next_activity(run, input: [:second])
assert_no_commands(run)
```

After a command is consumed, the returned handle can be resolved later. This
allows out-of-order activity completion while preserving deterministic command
assertions:

```elixir
complete_activity(run, second, {:ok, :second_done})
complete_activity(run, first, {:ok, :first_done})
```

The runner rejects new activations while emitted commands are still unconsumed.
That keeps tests honest about the full set of Temporal-visible side effects from
each workflow activation.

## Operation Handles

Activity and timer assertions return handles with the runtime identity needed to
resolve the exact operation:

```elixir
%Temporalex.Testing.Activity{
  seq: 0,
  thread_id: [],
  activity_id: "activity-0",
  type: "MyApp.Activities.charge_card",
  input: [%{order_id: "ord_123"}],
  task_queue: nil,
  headers: %{},
  start_to_close_timeout_ms: 30_000,
  retry_policy: nil,
  cancellation_type: :wait_cancellation_completed
}
```

The `seq` is the executor's pending operation identity. `activity_id` remains
visible because it is part of the Temporal command.

## Inputs

Signals, updates, queries, and cancellation are explicit workflow inputs:

```elixir
signal(run, "approve", [%{by: "alice"}])

update = update(run, "add_item", [%{sku: "ABC"}], protocol_instance_id: "add-item")
assert_next_update_accepted(run, update)
assert_next_update_completed(run, update, :ok)

assert_query(run, "status", [], :approved)

cancel_workflow(run, "user requested")
```

Queries consume their query response internally and return `{:ok, value}` or
`{:error, reason}`. Updates expose their accepted/completed/rejected responses
as commands so tests can observe durable update behavior around blocking work.

## Replay

Every run records an activation transcript. Use `assert_replay/1` to verify that
the same workflow code emits the same commands when replaying that transcript:

```elixir
assert_replay(run)
```

Safe mode defaults to `:fail`, so common nondeterministic workflow mistakes are
caught during these local workflow tests.
