# Timers and Scheduling

## Durable Sleeps

`sleep/1` creates a timer that survives crashes, restarts, and deployments. When the timer fires, the workflow picks up exactly where it left off.

```elixir
def run(%{"user_id" => user_id}) do
  {:ok, _} = execute_activity(SendWelcomeEmail, %{user_id: user_id})

  sleep(:timer.hours(24))  # Wait 24 hours — durable

  {:ok, _} = execute_activity(SendFollowUpEmail, %{user_id: user_id})
  {:ok, "onboarding complete"}
end
```

Works with `:timer` helpers:

```elixir
sleep(5_000)                  # 5 seconds
sleep(:timer.seconds(30))    # 30 seconds
sleep(:timer.minutes(5))     # 5 minutes
sleep(:timer.hours(1))       # 1 hour
```

## Continue-as-New

Long-running workflows accumulate history. After thousands of events, replay gets slow. `continue_as_new/1` resets the history by starting a fresh execution with new arguments.

```elixir
def run(%{"page" => page}) do
  {:ok, items} = execute_activity(FetchPage, %{page: page})

  if items == [] do
    {:ok, "all pages processed"}
  else
    {:ok, _} = execute_activity(ProcessItems, %{items: items})
    continue_as_new(%{"page" => page + 1})
  end
end
```

Each continuation is a new workflow execution with fresh history but the same workflow ID. The caller's `get_result/1` follows the chain automatically.

### Options

```elixir
continue_as_new(new_args,
  workflow_type: "DifferentWorkflow",   # Change the workflow type
  task_queue: "different-queue"          # Change the task queue
)
```

## Periodic Patterns

Temporal doesn't have built-in cron, but continue-as-new gives you the same thing:

```elixir
defmodule MyApp.Workflows.DailyReport do
  use Temporalex.Workflow

  def run(_args) do
    {:ok, _} = execute_activity(GenerateReport, %{date: Date.utc_today()})
    sleep(:timer.hours(24))
    continue_as_new(%{})
  end
end
```

Start it once. It runs forever, generating a report every 24 hours.

## What's Next

Compose workflows together with [child workflows](child_workflows.md).
