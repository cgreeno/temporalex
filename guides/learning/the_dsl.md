# The DSL

The DSL is an alternative to module-based activities. Instead of one module per activity, you define activities as functions inside a single module using `defactivity`.

## Basic Usage

```elixir
defmodule MyApp.Orders do
  use Temporalex.DSL

  defactivity charge_payment(amount), timeout: 30_000 do
    Stripe.charge(amount)
  end

  defactivity send_receipt(email), timeout: 10_000 do
    Mailer.deliver_receipt(email)
  end

  def process_order(%{"amount" => amount, "email" => email}) do
    with {:ok, charge_id} <- charge_payment(amount),
         {:ok, _} <- send_receipt(email) do
      {:ok, charge_id}
    end
  end
end
```

Register the module as both a workflow and activity source:

```elixir
{Temporalex,
  task_queue: "orders",
  workflows: [{"ProcessOrder", &MyApp.Orders.process_order/1}],
  activities: [MyApp.Orders]}
```

## How It Works

`defactivity` generates a function that auto-detects its execution context:

1. **In a workflow** — schedules the activity through Temporal (durable, retriable)
2. **In a test with stubs** — calls the registered stub function
3. **Everywhere else** — runs the body directly (great for `iex` and scripts)

You don't need to think about which mode you're in. It just works.

## Options

```elixir
defactivity upload(file),
  timeout: 60_000,                  # start_to_close_timeout
  schedule_timeout: 120_000,        # schedule_to_close_timeout
  heartbeat: 10_000,                # heartbeat_timeout
  task_queue: "uploads",            # override task queue
  retry_policy: [max_attempts: 3]   # retry configuration
do
  FileUploader.upload(file)
end
```

## Single Argument

Activities in Temporal accept a single input (typically a map). `defactivity` enforces this:

```elixir
# Good — single map argument
defactivity charge(%{amount: amount, currency: currency}) do
  PaymentService.charge(amount, currency)
end

# Good — no arguments
defactivity health_check do
  {:ok, "healthy"}
end

# Compile error — multiple arguments not allowed
defactivity process(order_id, user_id) do  # CompileError!
  ...
end
```

## Testing DSL Activities

DSL activities integrate with `Temporalex.Testing`:

```elixir
use Temporalex.Testing

test "order workflow charges correctly" do
  result = run_workflow(&MyApp.Orders.process_order/1, %{"amount" => 100, "email" => "a@b.com"},
    activities: %{
      {MyApp.Orders, :charge_payment} => fn amount -> {:ok, "ch-#{amount}"} end,
      {MyApp.Orders, :send_receipt} => fn _email -> {:ok, "sent"} end
    }
  )

  assert {:ok, "ch-100"} = result
end
```

Stubs are keyed by `{Module, :function_name}` for DSL activities.

## DSL vs Module Activities

| | DSL (`defactivity`) | Module (`use Activity`) |
|---|---|---|
| Definition | Function in a module | Separate module per activity |
| Best for | Multiple related activities | Complex activities with config |
| Heartbeats | Not directly (use module for those) | Full context support |
| Registration | One module covers all activities | Each module registered separately |

Use whichever feels right. You can mix both in the same project.

## What's Next

Learn to [test your workflows](testing.md) without a Temporal server.
