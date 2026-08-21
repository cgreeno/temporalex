defmodule Temporalex.StructuredErrorsIntegrationTest do
  @moduledoc """
  Round-trip verification that Temporalex error structs survive the
  Rust encoder → Temporal Server → Rust decoder path with their typed
  fields intact.

  Connects to a Temporal dev server at 127.0.0.1:7233. Skipped by
  default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  defmodule Activities do
    use Temporalex.Activity

    @doc "Raises an ApplicationError struct directly. non_retryable so a single attempt suffices."
    defactivity raise_application_error(message, type),
      start_to_close_timeout: 5_000,
      retry_policy: [maximum_attempts: 1] do
      raise %Temporalex.Failure.ApplicationError{
        message: message,
        type: type,
        retryable?: false,
        details: %{shopper_id: "S-001"}
      }
    end

    @doc "Returns {:error, reason} — gets wrapped into ApplicationError by the server."
    defactivity return_error(reason),
      start_to_close_timeout: 5_000,
      retry_policy: [maximum_attempts: 1] do
      {:error, reason}
    end

    @doc "Raises a plain RuntimeError — gets wrapped with type set to the exception module name."
    defactivity raise_generic(message),
      start_to_close_timeout: 5_000,
      retry_policy: [maximum_attempts: 1] do
      raise RuntimeError, message
    end
  end

  defmodule Workflow do
    use Temporalex.Workflow

    def run({:raise_app, message, type}) do
      case Activities.raise_application_error(message, type) do
        {:error, failure} -> {:ok, {:got_failure, failure}}
        other -> {:error, {:expected_failure, other}}
      end
    end

    def run({:return_error, reason}) do
      case Activities.return_error(reason) do
        {:error, failure} -> {:ok, {:got_failure, failure}}
        other -> {:error, {:expected_failure, other}}
      end
    end

    def run({:raise_generic, message}) do
      case Activities.raise_generic(message) do
        {:error, failure} -> {:ok, {:got_failure, failure}}
        other -> {:error, {:expected_failure, other}}
      end
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233 — run `temporal server start-dev`"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    client_name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    task_queue = "structured-errors-#{System.unique_integer([:positive])}"

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

  test "ApplicationError raised in activity arrives at workflow as %ActivityFailure{cause: %ApplicationError{}}",
       %{client: client} do
    workflow_id = "se-app-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(
        client,
        Workflow,
        {:raise_app, "invalid sku", "InvalidSku"},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:got_failure, failure}} =
             Temporalex.Client.get_result(handle, timeout: 15_000)

    assert %Temporalex.Failure.ActivityError{cause: cause} = failure
    assert %Temporalex.Failure.ApplicationError{} = cause
    assert cause.type == "InvalidSku"
    assert cause.message == "invalid sku"
    assert cause.retryable? == false
  end

  test "Bare {:error, reason} from activity wraps into ApplicationError with the reason as details",
       %{client: client} do
    workflow_id = "se-tup-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(
        client,
        Workflow,
        {:return_error, :insufficient_funds},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:got_failure, failure}} =
             Temporalex.Client.get_result(handle, timeout: 15_000)

    assert %Temporalex.Failure.ActivityError{cause: cause} = failure
    assert %Temporalex.Failure.ApplicationError{} = cause
    assert cause.type == "ApplicationError"
    # message reflects the inspected reason
    assert cause.message == ":insufficient_funds"
  end

  test "Plain RuntimeError raised in activity wraps with type set to exception module name",
       %{client: client} do
    workflow_id = "se-gen-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(
        client,
        Workflow,
        {:raise_generic, "boom"},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:got_failure, failure}} =
             Temporalex.Client.get_result(handle, timeout: 15_000)

    assert %Temporalex.Failure.ActivityError{cause: cause} = failure
    assert %Temporalex.Failure.ApplicationError{} = cause
    assert cause.type == "RuntimeError"
    assert cause.message == "boom"
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
