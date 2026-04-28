defmodule Temporalex.Testing.Executor do
  @moduledoc false
  # Test executor GenServer. Implements the same call protocol as production
  # executor, but in step-by-step mode for deterministic testing.
  #
  # Spawned processes (runner, handlers, parallel branches) communicate
  # completion via exit reasons. We trap exits to catch them as messages.
  #
  # The pending_queue holds {descriptor, workflow_from} tuples — one per
  # concurrent blocking call. Parallel branches and async handlers can
  # create multiple entries simultaneously.

  use GenServer

  defstruct workflow_module: nil,
            runner_pid: nil,
            pending_queue: nil,
            test_caller: nil,
            delivered_from: nil,
            published_state: nil,
            receive_state: nil,
            receive_opts: nil,
            receive_from: nil,
            async_handlers: nil,
            async_tracker: %{},
            signal_buffer: [],
            signal_waiters: %{},
            parallels: %{},
            branch_to_parallel: %{},
            sync_handler_pid: nil,
            sync_handler_update_from: nil,
            pending_handler_queue: nil,
            receive_timer_ref: nil,
            receive_timer_id: nil,
            receive_stop_value: nil,
            cancelled: false,
            result: nil,
            status: :starting,
            # Replay / versioning controls (driven by test API).
            is_replaying: false,
            patches: nil

  # --- Init ---

  @impl true
  def init({module, args, opts}) do
    Process.flag(:trap_exit, true)
    executor = self()

    is_replaying = Keyword.get(opts, :is_replaying, false)
    seen_patches = Keyword.get(opts, :seen_patches, []) |> MapSet.new()

    pid =
      spawn_link(fn ->
        Process.put(:__temporal_executor__, executor)
        result = module.run(args)
        exit({:workflow_result, result})
      end)

    {:ok,
     %__MODULE__{
       workflow_module: module,
       runner_pid: pid,
       pending_queue: :queue.new(),
       pending_handler_queue: :queue.new(),
       async_handlers: MapSet.new(),
       patches: seen_patches,
       is_replaying: is_replaying,
       status: :running
     }}
  end

  # Backwards-compatible init clause for callers still using the old
  # 2-tuple form.
  def init({module, args}), do: init({module, args, []})

  # --- Test API: next / resolve ---

  @impl true
  def handle_call(:next, _from, %{status: :done} = state) do
    {:reply, state.result, state}
  end

  def handle_call(:next, from, state) do
    try_deliver_to_test(from, state)
  end

  def handle_call({:resolve, _result}, _from, %{status: :done} = state) do
    {:reply, state.result, state}
  end

  def handle_call({:resolve, result}, from, state) do
    state = unblock_head(state, result)
    try_deliver_to_test(from, state)
  end

  # --- Test API: query / cancel ---

  def handle_call({:query, name, args}, _from, state) do
    response =
      try do
        state.workflow_module.handle_query(name, args, state.published_state)
      rescue
        e -> {:reply, {:error, inspect(e)}}
      end

    {:reply, response, state}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, %{state | cancelled: true}}
  end

  # Mark this executor as replaying; `patched?` will return false for any
  # patch that isn't already in state.patches (i.e. not in history).
  def handle_call(:set_replaying, _from, state) do
    {:reply, :ok, %{state | is_replaying: true}}
  end

  # Pre-populate seen patches, mirroring notify_has_patch jobs from a
  # replay activation.
  def handle_call({:mark_patch_seen, patch_id}, _from, state) do
    {:reply, :ok, %{state | patches: MapSet.put(state.patches, patch_id)}}
  end

  # --- Test API: signal delivery ---

  def handle_call({:send_signal, name, payload}, _from, %{status: :in_receive} = state) do
    signal_handlers = Keyword.get(state.receive_opts, :signal, %{})

    case Map.get(signal_handlers, name) do
      nil ->
        {:reply, :buffered, %{state | signal_buffer: state.signal_buffer ++ [{name, payload}]}}

      handler ->
        dispatch_sync_handler(handler, payload, nil, state)
    end
  end

  def handle_call({:send_signal, name, payload}, _from, state) do
    {:reply, :buffered, buffer_signal(state, name, payload)}
  end

  # --- Test API: update delivery ---

  def handle_call({:send_update, name, args}, from, %{status: :in_receive} = state) do
    update_handlers = Keyword.get(state.receive_opts, :update, %{})

    case Map.get(update_handlers, name) do
      nil ->
        {:reply, {:error, :no_handler}, state}

      {handler, opts} when is_list(opts) ->
        validator = Keyword.get(opts, :validator)

        if validator do
          case validator.(args, state.receive_state) do
            :ok -> dispatch_sync_handler(handler, args, from, state)
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        else
          dispatch_sync_handler(handler, args, from, state)
        end

      handler when is_function(handler) ->
        dispatch_sync_handler(handler, args, from, state)
    end
  end

  def handle_call({:send_update, _name, _args}, _from, state) do
    {:reply, {:error, :not_in_receive}, state}
  end

  # --- Workflow API calls (from runner/handler processes) ---

  def handle_call({:execute_activity, type, input, opts}, from, state) do
    {:noreply, enqueue_pending(state, {:activity, %{type: type, input: input, opts: opts}}, from)}
  end

  def handle_call({:execute_local_activity, type, input, opts}, from, state) do
    {:noreply,
     enqueue_pending(state, {:local_activity, %{type: type, input: input, opts: opts}}, from)}
  end

  def handle_call({:start_child_workflow, workflow_type, args, opts}, from, state) do
    {:noreply,
     enqueue_pending(
       state,
       {:child_workflow, %{workflow_type: workflow_type, args: args, opts: opts}},
       from
     )}
  end

  def handle_call({:sleep, duration_ms}, from, state) do
    {:noreply, enqueue_pending(state, {:sleep, duration_ms}, from)}
  end

  def handle_call({:wait_for_signal, name}, from, state) do
    case pop_signal(state.signal_buffer, name) do
      {payload, remaining} ->
        {:reply, payload, %{state | signal_buffer: remaining}}

      nil ->
        waiters = Map.put(state.signal_waiters, name, from)
        {:noreply, enqueue_pending(%{state | signal_waiters: waiters}, {:signal, name}, nil)}
    end
  end

  def handle_call({:side_effect, fun}, _from, state) do
    {:reply, fun.(), state}
  end

  def handle_call({:publish_state, new_state}, _from, state) do
    {:reply, :ok, %{state | published_state: new_state}}
  end

  def handle_call({:patched?, patch_id}, _from, state) do
    cond do
      MapSet.member?(state.patches, patch_id) ->
        {:reply, true, state}

      state.is_replaying ->
        {:reply, false, state}

      true ->
        {:reply, true, %{state | patches: MapSet.put(state.patches, patch_id)}}
    end
  end

  def handle_call({:deprecate_patch, _patch_id}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:cancelled?, _from, state) do
    {:reply, state.cancelled, state}
  end

  def handle_call({:receive, initial_state, opts}, from, state) do
    signal_handlers = Keyword.get(opts, :signal, %{})
    update_handlers = Keyword.get(opts, :update, %{})
    timeout = Keyword.get(opts, :timeout)

    state = %{
      state
      | receive_state: initial_state,
        receive_opts: opts,
        receive_from: from,
        status: :in_receive
    }

    state = arm_receive_timer(state, timeout)
    state = drain_buffered_signals(state)

    receive_info =
      {:receive,
       %{
         signals: Map.keys(signal_handlers),
         updates: Map.keys(update_handlers),
         timeout: timeout
       }}

    if state.sync_handler_pid do
      {:noreply, state}
    else
      {:noreply, enqueue_pending(state, receive_info, nil)}
    end
  end

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

  def handle_call({:update_state, fun}, _from, %{status: status} = state)
      when status in [:in_receive, :receive_stopping] do
    {result, new_receive_state} = fun.(state.receive_state)
    {:reply, result, %{state | receive_state: new_receive_state}}
  end

  # --- Process exits (trapped) ---

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.runner_pid -> handle_runner_exit(reason, state)
      pid == state.sync_handler_pid -> handle_sync_handler_exit(reason, state)
      Map.has_key?(state.async_tracker, pid) -> handle_async_handler_exit(pid, reason, state)
      Map.has_key?(state.branch_to_parallel, pid) -> handle_parallel_exit(pid, reason, state)
      true -> {:noreply, state}
    end
  end

  # Receive timer fired. Replies {:timeout, receive_state} to the runner
  # and tears down the receive. Stale fires (after the receive already
  # exited normally) are ignored via the timer_id check.
  def handle_info({:receive_timeout, id}, %{receive_timer_id: id} = state)
      when state.status in [:in_receive, :receive_stopping] do
    state = %{state | receive_timer_ref: nil, receive_timer_id: nil}
    timeout_reply = {:timeout, state.receive_state}

    if MapSet.size(state.async_handlers) > 0 do
      # Pending async handlers — wait for them, then complete with the
      # captured timeout value.
      {:noreply, %{state | status: :receive_stopping, receive_stop_value: timeout_reply}}
    else
      do_complete_receive(state, timeout_reply)
    end
  end

  def handle_info({:receive_timeout, _stale_id}, state), do: {:noreply, state}

  # --- Private: runner exit ---

  defp handle_runner_exit({:workflow_result, result}, state), do: finish(state, result)
  defp handle_runner_exit(:normal, state), do: {:noreply, state}
  defp handle_runner_exit(reason, state), do: finish(state, {:error, {:crashed, reason}})

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

  # --- Private: handler dispatch ---

  defp dispatch_sync_handler(handler, payload, update_from, state) do
    state =
      if state.sync_handler_pid do
        # Another sync handler is already running — queue this one. Handlers
        # serialize: only one runs at a time (matches real Temporal's
        # activation-level ordering). State is fetched at spawn time so the
        # handler always sees the freshest receive_state.
        entry = {handler, payload, update_from}
        %{state | pending_handler_queue: :queue.in(entry, state.pending_handler_queue)}
      else
        spawn_sync_handler(handler, payload, update_from, state)
      end

    # Signals are fire-and-forget (update_from == nil): reply :ok now.
    # Updates hold the caller until the handler's return value produces a reply.
    if update_from do
      {:noreply, state}
    else
      {:reply, :ok, state}
    end
  end

  defp spawn_sync_handler(handler, payload, update_from, state) do
    executor = self()
    current_state = state.receive_state

    pid =
      spawn_link(fn ->
        Process.put(:__temporal_executor__, executor)
        Process.put(:__temporal_in_handler__, true)
        exit({:handler_result, handler.(payload, current_state)})
      end)

    %{state | sync_handler_pid: pid, sync_handler_update_from: update_from}
  end

  defp maybe_dispatch_next_handler(state) do
    if state.sync_handler_pid == nil do
      case :queue.out(state.pending_handler_queue) do
        {{:value, {handler, payload, update_from}}, rest} ->
          spawn_sync_handler(handler, payload, update_from, %{
            state
            | pending_handler_queue: rest
          })

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  # --- Private: apply handler return values ---

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
    signal_handlers = Keyword.get(state.receive_opts, :signal, %{})

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
            exit({:handler_result, handler.(payload, state.receive_state)})
          end)

        %{state | signal_buffer: before ++ rest, sync_handler_pid: pid}
    end
  end

  defp drain_and_continue(state) do
    state = maybe_dispatch_next_handler(state)
    state = drain_buffered_signals(state)

    if notify_test_receiving?(state) do
      {:noreply, notify_test_receiving(state)}
    else
      {:noreply, state}
    end
  end

  defp notify_test_receiving?(state) do
    state.status == :in_receive and
      state.test_caller != nil and
      :queue.is_empty(state.pending_queue) and
      state.sync_handler_pid == nil and
      MapSet.size(state.async_handlers) == 0
  end

  defp notify_test_receiving(state) do
    signal_handlers = Keyword.get(state.receive_opts || [], :signal, %{})
    update_handlers = Keyword.get(state.receive_opts || [], :update, %{})
    timeout = Keyword.get(state.receive_opts || [], :timeout)

    GenServer.reply(
      state.test_caller,
      {:receive,
       %{
         signals: Map.keys(signal_handlers),
         updates: Map.keys(update_handlers),
         timeout: timeout
       }}
    )

    %{state | test_caller: nil}
  end

  defp complete_receive(state, final_state) do
    state = cancel_receive_timer(state)

    if MapSet.size(state.async_handlers) > 0 do
      {:noreply, %{state | status: :receive_stopping}}
    else
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

  # --- Private: receive timeout ---

  defp arm_receive_timer(state, nil), do: state

  defp arm_receive_timer(state, timeout) when is_integer(timeout) and timeout >= 0 do
    timer_id = make_ref()
    timer_ref = Process.send_after(self(), {:receive_timeout, timer_id}, timeout)
    %{state | receive_timer_ref: timer_ref, receive_timer_id: timer_id}
  end

  defp cancel_receive_timer(%{receive_timer_ref: nil} = state), do: state

  defp cancel_receive_timer(%{receive_timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    # Drain a stale message if it was already in the mailbox.
    receive do
      {:receive_timeout, _} -> :ok
    after
      0 -> :ok
    end

    %{state | receive_timer_ref: nil, receive_timer_id: nil}
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

  defp maybe_complete_receive(state) do
    # If test is waiting and nothing else is pending, let it know
    # we're back in receive so it can send more signals/updates.
    if state.test_caller && :queue.is_empty(state.pending_queue) do
      signal_handlers = Keyword.get(state.receive_opts || [], :signal, %{})
      update_handlers = Keyword.get(state.receive_opts || [], :update, %{})
      timeout = Keyword.get(state.receive_opts || [], :timeout)

      GenServer.reply(
        state.test_caller,
        {:receive,
         %{
           signals: Map.keys(signal_handlers),
           updates: Map.keys(update_handlers),
           timeout: timeout
         }}
      )

      {:noreply, %{state | test_caller: nil}}
    else
      {:noreply, state}
    end
  end

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

  # --- Private: pending queue ---

  # Enqueue a pending call. If the test is waiting, deliver immediately
  # (and don't queue — it's been consumed by the direct delivery).
  defp enqueue_pending(state, descriptor, workflow_from) do
    if state.test_caller do
      GenServer.reply(state.test_caller, descriptor)
      %{state | delivered_from: workflow_from, test_caller: nil}
    else
      q = :queue.in({descriptor, workflow_from}, state.pending_queue)
      %{state | pending_queue: q}
    end
  end

  # Try to deliver the head of the queue to a waiting test process.
  # If queue is empty, park the test_caller.
  defp try_deliver_to_test(test_from, state) do
    case :queue.out(state.pending_queue) do
      {{:value, {descriptor, workflow_from}}, rest} ->
        {:reply, descriptor,
         %{state | pending_queue: rest, delivered_from: workflow_from, test_caller: nil}}

      {:empty, _} ->
        {:noreply, %{state | test_caller: test_from}}
    end
  end

  # Unblock the last delivered entry with the provided result.
  defp unblock_head(state, result) do
    workflow_from = state.delivered_from
    state = %{state | delivered_from: nil}

    cond do
      workflow_from != nil ->
        GenServer.reply(workflow_from, result)
        state

      true ->
        state
    end
  end

  defp finish(state, result) do
    state = %{state | status: :done, result: result, pending_queue: :queue.new()}

    if state.test_caller do
      GenServer.reply(state.test_caller, result)
      {:noreply, %{state | test_caller: nil}}
    else
      {:noreply, state}
    end
  end
end
