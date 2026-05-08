defmodule Temporalex.ClientErrorTest do
  use ExUnit.Case, async: true

  alias Temporalex.Client
  alias Temporalex.Failure

  defmodule ErrorBackend do
    @behaviour Temporalex.Backend

    def start_client(opts, owner_pid) do
      case Keyword.fetch(opts, :start_client_error) do
        {:ok, reason} -> {:error, reason}
        :error -> {:ok, %{owner_pid: owner_pid, reasons: Keyword.get(opts, :reasons, %{})}}
      end
    end

    def shutdown_client(_state), do: :ok
    def start_worker(_client_state, _opts, _owner_pid), do: {:error, :not_used}

    def start_workflow(state, _workflow_type, _input, _opts),
      do: backend_error(state, :start_workflow)

    def get_workflow_result(state, _workflow_id, _run_id, _opts),
      do: backend_error(state, :get_result)

    def signal_workflow(state, _workflow_id, _run_id, _signal_name, _args, _opts),
      do: backend_error(state, :signal_workflow)

    def query_workflow(state, _workflow_id, _run_id, _query_name, _args, _opts),
      do: backend_error(state, :query_workflow)

    def update_workflow(state, _workflow_id, _run_id, _update_name, _args, _opts),
      do: backend_error(state, :update_workflow)

    def cancel_workflow(state, _workflow_id, _run_id, _opts),
      do: backend_error(state, :cancel_workflow)

    def terminate_workflow(state, _workflow_id, _run_id, _opts),
      do: backend_error(state, :terminate_workflow)

    def describe_workflow(state, _workflow_id, _run_id, _opts),
      do: backend_error(state, :describe_workflow)

    def complete_workflow_activation(_worker_state, _completion), do: :ok
    def complete_activity_task(_worker_state, _completion), do: :ok
    def record_activity_heartbeat(_worker_state, _task_token, _details), do: :ok
    def shutdown_worker(_worker_state), do: :ok

    defp backend_error(state, operation) do
      {:error, Map.fetch!(state.reasons, operation)}
    end
  end

  test "missing named client returns a client unavailable error" do
    name = :"MissingClient#{System.unique_integer([:positive])}"

    assert {:error,
            %Temporalex.ClientUnavailableError{
              operation: :connection,
              client: ^name,
              category: :client_not_started,
              reason: ^name
            }} = Client.connection(name)
  end

  test "client start failures return public error structs" do
    trap_exit = Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, trap_exit)
    end)

    assert {:error,
            %Temporalex.TransportError{
              operation: :start_client,
              category: :connect,
              message: "refused"
            }} =
             Client.start_link(
               backend: ErrorBackend,
               start_client_error: {:connect_error, "refused"}
             )
  end

  test "start_workflow maps already-started conflicts to a public error struct" do
    client = start_client!(%{start_workflow: {:already_started, "run-1"}})

    assert {:error,
            %Temporalex.WorkflowAlreadyStartedError{
              operation: :start_workflow,
              workflow_id: "workflow-1",
              workflow_type: "WorkflowType",
              run_id: "run-1"
            }} =
             Client.start_workflow(client, "WorkflowType", :input, workflow_id: "workflow-1")
  end

  test "get_result maps terminal workflow states to public error structs" do
    failure = Failure.application("boom", type: "Boom", details: [1], retryable?: false)

    assert {:error, %Temporalex.WorkflowFailedError{cause: ^failure}} =
             client_with_result({:failed, failure})
             |> Client.get_result()

    assert {:error, %Temporalex.WorkflowCancelledError{details: [:requested]}} =
             client_with_result({:cancelled, [:requested]})
             |> Client.get_result()

    assert {:error, %Temporalex.WorkflowTerminatedError{details: [:manual]}} =
             client_with_result({:terminated, [:manual]})
             |> Client.get_result()

    assert {:error, %Temporalex.WorkflowTimedOutError{operation: :get_result}} =
             client_with_result(:timed_out)
             |> Client.get_result()
  end

  test "query and update failures include operation context" do
    query_client = start_client!(%{query_workflow: {:rejected, :completed}})
    query_handle = handle(query_client)

    assert {:error,
            %Temporalex.QueryRejectedError{
              operation: :query_workflow,
              workflow_id: "workflow-1",
              run_id: "run-1",
              query_name: "state",
              status: :completed
            }} = Client.query_workflow(query_handle, "state")

    failure = Failure.application("invalid", type: "InvalidUpdate")
    update_client = start_client!(%{update_workflow: {:failed, failure}})
    update_handle = handle(update_client)

    assert {:error,
            %Temporalex.UpdateFailedError{
              operation: :update_workflow,
              workflow_id: "workflow-1",
              run_id: "run-1",
              update_name: "change",
              cause: ^failure
            }} = Client.update_workflow(update_handle, "change")
  end

  test "not found and backend transport errors are stable structs" do
    not_found_client = start_client!(%{signal_workflow: :not_found})

    assert {:error,
            %Temporalex.WorkflowNotFoundError{
              operation: :signal_workflow,
              workflow_id: "workflow-1",
              run_id: "run-1"
            }} = Client.signal_workflow(handle(not_found_client), "poke")

    invalid_client = start_client!(%{start_workflow: {:invalid_options, "bad timeout"}})

    assert {:error,
            %Temporalex.TransportError{
              operation: :start_workflow,
              category: :invalid_options,
              message: "bad timeout"
            }} = Client.start_workflow(invalid_client, "WorkflowType", :input)
  end

  defp client_with_result(reason) do
    %{get_result: reason}
    |> start_client!()
    |> handle()
  end

  defp start_client!(reasons) do
    {:ok, pid} = Client.start_link(backend: ErrorBackend, reasons: reasons)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    pid
  end

  defp handle(client) do
    %Client.Handle{
      client: client,
      workflow_id: "workflow-1",
      run_id: "run-1",
      workflow_type: "WorkflowType"
    }
  end
end
