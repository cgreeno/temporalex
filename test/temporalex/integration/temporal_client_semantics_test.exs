defmodule Temporalex.TemporalClientSemanticsTest do
  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.Client
  alias Temporalex.TestSupport.TemporalDevServer
  alias Temporalex.Workflow.API

  defmodule GateWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(label) do
      API.publish_state({:waiting, label})
      API.wait_for_signal!("finish")
      API.publish_state({:finished, label})
      {:ok, {:finished, label}}
    end
  end

  defmodule CompletedWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(label) do
      API.publish_state({:completed, label})
      {:ok, {:completed, label}}
    end
  end

  defmodule FailedWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(label) do
      API.publish_state({:failed, label})

      {:error,
       Temporalex.Failure.application("planned client semantics failure",
         type: "ClientSemanticsFailure",
         details: [label],
         retryable?: false
       )}
    end
  end

  test "client operation semantics are stable against a real Temporal server" do
    temporal = TemporalDevServer.start!()

    worker_name = unique_module("Worker")
    client_name = unique_module("Client")
    task_queue = "temporalex-client-semantics-#{System.unique_integer([:positive])}"

    {:ok, client_pid} =
      Client.start_link(
        name: client_name,
        backend: Temporalex.Backend.TemporalCore,
        target: temporal.target,
        namespace: "default",
        task_queue: task_queue,
        workflow_result_timeout: 30_000
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        client: client_name,
        task_queue: task_queue,
        workflows: [GateWorkflow, CompletedWorkflow, FailedWorkflow],
        activities: [],
        max_workflow_pollers: 2,
        max_activity_pollers: 1
      )

    try do
      assert_running_workflow_conflicts(client_name)
      assert_closed_workflow_reuse(client_name)
      assert_not_found_errors(client_name)
      assert_query_reject_condition(client_name)
      assert_update_rejection(client_name)
    after
      if Process.alive?(worker_pid) do
        Supervisor.stop(worker_pid, :normal, 15_000)
      end

      if Process.alive?(client_pid) do
        GenServer.stop(client_pid, :normal, 15_000)
      end

      TemporalDevServer.stop(temporal)
    end
  end

  defp assert_running_workflow_conflicts(client_name) do
    workflow_id = unique_workflow_id("conflict")

    assert {:ok, first} =
             Client.start_workflow(client_name, GateWorkflow, :conflict,
               workflow_id: workflow_id,
               id_conflict_policy: :fail,
               timeout: 10_000
             )

    assert TemporalDevServer.eventually(fn ->
             Client.query_workflow(first, "state", [], timeout: 10_000) ==
               {:ok, {:waiting, :conflict}}
           end)

    assert {:error,
            %Temporalex.WorkflowAlreadyStartedError{
              operation: :start_workflow,
              workflow_id: ^workflow_id,
              workflow_type: workflow_type,
              run_id: already_started_run_id
            }} =
             Client.start_workflow(client_name, GateWorkflow, :duplicate,
               workflow_id: workflow_id,
               id_conflict_policy: :fail,
               timeout: 10_000
             )

    assert workflow_type == GateWorkflow.__workflow_type__()
    assert already_started_run_id == first.run_id

    assert {:ok, existing} =
             Client.start_workflow(client_name, GateWorkflow, :duplicate,
               workflow_id: workflow_id,
               id_conflict_policy: :use_existing,
               timeout: 10_000
             )

    assert existing.workflow_id == first.workflow_id
    assert existing.run_id == first.run_id

    assert :ok = Client.signal_workflow(first, "finish", [], timeout: 10_000)
    assert {:ok, {:finished, :conflict}} = Client.get_result(first, timeout: 30_000)
  end

  defp assert_closed_workflow_reuse(client_name) do
    workflow_id = unique_workflow_id("reuse")

    assert {:ok, first} =
             Client.start_workflow(client_name, CompletedWorkflow, :first,
               workflow_id: workflow_id,
               timeout: 10_000
             )

    assert {:ok, {:completed, :first}} = Client.get_result(first, timeout: 30_000)

    assert {:error,
            %Temporalex.WorkflowAlreadyStartedError{
              operation: :start_workflow,
              workflow_id: ^workflow_id,
              run_id: duplicate_run_id
            }} =
             Client.start_workflow(client_name, CompletedWorkflow, :reject,
               workflow_id: workflow_id,
               id_reuse_policy: :reject_duplicate,
               timeout: 10_000
             )

    assert duplicate_run_id == first.run_id

    assert {:ok, second} =
             Client.start_workflow(client_name, CompletedWorkflow, :second,
               workflow_id: workflow_id,
               id_reuse_policy: :allow_duplicate,
               timeout: 10_000
             )

    assert second.workflow_id == workflow_id
    assert second.run_id != first.run_id
    assert {:ok, {:completed, :second}} = Client.get_result(second, timeout: 30_000)
  end

  defp assert_not_found_errors(client_name) do
    workflow_id = unique_workflow_id("missing")

    handle = %Client.Handle{
      client: client_name,
      workflow_id: workflow_id,
      run_id: nil,
      workflow_type: "MissingWorkflow"
    }

    assert_not_found(:get_result, workflow_id, fn ->
      Client.get_result(handle, timeout: 10_000)
    end)

    assert_not_found(:signal_workflow, workflow_id, fn ->
      Client.signal_workflow(client_name, workflow_id, "missing", [], timeout: 10_000)
    end)

    assert_not_found(:query_workflow, workflow_id, fn ->
      Client.query_workflow(client_name, workflow_id, "state", [], timeout: 10_000)
    end)

    assert_not_found(:update_workflow, workflow_id, fn ->
      Client.update_workflow(client_name, workflow_id, "change", [], timeout: 10_000)
    end)

    assert_not_found(:cancel_workflow, workflow_id, fn ->
      Client.cancel_workflow(client_name, workflow_id, timeout: 10_000)
    end)

    assert_not_found(:terminate_workflow, workflow_id, fn ->
      Client.terminate_workflow(client_name, workflow_id, timeout: 10_000)
    end)

    assert_not_found(:describe_workflow, workflow_id, fn ->
      Client.describe_workflow(client_name, workflow_id, timeout: 10_000)
    end)
  end

  defp assert_query_reject_condition(client_name) do
    completed_id = unique_workflow_id("query-completed")

    assert {:ok, completed} =
             Client.start_workflow(client_name, CompletedWorkflow, :query,
               workflow_id: completed_id,
               timeout: 10_000
             )

    assert {:ok, {:completed, :query}} = Client.get_result(completed, timeout: 30_000)

    assert {:error,
            %Temporalex.QueryRejectedError{
              operation: :query_workflow,
              workflow_id: ^completed_id,
              query_name: "state",
              status: :completed
            }} =
             Client.query_workflow(completed, "state", [],
               reject_condition: :not_open,
               timeout: 10_000
             )

    assert {:ok, {:completed, :query}} =
             Client.query_workflow(completed, "state", [],
               reject_condition: :not_completed_cleanly,
               timeout: 10_000
             )

    failed_id = unique_workflow_id("query-failed")

    assert {:ok, failed} =
             Client.start_workflow(client_name, FailedWorkflow, :query_failed,
               workflow_id: failed_id,
               timeout: 10_000
             )

    assert {:error, %Temporalex.WorkflowFailedError{}} =
             Client.get_result(failed, timeout: 30_000)

    assert {:error,
            %Temporalex.QueryRejectedError{
              operation: :query_workflow,
              workflow_id: ^failed_id,
              query_name: "state",
              status: :failed
            }} =
             Client.query_workflow(failed, "state", [],
               query_reject_condition: :not_completed_cleanly,
               timeout: 10_000
             )
  end

  defp assert_update_rejection(client_name) do
    workflow_id = unique_workflow_id("update-rejected")

    assert {:ok, handle} =
             Client.start_workflow(client_name, GateWorkflow, :update_rejected,
               workflow_id: workflow_id,
               timeout: 10_000
             )

    assert TemporalDevServer.eventually(fn ->
             Client.query_workflow(handle, "state", [], timeout: 10_000) ==
               {:ok, {:waiting, :update_rejected}}
           end)

    assert {:error,
            %Temporalex.UpdateFailedError{
              operation: :update_workflow,
              workflow_id: ^workflow_id,
              update_name: "add",
              cause: %Temporalex.Failure.ApplicationError{} = failure
            }} = Client.update_workflow(handle, "add", [-1], timeout: 15_000)

    assert failure.message == "Temporalex update rejected"
    assert failure.details == [not_accepting_update: "add"]

    assert :ok = Client.signal_workflow(handle, "finish", [], timeout: 10_000)
    assert {:ok, {:finished, :update_rejected}} = Client.get_result(handle, timeout: 30_000)
  end

  defp assert_not_found(operation, workflow_id, fun) do
    assert {:error,
            %Temporalex.WorkflowNotFoundError{
              operation: ^operation,
              workflow_id: ^workflow_id
            }} = fun.()
  end

  defp unique_module(prefix) do
    Module.concat(__MODULE__, :"#{prefix}#{System.unique_integer([:positive])}")
  end

  defp unique_workflow_id(prefix) do
    "temporalex-#{prefix}-#{System.unique_integer([:positive])}"
  end
end
