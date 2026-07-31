defmodule Temporalex.ChildWorkflowIntegrationTest do
  @moduledoc """
  Verifies `API.execute_child_workflow/3` against a live Temporal dev server:
  parent starts child, blocks until result, surfaces failures as
  `%Temporalex.Failure.WorkflowExecutionError{}` with the cause preserved.

  Connects to a Temporal dev server at 127.0.0.1:7233. Skipped by
  default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Child do
    use Temporalex.Workflow

    def run({:succeed, value}), do: {:ok, {:child_value, value}}

    def run({:fail, type, message}) do
      raise %Temporalex.Failure.ApplicationError{
        message: message,
        type: type,
        retryable?: false
      }
    end
  end

  defmodule Parent do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run({:simple, value}) do
      child_id = "child-of-" <> API.uuid4()

      {:ok, child_result} =
        API.execute_child_workflow(Child, [{:succeed, value}], workflow_id: child_id)

      {:ok, {:parent_saw, child_result}}
    end

    def run({:expect_failure, type, message}) do
      child_id = "child-of-" <> API.uuid4()

      case API.execute_child_workflow(Child, [{:fail, type, message}], workflow_id: child_id) do
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
    task_queue = "child-workflow-#{System.unique_integer([:positive])}"

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: "default",
        task_queue: task_queue,
        workflows: [Parent, Child],
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

  test "parent starts child and receives the child's return value", %{worker: worker} do
    workflow_id = "cw-simple-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, Parent, {:simple, 42},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:parent_saw, {:child_value, 42}}} =
             Temporalex.Client.get_result(handle, timeout: 30_000)
  end

  test "child failure surfaces as %ChildWorkflowFailure{cause: %ApplicationError{}}",
       %{worker: worker} do
    workflow_id = "cw-fail-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(
        worker,
        Parent,
        {:expect_failure, "BadInput", "child rejected"},
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, {:got_failure, failure}} =
             Temporalex.Client.get_result(handle, timeout: 30_000)

    assert %Temporalex.Failure.WorkflowExecutionError{cause: cause} = failure
    assert %Temporalex.Failure.ApplicationError{} = cause
    assert cause.type == "BadInput"
    assert cause.message == "child rejected"
    assert cause.retryable? == false
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
