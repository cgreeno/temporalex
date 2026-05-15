defmodule Temporalex.Client do
  @moduledoc """
  Client API for workflow operations through a running `Temporalex.Worker`.

  This implementation is backed by the worker's Temporal Core connection. Native
  resources stay inside `Temporalex.Backend.TemporalCore`; callers use Elixir terms
  and workflow handles.
  """

  alias Temporalex.Backend.TemporalCore

  defmodule Handle do
    @moduledoc """
    Handle for a started workflow execution.
    """

    defstruct [:worker, :workflow_id, :run_id, :workflow_type]
  end

  def start_workflow(worker, workflow, input, opts \\ []) when is_list(opts) do
    with {:ok, server} <- server_pid(worker),
         {:ok, state} <- temporal_core_state(server),
         workflow_type <- workflow_type(workflow),
         {:ok, info} <- TemporalCore.start_workflow(state, workflow_type, input, opts) do
      {:ok,
       %Handle{
         worker: worker,
         workflow_id: Map.fetch!(info, :workflow_id),
         run_id: Map.get(info, :run_id),
         workflow_type: Map.get(info, :workflow_type, workflow_type)
       }}
    end
  end

  def get_result(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with {:ok, server} <- server_pid(handle.worker),
         {:ok, state} <- temporal_core_state(server) do
      TemporalCore.get_workflow_result(state, handle.workflow_id, handle.run_id, opts)
    end
  end

  def signal_workflow(%Handle{} = handle, signal_name),
    do: signal_workflow(handle, signal_name, [], [])

  def signal_workflow(%Handle{} = handle, signal_name, args) when is_binary(signal_name),
    do: signal_workflow(handle, signal_name, args, [])

  def signal_workflow(%Handle{} = handle, signal_name, args, opts)
      when is_binary(signal_name) and is_list(opts) do
    with {:ok, state} <- state_for_worker(handle.worker) do
      TemporalCore.signal_workflow(
        state,
        handle.workflow_id,
        handle.run_id,
        signal_name,
        args,
        opts
      )
    end
  end

  def signal_workflow(worker, workflow_id, signal_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(signal_name) and is_list(opts) do
    with {:ok, state} <- state_for_worker(worker) do
      TemporalCore.signal_workflow(
        state,
        workflow_id,
        Keyword.get(opts, :run_id),
        signal_name,
        args,
        opts
      )
    end
  end

  def query_workflow(%Handle{} = handle, query_name),
    do: query_workflow(handle, query_name, [], [])

  def query_workflow(%Handle{} = handle, query_name, args) when is_binary(query_name),
    do: query_workflow(handle, query_name, args, [])

  def query_workflow(%Handle{} = handle, query_name, args, opts)
      when is_binary(query_name) and is_list(opts) do
    with {:ok, state} <- state_for_worker(handle.worker) do
      TemporalCore.query_workflow(
        state,
        handle.workflow_id,
        handle.run_id,
        query_name,
        args,
        opts
      )
    end
  end

  def query_workflow(worker, workflow_id, query_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(query_name) and is_list(opts) do
    with {:ok, state} <- state_for_worker(worker) do
      TemporalCore.query_workflow(
        state,
        workflow_id,
        Keyword.get(opts, :run_id),
        query_name,
        args,
        opts
      )
    end
  end

  def update_workflow(%Handle{} = handle, update_name),
    do: update_workflow(handle, update_name, [], [])

  def update_workflow(%Handle{} = handle, update_name, args) when is_binary(update_name),
    do: update_workflow(handle, update_name, args, [])

  def update_workflow(%Handle{} = handle, update_name, args, opts)
      when is_binary(update_name) and is_list(opts) do
    with {:ok, state} <- state_for_worker(handle.worker) do
      TemporalCore.update_workflow(
        state,
        handle.workflow_id,
        handle.run_id,
        update_name,
        args,
        opts
      )
    end
  end

  def update_workflow(worker, workflow_id, update_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(update_name) and is_list(opts) do
    with {:ok, state} <- state_for_worker(worker) do
      TemporalCore.update_workflow(
        state,
        workflow_id,
        Keyword.get(opts, :run_id),
        update_name,
        args,
        opts
      )
    end
  end

  def cancel_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with {:ok, state} <- state_for_worker(handle.worker) do
      TemporalCore.cancel_workflow(state, handle.workflow_id, handle.run_id, opts)
    end
  end

  def cancel_workflow(worker, workflow_id, opts) when is_binary(workflow_id) and is_list(opts) do
    with {:ok, state} <- state_for_worker(worker) do
      TemporalCore.cancel_workflow(state, workflow_id, Keyword.get(opts, :run_id), opts)
    end
  end

  def terminate_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with {:ok, state} <- state_for_worker(handle.worker) do
      TemporalCore.terminate_workflow(state, handle.workflow_id, handle.run_id, opts)
    end
  end

  def terminate_workflow(worker, workflow_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    with {:ok, state} <- state_for_worker(worker) do
      TemporalCore.terminate_workflow(state, workflow_id, Keyword.get(opts, :run_id), opts)
    end
  end

  def describe_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with {:ok, state} <- state_for_worker(handle.worker) do
      TemporalCore.describe_workflow(state, handle.workflow_id, handle.run_id, opts)
    end
  end

  def describe_workflow(worker, workflow_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    with {:ok, state} <- state_for_worker(worker) do
      TemporalCore.describe_workflow(state, workflow_id, Keyword.get(opts, :run_id), opts)
    end
  end

  defp server_pid(worker) do
    case Temporalex.Worker.server_pid(worker) do
      nil -> {:error, {:worker_not_started, worker}}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp state_for_worker(worker) do
    with {:ok, server} <- server_pid(worker) do
      temporal_core_state(server)
    end
  end

  defp temporal_core_state(server) do
    case Temporalex.Server.backend_state(server) do
      %TemporalCore.State{} = state -> {:ok, state}
      other -> {:error, {:unsupported_backend, other}}
    end
  end

  defp workflow_type(workflow_type) when is_binary(workflow_type), do: workflow_type

  defp workflow_type(workflow_module) when is_atom(workflow_module) do
    if function_exported?(workflow_module, :__workflow_type__, 0) do
      workflow_module.__workflow_type__()
    else
      inspect(workflow_module)
    end
  end
end
