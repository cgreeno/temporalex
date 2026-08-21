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

  alias Temporalex.TestSupport.Server

  defmodule Activities do
    use Temporalex.Activity

    @doc "Local activity: doubles its input in-process on the worker."
    # The explicit schedule_to_close covers the local codec's explicit-value
    # branch (#22); the other local activities exercise the unset default.
    defactivity double_local(value),
      local: true,
      start_to_close_timeout: 5_000,
      schedule_to_close_timeout: 9_000 do
      {:ok, value * 2}
    end

    @doc "Regular activity for control-group comparison."
    defactivity double_remote(value), start_to_close_timeout: 5_000 do
      {:ok, value * 2}
    end

    @doc "Local activity that fails deliberately and finally."
    defactivity decline_local(amount),
      local: true,
      start_to_close_timeout: 5_000,
      retry_policy: [maximum_attempts: 1] do
      Temporalex.fail!("locally declined: #{amount}", type: "LocalDeclined", retry: false)
    end
  end

  defmodule Workflow do
    use Temporalex.Workflow

    import Temporalex.Failure, only: [is_failure: 2]

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

    def run({:declined, n}) do
      # The guard must match the bare shape the local path produces, too.
      case Activities.decline_local(n) do
        {:ok, _} -> {:ok, :unexpected_success}
        {:error, e} when is_failure(e, "LocalDeclined") -> {:ok, {:declined, e}}
        {:error, other} -> {:ok, {:guard_missed, other}}
      end
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233 — run `temporal server start-dev`"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    client_name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    task_queue = "local-activity-#{System.unique_integer([:positive])}"

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client_name,
        backend: Temporalex.Backend.TemporalCore,
        target: Server.target(),
        namespace: Temporalex.TestSupport.Namespace.name(),
        task_queue: task_queue
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        client: client_name,
        task_queue: task_queue,
        workflows: [Workflow],
        activities: [Activities]
      )

    on_exit(fn ->
      try do
        if Process.alive?(worker_pid), do: Supervisor.stop(worker_pid, :normal, 5_000)
        if Process.alive?(client_pid), do: GenServer.stop(client_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, client: client_name, worker: worker_name}
  end

  test "local activity result reaches the workflow", %{client: client} do
    workflow_id = "la-local-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Workflow, {:local, 5},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, 11} = Temporalex.Client.get_result(handle, timeout: 15_000)
  end

  test "regular activity still works (control)", %{client: client} do
    workflow_id = "la-remote-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Workflow, {:remote, 7},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, 15} = Temporalex.Client.get_result(handle, timeout: 15_000)
  end

  test "local and remote activities can be mixed in one workflow", %{client: client} do
    workflow_id = "la-mixed-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Workflow, {:mixed, 3},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    # 3 → local doubles to 6 → remote doubles to 12
    assert {:ok, 12} = Temporalex.Client.get_result(handle, timeout: 15_000)
  end

  # Pins an asymmetry with the remote path, established empirically against a
  # live server: a failed REMOTE activity arrives wrapped in
  # %Failure.ActivityError{} with the raised error as its cause (see
  # structured_errors_test.exs), but a failed LOCAL activity arrives as the
  # raised error itself. Both paths decode through the same
  # activity_resolution_from_proto, so whether the wrapper exists is decided
  # upstream of Elixir, not here. Workflow code matching on activity failures
  # therefore cannot use one shape for both.
  test "a failed local activity reaches the workflow unwrapped", %{client: client} do
    workflow_id = "la-declined-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Workflow, {:declined, 42},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:declined, failure}} = Temporalex.Client.get_result(handle, timeout: 15_000)

    assert %Temporalex.Failure.ApplicationError{} = failure
    assert failure.type == "LocalDeclined"
    assert failure.message == "locally declined: 42"
    assert failure.retryable? == false
  end

  defp temporal_available? do
    case :gen_tcp.connect(
           String.to_charlist(Server.host()),
           Server.port(),
           [:binary, active: false],
           1_000
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
