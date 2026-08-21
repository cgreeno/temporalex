defmodule Temporalex.NonBlockingChildIntegrationTest do
  @moduledoc """
  Live-Temporal coverage for the non-blocking child workflow surface:
  `API.start_child_workflow/3` returns a handle, parent signals/cancels
  via that handle, then awaits the eventual result.

  Connects to 127.0.0.1:7233. Skipped by default.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  defmodule SignalReceiver do
    @moduledoc """
    Long-running child workflow that waits for a "go" signal then echoes
    the payload, or returns a sentinel if cancelled.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      result =
        API.phase(:waiting,
          signal: %{
            "go" => fn args, _state -> {:stop, {:received, args}} end
          },
          timeout: 60_000
        )

      case result do
        {:timeout, _} -> {:ok, :timed_out}
        other -> {:ok, other}
      end
    end
  end

  defmodule PollingChild do
    @moduledoc """
    Loops short sleeps and checks `cancelled?` between them. When the
    parent cancels via `API.cancel_child_workflow/1`, the child sees the
    flag on its next iteration and returns a cancelled tuple.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_), do: poll_loop()

    defp poll_loop do
      if API.cancelled?() do
        {:cancelled, :polled}
      else
        # Under Hans's interrupting cancellation model the pending sleep is
        # cancelled and returns {:cancelled, _}; observe that as the cancel.
        case API.sleep(200) do
          :ok -> poll_loop()
          {:cancelled, _} -> {:cancelled, :polled}
        end
      end
    end
  end

  defmodule StartSignalAwaitParent do
    @moduledoc """
    Demonstrates the full non-blocking flow: start child, get handle,
    signal it (using the handle), then await its result.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(payload) do
      child_id = "sca-#{API.uuid4()}"

      {:ok, handle} =
        API.start_child_workflow(SignalReceiver, [], workflow_id: child_id)

      # Tiny delay to let the child reach its phase. In real workflows
      # this is rarely needed since signal_child_workflow is durable, but
      # the test's setup makes the race observable without it.
      :ok = API.sleep(200)

      :ok = API.signal_child_workflow(handle, "go", [payload])

      {:ok, child_result} = API.await_child_workflow(handle)
      {:ok, child_result}
    end
  end

  defmodule StartCancelAwaitParent do
    @moduledoc """
    Start a polling child, cancel it via the handle, await its
    {:cancelled, _} return. Verifies cancel_child_workflow propagates
    a CancelRequested signal to the child.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      child_id = "cna-#{API.uuid4()}"

      {:ok, handle} =
        API.start_child_workflow(PollingChild, [], workflow_id: child_id)

      # Let the child run a couple of poll iterations.
      :ok = API.sleep(500)

      :ok = API.cancel_child_workflow(handle)

      result = API.await_child_workflow(handle)
      {:ok, {:awaited, result}}
    end
  end

  setup_all do
    unless temporal_available?(), do: raise("Temporal dev server not reachable")

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    client_name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    task_queue = "nbc-#{System.unique_integer([:positive])}"

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
          PollingChild,
          StartSignalAwaitParent,
          StartCancelAwaitParent
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

  test "start_child_workflow + signal via handle + await returns the child's result",
       %{client: client} do
    workflow_id = "nbc-signal-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, StartSignalAwaitParent, :hello,
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:received, [:hello]}} =
             Temporalex.Client.get_result(handle, timeout: 30_000)
  end

  test "start_child_workflow + cancel via handle + await sees the child's cancellation",
       %{client: client} do
    workflow_id = "nbc-cancel-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, StartCancelAwaitParent, nil,
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:awaited, child_outcome}} =
             Temporalex.Client.get_result(handle, timeout: 30_000)

    # The child is a polling workflow that returns {:cancelled, :polled}
    # on cancellation, which becomes the CancelWorkflowExecution command.
    # The parent's await sees it as {:cancelled, _} or {:error, %CancelledError{}}.
    case child_outcome do
      {:cancelled, _} -> :ok
      {:error, %Temporalex.Failure.CancelledError{}} -> :ok
      other -> flunk("expected cancellation outcome, got: #{inspect(other)}")
    end
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
