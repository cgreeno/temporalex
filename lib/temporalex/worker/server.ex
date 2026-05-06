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
    if Map.get(config, :skip_connect) do
      # Test seam: skip the connect/start_worker flow entirely. The server
      # sits idle in :running so test code can drive handle_info paths
      # (DOWN, activations, etc.) without a Temporal server.
      {:ok, %__MODULE__{config: config, status: :running}}
    else
      {:ok, %__MODULE__{config: config, status: :connecting}, {:continue, :connect}}
    end
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

  # --- Test-only handle_call ---

  # Monitor every pid currently in state.executors. Used by tests that
  # inject fake executor pids via :sys.replace_state — only available
  # when the :skip_connect config flag is set.
  @impl true
  def handle_call(:__test_monitor_executor__, _from, state) do
    if Map.get(state.config, :skip_connect) do
      Enum.each(state.executors, fn {_run_id, pid} -> Process.monitor(pid) end)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_in_test_mode}, state}
    end
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
            # Fail the workflow task on Temporal's side so it can retry
            # (replay against fresh executor) instead of waiting for the
            # task timeout. Best-effort — if encoding/sending fails we
            # already logged.
            fail_workflow_task(run_id, fail_message_for(reason), state)
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

  # Shut the worker down and wait for it to drain (poll loops finish, in-flight
  # activations complete). Without the wait, Tokio tasks can be ripped while
  # mid-completion — and worse, Core can panic on a non-empty completion sent
  # to a run that's already been evicted by the shutdown. Bounded by
  # the timeout so a buggy worker can't block BEAM termination.
  @default_shutdown_timeout_ms 30_000

  @impl true
  def terminate(_reason, %{worker: worker} = state) when not is_nil(worker) do
    timeout = Map.get(state.config, :shutdown_timeout_ms, @default_shutdown_timeout_ms)
    await_worker_shutdown(worker, state, timeout)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp await_worker_shutdown(worker, state, timeout) do
    # Reuse the same test pid for both completion and shutdown seams.
    test_pid = Map.get(state.config, :completion_to)

    if is_pid(test_pid) do
      send(test_pid, {:server_shutdown_initiated, worker})
    else
      # Async NIF — sends {:shutdown_complete, :ok} when Core's drain is done.
      Temporalex.Native.shutdown_worker(worker, self())
    end

    receive do
      {:shutdown_complete, :ok} -> :ok
    after
      timeout ->
        Logger.error("Worker shutdown timed out after #{timeout}ms — forcing exit")
        :timeout
    end
  end

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

        cancel_ref = Temporalex.Activity.Context.new_cancel_ref()

        ctx = %Temporalex.Activity.Context{
          task_token: task_token,
          activity_id: info.activity_id,
          activity_type: info.activity_type,
          attempt: info.attempt,
          workflow_type: info.workflow_type,
          workflow_id: info.workflow_id,
          workflow_namespace: info.workflow_namespace,
          worker: state.worker,
          server_pid: self(),
          cancel_ref: cancel_ref
        }

        task =
          Task.Supervisor.async_nolink(
            state.config.activity_supervisor,
            fn ->
              Process.put(:__temporal_activity_context__, ctx)
              apply(module, function, args)
            end
          )

        activity_tasks =
          Map.put(state.activity_tasks, task.ref, %{
            task_token: task_token,
            cancel_ref: cancel_ref,
            pid: task.pid
          })

        {:noreply, %{state | activity_tasks: activity_tasks}}
    end
  end

  defp handle_activity_cancel(token, _info, state) do
    # Find the activity task by token and set its cancel flag
    case Enum.find(state.activity_tasks, fn {_ref, info} -> info.task_token == token end) do
      {_ref, %{cancel_ref: cancel_ref, pid: pid}} ->
        Temporalex.Activity.Context.set_cancelled(cancel_ref)
        # For activities that don't heartbeat, kill the process
        Process.exit(pid, :shutdown)
        {:noreply, state}

      nil ->
        Logger.warning("Cancel for unknown activity task")
        {:noreply, state}
    end
  end

  # --- Private: completions ---

  defp send_workflow_completion(run_id, status, state) do
    test_pid = Map.get(state.config, :completion_to)

    cond do
      is_pid(test_pid) ->
        send(test_pid, {:server_completion, run_id, status})

      is_nil(state.worker) ->
        # Pre-connect path: nothing we can usefully do.
        Logger.warning(
          "Cannot send workflow completion for #{run_id}: worker not yet initialized"
        )

      true ->
        case Temporalex.Native.encode_workflow_completion(run_id, status) do
          {:ok, bytes} ->
            Temporalex.Native.complete_workflow_activation(state.worker, bytes, self())

          {:error, reason} ->
            Logger.error("Failed to encode workflow completion: #{inspect(reason)}")
        end
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

  # When an executor process dies mid-activation, fail the workflow task on
  # Temporal's side so it can be retried promptly instead of waiting for the
  # workflow-task timeout. Best-effort: if encoding/sending fails we log and
  # let the timeout take over.
  defp fail_workflow_task(run_id, message, state) do
    send_workflow_completion(run_id, {:failed, %{message: message}}, state)
  end

  @doc false
  # Format the executor-exit reason into a short human-readable message for
  # the workflow-task failure. Public-with-@doc-false so the test can call it
  # without spinning up a full server. Keep the output bounded — failure
  # messages are persisted in workflow history.
  def fail_message_for(:normal), do: "executor exited normally without completing activation"
  def fail_message_for(:shutdown), do: "executor shutdown before completing activation"
  def fail_message_for({:shutdown, _}), do: "executor shutdown before completing activation"

  def fail_message_for(reason) do
    formatted = reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 500)
    "executor crashed: #{formatted}"
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
