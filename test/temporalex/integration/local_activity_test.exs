defmodule Temporalex.LocalActivityIntegrationTest do
  @moduledoc """
  Verifies the `defactivity foo, local: true do ... end` surface and
  `API.execute_local_activity/3` round-trip through Temporal Core's
  local-activity history-marker mechanism against a live dev server.

  Connects to a Temporal dev server at 127.0.0.1:7233. Skipped by
  default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Activities do
    use Temporalex.Activity

    @doc "Local activity: doubles its input in-process on the worker."
    defactivity double_local(value), local: true, start_to_close_timeout: 5_000 do
      {:ok, value * 2}
    end

    @doc "Regular activity for control-group comparison."
    defactivity double_remote(value), start_to_close_timeout: 5_000 do
      {:ok, value * 2}
    end
  end

  defmodule Workflow do
    use Temporalex.Workflow

    def run({:local, n}) do
      {:ok, doubled} = Activities.double_local(n)
      {:ok, doubled + 1}
    end

    def run({:remote, n}) do
      {:ok, doubled} = Activities.double_remote(n)
      {:ok, doubled + 1}
    end

    def run({:mixed, n}) do
      {:ok, a} = Activities.double_local(n)
      {:ok, b} = Activities.double_remote(a)
      {:ok, b}
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233 — run `temporal server start-dev`"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    task_queue = "local-activity-#{System.unique_integer([:positive])}"

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: "default",
        task_queue: task_queue,
        workflows: [Workflow],
        activities: [Activities]
      )

    on_exit(fn ->
      try do
        if Process.alive?(worker_pid), do: Supervisor.stop(worker_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, worker: worker_name}
  end

  test "local activity result reaches the workflow", %{worker: worker} do
    workflow_id = "la-local-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, Workflow, {:local, 5},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, 11} = Temporalex.Client.get_result(handle, timeout: 15_000)
  end

  test "regular activity still works (control)", %{worker: worker} do
    workflow_id = "la-remote-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, Workflow, {:remote, 7},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, 15} = Temporalex.Client.get_result(handle, timeout: 15_000)
  end

  test "local and remote activities can be mixed in one workflow", %{worker: worker} do
    workflow_id = "la-mixed-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, Workflow, {:mixed, 3},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    # 3 → local doubles to 6 → remote doubles to 12
    assert {:ok, 12} = Temporalex.Client.get_result(handle, timeout: 15_000)
  end

  defp temporal_available? do
    case :gen_tcp.connect(~c"127.0.0.1", 7233, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
