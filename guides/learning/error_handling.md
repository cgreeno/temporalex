# Error Handling

Temporal has a rich error model. Understanding it helps you build workflows that handle failures gracefully.

## Error Types

| Error | When |
|-------|------|
| `ActivityFailure` | An activity execution failed after all retries |
| `TimeoutError` | A timeout was exceeded (start-to-close, heartbeat, etc.) |
| `CancelledError` | The workflow or activity was cancelled |
| `ApplicationError` | A user-thrown business error |
| `ChildWorkflowFailure` | A child workflow failed |
| `Nondeterminism` | Workflow code diverged from replay history |

## Handling Activity Failures

When an activity exhausts its retries, `execute_activity` returns `{:error, reason}`:

```elixir
def run(%{"order_id" => order_id}) do
  case execute_activity(ChargePayment, %{order_id: order_id}) do
    {:ok, receipt} ->
      {:ok, receipt}

    {:error, %Temporalex.Error.ActivityFailure{} = failure} ->
      # Activity failed after all retries
      {:ok, _} = execute_activity(NotifyFailure, %{order_id: order_id, error: failure.message})
      {:error, "payment failed"}
  end
end
```

## Non-Retryable Errors

Mark an error as non-retryable to stop retries immediately:

```elixir
def perform(%{card_id: card_id}) do
  case PaymentService.charge(card_id) do
    {:ok, receipt} ->
      {:ok, receipt}

    {:error, :insufficient_funds} ->
      {:error, %Temporalex.Error.ApplicationError{
        message: "Insufficient funds",
        type: "InsufficientFunds",
        non_retryable: true
      }}
  end
end
```

## Cancellation

Cancel a running workflow from outside:

```elixir
Temporalex.Client.cancel_workflow(conn, "order-42")
```

Inside the workflow, check for cancellation:

```elixir
def run(%{"items" => items}) do
  results =
    Enum.reduce_while(items, [], fn item, acc ->
      if cancelled?() do
        {:halt, acc}
      else
        {:ok, result} = execute_activity(ProcessItem, item)
        {:cont, [result | acc]}
      end
    end)

  {:ok, Enum.reverse(results)}
end
```

For hard termination (no cleanup):

```elixir
Temporalex.Client.terminate_workflow(conn, "order-42", reason: "manual override")
```

## Timeout Errors

When a timeout fires, you get a `TimeoutError` with the timeout type:

```elixir
case execute_activity(SlowService, input, start_to_close_timeout: 5_000) do
  {:ok, result} -> {:ok, result}
  {:error, %Temporalex.Error.TimeoutError{timeout_type: :start_to_close}} ->
    {:error, "service too slow"}
end
```

## What's Next

Simplify your code with [the DSL](the_dsl.md).
