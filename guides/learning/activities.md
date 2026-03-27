# Activities

Activities are where the real work happens. HTTP calls, database queries, file uploads, sending emails — anything with side effects goes in an activity.

Temporal runs activities with automatic retries, timeouts, and heartbeats. If an activity fails, Temporal retries it. If the worker crashes mid-activity, Temporal reschedules it on another worker.

## Defining an Activity

```elixir
defmodule MyApp.Activities.SendEmail do
  use Temporalex.Activity, start_to_close_timeout: 10_000

  @impl true
  def perform(%{to: to, subject: subject, body: body}) do
    case Mailer.send(to, subject, body) do
      :ok -> {:ok, "sent"}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

1. **`use Temporalex.Activity`** — marks this as an activity module
2. **`start_to_close_timeout: 10_000`** — the activity must complete within 10 seconds
3. **`perform/1`** — receives the input map, returns `{:ok, result}` or `{:error, reason}`

## Calling an Activity from a Workflow

```elixir
defmodule MyApp.Workflows.NotifyUser do
  use Temporalex.Workflow

  def run(%{"user_id" => user_id, "message" => message}) do
    {:ok, user} = execute_activity(MyApp.Activities.FetchUser, %{id: user_id})
    {:ok, _} = execute_activity(MyApp.Activities.SendEmail, %{
      to: user["email"],
      subject: "Notification",
      body: message
    })
    {:ok, "notified"}
  end
end
```

`execute_activity/2` blocks until the activity completes and returns its result.

## Timeouts

Activities support four timeout types:

```elixir
execute_activity(MyApp.Activities.Upload, input,
  start_to_close_timeout: 60_000,         # Max time to run once started
  schedule_to_start_timeout: 30_000,      # Max time waiting for a worker
  schedule_to_close_timeout: 120_000,     # Max total time (queue + run)
  heartbeat_timeout: 10_000               # Max time between heartbeats
)
```

You can set defaults on the module:

```elixir
use Temporalex.Activity,
  start_to_close_timeout: 30_000,
  heartbeat_timeout: 5_000
```

And override per-call. Call-site options win.

## Retry Policies

By default, Temporal retries failed activities indefinitely with exponential backoff. Customize it:

```elixir
execute_activity(MyApp.Activities.ChargeCard, input,
  retry_policy: [
    max_attempts: 3,
    initial_interval: 1_000,
    backoff_coefficient: 2.0,
    maximum_interval: 30_000,
    non_retryable_error_types: ["CardDeclined"]
  ]
)
```

To make an error non-retryable from inside the activity:

```elixir
def perform(%{card_id: card_id}) do
  case PaymentService.charge(card_id) do
    {:ok, receipt} -> {:ok, receipt}
    {:error, :declined} ->
      {:error, %Temporalex.Error.ApplicationError{
        message: "Card declined",
        type: "CardDeclined",
        non_retryable: true
      }}
  end
end
```

## Heartbeats

Long-running activities should heartbeat to tell Temporal they're still alive. If heartbeats stop, Temporal assumes the activity is stuck and reschedules it.

Use `perform/2` to get a context with heartbeat support:

```elixir
defmodule MyApp.Activities.ProcessFile do
  use Temporalex.Activity,
    start_to_close_timeout: 300_000,
    heartbeat_timeout: 30_000

  @impl true
  def perform(ctx, %{file: path}) do
    path
    |> File.stream!([], 1024)
    |> Stream.with_index()
    |> Enum.each(fn {chunk, i} ->
      process_chunk(chunk)
      Temporalex.Activity.Context.heartbeat(ctx, %{chunks_processed: i})
    end)

    {:ok, "done"}
  end
end
```

The heartbeat details are available on retry if the activity fails, so you can resume from where you left off.

## Local Activities

For short, fast operations that don't need the task queue round-trip:

```elixir
{:ok, result} = execute_local_activity(MyApp.Activities.QuickLookup, %{id: id})
```

Local activities run in the worker process. They're faster but don't appear as separate tasks in the Temporal UI.

## The DSL Alternative

If you prefer activities as plain functions instead of modules, see [The DSL](the_dsl.md).

## What's Next

Your workflows can call activities. Now let's learn to [communicate with running workflows](signals_and_queries.md).
