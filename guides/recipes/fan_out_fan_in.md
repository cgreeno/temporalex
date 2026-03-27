# Recipe: Fan-Out / Fan-In

## The Problem

You need to process a batch of items in parallel — resize 10 images, send notifications to 50 users, or validate 100 records. You want all results collected before moving on.

## The Implementation

Temporal activities run in parallel automatically. Each `execute_activity` call is independent — Temporal schedules them on available workers.

```elixir
defmodule MyApp.Workflows.BatchProcessor do
  use Temporalex.Workflow

  def run(%{"items" => items}) do
    # Fan out: start all activities
    results =
      items
      |> Enum.map(fn item ->
        case execute_activity(MyApp.Activities.ProcessItem, item) do
          {:ok, result} -> {:ok, item, result}
          {:error, reason} -> {:error, item, reason}
        end
      end)

    # Fan in: collect results
    successes = for {:ok, item, result} <- results, do: {item, result}
    failures = for {:error, item, reason} <- results, do: {item, reason}

    {:ok, %{
      processed: length(successes),
      failed: length(failures),
      failures: failures
    }}
  end
end
```

> **Note:** In the current version, activities within a single workflow task execute sequentially. True parallel fan-out requires the activities to span multiple workflow tasks (which Temporal handles via activity scheduling). For CPU-bound parallelism within a single step, use child workflows.

## With Child Workflows for True Parallelism

For heavier work, fan out to child workflows:

```elixir
defmodule MyApp.Workflows.ParallelProcessor do
  use Temporalex.Workflow

  def run(%{"batches" => batches}) do
    results =
      Enum.map(batches, fn batch ->
        execute_child_workflow(
          MyApp.Workflows.ProcessBatch,
          %{items: batch},
          id: "batch-#{:erlang.phash2(batch)}"
        )
      end)

    successes = for {:ok, r} <- results, do: r
    {:ok, %{completed: length(successes), total: length(batches)}}
  end
end
```

## Testing It

```elixir
test "processes all items and reports results" do
  result = run_workflow(MyApp.Workflows.BatchProcessor, %{
    "items" => [%{id: 1}, %{id: 2}, %{id: 3}]
  }, activities: %{
    MyApp.Activities.ProcessItem => fn %{id: id} ->
      if id == 2, do: {:error, "invalid"}, else: {:ok, "done-#{id}"}
    end
  })

  assert {:ok, %{processed: 2, failed: 1}} = result
end
```
