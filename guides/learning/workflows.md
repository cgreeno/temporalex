# Workflows

Workflows are the core of Temporal. A workflow is a function that orchestrates work — calling activities, waiting for signals, sleeping for hours or days — and Temporal guarantees it runs to completion, even through crashes and deployments.

## Your First Workflow

```elixir
defmodule MyApp.Workflows.GreetUser do
  use Temporalex.Workflow

  def run(%{"name" => name}) do
    {:ok, greeting} = execute_activity(MyApp.Activities.Greet, %{name: name})
    {:ok, greeting}
  end
end
```

That's it. Three things to notice:

1. **`use Temporalex.Workflow`** — imports all workflow functions (`execute_activity`, `sleep`, `wait_for_signal`, etc.)
2. **`def run(args)`** — the entry point. Temporal calls this when the workflow starts. `args` is whatever the caller passed.
3. **Return `{:ok, result}` or `{:error, reason}`** — standard Elixir convention.

## Registering Workflows

Tell Temporalex about your workflow when starting the server:

```elixir
{Temporalex,
  name: MyApp.Temporal,
  task_queue: "greetings",
  workflows: [MyApp.Workflows.GreetUser],
  activities: [MyApp.Activities.Greet]}
```

The workflow type is derived from the module name: `MyApp.Workflows.GreetUser` becomes `"MyApp.Workflows.GreetUser"`.

## Starting a Workflow

From anywhere in your app:

```elixir
conn = Temporalex.connection_name(MyApp.Temporal)

{:ok, handle} = Temporalex.Client.start_workflow(
  conn,
  MyApp.Workflows.GreetUser,
  %{name: "Alice"},
  id: "greet-alice",
  task_queue: "greetings"
)
```

The `:id` is the workflow's unique identifier. If you start a workflow with the same ID while one is already running, Temporal returns an error. This gives you natural idempotency.

## Getting the Result

```elixir
{:ok, result} = Temporalex.Client.get_result(handle)
# => {:ok, "Hello, Alice!"}
```

`get_result/1` blocks until the workflow completes. For fire-and-forget, just use `start_workflow` and ignore the result.

## The Determinism Rule

This is the one thing you must internalize: **workflow code must be deterministic.**

Temporal replays your workflow code from history to rebuild state. If your code produces different commands on replay, the workflow breaks.

**Don't do this inside a workflow:**
- `DateTime.utc_now()` — use `workflow_info()` for timestamps
- `:rand.uniform()` — use `random()` which is replay-safe
- `System.fetch_env!()` — use activities for environment access
- HTTP calls, DB queries — use activities for all I/O

**Do this instead:**

```elixir
def run(_args) do
  # Safe — deterministic on replay
  discount = if random() > 0.5, do: 0.1, else: 0.05
  key = uuid4()

  # Side effects go in activities
  {:ok, order} = execute_activity(PlaceOrder, %{discount: discount, key: key})
  {:ok, order}
end
```

Activities are where non-deterministic work lives. Workflows are pure orchestration.

## Workflow State

You can store and read state during execution:

```elixir
def run(args) do
  set_state(%{phase: "started"})
  {:ok, _} = execute_activity(Step1, args)

  set_state(%{phase: "processing"})
  {:ok, result} = execute_activity(Step2, args)

  set_state(%{phase: "done"})
  {:ok, result}
end
```

This state is accessible via [queries](signals_and_queries.md) from outside the workflow.

## Workflow Info

Access metadata about the current execution:

```elixir
info = workflow_info()
# %{workflow_id: "greet-alice", run_id: "abc-123", task_queue: "greetings", ...}
```

## What's Next

Workflows orchestrate activities. Let's [learn how to write them](activities.md).
