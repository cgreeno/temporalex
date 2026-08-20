defmodule Temporalex.SignalChildWorkflowIntegrationTest do
  @moduledoc """
  Live-Temporal coverage for `API.signal_child_workflow/4`: parent
  starts a child, signals it while the child is running, and observes
  the child consume the signal and return.

  Connects to 127.0.0.1:7233. Skipped by default.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  defmodule SignalReceiver do
    @moduledoc """
    Child workflow that parks waiting for a "go" signal and returns the
    signal payload.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      payload = API.wait_for_signal!("go")
      {:ok, {:received, payload}}
    end
  end

  defmodule MultiSignalReceiver do
    @moduledoc """
    Child workflow that consumes multiple signals before completing.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      accumulated =
        API.phase([],
          signal: %{
            "append" => fn args, list -> {:noreply, [args | list]} end,
            "done" => fn _args, list -> {:stop, Enum.reverse(list)} end
          }
        )

      {:ok, accumulated}
    end
  end

  defmodule MultiSignalingParent do
    @moduledoc """
    Parent that sends three signals to one child before telling it to stop.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      child_id = "msc-#{API.uuid4()}"

      [child_outcome, :ok] =
        API.parallel([
          fn ->
            {:ok, value} =
              API.execute_child_workflow(MultiSignalReceiver, [], workflow_id: child_id)

            value
          end,
          fn ->
            :ok = API.sleep(500)
            :ok = API.signal_child_workflow(child_id, "append", [:first])
            :ok = API.signal_child_workflow(child_id, "append", [:second])
            :ok = API.signal_child_workflow(child_id, "append", [:third])
            :ok = API.signal_child_workflow(child_id, "done", [])
            :ok
          end
        ])

      {:ok, child_outcome}
    end
  end

  defmodule RichPayloadParent do
    @moduledoc """
    Sends a complex Elixir term as a signal payload, verifying round-trip
    through Temporal's wire encoding.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      child_id = "rpc-#{API.uuid4()}"

      payload = %{
        nested: %{values: [1, 2, 3]},
        tag: :complex,
        binary: "hello",
        nil_field: nil
      }

      [child_outcome, :ok] =
        API.parallel([
          fn ->
            {:ok, value} =
              API.execute_child_workflow(SignalReceiver, [], workflow_id: child_id)

            value
          end,
          fn ->
            :ok = API.sleep(500)
            :ok = API.signal_child_workflow(child_id, "go", [payload])
            :ok
          end
        ])

      {:ok, child_outcome}
    end
  end

  defmodule SignalNonexistentParent do
    @moduledoc """
    Try to signal a child that was never started. Temporal must return a
    delivery failure that the parent can pattern-match.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      result = API.signal_child_workflow("never-started-#{API.uuid4()}", "wake", [])
      {:ok, result}
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
    client_name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    task_queue = "signal-child-#{System.unique_integer([:positive])}"

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
        workflows: [
          SignalReceiver,
          MultiSignalReceiver,
          SignalingParent,
          MultiSignalingParent,
          RichPayloadParent,
          SignalNonexistentParent
        ],
        activities: []
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

  test "parent signals running child and child consumes signal", %{client: client} do
    workflow_id = "scwfp-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, SignalingParent, :hello,
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:received, [:hello]}} =
             Temporalex.Client.get_result(handle, timeout: 30_000)
  end

  test "parent sends multiple signals in order; child accumulates and returns them", %{
    client: client
  } do
    workflow_id = "msc-parent-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, MultiSignalingParent, nil,
        workflow_id: workflow_id,
        timeout: 10_000
      )

    # Child accumulates in arrival order, returns the list.
    assert {:ok, accumulated} =
             Temporalex.Client.get_result(handle, timeout: 30_000)

    # Each signal had a single-arg list; child stores the whole args list.
    assert accumulated == [[:first], [:second], [:third]]
  end

  test "rich Elixir term as signal payload round-trips through Temporal intact", %{client: client} do
    workflow_id = "rpc-parent-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, RichPayloadParent, nil,
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:received, [payload]}} =
             Temporalex.Client.get_result(handle, timeout: 30_000)

    # The full nested term survived the encode → wire → decode round-trip.
    assert payload == %{
             nested: %{values: [1, 2, 3]},
             tag: :complex,
             binary: "hello",
             nil_field: nil
           }
  end

  test "signal to a nonexistent child surfaces a delivery failure to the parent", %{
    client: client
  } do
    workflow_id = "snp-parent-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, SignalNonexistentParent, nil,
        workflow_id: workflow_id,
        timeout: 10_000
      )

    # Parent's run/1 returns the result of API.signal_child_workflow directly.
    # That should be {:error, _} since the target doesn't exist.
    assert {:ok, result} =
             Temporalex.Client.get_result(handle, timeout: 30_000)

    assert {:error, %Temporalex.Failure.ApplicationError{}} = result
  end
end
