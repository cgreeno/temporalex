defmodule Temporalex.Worker do
  @moduledoc """
  Supervisor for a Temporal worker — one per task queue.

  Starts a Server (connects to Temporal, receives poll loop messages)
  and a Task.Supervisor for activity execution.

  ## Usage

      children = [
        {Temporalex.Worker,
          url: "http://localhost:7233",
          namespace: "default",
          task_queue: "my-queue",
          workflows: [MyApp.Workflows.Checkout],
          activities: [MyApp.Activities.Payment]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

  - `:url` (required) — Temporal server URL (http:// or https://)
  - `:task_queue` (required) — task queue name
  - `:namespace` — Temporal namespace (default: "default")
  - `:workflows` — list of workflow modules (default: [])
  - `:activities` — list of activity modules (default: [])
  - `:name` — supervisor name (default: `Temporalex.Worker`)
  - `:api_key` — API key for Temporal Cloud
  - `:headers` — additional gRPC headers
  - `:max_cached_workflows` — max cached workflow executions (default: 1000)
  """

  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    activity_sup = Module.concat(name, ActivitySupervisor)
    executor_sup = Module.concat(name, ExecutorSupervisor)

    config = %{
      url: Keyword.fetch!(opts, :url),
      namespace: Keyword.get(opts, :namespace, "default"),
      task_queue: Keyword.fetch!(opts, :task_queue),
      workflows: Keyword.get(opts, :workflows, []),
      activities: Keyword.get(opts, :activities, []),
      api_key: Keyword.get(opts, :api_key),
      headers: Keyword.get(opts, :headers, %{}),
      max_cached_workflows: Keyword.get(opts, :max_cached_workflows, 1000),
      activity_supervisor: activity_sup,
      executor_supervisor: executor_sup,
      # Test seam: when set, Server skips the connect/start_worker flow and
      # sits idle in :running. Use only from tests that drive the Server
      # directly via :sys.replace_state.
      skip_connect: Keyword.get(opts, :skip_connect, false)
    }

    children = [
      {Task.Supervisor, name: activity_sup},
      {DynamicSupervisor, name: executor_sup, strategy: :one_for_one},
      {Temporalex.Worker.Server, config}
    ]

    # :one_for_all because all three children form a single coherent unit:
    # the Server holds the WorkerResource NIF reference, the executors hold
    # cloned references via their state.worker, and the Task.Supervisor
    # runs the activity tasks that report back to the Server. If any one
    # dies, the others' references are stale or their callbacks point to
    # a dead recipient — restart the whole group.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
