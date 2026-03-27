# Recipe: Saga Pattern

## The Problem

You're processing an order: charge the card, reserve inventory, and schedule shipping. If shipping fails, you need to reverse the charge and release the inventory. Each step is a separate service call.

This is the saga pattern — a sequence of operations where each step has a compensating action that undoes it on failure.

## The Implementation

```elixir
defmodule MyApp.Workflows.ProcessOrder do
  use Temporalex.Workflow

  def run(%{"order_id" => order_id, "amount" => amount, "items" => items}) do
    compensations = []

    # Step 1: Charge the card
    case execute_activity(MyApp.Activities.ChargeCard, %{order_id: order_id, amount: amount}) do
      {:ok, charge_id} ->
        compensations = [{MyApp.Activities.RefundCharge, %{charge_id: charge_id}} | compensations]

        # Step 2: Reserve inventory
        case execute_activity(MyApp.Activities.ReserveInventory, %{items: items}) do
          {:ok, reservation_id} ->
            compensations = [{MyApp.Activities.ReleaseInventory, %{reservation_id: reservation_id}} | compensations]

            # Step 3: Schedule shipping
            case execute_activity(MyApp.Activities.ScheduleShipping, %{order_id: order_id, items: items}) do
              {:ok, tracking} ->
                {:ok, %{charge_id: charge_id, reservation_id: reservation_id, tracking: tracking}}

              {:error, _reason} ->
                compensate(compensations)
                {:error, "shipping failed — order rolled back"}
            end

          {:error, _reason} ->
            compensate(compensations)
            {:error, "inventory unavailable — order rolled back"}
        end

      {:error, _reason} ->
        {:error, "payment failed"}
    end
  end

  defp compensate(compensations) do
    for {activity, input} <- compensations do
      # Best effort — compensations should be idempotent
      execute_activity(activity, input)
    end
  end
end
```

## How It Works

1. Each successful step pushes its compensating activity onto a stack
2. On failure at any step, the stack is unwound in reverse order
3. Compensating activities should be idempotent — if they're retried, the result is the same

## A Cleaner Version with `with`

```elixir
def run(%{"order_id" => order_id, "amount" => amount, "items" => items}) do
  with {:ok, charge_id} <- execute_activity(ChargeCard, %{order_id: order_id, amount: amount}),
       {:ok, reservation_id} <- execute_activity(ReserveInventory, %{items: items}),
       {:ok, tracking} <- execute_activity(ScheduleShipping, %{order_id: order_id, items: items}) do
    {:ok, %{charge_id: charge_id, reservation_id: reservation_id, tracking: tracking}}
  else
    {:error, reason} ->
      # Compensate whatever succeeded — activities are idempotent
      execute_activity(RefundCharge, %{order_id: order_id})
      execute_activity(ReleaseInventory, %{order_id: order_id})
      {:error, reason}
  end
end
```

This is simpler but compensates everything regardless of which step failed. If your compensating activities are idempotent (they should be), this is fine.

## Testing It

```elixir
test "rolls back on shipping failure" do
  result = run_workflow(MyApp.Workflows.ProcessOrder, %{
    "order_id" => "123", "amount" => 100, "items" => ["book"]
  }, activities: %{
    MyApp.Activities.ChargeCard => fn _ -> {:ok, "ch-1"} end,
    MyApp.Activities.ReserveInventory => fn _ -> {:ok, "res-1"} end,
    MyApp.Activities.ScheduleShipping => fn _ -> {:error, "no carriers"} end,
    MyApp.Activities.RefundCharge => fn _ -> {:ok, "refunded"} end,
    MyApp.Activities.ReleaseInventory => fn _ -> {:ok, "released"} end
  })

  assert {:error, "shipping failed — order rolled back"} = result
  assert_activity_called(MyApp.Activities.RefundCharge)
  assert_activity_called(MyApp.Activities.ReleaseInventory)
end
```
