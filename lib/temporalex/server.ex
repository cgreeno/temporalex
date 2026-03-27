defmodule Temporalex.Server do
  @moduledoc """
  Long-running GenServer that connects to Temporal and drives workflow execution.

  Add it to your supervision tree:

      children = [
        {Temporalex.Server,
          task_queue: "orders",
          workflows: [{"ProcessOrder", &MyApp.Orders.process_order/1}],
          activities: [MyApp.Orders]}
      ]

  Multiple servers on different task queues:

      children = [
        {Temporalex.Server,
          name: MyApp.OrdersWorker,
          task_queue: "orders",
          workflows: [...], activities: [...]},
        {Temporalex.Server,
          name: MyApp.EmailsWorker,
          task_queue: "emails",
          workflows: [...], activities: [...]}
      ]

  ## Options

    * `:task_queue` (required) — Temporal task queue to poll
    * `:workflows` — list of `{"TypeName", &Mod.fun/1}` tuples
    * `:activities` — list of modules that `use Temporalex.DSL`
    * `:name` — process name (defaults to `{Temporalex.Server, task_queue}`)
    * `:address` — Temporal server address (default: `"http://localhost:7233"`)
    * `:namespace` — Temporal namespace (default: `"default"`)
    * `:connection` — use a shared `Temporalex.Connection` instead of address/namespace
    * `:max_concurrent_workflow_tasks` — max parallel workflow tasks (default: 5)
    * `:max_concurrent_activity_tasks` — max parallel activities (default: 5)
  """
  use GenServer
  require Logger

  alias Coresdk.WorkflowActivation.WorkflowActivation
  alias Coresdk.WorkflowCompletion.WorkflowActivationCompletion
  alias Coresdk.ActivityTask.ActivityTask
  alias Coresdk.ActivityResult.ActivityExecutionResult
  alias Temporalex.WorkflowTaskExecutor

  defstruct [
    :runtime,
    :client,
    :worker,
    :task_queue,
    :namespace,
    :activity_supervisor,
    workflow_map: %{},
    activity_map: %{},
    executors: %{},
    activity_tasks: %{},
    # Activations waiting for executor output before completion can be sent
    pending_activations: %{},
    # Track the last run_id sent for completion (logging only, not authoritative)
    last_completing_run_id: nil,
    poll_failures: 0,
    stats: %{activations: 0, completions: 0, activities: 0, errors: 0}
  ]

  @default_max_concurrent_wf_tasks 5
  @default_max_concurrent_activity_tasks 5
  @validate_timeout 10_000
  @shutdown_timeout 30_000
  @workflow_timeout 60_000
  @max_poll_failures 5
  @base_backoff_ms 1_000
  @max_backoff_ms 30_000

  # --- Public API ---

  def child_spec(opts) do
    task_queue =
      opts[:task_queue] ||
        raise ArgumentError,
              "Temporalex.Server requires :task_queue option (e.g., task_queue: \"my-queue\")"

    %{
      id: {__MODULE__, task_queue},
      start: {__MODULE__, :start_link, [opts]},
      shutdown: @shutdown_timeout + 5_000,
      restart: :permanent
    }
  end

  def start_link(opts) do
    server_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    task_queue =
      opts[:task_queue] ||
        raise ArgumentError,
              "Temporalex.Server requires :task_queue option (e.g., task_queue: \"my-queue\")"

    workflows = Keyword.get(opts, :workflows, [])
    activities = Keyword.get(opts, :activities, [])
    max_wf = Keyword.get(opts, :max_concurrent_workflow_tasks, @default_max_concurrent_wf_tasks)

    max_act =
      Keyword.get(opts, :max_concurrent_activity_tasks, @default_max_concurrent_activity_tasks)

    validate_positive_integer!(:max_concurrent_workflow_tasks, max_wf)
    validate_positive_integer!(:max_concurrent_activity_tasks, max_act)

    workflow_map = build_workflow_map(workflows)
    activity_map = build_activity_map(activities)

    Logger.info("Server starting",
      task_queue: task_queue,
      workflows: Map.keys(workflow_map),
      activities: Map.keys(activity_map)
    )

    {runtime, client, namespace} = resolve_connection(opts)

    {:ok, worker} =
      Temporalex.Native.create_worker(runtime, client, task_queue, namespace, max_wf, max_act)

    validate_worker(worker)

    {:ok, activity_sup} = Task.Supervisor.start_link()

    state = %__MODULE__{
      runtime: runtime,
      client: client,
      worker: worker,
      task_queue: task_queue,
      namespace: namespace,
      workflow_map: workflow_map,
      activity_map: activity_map,
      activity_supervisor: activity_sup
    }

    Logger.info("Server ready", task_queue: task_queue)

    poll_workflow(state)
    poll_activity(state)

    {:ok, state}
  end

  # ============================================================
  # Workflow poll/complete cycle
  # ============================================================

  defp poll_workflow(state), do: Temporalex.Native.poll_workflow_activation(state.worker, self())
  defp poll_activity(state), do: Temporalex.Native.poll_activity_task(state.worker, self())

  @impl true
  def handle_info({:workflow_activation, bytes}, state) when is_binary(bytes) do
    activation = WorkflowActivation.decode(bytes)

    Logger.debug("Activation received",
      run_id: activation.run_id,
      jobs: Enum.map(activation.jobs, fn j -> elem(j.variant, 0) end)
    )

    case dispatch_activation(activation, state) do
      {:complete, commands, state} ->
        send_completion(activation, commands, state)

      {:pending, inline_cmds, state} ->
        timer_ref =
          Process.send_after(self(), {:executor_timeout, activation.run_id}, @workflow_timeout)

        pending = %{
          activation: activation,
          inline_commands: inline_cmds,
          activation_start: System.monotonic_time(),
          timeout_ref: timer_ref
        }

        state = %{
          state
          | pending_activations: Map.put(state.pending_activations, activation.run_id, pending)
        }

        {:noreply, state}
    end
  end

  def handle_info({:workflow_completion, :ok}, state) do
    Logger.debug("Completion accepted", run_id: state.last_completing_run_id)
    state = %{state | last_completing_run_id: nil, poll_failures: 0} |> update_stat(:completions)
    poll_workflow(state)
    {:noreply, state}
  end

  def handle_info({:workflow_completion, {:error, msg}}, state) do
    Logger.error("Completion rejected", error: msg, run_id: state.last_completing_run_id)
    state = %{state | last_completing_run_id: nil} |> update_stat(:errors)
    poll_workflow(state)
    {:noreply, state}
  end

  # ============================================================
  # Executor output — build and send the activation completion
  # ============================================================

  def handle_info({:executor_commands, run_id, commands, wf_state, status}, state) do
    case Map.pop(state.pending_activations, run_id) do
      {nil, _} ->
        Logger.warning("Executor commands for unknown activation", run_id: run_id)
        {:noreply, state}

      {pending, remaining} ->
        Process.cancel_timer(pending.timeout_ref, info: false)
        state = %{state | pending_activations: remaining}

        # Update executor workflow state
        state = update_executor(state, run_id, fn info -> %{info | workflow_state: wf_state} end)

        # Handle :done — telemetry + remove executor
        state =
          if status == :done do
            emit_executor_done_telemetry(state, run_id, commands)
            remove_executor(state, run_id)
          else
            state
          end

        all_commands = pending.inline_commands ++ commands
        send_completion(pending.activation, all_commands, state, pending.activation_start)
    end
  end

  # ============================================================
  # Executor timeout — no response within @workflow_timeout
  # ============================================================

  def handle_info({:executor_timeout, run_id}, state) do
    case Map.pop(state.pending_activations, run_id) do
      {nil, _} ->
        {:noreply, state}

      {pending, remaining} ->
        Logger.error("Executor timed out", run_id: run_id)
        state = %{state | pending_activations: remaining}

        emit_timeout_telemetry(state, run_id)

        state = stop_executor(state, run_id)
        commands = pending.inline_commands ++ [fail_command("Workflow execution timed out")]
        send_completion(pending.activation, commands, state, pending.activation_start)
    end
  end

  # ============================================================
  # Executor GenServer crashed
  # ============================================================

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_executor_by_ref(state, ref) do
      {_run_id, _info} when reason in [:normal, :shutdown, :killed] ->
        {:noreply, state}

      {run_id, _info} ->
        Logger.error("Executor crashed", run_id: run_id, reason: inspect(reason))
        state = %{state | executors: Map.delete(state.executors, run_id)}

        # If there's a pending activation, complete it with failure
        case Map.pop(state.pending_activations, run_id) do
          {nil, _} ->
            {:noreply, state}

          {pending, remaining} ->
            Process.cancel_timer(pending.timeout_ref, info: false)
            state = %{state | pending_activations: remaining}

            commands =
              pending.inline_commands ++ [fail_command("Executor crashed: #{inspect(reason)}")]

            send_completion(pending.activation, commands, state, pending.activation_start)
        end

      nil ->
        # Check activity tasks
        case find_activity_by_ref(state, ref) do
          {task_ref, {task_token, activity_type, _pid}} ->
            Logger.error("Activity task crashed",
              activity_type: activity_type,
              reason: inspect(reason)
            )

            result = %ActivityExecutionResult{
              status:
                {:failed,
                 %Coresdk.ActivityResult.Failure{
                   failure: %Temporal.Api.Failure.V1.Failure{
                     message: "Activity crashed: #{inspect(reason)}"
                   }
                 }}
            }

            send_activity_completion(state, task_token, result)
            {:noreply, %{state | activity_tasks: Map.delete(state.activity_tasks, task_ref)}}

          nil ->
            {:noreply, state}
        end
    end
  end

  # ============================================================
  # Activity poll/complete cycle
  # ============================================================

  def handle_info({:activity_task, bytes}, state) when is_binary(bytes) do
    task = ActivityTask.decode(bytes)

    case task.variant do
      {:start, start} ->
        Logger.debug("Activity task received",
          activity_type: start.activity_type,
          activity_id: start.activity_id
        )

        state = spawn_activity(start, task.task_token, state)
        {:noreply, state}

      {:cancel, cancel} ->
        Logger.info("Activity cancel received", reason: inspect(cancel.reason))

        case find_activity_by_token(state, task.task_token) do
          {ref, {_token, activity_type, pid}} ->
            Logger.info("Cancelling activity task", activity_type: activity_type)
            Process.demonitor(ref, [:flush])
            Process.exit(pid, :kill)

            cancelled_result = %ActivityExecutionResult{
              status:
                {:cancelled,
                 %Coresdk.ActivityResult.Cancellation{
                   failure: %Temporal.Api.Failure.V1.Failure{
                     message: "Activity cancelled"
                   }
                 }}
            }

            send_activity_completion(state, task.task_token, cancelled_result)
            {:noreply, %{state | activity_tasks: Map.delete(state.activity_tasks, ref)}}

          nil ->
            {:noreply, state}
        end
    end
  end

  # Activity heartbeat from activity code
  def handle_info({:activity_heartbeat, task_token, details_bytes}, state) do
    Temporalex.Native.record_activity_heartbeat(state.worker, task_token, details_bytes)
    {:noreply, state}
  end

  # Activity task completed (Task.Supervisor sends {ref, result})
  def handle_info({ref, {task_token, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if Map.has_key?(state.activity_tasks, ref) do
      send_activity_completion(state, task_token, result)
      {:noreply, %{state | activity_tasks: Map.delete(state.activity_tasks, ref)}}
    else
      # Stale result — activity was already cancelled/cleaned up, discard
      Logger.debug("Discarding stale activity result", task_token_len: byte_size(task_token))
      {:noreply, state}
    end
  end

  def handle_info({:activity_completion, :ok}, state) do
    state = update_stat(state, :activities)
    poll_activity(state)
    {:noreply, state}
  end

  def handle_info({:activity_completion, {:error, msg}}, state) do
    Logger.error("Activity completion rejected", error: msg)
    state = update_stat(state, :errors)
    poll_activity(state)
    {:noreply, state}
  end

  # ============================================================
  # Shutdown
  # ============================================================

  def handle_info({:error, :shutdown}, state) do
    Logger.info("Poll returned shutdown", task_queue: state.task_queue)
    {:stop, :normal, state}
  end

  def handle_info({:shutdown_complete, :ok}, state), do: {:noreply, state}

  def handle_info({:error, reason}, state) do
    failures = state.poll_failures + 1

    if failures >= @max_poll_failures do
      Logger.error("Poll error — max retries exceeded, stopping",
        error: inspect(reason),
        failures: failures,
        task_queue: state.task_queue
      )

      {:stop, {:error, reason}, state}
    else
      backoff = poll_backoff_ms(failures)

      Logger.warning("Poll error — retrying after backoff",
        error: inspect(reason),
        failures: failures,
        backoff_ms: backoff,
        task_queue: state.task_queue
      )

      Process.send_after(self(), :retry_polls, backoff)
      {:noreply, %{state | poll_failures: failures}}
    end
  end

  def handle_info(:retry_polls, state) do
    Logger.info("Retrying polls after backoff", task_queue: state.task_queue)
    poll_workflow(state)
    poll_activity(state)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Unexpected message", message: inspect(msg, limit: 500))
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Server terminating",
      task_queue: state.task_queue,
      reason: inspect(reason),
      executors: map_size(state.executors),
      activities: map_size(state.activity_tasks)
    )

    # 1. Tell NIF to stop accepting new poll results
    Temporalex.Native.initiate_shutdown(state.worker)

    # 2. Cancel in-flight activity tasks and send completions so Rust can drain
    for {ref, {task_token, activity_type, _pid}} <- state.activity_tasks do
      Logger.info("Cancelling in-flight activity", activity_type: activity_type)
      Process.demonitor(ref, [:flush])

      cancelled_result = %Coresdk.ActivityResult.ActivityExecutionResult{
        status:
          {:failed,
           %Coresdk.ActivityResult.Failure{
             failure: %Temporal.Api.Failure.V1.Failure{message: "Server shutting down"}
           }}
      }

      send_activity_completion(state, task_token, cancelled_result)
    end

    # Stop the activity supervisor (kills remaining task processes)
    if state.activity_supervisor && Process.alive?(state.activity_supervisor) do
      Supervisor.stop(state.activity_supervisor, :shutdown)
    end

    # 3. Stop executors concurrently
    executor_pids =
      for {_run_id, %{pid: pid}} <- state.executors,
          pid != nil and Process.alive?(pid),
          do: pid

    if executor_pids != [] do
      Logger.info("Stopping executors",
        count: length(executor_pids),
        task_queue: state.task_queue
      )

      tasks =
        Enum.map(executor_pids, fn pid ->
          Task.async(fn ->
            try do
              GenServer.stop(pid, :shutdown, 5_000)
            catch
              :exit, _ -> :ok
            end
          end)
        end)

      Task.await_many(tasks, 10_000)
    end

    # 4. Drain the NIF worker (waits for Rust-side cleanup)
    Temporalex.Native.shutdown_worker(state.worker, self())

    # 5. Wait for shutdown, draining stale poll messages that arrive during teardown
    drain_until_shutdown(@shutdown_timeout)

    :ok
  end

  defp drain_until_shutdown(remaining) when remaining <= 0 do
    Logger.warning("Server shutdown timed out")
  end

  defp drain_until_shutdown(remaining) do
    start = System.monotonic_time(:millisecond)

    receive do
      {:shutdown_complete, :ok} ->
        Logger.info("Server drained")

      {:workflow_activation, _} ->
        # Stale poll result after initiate_shutdown — discard
        drain_until_shutdown(remaining - elapsed(start))

      {:workflow_completion, _} ->
        drain_until_shutdown(remaining - elapsed(start))

      {:activity_task, _} ->
        drain_until_shutdown(remaining - elapsed(start))

      {:activity_completion, _} ->
        drain_until_shutdown(remaining - elapsed(start))

      {:error, :shutdown} ->
        # Poll loop shut down — expected, keep waiting for shutdown_complete
        drain_until_shutdown(remaining - elapsed(start))

      {:error, _} ->
        drain_until_shutdown(remaining - elapsed(start))

      {ref, _} when is_reference(ref) ->
        # Activity task result — discard
        Process.demonitor(ref, [:flush])
        drain_until_shutdown(remaining - elapsed(start))
    after
      min(remaining, 1_000) ->
        drain_until_shutdown(remaining - elapsed(start))
    end
  end

  defp elapsed(start), do: System.monotonic_time(:millisecond) - start

  # ============================================================
  # Activation processing
  # ============================================================

  defp dispatch_activation(activation, state) do
    jobs = categorize_jobs(activation.jobs)

    # Evictions — remove executor
    state = handle_evictions(jobs.others, activation, state)

    # Patches — forward to existing executor
    deliver_patches(jobs.patches, activation, state)

    # Init — spawn executor with replay results from same activation
    {init_dispatched?, init_cmds, state} =
      dispatch_init(jobs.inits, activation, jobs.resolves, jobs.timers, jobs.patches, state)

    # Resolutions for continuing workflows (not consumed by init)
    {res_dispatched?, resolution_cmds, state} =
      if init_dispatched? do
        {false, [], state}
      else
        dispatch_resolutions(jobs.resolves, jobs.timers, jobs.signals, activation, state)
      end

    # Queries (inline, no executor interaction)
    query_cmds = handle_queries(jobs.queries, activation, state)

    # Updates (not yet supported — reject explicitly)
    update_cmds = reject_updates(jobs.updates)

    # Cancel and misc
    {misc_cmds, state} = handle_misc(jobs.others, activation, state)

    inline_cmds = init_cmds ++ resolution_cmds ++ query_cmds ++ update_cmds ++ misc_cmds

    if init_dispatched? or res_dispatched? do
      {:pending, inline_cmds, state}
    else
      {:complete, inline_cmds, state}
    end
  end

  # ============================================================
  # Job categorization
  # ============================================================

  defp categorize_jobs(jobs) do
    Enum.reduce(
      jobs,
      %{
        inits: [],
        resolves: [],
        timers: [],
        signals: [],
        queries: [],
        patches: [],
        updates: [],
        others: []
      },
      fn job, acc ->
        case job.variant do
          {:initialize_workflow, j} -> %{acc | inits: [j | acc.inits]}
          {:resolve_activity, j} -> %{acc | resolves: [j | acc.resolves]}
          {:fire_timer, j} -> %{acc | timers: [j | acc.timers]}
          {:signal_workflow, j} -> %{acc | signals: [j | acc.signals]}
          {:query_workflow, j} -> %{acc | queries: [j | acc.queries]}
          {:notify_has_patch, j} -> %{acc | patches: [j | acc.patches]}
          {:do_update, j} -> %{acc | updates: [j | acc.updates]}
          _ -> %{acc | others: [job | acc.others]}
        end
      end
    )
  end

  # ============================================================
  # Initialize workflow — spawn executor
  # ============================================================

  defp dispatch_init([], _activation, _resolves, _timers, _patches, state),
    do: {false, [], state}

  defp dispatch_init([init | _], activation, resolve_jobs, timer_jobs, patches, state) do
    workflow_type = init.workflow_type

    case Map.get(state.workflow_map, workflow_type) do
      nil ->
        registered = Map.keys(state.workflow_map) |> Enum.join(", ")

        Logger.error("Unknown workflow type",
          workflow_type: workflow_type,
          registered_types: registered
        )

        {false,
         [
           fail_command(
             "Unknown workflow type: #{workflow_type}. Registered types: [#{registered}]"
           )
         ], state}

      {run_fn, workflow_module} ->
        case decode_arguments(init.arguments) do
          {:error, reason} ->
            {false,
             [
               fail_command(
                 "Failed to decode workflow arguments for #{workflow_type}: #{inspect(reason)}"
               )
             ], state}

          args ->
            replay_results = extract_replay_results(resolve_jobs, timer_jobs)
            patch_ids = MapSet.new(patches, fn p -> p.patch_id end)

            workflow_info = %{
              workflow_id: init.workflow_id,
              run_id: activation.run_id,
              workflow_type: workflow_type,
              task_queue: state.task_queue,
              namespace: state.namespace,
              attempt: init.attempt
            }

            Temporalex.Telemetry.workflow_start(%{
              workflow_id: init.workflow_id,
              workflow_type: workflow_type,
              run_id: activation.run_id,
              task_queue: state.task_queue
            })

            {:ok, executor_pid} =
              WorkflowTaskExecutor.start(
                server_pid: self(),
                run_id: activation.run_id,
                task_queue: state.task_queue,
                run_fn: run_fn,
                replay_results: replay_results,
                workflow_info: workflow_info
              )

            ref = Process.monitor(executor_pid)

            state = %{
              state
              | executors:
                  Map.put(state.executors, activation.run_id, %{
                    pid: executor_pid,
                    monitor_ref: ref,
                    workflow_state: nil,
                    workflow_type: workflow_type,
                    workflow_module: workflow_module,
                    workflow_id: init.workflow_id,
                    telemetry_start: System.monotonic_time()
                  })
            }

            send(executor_pid, {:start, args, [patches: patch_ids]})

            {true, [], state}
        end
    end
  end

  # ============================================================
  # Resolutions — deliver to executor, collect output
  # ============================================================

  defp dispatch_resolutions(resolves, timers, signals, activation, state) do
    if resolves == [] and timers == [] and signals == [] do
      {false, [], state}
    else
      case Map.get(state.executors, activation.run_id) do
        nil ->
          Logger.warning("Resolution for unknown workflow", run_id: activation.run_id)
          {false, [], state}

        %{pid: pid} ->
          # Deliver signals
          for signal <- signals do
            case decode_arguments(signal.input) do
              {:error, reason} ->
                Logger.warning("Failed to decode signal",
                  signal: signal.signal_name,
                  reason: inspect(reason)
                )

              payload ->
                send(pid, {:signal, signal.signal_name, payload})
            end
          end

          # Deliver activity results
          for resolve <- resolves do
            result = extract_activity_result(resolve)
            send(pid, {:resolve_activity, resolve.seq, result})
          end

          # Deliver timer fires
          for fire <- timers do
            send(pid, {:fire_timer, fire.seq})
          end

          # Executor will send {:executor_commands, ...} when ready
          {true, [], state}
      end
    end
  end

  # ============================================================
  # Patches — forward to executor
  # ============================================================

  defp deliver_patches([], _activation, _state), do: :ok

  defp deliver_patches(patches, activation, state) do
    case Map.get(state.executors, activation.run_id) do
      nil ->
        :ok

      %{pid: pid} ->
        for patch <- patches do
          send(pid, {:notify_has_patch, patch.patch_id})
        end
    end
  end

  # ============================================================
  # Queries — inline, no executor interaction
  # ============================================================

  defp handle_queries([], _activation, _state), do: []

  defp handle_queries(queries, activation, state) do
    Enum.flat_map(queries, fn query ->
      case Map.get(state.executors, activation.run_id) do
        nil ->
          [query_fail_command(query.query_id, "Workflow not found")]

        info ->
          case decode_arguments(query.arguments) do
            {:error, reason} ->
              [query_fail_command(query.query_id, "Bad query args: #{inspect(reason)}")]

            args ->
              dispatch_query(query, args, info)
          end
      end
    end)
  end

  defp dispatch_query(query, args, info) do
    module = info.workflow_module

    if module && function_exported?(module, :handle_query, 3) do
      try do
        case module.handle_query(query.query_type, args, info.workflow_state) do
          {:reply, result} ->
            [query_success_command(query.query_id, result)]

          other ->
            [query_fail_command(query.query_id, "Bad handle_query return: #{inspect(other)}")]
        end
      rescue
        e ->
          [query_fail_command(query.query_id, "Query handler crashed: #{Exception.message(e)}")]
      end
    else
      [query_success_command(query.query_id, info.workflow_state)]
    end
  end

  # ============================================================
  # Updates — not yet supported, reject explicitly
  # ============================================================

  defp reject_updates([]), do: []

  defp reject_updates(updates) do
    Enum.map(updates, fn update ->
      Logger.warning("Workflow updates not yet supported, rejecting",
        update_name: update.name,
        protocol_instance_id: update.protocol_instance_id
      )

      %Coresdk.WorkflowCommands.WorkflowCommand{
        variant:
          {:update_response,
           %Coresdk.WorkflowCommands.UpdateResponse{
             protocol_instance_id: update.protocol_instance_id,
             response:
               {:rejected,
                %Temporal.Api.Failure.V1.Failure{
                  message: "Workflow updates are not yet supported in Temporalex v0.1"
                }}
           }}
      }
    end)
  end

  # ============================================================
  # Evictions & misc
  # ============================================================

  defp handle_evictions(jobs, activation, state) do
    Enum.reduce(jobs, state, fn job, st ->
      case job.variant do
        {:remove_from_cache, _} ->
          Logger.debug("Eviction", run_id: activation.run_id)
          stop_executor(st, activation.run_id)

        _ ->
          st
      end
    end)
  end

  defp handle_misc(jobs, activation, state) do
    Enum.reduce(jobs, {[], state}, fn job, {cmds, st} ->
      case job.variant do
        {:cancel_workflow, _} ->
          case Map.get(st.executors, activation.run_id) do
            %{pid: pid} -> send(pid, {:cancel_workflow})
            _ -> :ok
          end

          st = stop_executor(st, activation.run_id)
          {cmds ++ [cancel_command()], st}

        {:remove_from_cache, _} ->
          # Already handled in handle_evictions
          {cmds, st}

        {type, _} ->
          Logger.debug("Unhandled job type", type: type)
          {cmds, st}

        _ ->
          {cmds, st}
      end
    end)
  end

  # ============================================================
  # Completion helpers
  # ============================================================

  defp send_completion(activation, commands, state, activation_start \\ nil) do
    completion = %WorkflowActivationCompletion{
      run_id: activation.run_id,
      status: {:successful, %Coresdk.WorkflowCompletion.Success{commands: commands}}
    }

    completion_bytes = Protobuf.encode(completion)
    Temporalex.Native.complete_workflow_activation(state.worker, completion_bytes, self())

    duration =
      if activation_start,
        do: System.monotonic_time() - activation_start,
        else: 0

    Temporalex.Telemetry.worker_activation(duration, %{
      run_id: activation.run_id,
      task_queue: state.task_queue,
      job_count: length(activation.jobs),
      command_count: length(commands)
    })

    state = %{state | last_completing_run_id: activation.run_id}
    state = update_stat(state, :activations)
    {:noreply, state}
  end

  defp emit_executor_done_telemetry(state, run_id, commands) do
    case Map.get(state.executors, run_id) do
      %{telemetry_start: start_time, workflow_type: wf_type, workflow_id: wf_id}
      when start_time != nil ->
        result = classify_commands(commands)

        Temporalex.Telemetry.workflow_stop(start_time, %{
          workflow_id: wf_id,
          workflow_type: wf_type,
          run_id: run_id,
          result: result
        })

      _ ->
        :ok
    end
  end

  defp emit_timeout_telemetry(state, run_id) do
    case Map.get(state.executors, run_id) do
      %{telemetry_start: start_time, workflow_type: wf_type, workflow_id: wf_id}
      when start_time != nil ->
        Temporalex.Telemetry.workflow_exception(start_time, %{
          workflow_id: wf_id,
          workflow_type: wf_type,
          run_id: run_id,
          kind: :error,
          reason: :timeout
        })

      _ ->
        :ok
    end
  end

  # ============================================================
  # Executor lifecycle
  # ============================================================

  defp stop_executor(state, run_id) do
    case Map.get(state.executors, run_id) do
      nil ->
        state

      %{pid: pid, monitor_ref: ref} ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :shutdown, 5_000)
          catch
            :exit, _ -> :ok
          end
        end

        if ref, do: Process.demonitor(ref, [:flush])
        %{state | executors: Map.delete(state.executors, run_id)}
    end
  end

  defp remove_executor(state, run_id) do
    case Map.get(state.executors, run_id) do
      nil ->
        state

      %{monitor_ref: ref} ->
        if ref, do: Process.demonitor(ref, [:flush])
        %{state | executors: Map.delete(state.executors, run_id)}
    end
  end

  defp update_executor(state, run_id, fun) do
    case Map.get(state.executors, run_id) do
      nil -> state
      info -> %{state | executors: Map.put(state.executors, run_id, fun.(info))}
    end
  end

  defp find_executor_by_ref(state, ref) do
    Enum.find(state.executors, fn {_run_id, info} -> info.monitor_ref == ref end)
  end

  # ============================================================
  # Activity execution
  # ============================================================

  defp spawn_activity(start, task_token, state) do
    activity_type = start.activity_type

    case Map.get(state.activity_map, activity_type) do
      nil ->
        registered = Map.keys(state.activity_map) |> Enum.join(", ")

        Logger.error("Unknown activity type",
          activity_type: activity_type,
          registered_types: registered
        )

        msg = "Unknown activity type: #{activity_type}. Registered types: [#{registered}]"

        result = %ActivityExecutionResult{
          status:
            {:failed,
             %Coresdk.ActivityResult.Failure{
               failure: %Temporal.Api.Failure.V1.Failure{message: msg}
             }}
        }

        send_activity_completion(state, task_token, result)
        state

      {module, impl_fn} ->
        case decode_arguments(start.input) do
          {:error, reason} ->
            result = %ActivityExecutionResult{
              status:
                {:failed,
                 %Coresdk.ActivityResult.Failure{
                   failure: %Temporal.Api.Failure.V1.Failure{
                     message:
                       "Failed to decode arguments for activity #{activity_type}: #{inspect(reason)}"
                   }
                 }}
            }

            send_activity_completion(state, task_token, result)
            state

          args ->
            activity_ctx =
              Temporalex.Activity.Context.from_start(start,
                task_token: task_token,
                task_queue: state.task_queue,
                worker_pid: self()
              )

            task =
              Task.Supervisor.async_nolink(state.activity_supervisor, fn ->
                start_time =
                  Temporalex.Telemetry.activity_start(%{
                    activity_type: activity_type,
                    activity_id: start.activity_id,
                    task_queue: state.task_queue
                  })

                result = execute_activity(module, impl_fn, args, activity_ctx)

                activity_result =
                  case result do
                    %{status: {:completed, _}} -> :ok
                    _ -> :error
                  end

                Temporalex.Telemetry.activity_stop(start_time, %{
                  activity_type: activity_type,
                  activity_id: start.activity_id,
                  result: activity_result
                })

                {task_token, result}
              end)

            %{
              state
              | activity_tasks:
                  Map.put(state.activity_tasks, task.ref, {task_token, activity_type, task.pid})
            }
        end
    end
  end

  defp execute_activity(module, :__server_legacy_activity__, args, ctx) do
    execute_activity_result(fn -> module.perform(ctx, args) end)
  end

  defp execute_activity(module, impl_fn, args, _ctx) do
    execute_activity_result(fn -> apply(module, impl_fn, [args]) end)
  end

  defp execute_activity_result(fun) do
    try do
      case fun.() do
        {:ok, value} ->
          payload = Temporalex.Converter.to_payload(value)

          %ActivityExecutionResult{
            status: {:completed, %Coresdk.ActivityResult.Success{result: payload}}
          }

        {:error, reason} ->
          %ActivityExecutionResult{
            status:
              {:failed,
               %Coresdk.ActivityResult.Failure{
                 failure: %Temporal.Api.Failure.V1.Failure{message: to_string(reason)}
               }}
          }

        other ->
          %ActivityExecutionResult{
            status:
              {:failed,
               %Coresdk.ActivityResult.Failure{
                 failure: %Temporal.Api.Failure.V1.Failure{
                   message: "Unexpected return: #{inspect(other)}"
                 }
               }}
          }
      end
    rescue
      e ->
        %ActivityExecutionResult{
          status:
            {:failed,
             %Coresdk.ActivityResult.Failure{
               failure: %Temporal.Api.Failure.V1.Failure{
                 message: "Activity crashed: #{Exception.message(e)}"
               }
             }}
        }
    end
  end

  defp send_activity_completion(state, task_token, result) do
    completion = %Coresdk.ActivityTaskCompletion{task_token: task_token, result: result}
    completion_bytes = Protobuf.encode(completion)
    Temporalex.Native.complete_activity_task(state.worker, completion_bytes, self())
  end

  # ============================================================
  # Command builders
  # ============================================================

  defp fail_command(message) do
    %Coresdk.WorkflowCommands.WorkflowCommand{
      variant:
        {:fail_workflow_execution,
         %Coresdk.WorkflowCommands.FailWorkflowExecution{
           failure: %Temporal.Api.Failure.V1.Failure{message: message}
         }}
    }
  end

  defp cancel_command do
    %Coresdk.WorkflowCommands.WorkflowCommand{
      variant: {:cancel_workflow_execution, %Coresdk.WorkflowCommands.CancelWorkflowExecution{}}
    }
  end

  defp query_success_command(query_id, result) do
    payload = Temporalex.Converter.to_payload(result)

    %Coresdk.WorkflowCommands.WorkflowCommand{
      variant:
        {:respond_to_query,
         %Coresdk.WorkflowCommands.QueryResult{
           query_id: query_id,
           variant: {:succeeded, %Coresdk.WorkflowCommands.QuerySuccess{response: payload}}
         }}
    }
  end

  defp query_fail_command(query_id, message) do
    %Coresdk.WorkflowCommands.WorkflowCommand{
      variant:
        {:respond_to_query,
         %Coresdk.WorkflowCommands.QueryResult{
           query_id: query_id,
           variant: {:failed, %Temporal.Api.Failure.V1.Failure{message: message}}
         }}
    }
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp extract_activity_result(resolve) do
    case resolve.result do
      %{status: {:completed, %{result: payload}}} when not is_nil(payload) ->
        case Temporalex.Converter.from_payload(payload) do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end

      %{status: {:completed, _}} ->
        {:ok, nil}

      %{status: {:failed, failure}} ->
        if failure.failure do
          {:error, Temporalex.FailureConverter.from_failure(failure.failure)}
        else
          {:error, %Temporalex.Error.ActivityFailure{message: "unknown failure"}}
        end

      %{status: {:cancelled, _}} ->
        {:error, %Temporalex.Error.CancelledError{message: "activity cancelled"}}

      other ->
        {:error, %Temporalex.Error.ApplicationError{message: "unexpected: #{inspect(other)}"}}
    end
  end

  defp extract_replay_results(resolve_jobs, timer_jobs) do
    resolves = Map.new(resolve_jobs, fn r -> {r.seq, {:activity, extract_activity_result(r)}} end)
    timers = Map.new(timer_jobs, fn t -> {t.seq, {:timer, :ok}} end)
    Map.merge(resolves, timers)
  end

  defp build_workflow_map(workflows) do
    workflows
    |> Enum.flat_map(fn
      {name, fun} when is_binary(name) and is_function(fun, 1) ->
        [{name, {fun, nil}}]

      mod when is_atom(mod) ->
        unless Code.ensure_loaded?(mod) do
          raise ArgumentError,
                "Workflow module #{inspect(mod)} could not be loaded. " <>
                  "Check that the module exists and is compiled."
        end

        unless function_exported?(mod, :run, 1) do
          raise ArgumentError,
                "Workflow module #{inspect(mod)} does not export run/1. " <>
                  "Add `use Temporalex.Workflow` and define `def run(args)`."
        end

        [{mod.__workflow_type__(), {fn args -> mod.run(args) end, mod}}]

      other ->
        raise ArgumentError,
              "Invalid workflow spec: #{inspect(other)}. " <>
                "Expected a module or {\"TypeName\", &Mod.fun/1} tuple."
    end)
    |> Map.new()
  end

  defp build_activity_map(modules) do
    modules
    |> Enum.flat_map(fn mod ->
      unless Code.ensure_loaded?(mod) do
        raise ArgumentError,
              "Activity module #{inspect(mod)} could not be loaded. " <>
                "Check that the module exists and is compiled."
      end

      if function_exported?(mod, :__temporal_activities__, 0) do
        for {name, _opts} <- mod.__temporal_activities__() do
          type = Temporalex.DSL.activity_type_string(mod, name)
          impl_fn = :"__temporal_perform_#{name}__"

          unless function_exported?(mod, impl_fn, 1) do
            raise ArgumentError,
                  "Activity #{inspect(mod)}.#{name} is registered but #{impl_fn}/1 is not defined. " <>
                    "This is a bug in the module's defactivity macro."
          end

          {type, {mod, impl_fn}}
        end
      else
        unless function_exported?(mod, :__activity_type__, 0) do
          raise ArgumentError,
                "Activity module #{inspect(mod)} is not a valid activity. " <>
                  "Add `use Temporalex.Activity` or `use Temporalex.DSL`."
        end

        type = mod.__activity_type__()
        [{type, {mod, :__server_legacy_activity__}}]
      end
    end)
    |> Map.new()
  end

  defp decode_arguments([]), do: nil

  defp decode_arguments(payloads) when is_list(payloads) do
    case Temporalex.Converter.from_payloads(payloads, keys: :strings) do
      {:ok, [single]} -> single
      {:ok, multiple} -> multiple
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_arguments(other), do: {:error, {:unexpected_format, other}}

  defp find_activity_by_ref(state, ref) do
    Enum.find(state.activity_tasks, fn {task_ref, _} -> task_ref == ref end)
  end

  defp find_activity_by_token(state, token) do
    Enum.find(state.activity_tasks, fn {_ref, {task_token, _, _}} -> task_token == token end)
  end

  defp validate_worker(worker) do
    Temporalex.Native.validate_worker(worker, self())

    receive do
      {:validate_result, :ok} -> Logger.info("Worker validation succeeded")
      {:validate_result, {:error, reason}} -> Logger.warning("Validation failed", error: reason)
    after
      @validate_timeout -> Logger.warning("Validation timed out")
    end
  end

  defp resolve_connection(opts) do
    case Keyword.get(opts, :connection) do
      nil ->
        address = Keyword.get(opts, :address, "http://localhost:7233")
        namespace = Keyword.get(opts, :namespace, "default")
        api_key = Keyword.get(opts, :api_key, "")
        headers = Keyword.get(opts, :headers, [])
        {:ok, runtime} = Temporalex.Native.create_runtime()
        {:ok, client} = Temporalex.Native.connect_client(runtime, address, api_key, headers)
        {runtime, client, namespace}

      conn_name ->
        {:ok, conn} = Temporalex.Connection.get(conn_name)
        {conn.runtime, conn.client, conn.namespace}
    end
  end

  defp update_stat(state, key) do
    %{state | stats: Map.update!(state.stats, key, &(&1 + 1))}
  end

  defp classify_commands(commands) do
    Enum.reduce(commands, :ok, fn cmd, acc ->
      case cmd.variant do
        {:fail_workflow_execution, _} -> :error
        {:continue_as_new_workflow_execution, _} -> :continue_as_new
        {:cancel_workflow_execution, _} -> :cancelled
        _ -> acc
      end
    end)
  end

  defp validate_positive_integer!(name, value) do
    unless is_integer(value) and value > 0 do
      raise ArgumentError,
            "#{name} must be a positive integer, got: #{inspect(value)}"
    end
  end

  # Exponential backoff with jitter: base * 2^(failures-1) + random jitter
  defp poll_backoff_ms(failures) do
    base = @base_backoff_ms * Integer.pow(2, failures - 1)
    capped = min(base, @max_backoff_ms)
    jitter = :rand.uniform(div(capped, 2))
    capped + jitter
  end
end
