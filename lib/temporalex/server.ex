defmodule Temporalex.Server do
  @moduledoc """
  Worker server that routes backend work to core executors and activities.

  This process deliberately stays outside deterministic workflow semantics. It
  starts executors, tracks pending activations, runs activities, and submits
  completions through the configured backend.
  """

  use GenServer

  alias Temporalex.Activity.Context, as: ActivityContext
  alias Temporalex.Core.Activation
  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.ActivityTask
  alias Temporalex.Core.Completion
  alias Temporalex.Core.Executor
  alias Temporalex.Core.Job

  defmodule State do
    @moduledoc false

    defstruct name: nil,
              client: nil,
              client_pid: nil,
              client_ref: nil,
              backend: nil,
              backend_state: nil,
              namespace: "default",
              task_queue: "default",
              workflow_safe_mode: :off,
              workflow_map: %{},
              activity_map: %{},
              executor_supervisor: nil,
              activity_supervisor: nil,
              executors: %{},
              executor_refs: %{},
              pending_activations: %{},
              activity_tasks_by_ref: %{},
              activity_refs_by_token: %{}
  end

  def start_link(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    GenServer.start_link(__MODULE__, opts, name: server_name)
  end

  def backend_state(server) do
    GenServer.call(server, :backend_state)
  end

  def record_activity_heartbeat(server, task_token, details) when is_binary(task_token) do
    server
    |> Temporalex.Worker.server_pid()
    |> GenServer.call({:record_activity_heartbeat, task_token, details}, :infinity)
  end

  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @impl GenServer
  def init(opts) do
    client = Keyword.fetch!(opts, :client)

    with {:ok, connection} <- Temporalex.Client.connection(client),
         {:ok, backend_state} <-
           connection.backend.start_worker(connection.backend_state, opts, self()) do
      client_ref = Process.monitor(connection.pid)

      state = %State{
        name: Keyword.fetch!(opts, :name),
        client: client,
        client_pid: connection.pid,
        client_ref: client_ref,
        backend: connection.backend,
        backend_state: backend_state,
        namespace: connection.namespace || "default",
        task_queue: Keyword.get(opts, :task_queue, connection.task_queue || "default"),
        workflow_safe_mode: Keyword.get(opts, :workflow_safe_mode, :off),
        workflow_map: workflow_map(Keyword.get(opts, :workflows, [])),
        activity_map: activity_map(Keyword.get(opts, :activities, [])),
        executor_supervisor: Keyword.fetch!(opts, :executor_supervisor),
        activity_supervisor: Keyword.fetch!(opts, :activity_supervisor)
      }

      {:ok, state}
    else
      {:error, reason} ->
        {:stop, {:backend_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:backend_state, _from, state) do
    {:reply, state.backend_state, state}
  end

  def handle_call({:record_activity_heartbeat, task_token, details}, _from, state) do
    result = state.backend.record_activity_heartbeat(state.backend_state, task_token, details)
    {:reply, result, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info({:workflow_activation, %Activation{} = activation}, state) do
    {:noreply, handle_workflow_activation(activation, state)}
  end

  def handle_info({:activity_task, %ActivityTask{} = task}, state) do
    {:noreply, handle_activity_task(task, state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    {:noreply, handle_activity_result(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.client_ref ->
        {:stop, {:client_down, reason}, state}

      Map.has_key?(state.executor_refs, ref) ->
        {:noreply, handle_executor_down(ref, reason, state)}

      Map.has_key?(state.activity_tasks_by_ref, ref) ->
        {:noreply, handle_activity_down(ref, reason, state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:backend_error, reason}, state) do
    {:stop, {:backend_error, reason}, state}
  end

  def handle_info({:workflow_completion, :ok}, state), do: {:noreply, state}

  def handle_info({:workflow_completion, {:error, reason}}, state) do
    {:stop, {:backend_workflow_completion_failed, reason}, state}
  end

  def handle_info({:activity_completion, :ok}, state), do: {:noreply, state}

  def handle_info({:activity_completion, {:error, reason}}, state) do
    {:stop, {:backend_activity_completion_failed, reason}, state}
  end

  def handle_info({:poll_loop_exited, kind, :shutdown}, state)
      when kind in [:workflow, :activity] do
    {:stop, {:backend_worker_shutdown, {kind, :shutdown}}, state}
  end

  def handle_info({:poll_loop_exited, kind, :crashed}, state)
      when kind in [:workflow, :activity] do
    {:stop, {:backend_error, {:poll_loop_exited, kind, :crashed}}, state}
  end

  def handle_info({:backend_worker_shutdown, reason}, state) do
    {:stop, {:backend_worker_shutdown, reason}, state}
  end

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    if state.client_ref do
      Process.demonitor(state.client_ref, [:flush])
    end

    if state.backend_state do
      state.backend.shutdown_worker(state.backend_state)
    end

    :ok
  end

  defp handle_workflow_activation(%Activation{} = activation, state) do
    cond do
      Map.has_key?(state.pending_activations, activation.run_id) ->
        completion =
          failed_completion(activation.run_id, {:duplicate_activation, activation.run_id})

        submit_workflow_completion(state, completion)

      eviction_only?(activation.jobs) and not Map.has_key?(state.executors, activation.run_id) ->
        completion = %Completion{run_id: activation.run_id, status: {:ok, []}}
        submit_workflow_completion(state, completion)

      true ->
        route_workflow_activation(activation, state)
    end
  end

  defp route_workflow_activation(activation, state) do
    case ensure_executor(activation, state) do
      {:ok, executor, state} ->
        activate_executor(activation, executor, state)

      {:error, reason} ->
        completion = failed_completion(activation.run_id, reason)
        submit_workflow_completion(state, completion)
    end
  end

  defp activate_executor(activation, executor, state) do
    pending = %{
      executor: executor,
      is_replaying: activation.is_replaying,
      started_at: System.monotonic_time(:millisecond)
    }

    state = put_in(state.pending_activations[activation.run_id], pending)

    completion =
      try do
        Executor.activate(executor, activation)
      catch
        :exit, reason -> failed_completion(activation.run_id, {:executor_exit, reason})
        kind, reason -> failed_completion(activation.run_id, {kind, reason})
      end

    state =
      state
      |> update_in([Access.key!(:pending_activations)], &Map.delete(&1, activation.run_id))
      |> submit_workflow_completion(completion)

    if eviction_only?(activation.jobs) do
      remove_executor(activation.run_id, state)
    else
      state
    end
  end

  defp ensure_executor(%Activation{} = activation, state) do
    case Map.fetch(state.executors, activation.run_id) do
      {:ok, executor_info} -> {:ok, executor_info.pid, state}
      :error -> start_executor_from_init(activation, state)
    end
  end

  defp start_executor_from_init(activation, state) do
    case initialize_job(activation.jobs) do
      nil ->
        {:error, {:unknown_workflow_run, activation.run_id}}

      %Job.InitializeWorkflow{workflow_type: workflow_type} ->
        case Map.fetch(state.workflow_map, workflow_type) do
          {:ok, workflow_module} ->
            start_executor(state, activation.run_id, workflow_type, workflow_module)

          :error ->
            {:error, {:unknown_workflow_type, workflow_type}}
        end
    end
  end

  defp start_executor(state, run_id, workflow_type, workflow_module) do
    child = {
      Executor,
      workflow_module: workflow_module, run_id: run_id, safe_mode: state.workflow_safe_mode
    }

    case DynamicSupervisor.start_child(state.executor_supervisor, child) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state =
          state
          |> put_in([Access.key!(:executors), run_id], %{
            pid: pid,
            ref: ref,
            workflow_type: workflow_type
          })
          |> put_in([Access.key!(:executor_refs), ref], run_id)

        {:ok, pid, state}

      {:error, reason} ->
        {:error, {:executor_start_failed, reason}}
    end
  end

  defp handle_executor_down(ref, reason, state) do
    {run_id, executor_refs} = Map.pop(state.executor_refs, ref)
    {executor_info, executors} = Map.pop(state.executors, run_id)
    state = %{state | executor_refs: executor_refs, executors: executors}

    case Map.pop(state.pending_activations, run_id) do
      {nil, pending_activations} ->
        %{state | pending_activations: pending_activations}

      {_pending, pending_activations} ->
        completion = failed_completion(run_id, {:executor_down, reason, executor_info})

        state
        |> Map.put(:pending_activations, pending_activations)
        |> submit_workflow_completion(completion)
    end
  end

  defp remove_executor(run_id, state) do
    case Map.pop(state.executors, run_id) do
      {nil, executors} ->
        %{state | executors: executors}

      {%{pid: pid, ref: ref}, executors} ->
        Process.demonitor(ref, [:flush])
        DynamicSupervisor.terminate_child(state.executor_supervisor, pid)
        %{state | executors: executors, executor_refs: Map.delete(state.executor_refs, ref)}
    end
  end

  defp handle_activity_task(%ActivityTask{variant: :cancel} = task, state) do
    case Map.fetch(state.activity_refs_by_token, task.task_token) do
      {:ok, ref} ->
        %{cancelled: cancelled} = Map.fetch!(state.activity_tasks_by_ref, ref)
        :atomics.put(cancelled, 1, 1)
        state

      :error ->
        completion = %ActivityCompletion{
          task_token: task.task_token,
          result: {:cancelled, task.cancel_reason || :cancelled}
        }

        submit_activity_completion(state, completion)
    end
  end

  defp handle_activity_task(%ActivityTask{variant: :start} = task, state) do
    case Map.fetch(state.activity_map, task.activity_type) do
      {:ok, activity} ->
        cancelled = :atomics.new(1, signed: false)
        context = activity_context(task, state, cancelled)

        task_ref =
          Task.Supervisor.async_nolink(state.activity_supervisor, fn ->
            run_activity(activity, task, context)
          end)

        activity_info = %{
          task: task,
          task_pid: task_ref.pid,
          task_token: task.task_token,
          cancelled: cancelled
        }

        state
        |> put_in([Access.key!(:activity_tasks_by_ref), task_ref.ref], activity_info)
        |> put_in([Access.key!(:activity_refs_by_token), task.task_token], task_ref.ref)

      :error ->
        completion = %ActivityCompletion{
          task_token: task.task_token,
          result:
            {:error,
             %Temporalex.ApplicationError{
               message: "unknown activity type: #{task.activity_type}",
               type: "UnknownActivityType",
               non_retryable: true,
               details: task.activity_type
             }}
        }

        submit_activity_completion(state, completion)
    end
  end

  defp handle_activity_result(ref, result, state) do
    Process.demonitor(ref, [:flush])

    case pop_activity_task(ref, state) do
      {nil, state} ->
        state

      {activity_info, state} ->
        completion = %ActivityCompletion{task_token: activity_info.task_token, result: result}
        submit_activity_completion(state, completion)
    end
  end

  defp handle_activity_down(ref, :normal, state) do
    {_activity_info, state} = pop_activity_task(ref, state)
    state
  end

  defp handle_activity_down(ref, reason, state) do
    case pop_activity_task(ref, state) do
      {nil, state} ->
        state

      {activity_info, state} ->
        completion = %ActivityCompletion{
          task_token: activity_info.task_token,
          result:
            {:error,
             %Temporalex.ApplicationError{
               message: "activity process exited: #{inspect(reason)}",
               type: "ActivityExit",
               non_retryable: false,
               details: reason
             }}
        }

        submit_activity_completion(state, completion)
    end
  end

  defp pop_activity_task(ref, state) do
    {activity_info, activity_tasks_by_ref} = Map.pop(state.activity_tasks_by_ref, ref)

    activity_refs_by_token =
      if activity_info do
        Map.delete(state.activity_refs_by_token, activity_info.task_token)
      else
        state.activity_refs_by_token
      end

    {activity_info,
     %{
       state
       | activity_tasks_by_ref: activity_tasks_by_ref,
         activity_refs_by_token: activity_refs_by_token
     }}
  end

  defp submit_workflow_completion(state, %Completion{} = completion) do
    case state.backend.complete_workflow_activation(state.backend_state, completion) do
      :ok -> state
      {:error, reason} -> raise "backend workflow completion failed: #{inspect(reason)}"
    end
  end

  defp submit_activity_completion(state, %ActivityCompletion{} = completion) do
    case state.backend.complete_activity_task(state.backend_state, completion) do
      :ok -> state
      {:error, reason} -> raise "backend activity completion failed: #{inspect(reason)}"
    end
  end

  defp run_activity(activity, task, context) do
    args =
      if activity.context? do
        [context | task.input]
      else
        task.input
      end

    try do
      case apply(activity.module, activity.implementation, args) do
        {:ok, value} ->
          {:ok, value}

        {:error, %Temporalex.ApplicationError{} = err} ->
          {:error, err}

        {:error, reason} ->
          {:error, application_error_from_reason(reason)}

        other ->
          {:error,
           %Temporalex.ApplicationError{
             message: "activity returned invalid value: #{inspect(other)}",
             type: "InvalidActivityReturn",
             non_retryable: true,
             details: other
           }}
      end
    rescue
      err in Temporalex.ApplicationError ->
        {:error, err}

      error ->
        {:error,
         %Temporalex.ApplicationError{
           message: Exception.message(error),
           type: inspect(error.__struct__),
           non_retryable: false,
           details: %{exception: error, stacktrace: __STACKTRACE__}
         }}
    catch
      :throw, {:cancelled, reason} ->
        {:cancelled,
         %Temporalex.CancelledError{
           message: "activity cancelled",
           details: reason
         }}

      kind, reason ->
        {:error,
         %Temporalex.ApplicationError{
           message: "activity #{kind}: #{inspect(reason)}",
           type: "ActivityExit",
           non_retryable: false,
           details: %{kind: kind, reason: reason, stacktrace: __STACKTRACE__}
         }}
    end
  end

  defp application_error_from_reason(%Temporalex.ApplicationError{} = err), do: err

  defp application_error_from_reason(reason) do
    %Temporalex.ApplicationError{
      message: inspect(reason),
      type: "ApplicationError",
      non_retryable: false,
      details: reason
    }
  end

  defp activity_context(task, state, cancelled) do
    %ActivityContext{
      activity_id: task.activity_id,
      activity_type: task.activity_type,
      task_token: task.task_token,
      workflow_id: task.workflow_id,
      workflow_type: task.workflow_type,
      workflow_namespace: task.namespace || state.namespace,
      run_id: task.run_id,
      task_queue: task.task_queue || state.task_queue,
      attempt: task.attempt,
      heartbeat_timeout: task.heartbeat_timeout,
      is_local: task.is_local,
      worker: state.name,
      cancelled: cancelled,
      cancel_reason: task.cancel_reason
    }
  end

  defp workflow_map(workflows) do
    Map.new(workflows, fn workflow ->
      type =
        if function_exported?(workflow, :__workflow_type__, 0) do
          workflow.__workflow_type__()
        else
          inspect(workflow)
        end

      {type, workflow}
    end)
  end

  defp activity_map(activities) do
    activities
    |> Enum.flat_map(fn activity_module ->
      activity_module.__temporal_activities__()
      |> Enum.map(&activity_entry(activity_module, &1))
    end)
    |> Map.new(fn entry -> {entry.type, entry} end)
  end

  defp activity_entry(module, %{type: type} = metadata) do
    metadata
    |> Map.put(:module, module)
    |> Map.put_new(:context?, false)
    |> Map.put_new(:opts, [])
    |> Map.put(:type, type)
  end

  defp activity_entry(module, {name, opts}) do
    %{
      module: module,
      name: name,
      type: "#{inspect(module)}.#{name}",
      implementation: :"__#{name}__",
      context?: false,
      opts: opts
    }
  end

  defp initialize_job(jobs) do
    Enum.find(jobs, &match?(%Job.InitializeWorkflow{}, &1))
  end

  defp eviction_only?([%Job.RemoveFromCache{} | rest]),
    do: Enum.all?(rest, &match?(%Job.RemoveFromCache{}, &1))

  defp eviction_only?(_jobs), do: false

  defp failed_completion(run_id, reason) do
    %Completion{run_id: run_id, status: {:failed, reason, force_cause: :workflow_task_failed}}
  end
end
