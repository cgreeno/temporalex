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

  # Hard caps to bound memory under flood scenarios (misbehaving signal
  # producer, server-side replay storm). Override via opts for tests.
  @default_max_signal_buffer 10_000
  @default_max_pending_handlers 10_000

  defstruct [
    # Identity
    :server_pid,
    :worker,
    :run_id,
    :task_queue,
    :workflow_module,
    # Test seam: when set, do_flush sends {:flushed, run_id, commands} to this
    # pid instead of calling the NIF. Production callers leave this nil.
    :flush_to,
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
    # Length-tracked counterpart of signal_buffer — :queue.len / List.length
    # is O(n), so we maintain a separate counter for the cap check.
    signal_buffer_size: 0,
    signal_waiters: %{},
    # Sync handler — only one runs at a time. Subsequent dispatches queue
    # behind it; pending_handler_queue is drained as each finishes. Matches
    # Temporal's per-activation single-threaded handler ordering.
    sync_handler_pid: nil,
    sync_handler_update_from: nil,
    pending_handler_queue: nil,
    pending_handler_count: 0,
    max_signal_buffer: nil,
    max_pending_handlers: nil,
    # Parallel
    parallels: %{},
    branch_to_parallel: %{},
    # Metadata
    patches: nil,
    is_replaying: false,
    cancelled: false,
    commands: [],
    status: :idle,
    # Receive timeout
    receive_timer_ref: nil,
    receive_timer_id: nil,
    receive_stop_value: nil,
    # Set true while inside handle_info({:activation, _}). Used by the
    # test harness to validate the one-completion-per-activation
    # protocol invariant — see test/support/executor_test_helpers.ex.
    in_activation: false
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
      flush_to: Map.get(opts, :flush_to),
      max_signal_buffer: Map.get(opts, :max_signal_buffer, @default_max_signal_buffer),
      max_pending_handlers: Map.get(opts, :max_pending_handlers, @default_max_pending_handlers),
      async_handlers: MapSet.new(),
      pending_handler_queue: :queue.new(),
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

    # Notify the test seam that an activation window is starting. Used by
    # the test harness to validate the one-completion-per-activation
    # protocol invariant — see test/support/executor_test_helpers.ex.
    if pid = state.flush_to, do: send(pid, {:activation_start, state.run_id})

    state = %{
      state
      | commands: [],
        is_replaying: Map.get(activation, :is_replaying, false),
        in_activation: true
    }

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

    # 8. Drain any in-flight sync handler synchronously, processing its
    #    API calls and exit inline. Required for the wire-protocol
    #    invariant: each activation must produce exactly one
    #    `complete_workflow_activation` call. Without this, an update
    #    handler that exits between `handle_info({:activation, _})` and
    #    the next gen_server cycle would emit `Completed` out-of-band,
    #    which Core rejects as "Task not found when completing".
    state = drain_handler_until_settled(state, deadline_ms(50))

    # 9. Flush commands if the runner is blocked or done
    {:noreply, state} = maybe_flush_commands(state)

    state = %{state | in_activation: false}
    {:noreply, state}
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

  # Receive timer fired (SDK-local, not a workflow timer).
  def handle_info({:receive_timeout, id}, %{receive_timer_id: id} = state)
      when state.status in [:in_receive, :receive_stopping] do
    state = %{state | receive_timer_ref: nil, receive_timer_id: nil}
    timeout_reply = {:timeout, state.receive_state}

    cond do
      state.status == :receive_stopping ->
        # A handler already started the stop with a captured value — first
        # decision wins, don't override with the timer fire.
        {:noreply, state}

      MapSet.size(state.async_handlers) > 0 ->
        {:noreply, %{state | status: :receive_stopping, receive_stop_value: timeout_reply}}

      true ->
        do_complete_receive(state, timeout_reply)
    end
  end

  def handle_info({:receive_timeout, _stale_id}, state), do: {:noreply, state}

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

  def handle_call({:execute_local_activity, type, input, opts}, from, state) do
    {seq, state} = next_seq(state)

    case check_replay(state, :activity, seq) do
      {:replay, result, state} ->
        {:reply, result, state}

      {:new, state} ->
        payloads = Temporalex.Converter.encode_args(input)
        timeout = Keyword.get(opts, :start_to_close_timeout_ms, 30_000)

        cmd =
          {:schedule_local_activity,
           %{
             seq: seq,
             activity_type: type,
             input: payloads,
             start_to_close_timeout_ms: timeout
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
        {:reply, payload,
         %{state | signal_buffer: remaining, signal_buffer_size: state.signal_buffer_size - 1}}

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
    # KNOWN LIMITATION: side_effect is not durable across cache evictions.
    #
    # Within a single Executor's lifetime, side_effect runs exactly once
    # per call site (the runner process keeps the value in its own stack),
    # so identical workflow code sees identical results — the contract
    # users expect in the happy path.
    #
    # However, if the workflow is evicted from Temporal's cache and later
    # re-activated on a different worker, the Executor replays the
    # workflow from history and side_effect runs again with a new value.
    # Modern Temporal deprecated this pattern in favor of LocalActivity,
    # which has proper marker-event support in workflow history. Use an
    # Activity or LocalActivity (when implemented — see
    # `notes/local_activity_design.md`) for non-deterministic work that
    # must survive eviction.
    {_seq, state} = next_seq(state)
    result = fun.()
    {:reply, result, state}
  end

  def handle_call({:publish_state, new_state}, _from, state) do
    {:reply, :ok, %{state | published_state: new_state}}
  end

  def handle_call({:patched?, patch_id}, _from, state) do
    cond do
      # Already seen this patch — from a prior call this run, or from a
      # notify_has_patch job (means the marker exists in history).
      MapSet.member?(state.patches, patch_id) ->
        {:reply, true, state}

      # Replay: the marker wasn't in history. Code that calls patched?
      # from the "new" branch should NOT see true during replay.
      state.is_replaying ->
        {:reply, false, state}

      # New execution, first time seeing this patch: emit the marker and
      # record it so subsequent calls in this run return true.
      true ->
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

    # Arm an SDK-side timer for the optional :timeout. Note: this is not
    # a workflow timer command — it's local to the executor process and
    # fires only while this Executor is alive. After cache eviction the
    # timer is gone (and a new activation would re-arm it on replay).
    state = arm_receive_timer(state, Keyword.get(opts, :timeout))

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
    # Apply this handler's return first (mutating receive_state), THEN drain
    # the next queued handler so it observes those mutations.
    apply_handler_return_then_drain(handler_return, update_from, state)
  end

  defp handle_sync_handler_exit(reason, state) do
    update_from = state.sync_handler_update_from
    state = %{state | sync_handler_pid: nil, sync_handler_update_from: nil}

    state =
      if update_from do
        # Handler crashed AFTER we already emitted :accepted. Emit a
        # :rejected response so the Update API caller doesn't hang.
        emit_update_rejected(state, update_from, "handler crashed: #{inspect(reason)}")
      else
        state
      end

    # Promote the next queued handler (if any) THEN run drain_and_continue
    # to flush whatever the rejection produced. Mirrors the success path
    # in apply_handler_return_then_drain.
    state = maybe_dispatch_next_handler(state)
    drain_and_continue(state)
  end

  # Wraps apply_handler_return so that after a handler's return is applied
  # we drain the next queued handler. The next handler must see the latest
  # receive_state (mutated by this return) — not a stale snapshot.
  defp apply_handler_return_then_drain(handler_return, update_from, state) do
    case apply_handler_return(handler_return, update_from, state) do
      {:noreply, state} -> {:noreply, maybe_dispatch_next_handler(state)}
      other -> other
    end
  end

  # --- Private: async handler exit ---

  defp handle_async_handler_exit(pid, reason, state) do
    {tracker_info, async_tracker} = Map.pop(state.async_tracker, pid)
    async_handlers = MapSet.delete(state.async_handlers, pid)
    state = %{state | async_tracker: async_tracker, async_handlers: async_handlers}

    state =
      case {tracker_info, reason} do
        {{:update, protocol_instance_id}, {:handler_result, result}}
        when protocol_instance_id != nil ->
          emit_update_completed(state, protocol_instance_id, result)

        {{:update, protocol_instance_id}, _} when protocol_instance_id != nil ->
          emit_update_rejected(
            state,
            protocol_instance_id,
            "handler crashed: #{inspect(reason)}"
          )

        _ ->
          state
      end

    maybe_complete_receive(state)
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

  defp apply_handler_return({:noreply, new_state}, update_from, state) do
    # Updates require an explicit response — {:noreply} is a contract
    # violation. Reject so the API caller doesn't hang.
    state =
      if update_from do
        emit_update_rejected(
          state,
          update_from,
          "update handler returned {:noreply, _} — must return {:reply, response, state} or {:stop, response, state}"
        )
      else
        state
      end

    drain_and_continue(%{state | receive_state: new_state})
  end

  defp apply_handler_return({:stop, final_state}, update_from, state) do
    state =
      if update_from do
        emit_update_rejected(
          state,
          update_from,
          "update handler returned {:stop, state} — must return {:stop, response, state} to surface a value"
        )
      else
        state
      end

    complete_receive(%{state | receive_state: final_state}, final_state)
  end

  defp apply_handler_return({:reply, response, new_state}, update_from, state) do
    state = if update_from, do: emit_update_completed(state, update_from, response), else: state
    drain_and_continue(%{state | receive_state: new_state})
  end

  defp apply_handler_return({:stop, response, final_state}, update_from, state) do
    state = if update_from, do: emit_update_completed(state, update_from, response), else: state
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

        state = %{
          state
          | signal_buffer: before ++ rest,
            signal_buffer_size: state.signal_buffer_size - 1
        }

        dispatch_sync_handler(handler, [payload, state.receive_state], nil, state)
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
    state = cancel_receive_timer(state)

    cond do
      # Receive already completed (timer fired and won; or another stop
      # already replied). receive_from is nil, so any further completion
      # would call GenServer.reply(nil, _) → FunctionClauseError.
      is_nil(state.receive_from) ->
        {:noreply, state}

      state.status == :receive_stopping ->
        # Already stopping — first stop wins (a queued handler or a racing
        # timer must not overwrite the originally decided value).
        {:noreply, state}

      MapSet.size(state.async_handlers) > 0 ->
        # Capture final_state — concurrent async handlers may mutate
        # receive_state via update_state before they exit, but the receive's
        # return value must reflect the moment :stop fired.
        {:noreply, %{state | status: :receive_stopping, receive_stop_value: final_state}}

      true ->
        do_complete_receive(state, final_state)
    end
  end

  defp do_complete_receive(state, final_state) do
    GenServer.reply(state.receive_from, final_state)

    {:noreply,
     %{
       state
       | receive_state: nil,
         receive_opts: nil,
         receive_from: nil,
         status: :running
     }}
  end

  defp maybe_complete_receive(%{status: :receive_stopping} = state) do
    if MapSet.size(state.async_handlers) == 0 do
      reply_value = state.receive_stop_value || state.receive_state
      state = %{state | receive_stop_value: nil}
      do_complete_receive(state, reply_value)
    else
      {:noreply, state}
    end
  end

  defp maybe_complete_receive(state), do: {:noreply, state}

  # --- Private: receive timer (SDK-local) ---

  defp arm_receive_timer(state, nil), do: state

  defp arm_receive_timer(state, timeout) when is_integer(timeout) and timeout >= 0 do
    timer_id = make_ref()
    timer_ref = Process.send_after(self(), {:receive_timeout, timer_id}, timeout)
    %{state | receive_timer_ref: timer_ref, receive_timer_id: timer_id}
  end

  defp cancel_receive_timer(%{receive_timer_ref: nil} = state), do: state

  defp cancel_receive_timer(%{receive_timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)

    receive do
      {:receive_timeout, _} -> :ok
    after
      0 -> :ok
    end

    %{state | receive_timer_ref: nil, receive_timer_id: nil}
  end

  # --- Private: signal buffer ---

  defp buffer_signal(state, name, payload) do
    case Map.pop(state.signal_waiters, name) do
      {nil, _} ->
        enqueue_signal_capped(state, name, payload)

      {from, remaining} ->
        GenServer.reply(from, payload)
        %{state | signal_waiters: remaining}
    end
  end

  # Append a buffered signal, dropping the oldest if the cap is hit. Caps
  # are intentionally per-executor (per workflow run): a single workflow
  # cannot fill the worker's heap by spamming itself with signals.
  defp enqueue_signal_capped(state, name, payload) do
    if state.signal_buffer_size >= state.max_signal_buffer do
      Logger.warning(
        "Executor #{state.run_id}: signal buffer at cap #{state.max_signal_buffer}; dropping oldest"
      )

      [_dropped | rest] = state.signal_buffer

      %{
        state
        | signal_buffer: rest ++ [{name, payload}],
          # Size unchanged: dropped one, added one.
          signal_buffer_size: state.signal_buffer_size
      }
    else
      %{
        state
        | signal_buffer: state.signal_buffer ++ [{name, payload}],
          signal_buffer_size: state.signal_buffer_size + 1
      }
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
    {init, resolve, signal, update, query, patch, other} =
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

    # Reverse to restore activation order — signals/updates and other jobs
    # must be processed in the order Temporal delivered them.
    {Enum.reverse(init), Enum.reverse(resolve), Enum.reverse(signal), Enum.reverse(update),
     Enum.reverse(query), Enum.reverse(patch), Enum.reverse(other)}
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

      {:resolve_child_workflow_execution, %{seq: seq, result: {:cancelled, failure}}}, state ->
        unblock_pending(state, seq, {:error, {:cancelled, failure}})

      # Backoff on a local-activity is intentional passthrough — the runner
      # stays parked until the eventual final resolution arrives.
      {:resolve_activity, %{result: {:backoff, _}}}, state ->
        state

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
        catch
          kind, value -> {:reply, {:error, "#{kind}: #{inspect(value)}"}}
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
    Enum.reduce(update_jobs, state, fn {:do_update,
                                        %{
                                          id: _id,
                                          protocol_instance_id: pid,
                                          name: name,
                                          input: input
                                        }},
                                       state ->
      if state.status != :in_receive do
        # Updates outside a receive can't be served — reject.
        Logger.warning("Update #{name} rejected: not in receive")
        emit_update_rejected(state, pid, "no receive in progress")
      else
        update_handlers = Keyword.get(state.receive_opts, :update, %{})

        case Map.get(update_handlers, name) do
          nil ->
            Logger.warning("Update #{name} rejected: no handler")
            emit_update_rejected(state, pid, "no handler for #{name}")

          {handler, opts} when is_list(opts) ->
            decoded_args = Temporalex.Converter.decode_args(input)
            validator = Keyword.get(opts, :validator)

            if validator do
              case run_validator(validator, decoded_args, state.receive_state) do
                :ok ->
                  state = emit_update_accepted(state, pid)
                  dispatch_sync_handler(handler, [decoded_args, state.receive_state], pid, state)

                {:error, reason} ->
                  emit_update_rejected(state, pid, "validator: #{inspect(reason)}")
              end
            else
              state = emit_update_accepted(state, pid)
              dispatch_sync_handler(handler, [decoded_args, state.receive_state], pid, state)
            end

          handler when is_function(handler) ->
            decoded_args = Temporalex.Converter.decode_args(input)
            state = emit_update_accepted(state, pid)
            dispatch_sync_handler(handler, [decoded_args, state.receive_state], pid, state)
        end
      end
    end)
  end

  # --- Private: update response emission ---

  # Per Temporal protocol, update flow is:
  #   accepted (validator passed)  →  completed (handler returned)
  # OR:
  #   rejected (validator failed, OR handler crashed after acceptance).
  # Without these UpdateResponse commands the Temporal Update API caller
  # hangs until update timeout.
  defp emit_update_accepted(state, protocol_instance_id) do
    cmd =
      {:update_response,
       %{protocol_instance_id: protocol_instance_id, response: {:accepted, %{}}}}

    %{state | commands: [cmd | state.commands]}
  end

  defp emit_update_completed(state, protocol_instance_id, result) do
    payload = Temporalex.Converter.encode(result)

    cmd =
      {:update_response,
       %{protocol_instance_id: protocol_instance_id, response: {:completed, payload}}}

    %{state | commands: [cmd | state.commands]}
  end

  defp emit_update_rejected(state, protocol_instance_id, message)
       when is_binary(message) do
    cmd =
      {:update_response,
       %{
         protocol_instance_id: protocol_instance_id,
         response: {:rejected, %{message: message}}
       }}

    %{state | commands: [cmd | state.commands]}
  end

  # --- Private: inline handler drain ---

  # Drain any in-flight sync handler's API calls and exit inline, so its
  # commands land in the SAME activation completion. Required for the
  # wire-protocol invariant. Bounded by `deadline` (epoch-ms).
  defp drain_handler_until_settled(state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      remaining == 0 ->
        state

      state.sync_handler_pid == nil ->
        state

      true ->
        handler_pid = state.sync_handler_pid

        receive do
          {:EXIT, ^handler_pid, reason} ->
            {:noreply, new_state} = handle_sync_handler_exit(reason, state)
            drain_handler_until_settled(new_state, deadline)

          {:"$gen_call", {caller_pid, _} = from, request} when caller_pid == handler_pid ->
            new_state = dispatch_inline_call(request, from, state)
            drain_handler_until_settled(new_state, deadline)
        after
          remaining -> state
        end
    end
  end

  # Drive a handle_call as if the gen_server framework had received it,
  # mirroring its return semantics: send the reply on `{:reply, _, _}`,
  # leave the caller parked on `{:noreply, _}`.
  defp dispatch_inline_call(request, from, state) do
    case handle_call(request, from, state) do
      {:reply, reply, new_state} ->
        GenServer.reply(from, reply)
        new_state

      {:noreply, new_state} ->
        new_state
    end
  end

  defp deadline_ms(ms), do: System.monotonic_time(:millisecond) + ms

  # Validators run inline in this GenServer's process, so a crashing
  # validator would otherwise take down the executor. Trap raise/throw/exit
  # and treat any failure as a validation rejection.
  defp run_validator(validator, args, state) do
    try do
      case validator.(args, state) do
        :ok -> :ok
        {:error, _} = err -> err
      end
    rescue
      e -> {:error, {:validator_crashed, inspect(e)}}
    catch
      kind, value -> {:error, {:validator_crashed, "#{kind}: #{inspect(value)}"}}
    end
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

  # Single entry point for spawning a sync handler. If one is already running,
  # queue this dispatch behind it. Handlers run serially in dispatch order so
  # each one observes the prior one's mutations to receive_state.
  defp dispatch_sync_handler(handler, handler_args, update_from, state) do
    cond do
      state.sync_handler_pid == nil ->
        spawn_sync_handler(handler, handler_args, update_from, state)

      state.pending_handler_count >= state.max_pending_handlers ->
        # Cap reached. Updates need a response so the caller doesn't hang;
        # signals are fire-and-forget so we just drop with a warning.
        Logger.warning(
          "Executor #{state.run_id}: handler queue at cap #{state.max_pending_handlers}; " <>
            "rejecting (update_from=#{inspect(update_from)})"
        )

        if update_from do
          emit_update_rejected(state, update_from, "handler queue full")
        else
          state
        end

      true ->
        entry = {handler, handler_args, update_from}

        %{
          state
          | pending_handler_queue: :queue.in(entry, state.pending_handler_queue),
            pending_handler_count: state.pending_handler_count + 1
        }
    end
  end

  defp spawn_sync_handler(handler, handler_args, update_from, state) do
    executor = self()

    pid =
      spawn_link(fn ->
        Process.put(:__temporal_executor__, executor)
        Process.put(:__temporal_in_handler__, true)
        exit({:handler_result, apply(handler, handler_args)})
      end)

    %{state | sync_handler_pid: pid, sync_handler_update_from: update_from}
  end

  # Drain one queued handler when the current one finishes. Refetches
  # receive_state at spawn time so each handler sees the freshest state.
  # If the receive has already ended (status moved past :receive_stopping),
  # drain the entire queue instead — emit :rejected for any update entries
  # so their callers don't hang.
  defp maybe_dispatch_next_handler(state) do
    cond do
      state.status not in [:in_receive, :receive_stopping] ->
        drain_queued_handlers_post_receive(state)

      state.sync_handler_pid != nil ->
        state

      true ->
        case :queue.out(state.pending_handler_queue) do
          {{:value, {handler, handler_args, update_from}}, rest} ->
            spawn_sync_handler(
              handler,
              refresh_handler_args(handler_args, state),
              update_from,
              %{
                state
                | pending_handler_queue: rest,
                  pending_handler_count: state.pending_handler_count - 1
              }
            )

          {:empty, _} ->
            state
        end
    end
  end

  defp drain_queued_handlers_post_receive(state) do
    state =
      Enum.reduce(:queue.to_list(state.pending_handler_queue), state, fn
        {_handler, _args, nil}, s ->
          s

        {_handler, _args, protocol_instance_id}, s ->
          emit_update_rejected(s, protocol_instance_id, "receive ended before handler ran")
      end)

    %{state | pending_handler_queue: :queue.new(), pending_handler_count: 0}
  end

  # When a queued handler runs, it should see the latest receive_state, not
  # the snapshot at queue-time. Args lists end with the receive_state slot
  # (handlers take [payload, state] or [decoded_args, state]).
  defp refresh_handler_args([_ | _] = args, state) do
    case Enum.reverse(args) do
      [_old_state | rest] -> Enum.reverse([state.receive_state | rest])
      _ -> args
    end
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

  defp do_flush(%{flush_to: pid} = state) when is_pid(pid) do
    commands = Enum.reverse(state.commands)
    send(pid, {:flushed, state.run_id, commands})
    {:noreply, %{state | commands: []}}
  end

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
