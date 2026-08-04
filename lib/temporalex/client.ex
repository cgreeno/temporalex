defmodule Temporalex.Client do
  @moduledoc """
  Client owner and public API for workflow operations.

  A client owns the backend connection resources. Workflow operations resolve a
  current backend handle from the client process and then call the backend
  directly; the client process is not a request proxy.
  """

  use GenServer

  alias Temporalex.Backend.TemporalCore
  alias Temporalex.Error

  defmodule Connection do
    @moduledoc false

    defstruct [:pid, :backend, :backend_state, :namespace, :task_queue, interceptors: []]
  end

  defmodule State do
    @moduledoc false

    defstruct [
      :backend,
      :backend_state,
      :namespace,
      :task_queue,
      interceptors: []
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

  def connection(%Connection{} = connection), do: connection(connection, :connection)
  def connection(client), do: connection(client, :connection)

  defp connection(%Connection{} = connection, operation) do
    if Process.alive?(connection.pid) do
      {:ok, connection}
    else
      {:error,
       Error.normalize_client_reason({:client_down, :noproc},
         operation: operation,
         client: connection.pid
       )}
    end
  end

  defp connection(client, operation) do
    with {:ok, pid} <- client_pid(client, operation) do
      try do
        GenServer.call(pid, :connection)
      catch
        :exit, reason ->
          {:error,
           Error.normalize_client_reason({:client_down, reason},
             operation: operation,
             client: client
           )}
      end
    end
  end

  @doc """
  Starts a workflow.

  Beyond the usual `:workflow_id`, `:task_queue`, timeouts, `:retry_policy`,
  `:search_attributes`, and `:cron_schedule`, this accepts:

    * `:priority` — task priority and fairness, as a keyword list:

      * `:priority_key` — positive integer, **smaller is higher priority**.
        The server's maximum is configurable and defaults to 5; an unset key
        gets the server default (the midpoint, 3 by default).

      * `:fairness_key` — short string, max 64 bytes, typically a tenant id.
        Tasks sharing a key are dispatched in proportion to their weight, so a
        single noisy tenant cannot monopolise a task queue.

      * `:fairness_weight` — float, clamped server-side to `[0.001, 1000]`,
        default `1.0`.

  Each priority field is optional, and an unset field inherits from the calling
  workflow or falls back to the server default. Omit `:priority` entirely for
  the previous behaviour.

      Temporalex.Client.start_workflow(client, Checkout, order,
        workflow_id: "checkout-\#{order_id}",
        priority: [priority_key: 2, fairness_key: salon_id]
      )

  > #### Server support {: .info}
  >
  > Priority requires a server that records it. Older servers accept the field
  > and silently drop it — `temporalio/auto-setup:1.27` reports
  > `priority: null` in both `describe` and history, including for workflows
  > started by the `temporal` CLI.
  """
  def start_workflow(client, workflow, input, opts \\ []) when is_list(opts) do
    workflow_type = workflow_type(workflow)
    workflow_id = workflow_id_opt(opts)

    with_client_connection(client, :start_workflow, opts, fn %Connection{} = connection, opts ->
      case connection.backend.start_workflow(
             connection.backend_state,
             workflow_type,
             input,
             opts
           ) do
        {:ok, info} ->
          {:ok,
           %Handle{
             client: client,
             workflow_id: Map.fetch!(info, :workflow_id),
             run_id: Map.get(info, :run_id),
             workflow_type: Map.get(info, :workflow_type, workflow_type)
           }}

        {:error, reason} ->
          {:error,
           Error.normalize_client_reason(reason,
             operation: :start_workflow,
             client: client,
             workflow_id: workflow_id,
             workflow_type: workflow_type
           )}
      end
    end)
  end

  def get_result(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, :get_result, opts, fn %Connection{} = connection,
                                                                opts ->
      connection.backend.get_workflow_result(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
      |> normalize_client_result(
        operation: :get_result,
        client: handle.client,
        workflow_id: handle.workflow_id,
        run_id: handle.run_id,
        workflow_type: handle.workflow_type
      )
    end)
  end

  def signal_workflow(%Handle{} = handle, signal_name),
    do: signal_workflow(handle, signal_name, [], [])

  def signal_workflow(%Handle{} = handle, signal_name, args) when is_binary(signal_name),
    do: signal_workflow(handle, signal_name, args, [])

  def signal_workflow(%Handle{} = handle, signal_name, args, opts)
      when is_binary(signal_name) and is_list(opts) do
    with_client_connection(handle.client, :signal_workflow, opts, fn %Connection{} = connection,
                                                                     opts ->
      connection.backend.signal_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        signal_name,
        args,
        opts
      )
      |> normalize_client_result(
        operation: :signal_workflow,
        client: handle.client,
        workflow_id: handle.workflow_id,
        run_id: handle.run_id,
        workflow_type: handle.workflow_type
      )
    end)
  end

  def signal_workflow(client, workflow_id, signal_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(signal_name) and is_list(opts) do
    with_client_connection(client, :signal_workflow, opts, fn %Connection{} = connection, opts ->
      run_id = Keyword.get(opts, :run_id)

      connection.backend.signal_workflow(
        connection.backend_state,
        workflow_id,
        run_id,
        signal_name,
        args,
        opts
      )
      |> normalize_client_result(
        operation: :signal_workflow,
        client: client,
        workflow_id: workflow_id,
        run_id: run_id
      )
    end)
  end

  def query_workflow(%Handle{} = handle, query_name),
    do: query_workflow(handle, query_name, [], [])

  def query_workflow(%Handle{} = handle, query_name, args) when is_binary(query_name),
    do: query_workflow(handle, query_name, args, [])

  def query_workflow(%Handle{} = handle, query_name, args, opts)
      when is_binary(query_name) and is_list(opts) do
    with_client_connection(handle.client, :query_workflow, opts, fn %Connection{} = connection,
                                                                    opts ->
      connection.backend.query_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        query_name,
        args,
        opts
      )
      |> normalize_client_result(
        operation: :query_workflow,
        client: handle.client,
        workflow_id: handle.workflow_id,
        run_id: handle.run_id,
        workflow_type: handle.workflow_type,
        query_name: query_name
      )
    end)
  end

  def query_workflow(client, workflow_id, query_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(query_name) and is_list(opts) do
    with_client_connection(client, :query_workflow, opts, fn %Connection{} = connection, opts ->
      run_id = Keyword.get(opts, :run_id)

      connection.backend.query_workflow(
        connection.backend_state,
        workflow_id,
        run_id,
        query_name,
        args,
        opts
      )
      |> normalize_client_result(
        operation: :query_workflow,
        client: client,
        workflow_id: workflow_id,
        run_id: run_id,
        query_name: query_name
      )
    end)
  end

  def update_workflow(%Handle{} = handle, update_name),
    do: update_workflow(handle, update_name, [], [])

  def update_workflow(%Handle{} = handle, update_name, args) when is_binary(update_name),
    do: update_workflow(handle, update_name, args, [])

  def update_workflow(%Handle{} = handle, update_name, args, opts)
      when is_binary(update_name) and is_list(opts) do
    with_client_connection(handle.client, :update_workflow, opts, fn %Connection{} = connection,
                                                                     opts ->
      connection.backend.update_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        update_name,
        args,
        opts
      )
      |> normalize_client_result(
        operation: :update_workflow,
        client: handle.client,
        workflow_id: handle.workflow_id,
        run_id: handle.run_id,
        workflow_type: handle.workflow_type,
        update_name: update_name
      )
    end)
  end

  def update_workflow(client, workflow_id, update_name, args, opts \\ [])
      when is_binary(workflow_id) and is_binary(update_name) and is_list(opts) do
    with_client_connection(client, :update_workflow, opts, fn %Connection{} = connection, opts ->
      run_id = Keyword.get(opts, :run_id)

      connection.backend.update_workflow(
        connection.backend_state,
        workflow_id,
        run_id,
        update_name,
        args,
        opts
      )
      |> normalize_client_result(
        operation: :update_workflow,
        client: client,
        workflow_id: workflow_id,
        run_id: run_id,
        update_name: update_name
      )
    end)
  end

  def cancel_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, :cancel_workflow, opts, fn %Connection{} = connection,
                                                                     opts ->
      connection.backend.cancel_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
      |> normalize_client_result(
        operation: :cancel_workflow,
        client: handle.client,
        workflow_id: handle.workflow_id,
        run_id: handle.run_id,
        workflow_type: handle.workflow_type
      )
    end)
  end

  def cancel_workflow(client, workflow_id, opts) when is_binary(workflow_id) and is_list(opts) do
    with_client_connection(client, :cancel_workflow, opts, fn %Connection{} = connection, opts ->
      run_id = Keyword.get(opts, :run_id)

      connection.backend.cancel_workflow(
        connection.backend_state,
        workflow_id,
        run_id,
        opts
      )
      |> normalize_client_result(
        operation: :cancel_workflow,
        client: client,
        workflow_id: workflow_id,
        run_id: run_id
      )
    end)
  end

  def terminate_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, :terminate_workflow, opts, fn %Connection{} = connection,
                                                                        opts ->
      connection.backend.terminate_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
      |> normalize_client_result(
        operation: :terminate_workflow,
        client: handle.client,
        workflow_id: handle.workflow_id,
        run_id: handle.run_id,
        workflow_type: handle.workflow_type
      )
    end)
  end

  def terminate_workflow(client, workflow_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    with_client_connection(client, :terminate_workflow, opts, fn %Connection{} = connection,
                                                                 opts ->
      run_id = Keyword.get(opts, :run_id)

      connection.backend.terminate_workflow(
        connection.backend_state,
        workflow_id,
        run_id,
        opts
      )
      |> normalize_client_result(
        operation: :terminate_workflow,
        client: client,
        workflow_id: workflow_id,
        run_id: run_id
      )
    end)
  end

  def describe_workflow(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, :describe_workflow, opts, fn %Connection{} = connection,
                                                                       opts ->
      connection.backend.describe_workflow(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
      |> normalize_client_result(
        operation: :describe_workflow,
        client: handle.client,
        workflow_id: handle.workflow_id,
        run_id: handle.run_id,
        workflow_type: handle.workflow_type
      )
    end)
  end

  def describe_workflow(client, workflow_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    with_client_connection(client, :describe_workflow, opts, fn %Connection{} = connection,
                                                                opts ->
      run_id = Keyword.get(opts, :run_id)

      connection.backend.describe_workflow(
        connection.backend_state,
        workflow_id,
        run_id,
        opts
      )
      |> normalize_client_result(
        operation: :describe_workflow,
        client: client,
        workflow_id: workflow_id,
        run_id: run_id
      )
    end)
  end

  @doc """
  Fetches a workflow's history as an opaque binary.

  Feed the result to `Temporalex.Replay` to check current workflow code against
  a real execution, or write it to a file as a replay fixture. Treat it as
  opaque — it is encoded protobuf, and parsing it in application code would put
  backend transport detail somewhere it does not belong.
  """
  def fetch_workflow_history(%Handle{} = handle, opts \\ []) when is_list(opts) do
    with_client_connection(handle.client, :fetch_workflow_history, opts, fn %Connection{} =
                                                                              connection,
                                                                            opts ->
      connection.backend.fetch_workflow_history(
        connection.backend_state,
        handle.workflow_id,
        handle.run_id,
        opts
      )
      |> normalize_client_result(
        operation: :fetch_workflow_history,
        client: handle.client,
        workflow_id: handle.workflow_id,
        run_id: handle.run_id,
        workflow_type: handle.workflow_type
      )
    end)
  end

  def fetch_workflow_history(client, workflow_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    with_client_connection(client, :fetch_workflow_history, opts, fn %Connection{} = connection,
                                                                     opts ->
      run_id = Keyword.get(opts, :run_id)

      connection.backend.fetch_workflow_history(
        connection.backend_state,
        workflow_id,
        run_id,
        opts
      )
      |> normalize_client_result(
        operation: :fetch_workflow_history,
        client: client,
        workflow_id: workflow_id,
        run_id: run_id
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
           task_queue: Keyword.get(opts, :task_queue, @default_task_queue),
           interceptors: interceptors(opts)
         }}

      {:error, reason} ->
        {:stop, Error.normalize_client_reason(reason, operation: :start_client)}
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
        task_queue: state.task_queue,
        interceptors: state.interceptors
      }}, state}
  end

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    state.backend.shutdown_client(state.backend_state)
    :ok
  end

  # Validated at client start so a bad interceptor is a startup error rather than
  # a crash on the first operation, long after the config was written.
  defp interceptors(opts) do
    opts
    |> Keyword.get(:interceptors, [])
    |> List.wrap()
    |> Enum.map(&validate_interceptor/1)
  end

  defp validate_interceptor(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :intercept, 3) do
      raise ArgumentError,
            "#{inspect(module)} is not a Temporalex.Interceptor: it does not export intercept/3"
    end

    module
  end

  defp validate_interceptor(other) do
    raise ArgumentError,
          "expected an interceptor module, got: #{inspect(other)}"
  end

  defp with_client_connection(client, operation, opts, fun) when is_function(fun, 2) do
    with {:ok, %Connection{} = connection} <- connection(client, operation) do
      monitor_ref = Process.monitor(connection.pid)

      try do
        if Process.alive?(connection.pid) do
          context = %Temporalex.Interceptor.Context{operation: operation, client: client}

          result =
            Temporalex.Interceptor.run(connection.interceptors, context, opts, fn opts ->
              # Stamped inside the innermost closure so interceptors never see it.
              # It is an internal `receive` pattern in the backend: dropping it
              # disables client-down detection (the caller then blocks for the
              # full timeout), and corrupting it raises from a private function
              # after the operation has already been issued.
              fun.(connection, Keyword.put(opts, :client_monitor, {connection.pid, monitor_ref}))
            end)

          case result do
            {:error, %{__struct__: Temporalex.ClientUnavailableError}} ->
              result

            {:error, {:client_down, reason}} ->
              {:error,
               Error.normalize_client_reason({:client_down, reason},
                 operation: operation,
                 client: client
               )}

            _ ->
              if Process.alive?(connection.pid) do
                result
              else
                {:error,
                 Error.normalize_client_reason({:client_down, :shutdown},
                   operation: operation,
                   client: client
                 )}
              end
          end
        else
          {:error,
           Error.normalize_client_reason({:client_down, :noproc},
             operation: operation,
             client: client
           )}
        end
      after
        Process.demonitor(monitor_ref, [:flush])
      end
    end
  end

  defp client_pid(pid, _operation) when is_pid(pid), do: {:ok, pid}

  defp client_pid(name, operation) do
    case GenServer.whereis(name) do
      nil ->
        {:error,
         Error.normalize_client_reason({:client_not_started, name},
           operation: operation,
           client: name
         )}

      pid ->
        {:ok, pid}
    end
  end

  defp normalize_client_result({:error, reason}, opts),
    do: {:error, Error.normalize_client_reason(reason, opts)}

  defp normalize_client_result(result, _opts), do: result

  defp workflow_id_opt(opts) do
    Keyword.get_lazy(opts, :workflow_id, fn -> Keyword.get(opts, :id) end)
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
