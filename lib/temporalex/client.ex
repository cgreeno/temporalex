defmodule Temporalex.Client do
  @moduledoc """
  Client owner and public API for workflow operations.

  A client owns the backend connection resources. Workflow operations resolve a
  current backend handle from the client process and then call the backend
  directly; the client process is not a request proxy.
  """

  use GenServer

  alias Temporalex.Backend.TemporalCore

  defmodule Connection do
    @moduledoc false

    defstruct [:pid, :backend, :backend_state, :namespace, :task_queue]
  end

  defmodule State do
    @moduledoc false

    defstruct [
      :backend,
      :backend_state,
      :namespace,
      :task_queue
    ]
  end

  defmodule Handle do
    @moduledoc """
    Handle for a started workflow execution.
    """

    defstruct [:client, :workflow_id, :run_id, :workflow_type]
  end

  @default_namespace "default"
  @default_task_queue "default"

  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def connection(%Connection{} = connection) do
    if Process.alive?(connection.pid) do
      {:ok, connection}
    else
      {:error, {:client_down, :noproc}}
    end
  end

  def connection(client) do
    with {:ok, pid} <- client_pid(client) do
      try do
        GenServer.call(pid, :connection)
      catch
        :exit, reason -> {:error, {:client_down, reason}}
      end
    end
  end

  def start_workflow(client, workflow, input, opts \\ []) when is_list(opts) do
    workflow_type = workflow_type(workflow)

    with_client_connection(client, opts, fn %Connection{} = connection, opts ->
      with {:ok, info} <-
             connection.backend.start_workflow(
               connection.backend_state,
               workflow_type,
               input,
               opts
             ) do
        {:ok,
         %Handle{
           client: client,
           workflow_id: Map.fetch!(info, :workflow_id),
           run_id: Map.get(info, :run_id),
           workflow_type: Map.get(info, :workflow_type, workflow_type)
         }}
      end
    end)
  end

  def get_result(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, opts, fn %Connection{} = connection, opts ->
      connection.backend.get_workflow_result(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
    end)
  end

  def signal_workflow(%Handle{} = handle, signal_name),
    do: signal_workflow(handle, signal_name, [], [])

  def signal_workflow(%Handle{} = handle, signal_name, args) when is_binary(signal_name),
    do: signal_workflow(handle, signal_name, args, [])

  def signal_workflow(%Handle{} = handle, signal_name, args, opts)
      when is_binary(signal_name) and is_list(opts) do
    with_client_connection(handle.client, opts, fn %Connection{} = connection, opts ->
      connection.backend.signal_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        signal_name,
        args,
        opts
      )
    end)
  end

  def signal_workflow(client, workflow_id, signal_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(signal_name) and is_list(opts) do
    with_client_connection(client, opts, fn %Connection{} = connection, opts ->
      connection.backend.signal_workflow(
        connection.backend_state,
        workflow_id,
        Keyword.get(opts, :run_id),
        signal_name,
        args,
        opts
      )
    end)
  end

  def query_workflow(%Handle{} = handle, query_name),
    do: query_workflow(handle, query_name, [], [])

  def query_workflow(%Handle{} = handle, query_name, args) when is_binary(query_name),
    do: query_workflow(handle, query_name, args, [])

  def query_workflow(%Handle{} = handle, query_name, args, opts)
      when is_binary(query_name) and is_list(opts) do
    with_client_connection(handle.client, opts, fn %Connection{} = connection, opts ->
      connection.backend.query_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        query_name,
        args,
        opts
      )
    end)
  end

  def query_workflow(client, workflow_id, query_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(query_name) and is_list(opts) do
    with_client_connection(client, opts, fn %Connection{} = connection, opts ->
      connection.backend.query_workflow(
        connection.backend_state,
        workflow_id,
        Keyword.get(opts, :run_id),
        query_name,
        args,
        opts
      )
    end)
  end

  def update_workflow(%Handle{} = handle, update_name),
    do: update_workflow(handle, update_name, [], [])

  def update_workflow(%Handle{} = handle, update_name, args) when is_binary(update_name),
    do: update_workflow(handle, update_name, args, [])

  def update_workflow(%Handle{} = handle, update_name, args, opts)
      when is_binary(update_name) and is_list(opts) do
    with_client_connection(handle.client, opts, fn %Connection{} = connection, opts ->
      connection.backend.update_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        update_name,
        args,
        opts
      )
    end)
  end

  def update_workflow(client, workflow_id, update_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(update_name) and is_list(opts) do
    with_client_connection(client, opts, fn %Connection{} = connection, opts ->
      connection.backend.update_workflow(
        connection.backend_state,
        workflow_id,
        Keyword.get(opts, :run_id),
        update_name,
        args,
        opts
      )
    end)
  end

  def cancel_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, opts, fn %Connection{} = connection, opts ->
      connection.backend.cancel_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
    end)
  end

  def cancel_workflow(client, workflow_id, opts) when is_binary(workflow_id) and is_list(opts) do
    with_client_connection(client, opts, fn %Connection{} = connection, opts ->
      connection.backend.cancel_workflow(
        connection.backend_state,
        workflow_id,
        Keyword.get(opts, :run_id),
        opts
      )
    end)
  end

  def terminate_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, opts, fn %Connection{} = connection, opts ->
      connection.backend.terminate_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
    end)
  end

  def terminate_workflow(client, workflow_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    with_client_connection(client, opts, fn %Connection{} = connection, opts ->
      connection.backend.terminate_workflow(
        connection.backend_state,
        workflow_id,
        Keyword.get(opts, :run_id),
        opts
      )
    end)
  end

  def describe_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, opts, fn %Connection{} = connection, opts ->
      connection.backend.describe_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
    end)
  end

  def describe_workflow(client, workflow_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    with_client_connection(client, opts, fn %Connection{} = connection, opts ->
      connection.backend.describe_workflow(
        connection.backend_state,
        workflow_id,
        Keyword.get(opts, :run_id),
        opts
      )
    end)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    backend = Keyword.get(opts, :backend, TemporalCore)

    case backend.start_client(opts, self()) do
      {:ok, backend_state} ->
        {:ok,
         %State{
           backend: backend,
           backend_state: backend_state,
           namespace: Keyword.get(opts, :namespace, @default_namespace),
           task_queue: Keyword.get(opts, :task_queue, @default_task_queue)
         }}

      {:error, reason} ->
        {:stop, {:backend_client_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:connection, _from, %State{} = state) do
    {:reply,
     {:ok,
      %Connection{
        pid: self(),
        backend: state.backend,
        backend_state: state.backend_state,
        namespace: state.namespace,
        task_queue: state.task_queue
      }}, state}
  end

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    state.backend.shutdown_client(state.backend_state)
    :ok
  end

  defp with_client_connection(client, opts, fun) when is_function(fun, 2) do
    with {:ok, %Connection{} = connection} <- connection(client) do
      monitor_ref = Process.monitor(connection.pid)

      try do
        if Process.alive?(connection.pid) do
          opts = Keyword.put(opts, :client_monitor, {connection.pid, monitor_ref})
          result = fun.(connection, opts)

          case result do
            {:error, {:client_down, _reason}} ->
              result

            _ ->
              if Process.alive?(connection.pid) do
                result
              else
                {:error, {:client_down, :shutdown}}
              end
          end
        else
          {:error, {:client_down, :noproc}}
        end
      after
        Process.demonitor(monitor_ref, [:flush])
      end
    end
  end

  defp client_pid(pid) when is_pid(pid), do: {:ok, pid}

  defp client_pid(name) do
    case GenServer.whereis(name) do
      nil -> {:error, {:client_not_started, name}}
      pid -> {:ok, pid}
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
