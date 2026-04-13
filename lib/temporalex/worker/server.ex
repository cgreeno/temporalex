defmodule Temporalex.Worker.Server do
  @moduledoc """
  GenServer that owns the Temporal connection and worker.

  Receives push-based messages from NIF poll loops:
  - `{:workflow_activation, bytes}` — decoded and routed to executors
  - `{:activity_task, bytes}` — decoded, activity implementation looked up and spawned

  Activity completions are sent directly to the NIF. Workflow completions
  are handled by executors (production executor comes in next phase).
  """

  use GenServer

  require Logger

  defstruct [
    :config,
    :runtime,
    :client,
    :worker,
    status: :init,
    executors: %{},
    activity_tasks: %{},
    workflow_registry: %{},
    activity_registry: %{}
  ]

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  # --- Init ---

  @impl true
  def init(config) do
    {:ok, %__MODULE__{config: config, status: :connecting}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:ok, runtime} = Temporalex.Runtime.get()

    Logger.info("Connecting to Temporal at #{state.config.url}")

    Temporalex.Native.connect(
      runtime,
      state.config.url,
      state.config.api_key || "",
      state.config.headers,
      self()
    )

    {:noreply, %{state | runtime: runtime}}
  end

  # --- Connection established ---

  @impl true
  def handle_info({:connected, client}, state) do
    Logger.info("Connected to Temporal, starting worker on #{state.config.task_queue}")

    case Temporalex.Native.start_worker(
           state.runtime,
           client,
           state.config.task_queue,
           state.config.namespace,
           state.config.max_cached_workflows,
           self()
         ) do
      {:ok, worker} ->
        Logger.info("Worker started on task queue: #{state.config.task_queue}")

        {:noreply,
         %{
           state
           | client: client,
             worker: worker,
             status: :running,
             workflow_registry: build_workflow_registry(state.config.workflows),
             activity_registry: build_activity_registry(state.config.activities)
         }}

      {:error, reason} ->
        Logger.error("Failed to start worker: #{inspect(reason)}")
        {:stop, {:worker_start_failed, reason}, state}
    end
  end

  def handle_info({:connect_error, reason}, state) do
    Logger.error("Failed to connect to Temporal: #{inspect(reason)}")
    {:stop, {:connect_failed, reason}, state}
  end

  # --- Workflow activations ---

  def handle_info({:workflow_activation, bytes}, state) do
    case Temporalex.Native.decode_workflow_activation(bytes) do
      {:ok, activation} ->
        handle_activation(activation, state)

      {:error, reason} ->
        Logger.error("Failed to decode workflow activation: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # --- Activity tasks ---

  def handle_info({:activity_task, bytes}, state) do
    case Temporalex.Native.decode_activity_task(bytes) do
      {:ok, %{task_token: token, variant: {:start, info}}} ->
        handle_activity_start(token, info, state)

      {:ok, %{task_token: token, variant: {:cancel, info}}} ->
        handle_activity_cancel(token, info, state)

      {:error, reason} ->
        Logger.error("Failed to decode activity task: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # --- Activity task completion (from Task.Supervisor) ---

  # Successful task completion
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.activity_tasks, ref) do
      {%{task_token: token}, remaining} ->
        complete_activity(token, {:completed, Temporalex.Converter.encode(result)}, state)
        {:noreply, %{state | activity_tasks: remaining}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # Task crash / exit / executor crash
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # Check if it's an activity task
    case Map.pop(state.activity_tasks, ref) do
      {%{task_token: token}, remaining} ->
        message = Exception.format(:exit, reason)
        complete_activity(token, {:failed, %{message: message}}, state)
        {:noreply, %{state | activity_tasks: remaining}}

      {nil, _} ->
        # Check if it's an executor
        case Enum.find(state.executors, fn {_run_id, exec_pid} -> exec_pid == pid end) do
          {run_id, _} ->
            Logger.warning("Executor for #{run_id} exited: #{inspect(reason)}")
            {:noreply, %{state | executors: Map.delete(state.executors, run_id)}}

          nil ->
            {:noreply, state}
        end
    end
  end

  # --- Poll loop exits ---

  def handle_info({:poll_loop_exited, _type, :shutdown}, state) do
    {:noreply, state}
  end

  def handle_info({:poll_loop_exited, type, :crashed}, state) do
    Logger.error("Poll loop crashed: #{type}")
    {:stop, {:poll_loop_crashed, type}, state}
  end

  # --- Completion acknowledgments ---

  def handle_info({:workflow_completion, :ok}, state), do: {:noreply, state}

  def handle_info({:workflow_completion, {:error, msg}}, state) do
    Logger.error("Workflow completion failed: #{msg}")
    {:noreply, state}
  end

  def handle_info({:activity_completion, :ok}, state), do: {:noreply, state}

  def handle_info({:activity_completion, {:error, msg}}, state) do
    Logger.error("Activity completion failed: #{msg}")
    {:noreply, state}
  end

  # --- Shutdown ---

  @impl true
  def terminate(_reason, %{worker: worker}) when not is_nil(worker) do
    Temporalex.Native.initiate_shutdown(worker)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private: activation handling ---

  defp handle_activation(%{jobs: jobs} = activation, state) do
    # Check if this is an eviction-only activation
    eviction_only? =
      Enum.all?(jobs, fn
        {:remove_from_cache, _} -> true
        _ -> false
      end)

    if eviction_only? do
      # Handle eviction: stop executor if exists, send empty completion
      case Map.get(state.executors, activation.run_id) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(state.config.executor_supervisor, pid)
      end

      send_workflow_completion(activation.run_id, {:successful, []}, state)
      executors = Map.delete(state.executors, activation.run_id)
      {:noreply, %{state | executors: executors}}
    else
      # Find or create executor for this run_id
      {executor_pid, state} = get_or_create_executor(activation, state)

      # Forward the full activation to the executor
      send(executor_pid, {:activation, activation})

      {:noreply, state}
    end
  end

  defp get_or_create_executor(activation, state) do
    case Map.get(state.executors, activation.run_id) do
      nil ->
        # Find workflow module from initialize_workflow job
        workflow_module = find_workflow_module(activation.jobs, state)

        opts = %{
          server_pid: self(),
          worker: state.worker,
          run_id: activation.run_id,
          task_queue: state.config.task_queue,
          workflow_module: workflow_module
        }

        {:ok, pid} =
          DynamicSupervisor.start_child(
            state.config.executor_supervisor,
            {Temporalex.Worker.Executor, opts}
          )

        Process.monitor(pid)
        executors = Map.put(state.executors, activation.run_id, pid)
        {pid, %{state | executors: executors}}

      pid ->
        {pid, state}
    end
  end

  defp find_workflow_module(jobs, state) do
    Enum.find_value(jobs, fn
      {:initialize_workflow, %{workflow_type: wf_type}} ->
        Map.get(state.workflow_registry, wf_type)

      _ ->
        nil
    end)
  end

  # --- Private: activity handling ---

  defp handle_activity_start(task_token, info, state) do
    case Map.get(state.activity_registry, info.activity_type) do
      nil ->
        Logger.error("Unknown activity type: #{info.activity_type}")

        complete_activity(
          task_token,
          {:failed, %{message: "Unknown activity: #{info.activity_type}"}},
          state
        )

        {:noreply, state}

      {module, function} ->
        args = Temporalex.Converter.decode_args(info.input)

        ctx = %Temporalex.Activity.Context{
          task_token: task_token,
          activity_id: info.activity_id,
          activity_type: info.activity_type,
          attempt: info.attempt,
          workflow_type: info.workflow_type,
          workflow_id: info.workflow_id,
          workflow_namespace: info.workflow_namespace,
          worker: state.worker,
          server_pid: self()
        }

        task =
          Task.Supervisor.async_nolink(
            state.config.activity_supervisor,
            fn ->
              Process.put(:__temporal_activity_context__, ctx)
              apply(module, function, args)
            end
          )

        activity_tasks = Map.put(state.activity_tasks, task.ref, %{task_token: task_token})
        {:noreply, %{state | activity_tasks: activity_tasks}}
    end
  end

  defp handle_activity_cancel(_token, _info, state) do
    # TODO: set atomics flag or kill activity process
    Logger.warning("Activity cancel not yet implemented")
    {:noreply, state}
  end

  # --- Private: completions ---

  defp send_workflow_completion(run_id, status, state) do
    case Temporalex.Native.encode_workflow_completion(run_id, status) do
      {:ok, bytes} ->
        Temporalex.Native.complete_workflow_activation(state.worker, bytes, self())

      {:error, reason} ->
        Logger.error("Failed to encode workflow completion: #{inspect(reason)}")
    end
  end

  defp complete_activity(task_token, result, state) do
    case Temporalex.Native.encode_activity_result(task_token, result) do
      {:ok, bytes} ->
        Temporalex.Native.complete_activity_task(state.worker, bytes, self())

      {:error, reason} ->
        Logger.error("Failed to encode activity result: #{inspect(reason)}")
    end
  end

  # --- Private: registry builders ---

  defp build_workflow_registry(modules) do
    for module <- modules, into: %{} do
      type = module.__temporal_workflow_type__()
      {type, module}
    end
  end

  defp build_activity_registry(modules) do
    for module <- modules,
        {name, _opts} <- module.__temporal_activities__(),
        into: %{} do
      module_str = module |> to_string() |> String.trim_leading("Elixir.")
      type = "#{module_str}.#{name}"
      impl_fn = :"__#{name}__"
      {type, {module, impl_fn}}
    end
  end
end
