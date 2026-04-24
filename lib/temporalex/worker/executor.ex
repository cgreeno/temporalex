defmodule Temporalex.Worker.Executor do
  @moduledoc """
  Production workflow executor — owns all runtime state for one workflow execution.

  Receives activations from the Server, manages the replay log, spawns
  the runner process, and sends completions directly to the NIF.

  Implements the same GenServer.call protocol as `Temporalex.Testing.Executor`,
  so workflow code (runner, handlers, parallel branches) can't tell the difference.
  """

  use GenServer

  require Logger

  defstruct [
    # Identity
    :server_pid,
    :worker,
    :run_id,
    :task_queue,
    :workflow_module,
    # Runner
    :runner_pid,
    # Replay
    replay_log: [],
    seq: 0,
    pending_calls: %{},
    # State model
    published_state: nil,
    receive_state: nil,
    receive_opts: nil,
    receive_from: nil,
    # Concurrency
    async_handlers: nil,
    async_tracker: %{},
    # Signals
    signal_buffer: [],
    signal_waiters: %{},
    # Sync handler
    sync_handler_pid: nil,
    sync_handler_update_from: nil,
    # Parallel
    parallels: %{},
    branch_to_parallel: %{},
    # Metadata
    patches: nil,
    cancelled: false,
    commands: [],
    status: :idle
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # --- Init ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      server_pid: opts.server_pid,
      worker: opts.worker,
      run_id: opts.run_id,
      task_queue: opts.task_queue,
      workflow_module: opts.workflow_module,
      async_handlers: MapSet.new(),
      patches: MapSet.new(),
      status: :idle
    }

    {:ok, state}
  end

  # --- Activation from Server ---

  @impl true
  def handle_info({:activation, activation}, state) do
    Logger.debug(
      "Executor #{state.run_id}: processing activation with #{length(activation.jobs)} jobs"
    )

    state = %{state | commands: []}

    # Categorize jobs
    {init_jobs, resolve_jobs, signal_jobs, update_jobs, query_jobs, patch_jobs, other_jobs} =
      categorize_jobs(activation.jobs)

    # 1. Apply patches
    state = apply_patches(patch_jobs, state)

    # 2. Apply resolutions (unblock pending activities/timers)
    state = apply_resolutions(resolve_jobs, state)

    # 3. Dispatch signals
    state = dispatch_signals(signal_jobs, state)

    # 4. Handle queries (always available, from published_state)
    state = handle_queries(query_jobs, state)

    # 5. Dispatch updates (only if in receive)
    state = dispatch_updates(update_jobs, state)

    # 6. Maybe start runner (on initialize_workflow)
    state = maybe_start_runner(init_jobs, activation, state)

    # 7. Handle evictions/cancels
    state = handle_other_jobs(other_jobs, state)

    # 8. Flush commands if the runner is blocked or done
    maybe_flush_commands(state)
  end

  # --- Process exits ---

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.runner_pid -> handle_runner_exit(reason, state)
      pid == state.sync_handler_pid -> handle_sync_handler_exit(reason, state)
      Map.has_key?(state.async_tracker, pid) -> handle_async_handler_exit(pid, reason, state)
      Map.has_key?(state.branch_to_parallel, pid) -> handle_parallel_exit(pid, reason, state)
      true -> {:noreply, state}
    end
  end

  # Completion acknowledgment
  def handle_info({:workflow_completion, :ok}, state), do: {:noreply, state}

  def handle_info({:workflow_completion, {:error, msg}}, state) do
    Logger.error("Executor #{state.run_id}: completion failed: #{msg}")
    {:noreply, state}
  end

  # --- Workflow API calls (from runner/handler processes) ---

  @impl true
  def handle_call({:execute_activity, type, input, opts}, from, state) do
    {seq, state} = next_seq(state)

    case check_replay(state, :activity, seq) do
      {:replay, result, state} ->
        {:reply, result, state}

      {:new, state} ->
        # Encode input as payloads
        payloads = Temporalex.Converter.encode_args(input)
        timeout = Keyword.get(opts, :timeout, 30_000)

        cmd =
          {:schedule_activity,
           %{
             seq: seq,
             activity_type: type,
             task_queue: state.task_queue,
             input: payloads,
             schedule_to_close_timeout_ms: timeout
           }}

        state = %{
          state
          | commands: [cmd | state.commands],
            pending_calls: Map.put(state.pending_calls, seq, from)
        }

        flush_commands(state)
    end
  end

  def handle_call({:start_child_workflow, workflow_type, args, opts}, from, state) do
    {seq, state} = next_seq(state)

    case check_replay(state, :child_workflow, seq) do
      {:replay, result, state} ->
        {:reply, result, state}

      {:new, state} ->
        payloads = Temporalex.Converter.encode_args([args])
        workflow_id = Keyword.get(opts, :workflow_id, "#{state.run_id}-child-#{seq}")
        task_queue = Keyword.get(opts, :task_queue, state.task_queue)

        cmd =
          {:start_child_workflow_execution,
           %{
             seq: seq,
             workflow_type: workflow_type,
             workflow_id: workflow_id,
             task_queue: task_queue,
             input: payloads
           }}

        state = %{
          state
          | commands: [cmd | state.commands],
            pending_calls: Map.put(state.pending_calls, seq, from)
        }

        flush_commands(state)
    end
  end

  def handle_call({:sleep, duration_ms}, from, state) do
    {seq, state} = next_seq(state)

    case check_replay(state, :timer, seq) do
      {:replay, _result, state} ->
        {:reply, :ok, state}

      {:new, state} ->
        cmd = {:start_timer, %{seq: seq, start_to_fire_timeout_ms: duration_ms}}

        state = %{
          state
          | commands: [cmd | state.commands],
            pending_calls: Map.put(state.pending_calls, seq, from)
        }

        flush_commands(state)
    end
  end

  def handle_call({:wait_for_signal, name}, from, state) do
    case pop_signal(state.signal_buffer, name) do
      {payload, remaining} ->
        {:reply, payload, %{state | signal_buffer: remaining}}

      nil ->
        # Runner is parked with nothing more to produce this activation.
        # Flush any accumulated commands (including an empty list) so
        # Temporal knows the workflow task is complete and that we're
        # awaiting new events (signals, timers, etc.).
        waiters = Map.put(state.signal_waiters, name, from)
        state = %{state | signal_waiters: waiters}
        force_flush_commands(state)
    end
  end

  def handle_call({:side_effect, fun}, _from, state) do
    {seq, state} = next_seq(state)

    case check_replay(state, :side_effect, seq) do
      {:replay, result, state} ->
        {:reply, result, state}

      {:new, state} ->
        # Execute once and record (side effects aren't commands, they're marker events)
        result = fun.()
        # In production, this would record a SideEffect marker.
        # For now, execute and return immediately.
        {:reply, result, state}
    end
  end

  def handle_call({:publish_state, new_state}, _from, state) do
    {:reply, :ok, %{state | published_state: new_state}}
  end

  def handle_call({:patched?, patch_id}, _from, state) do
    if MapSet.member?(state.patches, patch_id) do
      {:reply, true, state}
    else
      cmd = {:set_patch_marker, %{patch_id: patch_id, deprecated: false}}

      state = %{
        state
        | patches: MapSet.put(state.patches, patch_id),
          commands: [cmd | state.commands]
      }

      {:reply, true, state}
    end
  end

  def handle_call({:deprecate_patch, patch_id}, _from, state) do
    cmd = {:set_patch_marker, %{patch_id: patch_id, deprecated: true}}
    {:reply, :ok, %{state | commands: [cmd | state.commands]}}
  end

  def handle_call(:cancelled?, _from, state) do
    {:reply, state.cancelled, state}
  end

  # --- Receive ---

  def handle_call({:receive, initial_state, opts}, from, state) do
    state = %{
      state
      | receive_state: initial_state,
        receive_opts: opts,
        receive_from: from,
        status: :in_receive
    }

    # Drain buffered signals that have matching handlers
    state = drain_buffered_signals(state)

    # Runner is parked in receive. Flush any pending commands so Temporal
    # knows this workflow task is complete — otherwise it waits forever
    # for an activation completion.
    force_flush_commands(state)
  end

  # --- Parallel ---

  def handle_call({:parallel, []}, _from, state) do
    {:reply, [], state}
  end

  def handle_call({:parallel, fns}, from, state) do
    executor = self()
    ref = make_ref()

    pids_by_idx =
      fns
      |> Enum.with_index()
      |> Enum.map(fn {fun, idx} ->
        pid =
          spawn_link(fn ->
            Process.put(:__temporal_executor__, executor)
            Process.put(:__temporal_in_handler__, true)

            try do
              exit({:parallel_result, ref, idx, fun.()})
            rescue
              e -> exit({:parallel_result, ref, idx, {:error, e}})
            end
          end)

        {pid, idx}
      end)

    branch_idx = Map.new(pids_by_idx)

    group = %{
      ref: ref,
      branch_idx: branch_idx,
      results: %{},
      count: length(fns),
      from: from
    }

    branch_updates =
      pids_by_idx
      |> Enum.map(fn {pid, _} -> {pid, ref} end)
      |> Map.new()

    {:noreply,
     %{
       state
       | parallels: Map.put(state.parallels, ref, group),
         branch_to_parallel: Map.merge(state.branch_to_parallel, branch_updates)
     }}
  end

  # --- Update state (async handlers) ---

  def handle_call({:update_state, fun}, _from, %{status: status} = state)
      when status in [:in_receive, :receive_stopping] do
    {result, new_receive_state} = fun.(state.receive_state)
    {:reply, result, %{state | receive_state: new_receive_state}}
  end

  # --- Private: runner lifecycle ---

  defp maybe_start_runner([], _activation, state), do: state

  defp maybe_start_runner([{:initialize_workflow, init} | _], activation, state) do
    # Build replay log from remaining jobs in activation
    replay_log = build_replay_log(activation.jobs)

    executor = self()
    args = Temporalex.Converter.decode_args(Map.get(init, :arguments, []))
    # For initialize, args is a list of payloads — workflow gets the first one (or a map)
    workflow_args =
      case args do
        [single] -> single
        [] -> %{}
        multiple -> multiple
      end

    pid =
      spawn_link(fn ->
        Process.put(:__temporal_executor__, executor)
        result = state.workflow_module.run(workflow_args)
        exit({:workflow_result, result})
      end)

    %{state | runner_pid: pid, replay_log: replay_log, status: :running}
  end

  defp maybe_start_runner(_, _activation, state), do: state

  defp handle_runner_exit({:workflow_result, {:ok, result}}, state) do
    payload = Temporalex.Converter.encode(result)
    cmd = {:complete_workflow_execution, %{result: payload}}
    state = %{state | commands: [cmd | state.commands], runner_pid: nil, status: :done}
    maybe_flush_commands(state)
  end

  defp handle_runner_exit({:workflow_result, {:error, reason}}, state) do
    cmd = {:fail_workflow_execution, %{message: inspect(reason)}}
    state = %{state | commands: [cmd | state.commands], runner_pid: nil, status: :done}
    maybe_flush_commands(state)
  end

  defp handle_runner_exit({:workflow_result, {:continue_as_new, args}}, state) do
    payload = Temporalex.Converter.encode(args)

    cmd =
      {:continue_as_new,
       %{arguments: [payload], workflow_type: state.workflow_module.__temporal_workflow_type__()}}

    state = %{state | commands: [cmd | state.commands], runner_pid: nil, status: :done}
    maybe_flush_commands(state)
  end

  defp handle_runner_exit(:normal, state) do
    # Runner yielded — blocked on a GenServer.call. Don't flush yet.
    {:noreply, state}
  end

  defp handle_runner_exit(reason, state) do
    cmd = {:fail_workflow_execution, %{message: "workflow crashed: #{inspect(reason)}"}}
    state = %{state | commands: [cmd | state.commands], runner_pid: nil, status: :done}
    maybe_flush_commands(state)
  end

  # --- Private: sync handler exit ---

  defp handle_sync_handler_exit({:handler_result, handler_return}, state) do
    update_from = state.sync_handler_update_from
    state = %{state | sync_handler_pid: nil, sync_handler_update_from: nil}
    apply_handler_return(handler_return, update_from, state)
  end

  defp handle_sync_handler_exit(_reason, state) do
    {:noreply, %{state | sync_handler_pid: nil, sync_handler_update_from: nil}}
  end

  # --- Private: async handler exit ---

  defp handle_async_handler_exit(pid, reason, state) do
    {tracker_info, async_tracker} = Map.pop(state.async_tracker, pid)
    async_handlers = MapSet.delete(state.async_handlers, pid)
    state = %{state | async_tracker: async_tracker, async_handlers: async_handlers}

    case {tracker_info, reason} do
      {{:update, update_from}, {:handler_result, result}} when update_from != nil ->
        GenServer.reply(update_from, result)
        maybe_complete_receive(state)

      {{:signal, _}, {:handler_result, _}} ->
        maybe_complete_receive(state)

      {{:update, update_from}, _} when update_from != nil ->
        GenServer.reply(update_from, {:error, {:handler_crashed, reason}})
        maybe_complete_receive(state)

      _ ->
        maybe_complete_receive(state)
    end
  end

  # --- Private: parallel branch exit ---

  defp handle_parallel_exit(pid, reason, state) do
    {ref, branch_to_parallel} = Map.pop(state.branch_to_parallel, pid)
    group = Map.fetch!(state.parallels, ref)
    idx = Map.fetch!(group.branch_idx, pid)

    result =
      case reason do
        {:parallel_result, ^ref, ^idx, value} -> value
        other -> {:error, {:branch_crashed, other}}
      end

    results = Map.put(group.results, idx, result)
    group = %{group | results: results}

    if map_size(results) == group.count do
      ordered = Enum.map(0..(group.count - 1), &Map.fetch!(results, &1))
      GenServer.reply(group.from, ordered)

      {:noreply,
       %{
         state
         | parallels: Map.delete(state.parallels, ref),
           branch_to_parallel: branch_to_parallel
       }}
    else
      {:noreply,
       %{
         state
         | parallels: Map.put(state.parallels, ref, group),
           branch_to_parallel: branch_to_parallel
       }}
    end
  end

  # --- Private: handler return values ---

  defp apply_handler_return({:noreply, new_state}, _update_from, state) do
    drain_and_continue(%{state | receive_state: new_state})
  end

  defp apply_handler_return({:stop, final_state}, _update_from, state) do
    complete_receive(%{state | receive_state: final_state}, final_state)
  end

  defp apply_handler_return({:reply, response, new_state}, update_from, state) do
    if update_from, do: GenServer.reply(update_from, response)
    drain_and_continue(%{state | receive_state: new_state})
  end

  defp apply_handler_return({:stop, response, final_state}, update_from, state) do
    if update_from, do: GenServer.reply(update_from, response)
    complete_receive(%{state | receive_state: final_state}, final_state)
  end

  defp apply_handler_return({:async, fun, _state}, update_from, state) do
    # The third element of {:async, fn, state} is intentionally ignored.
    # Replacing receive_state here would wipe concurrent `update_state`
    # writes from other async fns. Use `update_state` inside the async fn
    # to mutate receive_state safely.
    executor = self()

    pid =
      spawn_link(fn ->
        Process.put(:__temporal_executor__, executor)
        Process.put(:__temporal_in_handler__, true)
        exit({:handler_result, fun.()})
      end)

    tracker_type = if update_from, do: {:update, update_from}, else: {:signal, nil}

    drain_and_continue(%{
      state
      | async_handlers: MapSet.put(state.async_handlers, pid),
        async_tracker: Map.put(state.async_tracker, pid, tracker_type)
    })
  end

  # --- Private: receive helpers ---

  defp drain_buffered_signals(state) do
    signal_handlers = Keyword.get(state.receive_opts || [], :signal, %{})

    case Enum.split_while(state.signal_buffer, fn {name, _} ->
           !Map.has_key?(signal_handlers, name)
         end) do
      {_unmatched, []} ->
        state

      {before, [{name, payload} | rest]} ->
        handler = Map.fetch!(signal_handlers, name)
        executor = self()

        pid =
          spawn_link(fn ->
            Process.put(:__temporal_executor__, executor)
            Process.put(:__temporal_in_handler__, true)
            exit({:handler_result, handler.(payload, state.receive_state)})
          end)

        %{state | signal_buffer: before ++ rest, sync_handler_pid: pid}
    end
  end

  defp drain_and_continue(state) do
    state = drain_buffered_signals(state)

    # If no sync handler is currently running and no async handlers are
    # pending, the runner is parked. Flush whatever the activation
    # produced (including an empty completion) so Temporal acknowledges
    # the workflow task.
    if state.sync_handler_pid == nil and MapSet.size(state.async_handlers) == 0 and
         state.status in [:in_receive, :receive_stopping] do
      force_flush_commands(state)
    else
      {:noreply, state}
    end
  end

  defp complete_receive(state, final_state) do
    if MapSet.size(state.async_handlers) > 0 do
      {:noreply, %{state | status: :receive_stopping}}
    else
      do_complete_receive(state, final_state)
    end
  end

  defp do_complete_receive(state, final_state) do
    GenServer.reply(state.receive_from, final_state)

    {:noreply,
     %{state | receive_state: nil, receive_opts: nil, receive_from: nil, status: :running}}
  end

  defp maybe_complete_receive(%{status: :receive_stopping} = state) do
    if MapSet.size(state.async_handlers) == 0 do
      do_complete_receive(state, state.receive_state)
    else
      {:noreply, state}
    end
  end

  defp maybe_complete_receive(state), do: {:noreply, state}

  # --- Private: signal buffer ---

  defp buffer_signal(state, name, payload) do
    case Map.pop(state.signal_waiters, name) do
      {nil, _} ->
        %{state | signal_buffer: state.signal_buffer ++ [{name, payload}]}

      {from, remaining} ->
        GenServer.reply(from, payload)
        %{state | signal_waiters: remaining}
    end
  end

  defp pop_signal(buffer, name) do
    case Enum.split_while(buffer, fn {n, _} -> n != name end) do
      {_before, []} -> nil
      {before, [{^name, payload} | rest]} -> {payload, before ++ rest}
    end
  end

  # --- Private: replay log ---

  defp next_seq(state) do
    seq = state.seq + 1
    {seq, %{state | seq: seq}}
  end

  defp check_replay(state, type, seq) do
    case Temporalex.Worker.Replay.consume(state.replay_log, type, seq) do
      {:replay, result, rest} -> {:replay, result, %{state | replay_log: rest}}
      {:new, _} -> {:new, state}
    end
  end

  defp build_replay_log(jobs), do: Temporalex.Worker.Replay.build_log(jobs)

  # --- Private: job categorization ---

  defp categorize_jobs(jobs) do
    Enum.reduce(jobs, {[], [], [], [], [], [], []}, fn job,
                                                       {init, resolve, signal, update, query,
                                                        patch, other} ->
      case job do
        {:initialize_workflow, _} = j ->
          {[j | init], resolve, signal, update, query, patch, other}

        {:resolve_activity, _} = j ->
          {init, [j | resolve], signal, update, query, patch, other}

        {:fire_timer, _} = j ->
          {init, [j | resolve], signal, update, query, patch, other}

        {:resolve_child_workflow_execution, _} = j ->
          {init, [j | resolve], signal, update, query, patch, other}

        {:signal_workflow, _} = j ->
          {init, resolve, [j | signal], update, query, patch, other}

        {:do_update, _} = j ->
          {init, resolve, signal, [j | update], query, patch, other}

        {:query_workflow, _} = j ->
          {init, resolve, signal, update, [j | query], patch, other}

        {:notify_has_patch, _} = j ->
          {init, resolve, signal, update, query, [j | patch], other}

        j ->
          {init, resolve, signal, update, query, patch, [j | other]}
      end
    end)
  end

  # --- Private: activation job handlers ---

  defp apply_patches(patch_jobs, state) do
    Enum.reduce(patch_jobs, state, fn {:notify_has_patch, %{patch_id: id}}, state ->
      %{state | patches: MapSet.put(state.patches, id)}
    end)
  end

  defp apply_resolutions(resolve_jobs, state) do
    Enum.reduce(resolve_jobs, state, fn
      {:resolve_activity, %{seq: seq, result: {:completed, payload}}}, state ->
        result = Temporalex.Converter.decode(payload)
        unblock_pending(state, seq, result)

      {:resolve_activity, %{seq: seq, result: {:failed, failure}}}, state ->
        unblock_pending(state, seq, {:error, failure})

      {:resolve_activity, %{seq: seq, result: {:cancelled, failure}}}, state ->
        unblock_pending(state, seq, {:error, {:cancelled, failure}})

      {:fire_timer, %{seq: seq}}, state ->
        unblock_pending(state, seq, :ok)

      {:resolve_child_workflow_execution, %{seq: seq, result: {:completed, payload}}}, state ->
        result = Temporalex.Converter.decode(payload)
        unblock_pending(state, seq, result)

      {:resolve_child_workflow_execution, %{seq: seq, result: {:failed, failure}}}, state ->
        unblock_pending(state, seq, {:error, failure})

      _, state ->
        state
    end)
  end

  defp dispatch_signals(signal_jobs, state) do
    Enum.reduce(signal_jobs, state, fn {:signal_workflow, %{signal_name: name, input: input}},
                                       state ->
      payload =
        case Temporalex.Converter.decode_args(input) do
          [single] -> single
          [] -> nil
          multiple -> multiple
        end

      if state.status == :in_receive do
        signal_handlers = Keyword.get(state.receive_opts, :signal, %{})

        case Map.get(signal_handlers, name) do
          nil -> buffer_signal(state, name, payload)
          handler -> dispatch_sync_handler(handler, [payload, state.receive_state], nil, state)
        end
      else
        buffer_signal(state, name, payload)
      end
    end)
  end

  defp handle_queries(query_jobs, state) do
    Enum.reduce(query_jobs, state, fn {:query_workflow,
                                       %{query_id: qid, query_type: qtype, arguments: args}},
                                      state ->
      decoded_args = Temporalex.Converter.decode_args(args)

      response =
        try do
          state.workflow_module.handle_query(qtype, decoded_args, state.published_state)
        rescue
          e -> {:reply, {:error, inspect(e)}}
        end

      case response do
        {:reply, value} ->
          payload = Temporalex.Converter.encode(value)
          # Rust encoder reads succeeded.result (see proto_bridge.rs); key
          # name must match the native-side atom.
          cmd = {:respond_to_query, %{query_id: qid, succeeded: %{result: payload}}}
          %{state | commands: [cmd | state.commands]}

        _ ->
          state
      end
    end)
  end

  defp dispatch_updates(update_jobs, state) do
    Enum.reduce(update_jobs, state, fn {:do_update, %{id: _id, name: name, input: input}},
                                       state ->
      if state.status != :in_receive do
        # Updates rejected outside receive
        Logger.warning("Update #{name} rejected: not in receive")
        state
      else
        update_handlers = Keyword.get(state.receive_opts, :update, %{})

        case Map.get(update_handlers, name) do
          nil ->
            Logger.warning("Update #{name} rejected: no handler")
            state

          {handler, opts} when is_list(opts) ->
            decoded_args = Temporalex.Converter.decode_args(input)
            validator = Keyword.get(opts, :validator)

            if validator do
              case validator.(decoded_args, state.receive_state) do
                :ok ->
                  dispatch_sync_handler(handler, [decoded_args, state.receive_state], nil, state)

                {:error, _reason} ->
                  state
              end
            else
              dispatch_sync_handler(handler, [decoded_args, state.receive_state], nil, state)
            end

          handler when is_function(handler) ->
            decoded_args = Temporalex.Converter.decode_args(input)
            dispatch_sync_handler(handler, [decoded_args, state.receive_state], nil, state)
        end
      end
    end)
  end

  defp handle_other_jobs(other_jobs, state) do
    Enum.reduce(other_jobs, state, fn
      {:cancel_workflow, _}, state ->
        %{state | cancelled: true}

      {:remove_from_cache, _}, state ->
        state

      {:update_random_seed, _}, state ->
        state

      _, state ->
        state
    end)
  end

  # --- Private: handler dispatch ---

  defp dispatch_sync_handler(handler, handler_args, update_from, state) do
    executor = self()

    pid =
      spawn_link(fn ->
        Process.put(:__temporal_executor__, executor)
        Process.put(:__temporal_in_handler__, true)
        exit({:handler_result, apply(handler, handler_args)})
      end)

    %{state | sync_handler_pid: pid, sync_handler_update_from: update_from}
  end

  # --- Private: pending calls ---

  defp unblock_pending(state, seq, result) do
    case Map.pop(state.pending_calls, seq) do
      {nil, _} ->
        # No one waiting — this was replayed
        state

      {from, remaining} ->
        GenServer.reply(from, result)
        %{state | pending_calls: remaining}
    end
  end

  # --- Private: command flushing ---

  # Flush immediately — called when the runner yields (blocks on a call).
  # No-op when there are no commands to send.
  defp flush_commands(%{commands: []} = state), do: {:noreply, state}

  defp flush_commands(state), do: do_flush(state)

  # Force flush — always sends a completion, even with empty commands.
  # Used when the runner parks on receive/wait_for_signal with nothing
  # produced this activation; Temporal still needs an acknowledgement.
  defp force_flush_commands(state), do: do_flush(state)

  defp do_flush(state) do
    commands = Enum.reverse(state.commands)

    case Temporalex.Native.encode_workflow_completion(state.run_id, {:successful, commands}) do
      {:ok, bytes} ->
        Temporalex.Native.complete_workflow_activation(state.worker, bytes, self())

      {:error, reason} ->
        Logger.error("Failed to encode completion: #{inspect(reason)}")
    end

    {:noreply, %{state | commands: []}}
  end

  # Flush at end of activation processing — only if there are commands ready
  defp maybe_flush_commands(state) do
    if state.commands != [] do
      flush_commands(state)
    else
      {:noreply, state}
    end
  end
end
