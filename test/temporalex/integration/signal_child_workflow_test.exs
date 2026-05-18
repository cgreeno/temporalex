defmodule Temporalex.SignalChildWorkflowIntegrationTest do
  @moduledoc """
  Live-Temporal coverage for `API.signal_child_workflow/4`: parent
  starts a child, signals it while the child is running, and observes
  the child consume the signal and return.

  Connects to 127.0.0.1:7233. Skipped by default.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule SignalReceiver do
    @moduledoc """
    Child workflow that parks waiting for a "go" signal and returns the
    signal payload.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      payload = API.wait_for_signal("go")
      {:ok, {:received, payload}}
    end
  end

  defmodule SignalingParent do
    @moduledoc """
    Parent that starts a child and concurrently signals it. The child
    needs a moment to start before the signal can be routed by id, so
    the signal branch sleeps briefly first. Both branches join via
    `API.parallel/1`.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(message) do
      child_id = "sc-#{API.uuid4()}"

      [child_outcome, :ok] =
        API.parallel([
          fn ->
            {:ok, value} =
              API.execute_child_workflow(SignalReceiver, [], workflow_id: child_id)

            value
          end,
          fn ->
            # Wait long enough for the child workflow task to be registered.
            :ok = API.sleep(500)
            :ok = API.signal_child_workflow(child_id, "go", [message])
            :ok
          end
        ])

      {:ok, child_outcome}
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    task_queue = "signal-child-#{System.unique_integer([:positive])}"

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: "default",
        task_queue: task_queue,
        workflows: [SignalReceiver, SignalingParent],
        activities: []
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

  defp temporal_available? do
    case :gen_tcp.connect(~c"127.0.0.1", 7233, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  test "parent signals running child and child consumes signal", %{worker: worker} do
    workflow_id = "scwfp-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, SignalingParent, :hello,
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:received, [:hello]}} =
             Temporalex.Client.get_result(handle, timeout: 30_000)
  end
end
