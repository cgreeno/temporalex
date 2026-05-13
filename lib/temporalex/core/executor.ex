defmodule Temporalex.Core.Executor do
  @moduledoc """
  Deterministic workflow executor for the core implementation slices.

  The executor processes one activation at a time. While an activation is open it
  grants explicit turns to workflow processes and handles their `GenServer.call/3`
  messages directly so command ordering is owned by executor state, not by BEAM
  process scheduling.
  """

  use GenServer

  import Bitwise

  alias Temporalex.Core.Activation
  alias Temporalex.Core.Command
  alias Temporalex.Core.Completion
  alias Temporalex.Core.Context
  alias Temporalex.Core.Job
  alias Temporalex.Core.Nondeterminism
  alias Temporalex.Core.Op
  alias Temporalex.Core.ParallelScope
  alias Temporalex.Core.Pending
  alias Temporalex.Core.Phase
  alias Temporalex.Core.SchedulerViolation
  alias Temporalex.Core.Thread
  alias Temporalex.Workflow.API

  defmodule State do
    @moduledoc false

    defstruct run_id: nil,
              workflow_module: nil,
              workflow_id: nil,
              workflow_type: nil,
              arguments: [],
              workflow_info: %{},
              timestamp: nil,
              is_replaying: false,
              history_length: 0,
              history_size_bytes: nil,
              continue_as_new_suggested: false,
              available_internal_flags: [],
              deployment_version: nil,
              randomness_seed: 0,
              patch_ids: MapSet.new(),
              patch_markers: MapSet.new(),
              cancelled?: false,
              initialized?: false,
              evicted?: false,
              published_state: nil,
              signal_buffer: [],
              signal_waiters: %{},
              next_seq: 0,
              commands: [],
              expected_commands: nil,
              expected_index: 0,
              activation_failed: nil,
              pending: %{},
              threads: %{},
              running: nil,
              round: 0,
              current_round: [],
              next_round: [],
              in_round?: false,
              parallel_scopes: %{},
              next_scope_id: 0,
              phase: nil,
              next_phase_id: 0
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def activate(executor, %Activation{} = activation, opts \\ []) do
    GenServer.call(executor, {:activate, activation, opts}, :infinity)
  end

  def inspect_state(executor) do
    GenServer.call(executor, :inspect_state)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %State{
       run_id: Keyword.get(opts, :run_id),
       workflow_module: Keyword.fetch!(opts, :workflow_module)
     }}
  end

  @impl GenServer
  def handle_call(:inspect_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:activate, %Activation{} = activation, opts}, _from, state) do
    state = prepare_activation(state, activation, opts)

    {completion, state} =
      if eviction_only?(activation.jobs) do
        state = teardown_threads(%{state | evicted?: true})
        {%Completion{run_id: activation.run_id, status: {:ok, []}}, finish_activation(state)}
      else
        {query_jobs, state} = apply_jobs(activation.jobs, [], state)

        state =
          query_jobs
          |> Enum.reverse()
          |> Enum.reduce(state, &respond_to_query/2)

        state =
          if query_only?(activation.jobs) do
            state
          else
            state
            |> maybe_dispatch_phase()
            |> drain_scheduler()
          end

        completion = completion_from_state(state)
        {completion, finish_activation(state)}
      end

    {:reply, completion, state}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, state) do
    {:noreply, handle_thread_exit(state, pid, reason)}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp prepare_activation(state, activation, opts) do
    %{
      state
      | run_id: activation.run_id || state.run_id,
        timestamp: activation.timestamp,
        is_replaying: activation.is_replaying,
        history_length: activation.history_length,
        history_size_bytes: activation.history_size_bytes,
        continue_as_new_suggested: activation.continue_as_new_suggested,
        available_internal_flags: activation.available_internal_flags,
        deployment_version: activation.deployment_version,
        commands: [],
        expected_commands: Keyword.get(opts, :expected_commands),
        expected_index: 0,
        activation_failed: nil
    }
  end

  defp finish_activation(state) do
    %{state | commands: [], expected_commands: nil, expected_index: 0, activation_failed: nil}
  end

  defp eviction_only?([%Job.RemoveFromCache{} | rest]),
    do: Enum.all?(rest, &match?(%Job.RemoveFromCache{}, &1))

  defp eviction_only?(_jobs), do: false

  defp query_only?(jobs) when jobs != [] do
    Enum.all?(jobs, &match?(%Job.QueryReceived{}, &1))
  end

  defp query_only?(_jobs), do: false

  defp apply_jobs([], query_jobs, state), do: {query_jobs, state}

  defp apply_jobs([job | rest], query_jobs, state) do
    {query_jobs, state} =
      case job do
        %Job.InitializeWorkflow{} = init ->
          {query_jobs, initialize_workflow(state, init)}

        %Job.UpdateRandomSeed{randomness_seed: seed} ->
          {query_jobs, %{state | randomness_seed: seed}}

        %Job.ActivityResolved{seq: seq, result: result} ->
          {query_jobs, resolve_pending(state, seq, result)}

        %Job.TimerFired{seq: seq} ->
          {query_jobs, resolve_pending(state, seq, :timer_fired)}

        %Job.SignalReceived{} = signal ->
          {query_jobs, receive_signal(state, signal)}

        %Job.UpdateReceived{} = update ->
          {query_jobs, receive_update(state, update)}

        %Job.QueryReceived{} = query ->
          {[query | query_jobs], state}

        %Job.CancelWorkflow{} ->
          {query_jobs, %{state | cancelled?: true}}

        %Job.NotifyPatch{id: id} ->
          {query_jobs, %{state | patch_ids: MapSet.put(state.patch_ids, id)}}

        %Job.RemoveFromCache{} ->
          {query_jobs, teardown_threads(%{state | evicted?: true})}
      end

    apply_jobs(rest, query_jobs, state)
  end

  defp initialize_workflow(%State{initialized?: true} = state, _init), do: state

  defp initialize_workflow(state, %Job.InitializeWorkflow{} = init) do
    args = init.arguments
    workflow_module = state.workflow_module

    run_fun = fn ->
      input =
        case args do
          [single] -> single
          many -> many
        end

      workflow_module.run(input)
    end

    workflow_type =
      if function_exported?(workflow_module, :__workflow_type__, 0) do
        workflow_module.__workflow_type__()
      else
        init.workflow_type || inspect(workflow_module)
      end

    state =
      %{
        state
        | workflow_id: init.workflow_id,
          workflow_type: workflow_type,
          arguments: args,
          workflow_info:
            Map.merge(init.workflow_info || %{}, %{
              workflow_id: init.workflow_id,
              workflow_type: workflow_type
            }),
          randomness_seed: init.randomness_seed,
          initialized?: true
      }

    spawn_thread(state, [], :root, run_fun)
  end

  defp drain_scheduler(%State{activation_failed: nil} = state) do
    runnable = ready_thread_ids(state)

    state
    |> Map.put(:current_round, runnable)
    |> Map.put(:next_round, [])
    |> Map.put(:in_round?, true)
    |> drain_rounds()
  end

  defp drain_scheduler(state), do: state

  defp drain_rounds(%State{activation_failed: nil} = state) do
    drain_rounds_open(state)
  end

  defp drain_rounds(state), do: %{state | in_round?: false, running: nil}

  defp drain_rounds_open(%State{current_round: [], next_round: []} = state) do
    %{state | in_round?: false, running: nil}
  end

  defp drain_rounds_open(%State{current_round: [], next_round: next_round} = state) do
    current_round = next_round |> Enum.uniq() |> Enum.sort()
    drain_rounds(%{state | round: state.round + 1, current_round: current_round, next_round: []})
  end

  defp drain_rounds_open(%State{current_round: [thread_id | rest]} = state) do
    state = %{state | current_round: rest}

    case Map.fetch(state.threads, thread_id) do
      {:ok, %Thread{status: :ready}} ->
        state
        |> run_thread_step(thread_id)
        |> maybe_dispatch_phase()
        |> drain_rounds()

      _ ->
        drain_rounds(state)
    end
  end

  defp ready_thread_ids(state) do
    state.threads
    |> Enum.filter(fn {_id, thread} -> thread.status == :ready end)
    |> Enum.map(fn {id, _thread} -> id end)
    |> Enum.sort()
  end

  defp run_thread_step(state, thread_id) do
    thread = Map.fetch!(state.threads, thread_id)
    state = put_thread(state, %{thread | status: :running})
    state = %{state | running: thread_id}

    state =
      case thread.resume do
        {from, value} ->
          GenServer.reply(from, value)
          put_thread(state, %{thread | status: :running, resume: nil, started?: true})

        nil ->
          if thread.started? do
            state
          else
            send(thread.pid, {:temporalex_run, thread_id})
            put_thread(state, %{thread | status: :running, started?: true})
          end
      end

    wait_for_thread_event(state, thread_id)
  end

  defp wait_for_thread_event(%State{activation_failed: nil} = state, thread_id) do
    wait_for_thread_event_open(state, thread_id)
  end

  defp wait_for_thread_event(state, _thread_id), do: %{state | running: nil}

  defp wait_for_thread_event_open(state, thread_id) do
    receive do
      {:"$gen_call", from, {:workflow_op, caller_thread_id, op}} ->
        state =
          if caller_thread_id == thread_id and state.running == thread_id do
            handle_workflow_op(state, from, caller_thread_id, op)
          else
            violation =
              SchedulerViolation.exception(thread_id: caller_thread_id, running: state.running)

            GenServer.reply(from, {:error, violation})
            fail_activation(state, violation)
          end

        case Map.get(state.threads, thread_id) do
          %Thread{status: :running} ->
            wait_for_thread_event(state, thread_id)

          _ ->
            %{state | running: nil}
        end

      {:temporalex_thread_completed, ^thread_id, result} ->
        state
        |> complete_thread(thread_id, result)
        |> Map.put(:running, nil)

      {:temporalex_thread_failed, ^thread_id, reason} ->
        state
        |> fail_thread(thread_id, reason)
        |> Map.put(:running, nil)

      {:EXIT, pid, reason} ->
        state = handle_thread_exit(state, pid, reason)

        case Map.get(state.threads, thread_id) do
          %Thread{status: :running} ->
            wait_for_thread_event(state, thread_id)

          _ ->
            %{state | running: nil}
        end
    after
      5_000 ->
        fail_activation(state, %RuntimeError{
          message: "workflow thread #{inspect(thread_id)} did not yield"
        })
    end
  end

  defp handle_workflow_op(state, from, thread_id, %Op.ExecuteActivity{} = op) do
    seq = state.next_seq
    activity_id = Keyword.get(op.opts, :activity_id, "activity-#{seq}")

    command = %Command.ScheduleActivity{
      seq: seq,
      thread_id: thread_id,
      activity_id: activity_id,
      type: op.type,
      input: op.input,
      opts: op.opts
    }

    state
    |> append_command(command)
    |> put_pending(seq, thread_id, from, op)
    |> block_thread(thread_id)
    |> Map.update!(:next_seq, &(&1 + 1))
  end

  defp handle_workflow_op(state, from, thread_id, %Op.Sleep{} = op) do
    seq = state.next_seq
    command = %Command.StartTimer{seq: seq, thread_id: thread_id, duration_ms: op.duration_ms}

    state
    |> append_command(command)
    |> put_pending(seq, thread_id, from, op)
    |> block_thread(thread_id)
    |> Map.update!(:next_seq, &(&1 + 1))
  end

  defp handle_workflow_op(state, from, thread_id, %Op.WaitForSignal{name: name} = op) do
    case pop_buffered_signal(state.signal_buffer, name) do
      {:ok, args, signal_buffer} ->
        GenServer.reply(from, args)
        %{state | signal_buffer: signal_buffer}

      :error ->
        waiter = %{thread_id: thread_id, from: from, op: op}

        signal_waiters =
          Map.update(
            state.signal_waiters,
            name,
            :queue.from_list([waiter]),
            &:queue.in(waiter, &1)
          )

        state
        |> Map.put(:signal_waiters, signal_waiters)
        |> block_thread(thread_id)
    end
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.PublishState{state: published_state}) do
    GenServer.reply(from, :ok)
    %{state | published_state: published_state}
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.WorkflowInfo{}) do
    GenServer.reply(from, state.workflow_info)
    state
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.Cancelled{}) do
    GenServer.reply(from, state.cancelled?)
    state
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.Now{}) do
    GenServer.reply(from, state.timestamp)
    state
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.Random{}) do
    {value, seed} = next_random_float(state.randomness_seed)
    GenServer.reply(from, value)
    %{state | randomness_seed: seed}
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.UUID4{}) do
    {uuid, seed} = next_uuid4(state.randomness_seed)
    GenServer.reply(from, uuid)
    %{state | randomness_seed: seed}
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.Patched{id: id}) do
    {patched?, state} = apply_patch_check(state, id)
    GenServer.reply(from, patched?)
    state
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.DeprecatePatch{id: id}) do
    state = apply_patch_deprecation(state, id)
    GenServer.reply(from, :ok)
    state
  end

  defp handle_workflow_op(state, from, _thread_id, %Op.UpsertSearchAttributes{attrs: attrs}) do
    state = append_command(state, %Command.UpsertSearchAttributes{attrs: attrs})
    GenServer.reply(from, :ok)
    state
  end

  defp handle_workflow_op(state, from, thread_id, %Op.Parallel{funs: []}) do
    GenServer.reply(from, [])
    put_thread(state, %{Map.fetch!(state.threads, thread_id) | status: :running})
  end

  defp handle_workflow_op(state, from, thread_id, %Op.Parallel{funs: funs}) do
    scope_id = state.next_scope_id

    scope = %ParallelScope{
      id: scope_id,
      parent_thread_id: thread_id,
      from: from,
      size: length(funs),
      remaining: length(funs)
    }

    state =
      state
      |> Map.put(:next_scope_id, scope_id + 1)
      |> Map.update!(:parallel_scopes, &Map.put(&1, scope_id, scope))
      |> block_thread(thread_id)

    funs
    |> Enum.with_index()
    |> Enum.reduce(state, fn {fun, index}, acc ->
      child_id = thread_id ++ [{:p, index}]

      acc
      |> spawn_thread(child_id, :parallel_branch, fun, parent_scope: scope_id, index: index)
      |> enqueue_ready(child_id)
    end)
  end

  defp handle_workflow_op(state, from, thread_id, %Op.Phase{
         initial_state: initial_state,
         opts: opts
       }) do
    if state.phase do
      error = %RuntimeError{message: "nested phases are not supported by the Slice 2 core"}
      GenServer.reply(from, {:error, error})
      fail_activation(state, error)
    else
      phase_id = state.next_phase_id
      phase = build_phase(phase_id, thread_id, from, initial_state, opts)

      state =
        state
        |> Map.put(:next_phase_id, phase_id + 1)
        |> Map.put(:phase, phase)
        |> block_thread(thread_id)
        |> maybe_start_phase_timer()
        |> consume_buffered_phase_signals()

      state
    end
  end

  defp handle_workflow_op(state, from, thread_id, %Op.UpdateState{fun: fun}) do
    thread = Map.fetch!(state.threads, thread_id)

    cond do
      thread.kind not in [:async_signal_handler, :async_update_handler] ->
        GenServer.reply(from, {:error, :not_async_phase_handler})
        state

      state.phase == nil ->
        GenServer.reply(from, {:error, :no_active_phase})
        state

      true ->
        try do
          case fun.(state.phase.state) do
            {result, new_state} ->
              phase = %{state.phase | state: new_state}
              GenServer.reply(from, result)
              %{state | phase: phase}

            other ->
              GenServer.reply(from, {:error, {:invalid_update_state_return, other}})
              state
          end
        rescue
          error ->
            GenServer.reply(from, {:error, error})
            state
        catch
          kind, reason ->
            GenServer.reply(from, {:error, {kind, reason}})
            state
        end
    end
  end

  defp put_pending(state, seq, thread_id, from, op) do
    pending = %Pending{seq: seq, thread_id: thread_id, from: from, op: op}
    put_in(state.pending[seq], pending)
  end

  defp block_thread(state, thread_id) do
    thread = Map.fetch!(state.threads, thread_id)
    put_thread(state, %{thread | status: :blocked})
  end

  defp resolve_pending(state, seq, result) do
    case Map.pop(state.pending, seq) do
      {nil, pending} ->
        fail_activation(%{state | pending: pending}, %Nondeterminism{
          message: "activation resolved unknown command sequence #{inspect(seq)}",
          expected: Map.keys(state.pending),
          actual: seq
        })

      {%Pending{op: %Op.ExecuteActivity{}, thread_id: thread_id, from: from}, pending} ->
        state
        |> Map.put(:pending, pending)
        |> ready_thread(thread_id, {from, result})

      {%Pending{op: %Op.Sleep{}, thread_id: thread_id, from: from}, pending} ->
        state
        |> Map.put(:pending, pending)
        |> ready_thread(thread_id, {from, :ok})

      {%Pending{op: {:phase_timeout, phase_id}}, pending} ->
        state
        |> Map.put(:pending, pending)
        |> fire_phase_timeout(phase_id)
    end
  end

  defp receive_signal(state, %Job.SignalReceived{} = signal) do
    cond do
      phase_accepts_signal?(state.phase, signal.name) ->
        enqueue_phase_message(
          state,
          {:signal, signal.name, signal.args, signal.headers, signal.identity}
        )

      has_signal_waiter?(state, signal.name) ->
        resolve_signal_waiter(state, signal.name, signal.args)

      true ->
        %{state | signal_buffer: state.signal_buffer ++ [signal]}
    end
  end

  defp has_signal_waiter?(state, name) do
    case Map.get(state.signal_waiters, name) do
      nil -> false
      queue -> not :queue.is_empty(queue)
    end
  end

  defp resolve_signal_waiter(state, name, args) do
    {queue, waiter} =
      state.signal_waiters
      |> Map.fetch!(name)
      |> :queue.out()
      |> case do
        {{:value, waiter}, queue} -> {queue, waiter}
      end

    signal_waiters =
      if :queue.is_empty(queue) do
        Map.delete(state.signal_waiters, name)
      else
        Map.put(state.signal_waiters, name, queue)
      end

    state
    |> Map.put(:signal_waiters, signal_waiters)
    |> ready_thread(waiter.thread_id, {waiter.from, args})
  end

  defp pop_buffered_signal(buffer, name) do
    {before_match, rest} = Enum.split_while(buffer, fn signal -> signal.name != name end)

    case rest do
      [%Job.SignalReceived{args: args} | after_match] -> {:ok, args, before_match ++ after_match}
      [] -> :error
    end
  end

  defp receive_update(state, %Job.UpdateReceived{} = update) do
    with %Phase{} = phase <- state.phase,
         {:ok, handler, validator} <- update_handler(phase, update.name),
         false <- phase.stopping? do
      case validate_update(update, validator, phase.state) do
        :ok ->
          state
          |> append_command(%Command.RespondToUpdate{
            protocol_instance_id: update.protocol_instance_id,
            response: :accepted
          })
          |> enqueue_phase_message(
            {:update, update.name, update.args, update.headers, update.protocol_instance_id,
             handler}
          )

        {:error, reason} ->
          append_command(state, %Command.RespondToUpdate{
            protocol_instance_id: update.protocol_instance_id,
            response: {:rejected, reason}
          })
      end
    else
      _ ->
        append_command(state, %Command.RespondToUpdate{
          protocol_instance_id: update.protocol_instance_id,
          response: {:rejected, {:not_accepting_update, update.name}}
        })
    end
  end

  defp validate_update(%Job.UpdateReceived{run_validator: false}, _validator, _state), do: :ok
  defp validate_update(_update, nil, _state), do: :ok

  defp validate_update(update, validator, state) do
    try do
      case validator.(update.args, state) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_validator_return, other}}
      end
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp respond_to_query(%Job.QueryReceived{} = query, state) do
    result =
      try do
        case state.workflow_module.handle_query(
               query.query_type,
               query.args,
               state.published_state
             ) do
          {:reply, value} -> {:ok, value}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:invalid_query_return, other}}
        end
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    append_command(state, %Command.RespondToQuery{query_id: query.query_id, result: result})
  end

  defp build_phase(phase_id, owner_thread_id, from, initial_state, opts) do
    %Phase{
      id: phase_id,
      owner_thread_id: owner_thread_id,
      from: from,
      state: initial_state,
      signal_handlers: Keyword.get(opts, :signal, %{}),
      update_handlers: Keyword.get(opts, :update, %{}),
      timeout_ms: Keyword.get(opts, :timeout)
    }
  end

  defp maybe_start_phase_timer(%State{phase: %Phase{timeout_ms: nil}} = state), do: state

  defp maybe_start_phase_timer(%State{phase: %Phase{} = phase} = state) do
    seq = state.next_seq

    command = %Command.StartTimer{
      seq: seq,
      thread_id: phase.owner_thread_id,
      duration_ms: phase.timeout_ms
    }

    phase = %{phase | timeout_seq: seq}

    state
    |> Map.put(:phase, phase)
    |> append_command(command)
    |> put_pending(seq, phase.owner_thread_id, nil, {:phase_timeout, phase.id})
    |> Map.update!(:next_seq, &(&1 + 1))
  end

  defp consume_buffered_phase_signals(%State{phase: nil} = state), do: state

  defp consume_buffered_phase_signals(%State{phase: phase} = state) do
    {matching, remaining} =
      Enum.split_with(state.signal_buffer, fn signal ->
        phase_accepts_signal?(phase, signal.name)
      end)

    Enum.reduce(matching, %{state | signal_buffer: remaining}, fn signal, acc ->
      enqueue_phase_message(
        acc,
        {:signal, signal.name, signal.args, signal.headers, signal.identity}
      )
    end)
  end

  defp phase_accepts_signal?(%Phase{stopping?: false} = phase, name) do
    Map.has_key?(phase.signal_handlers, name)
  end

  defp phase_accepts_signal?(_phase, _name), do: false

  defp enqueue_phase_message(%State{phase: %Phase{} = phase} = state, message) do
    phase = %{phase | queue: :queue.in(message, phase.queue)}
    %{state | phase: phase}
  end

  defp maybe_dispatch_phase(%State{phase: nil} = state), do: state

  defp maybe_dispatch_phase(%State{phase: %Phase{stopping?: true}} = state) do
    maybe_complete_phase(state)
  end

  defp maybe_dispatch_phase(%State{phase: %Phase{active_dispatch: nil} = phase} = state) do
    case :queue.out(phase.queue) do
      {{:value, message}, queue} ->
        phase = %{phase | queue: queue}
        state = %{state | phase: phase}
        spawn_phase_dispatch(state, message)

      {:empty, _queue} ->
        state
    end
  end

  defp maybe_dispatch_phase(state), do: state

  defp spawn_phase_dispatch(%State{phase: phase} = state, message) do
    dispatch_id = phase.owner_thread_id ++ [{:h, phase.dispatch_counter}]

    {fun, update_protocol_instance_id, signal?} =
      case message do
        {:signal, name, args, _headers, _identity} ->
          handler = Map.fetch!(phase.signal_handlers, name)
          {fn -> handler.(args, phase.state) end, nil, true}

        {:update, _name, args, _headers, protocol_instance_id, handler} ->
          {fn -> handler.(args, phase.state) end, protocol_instance_id, false}
      end

    phase = %{phase | active_dispatch: dispatch_id, dispatch_counter: phase.dispatch_counter + 1}

    state
    |> Map.put(:phase, phase)
    |> spawn_thread(dispatch_id, :phase_dispatch, fun,
      phase_id: phase.id,
      update_protocol_instance_id: update_protocol_instance_id,
      signal?: signal?
    )
    |> enqueue_ready(dispatch_id)
  end

  defp update_handler(%Phase{} = phase, name) do
    case Map.fetch(phase.update_handlers, name) do
      {:ok, {handler, opts}} when is_function(handler, 2) and is_list(opts) ->
        {:ok, handler, Keyword.get(opts, :validator)}

      {:ok, handler} when is_function(handler, 2) ->
        {:ok, handler, nil}

      :error ->
        :error
    end
  end

  defp fire_phase_timeout(%State{phase: %Phase{id: phase_id} = phase} = state, phase_id) do
    phase = %{phase | stopping?: true, result: :timeout, timeout_fired?: true}

    %{state | phase: phase}
    |> maybe_complete_phase()
  end

  defp fire_phase_timeout(state, _phase_id), do: state

  defp complete_thread(state, thread_id, result) do
    thread = Map.fetch!(state.threads, thread_id)

    state = put_thread(state, %{thread | status: :done, result: result})

    case thread.kind do
      :root ->
        complete_root_thread(state, result)

      :parallel_branch ->
        complete_parallel_branch(state, thread, result)

      :phase_dispatch ->
        complete_phase_dispatch(state, thread, result)

      :async_signal_handler ->
        complete_async_signal(state, thread)

      :async_update_handler ->
        complete_async_update(state, thread, {:completed, result})
    end
  end

  defp fail_thread(state, thread_id, reason) do
    thread = Map.fetch!(state.threads, thread_id)
    state = put_thread(state, %{thread | status: :failed, error: reason})

    case thread.kind do
      :root ->
        append_command(state, %Command.FailWorkflow{reason: {:exception, reason}})

      :parallel_branch ->
        complete_parallel_branch(state, thread, {:error, reason})

      :phase_dispatch ->
        fail_phase_dispatch(state, thread, reason)

      :async_signal_handler ->
        complete_async_signal(state, thread)

      :async_update_handler ->
        complete_async_update(state, thread, {:rejected, reason})
    end
  end

  defp complete_root_thread(state, {:ok, result}) do
    append_command(state, %Command.CompleteWorkflow{result: result})
  end

  defp complete_root_thread(state, {:error, reason}) do
    append_command(state, %Command.FailWorkflow{reason: reason})
  end

  defp complete_root_thread(state, {:continue_as_new, args}) do
    append_command(state, %Command.ContinueAsNew{args: args, workflow_type: state.workflow_type})
  end

  defp complete_root_thread(state, {:cancelled, _reason}) do
    append_command(state, %Command.CancelWorkflow{})
  end

  defp complete_root_thread(state, other) do
    append_command(state, %Command.FailWorkflow{reason: {:unsupported_workflow_return, other}})
  end

  defp complete_parallel_branch(state, thread, result) do
    scope = Map.fetch!(state.parallel_scopes, thread.parent_scope)
    results = Map.put(scope.results, thread.index, result)
    remaining = scope.remaining - 1
    scope = %{scope | results: results, remaining: remaining}

    state = put_in(state.parallel_scopes[scope.id], scope)

    if remaining == 0 do
      ordered_results =
        0..(scope.size - 1)
        |> Enum.map(&Map.fetch!(results, &1))

      state
      |> Map.update!(:parallel_scopes, &Map.delete(&1, scope.id))
      |> ready_thread(scope.parent_thread_id, {scope.from, ordered_results})
    else
      state
    end
  end

  defp complete_phase_dispatch(%State{phase: %Phase{} = phase} = state, thread, result) do
    phase = %{phase | active_dispatch: nil}
    state = %{state | phase: phase}

    state =
      if thread.signal? do
        apply_signal_handler_result(state, thread, result)
      else
        apply_update_handler_result(state, thread, result)
      end

    state
    |> maybe_dispatch_phase()
    |> maybe_complete_phase()
  end

  defp fail_phase_dispatch(%State{phase: %Phase{} = phase} = state, thread, reason) do
    phase = %{phase | active_dispatch: nil}
    state = %{state | phase: phase}

    state =
      if thread.signal? do
        state
      else
        append_command(state, %Command.RespondToUpdate{
          protocol_instance_id: thread.update_protocol_instance_id,
          response: {:rejected, reason}
        })
      end

    state
    |> maybe_dispatch_phase()
    |> maybe_complete_phase()
  end

  defp apply_signal_handler_result(state, _thread, {:noreply, new_state}) do
    put_phase_state(state, new_state)
  end

  defp apply_signal_handler_result(state, _thread, {:stop, new_state}) do
    state
    |> put_phase_state(new_state)
    |> stop_phase(:stop)
  end

  defp apply_signal_handler_result(state, thread, {:async, fun, new_state})
       when is_function(fun) do
    state
    |> put_phase_state(new_state)
    |> spawn_async_handler(thread, fun, :async_signal_handler)
  end

  defp apply_signal_handler_result(state, _thread, other) do
    put_phase_state(state, {:invalid_signal_handler_return, other})
  end

  defp apply_update_handler_result(state, thread, {:reply, response, new_state}) do
    state
    |> append_command(%Command.RespondToUpdate{
      protocol_instance_id: thread.update_protocol_instance_id,
      response: {:completed, response}
    })
    |> put_phase_state(new_state)
  end

  defp apply_update_handler_result(state, thread, {:stop, response, new_state}) do
    state
    |> append_command(%Command.RespondToUpdate{
      protocol_instance_id: thread.update_protocol_instance_id,
      response: {:completed, response}
    })
    |> put_phase_state(new_state)
    |> stop_phase(:stop)
  end

  defp apply_update_handler_result(state, thread, {:async, fun, new_state})
       when is_function(fun) do
    state
    |> put_phase_state(new_state)
    |> spawn_async_handler(thread, fun, :async_update_handler, thread.update_protocol_instance_id)
  end

  defp apply_update_handler_result(state, thread, other) do
    append_command(state, %Command.RespondToUpdate{
      protocol_instance_id: thread.update_protocol_instance_id,
      response: {:rejected, {:invalid_update_handler_return, other}}
    })
  end

  defp put_phase_state(%State{phase: %Phase{} = phase} = state, new_state) do
    %{state | phase: %{phase | state: new_state}}
  end

  defp spawn_async_handler(state, dispatch_thread, fun, kind, protocol_instance_id \\ nil) do
    phase = state.phase
    async_id = dispatch_thread.id ++ [{:a, 0}]
    phase_state = phase.state

    async_fun = fn ->
      case :erlang.fun_info(fun, :arity) do
        {:arity, 0} -> fun.()
        {:arity, 1} -> fun.(phase_state)
      end
    end

    phase = %{phase | async_threads: MapSet.put(phase.async_threads, async_id)}

    state
    |> Map.put(:phase, phase)
    |> spawn_thread(async_id, kind, async_fun,
      phase_id: phase.id,
      update_protocol_instance_id: protocol_instance_id
    )
    |> enqueue_ready(async_id)
  end

  defp complete_async_signal(%State{phase: nil} = state, _thread), do: state

  defp complete_async_signal(%State{phase: phase} = state, thread) do
    phase = %{phase | async_threads: MapSet.delete(phase.async_threads, thread.id)}

    %{state | phase: phase}
    |> maybe_dispatch_phase()
    |> maybe_complete_phase()
  end

  defp complete_async_update(%State{phase: nil} = state, _thread, _response), do: state

  defp complete_async_update(%State{phase: phase} = state, thread, response) do
    state =
      append_command(state, %Command.RespondToUpdate{
        protocol_instance_id: thread.update_protocol_instance_id,
        response: response
      })

    phase = %{state.phase | async_threads: MapSet.delete(phase.async_threads, thread.id)}

    %{state | phase: phase}
    |> maybe_dispatch_phase()
    |> maybe_complete_phase()
  end

  defp stop_phase(%State{phase: %Phase{}} = state, result) do
    state = maybe_cancel_phase_timer(state)
    phase = %{state.phase | stopping?: true, result: result}

    %{state | phase: phase}
    |> maybe_complete_phase()
  end

  defp maybe_cancel_phase_timer(%State{phase: %Phase{timeout_seq: nil}} = state), do: state

  defp maybe_cancel_phase_timer(%State{phase: %Phase{timeout_fired?: true}} = state), do: state

  defp maybe_cancel_phase_timer(%State{phase: %Phase{timer_cancelled?: true}} = state), do: state

  defp maybe_cancel_phase_timer(%State{phase: %Phase{} = phase} = state) do
    phase = %{phase | timer_cancelled?: true}
    state = %{state | phase: phase}

    pending =
      case phase.timeout_seq do
        nil -> state.pending
        seq -> Map.delete(state.pending, seq)
      end

    state
    |> Map.put(:pending, pending)
    |> append_command(%Command.CancelTimer{seq: phase.timeout_seq})
  end

  defp maybe_complete_phase(%State{phase: nil} = state), do: state

  defp maybe_complete_phase(%State{phase: %Phase{stopping?: false}} = state), do: state

  defp maybe_complete_phase(%State{phase: %Phase{active_dispatch: active_dispatch}} = state)
       when active_dispatch != nil,
       do: state

  defp maybe_complete_phase(%State{phase: %Phase{} = phase} = state) do
    if MapSet.size(phase.async_threads) == 0 do
      result =
        case phase.result do
          :timeout -> {:timeout, phase.state}
          _ -> phase.state
        end

      state
      |> Map.put(:phase, nil)
      |> ready_thread(phase.owner_thread_id, {phase.from, result})
    else
      state
    end
  end

  defp spawn_thread(state, thread_id, kind, fun, opts \\ []) do
    executor = self()
    phase_id = Keyword.get(opts, :phase_id)

    handler_mode =
      if kind in [:async_signal_handler, :async_update_handler], do: :async, else: nil

    pid =
      spawn_link(fn ->
        API.install_context(%Context{
          executor: executor,
          thread_id: thread_id,
          phase_id: phase_id,
          handler_mode: handler_mode
        })

        receive do
          {:temporalex_run, ^thread_id} ->
            run_thread_fun(executor, thread_id, fun)
        end
      end)

    thread = %Thread{
      id: thread_id,
      pid: pid,
      status: :ready,
      kind: kind,
      parent_scope: Keyword.get(opts, :parent_scope),
      index: Keyword.get(opts, :index),
      phase_id: phase_id,
      update_protocol_instance_id: Keyword.get(opts, :update_protocol_instance_id),
      signal?: Keyword.get(opts, :signal?, false)
    }

    put_thread(state, thread)
  end

  defp run_thread_fun(executor, thread_id, fun) do
    try do
      send(executor, {:temporalex_thread_completed, thread_id, fun.()})
    rescue
      error ->
        send(
          executor,
          {:temporalex_thread_failed, thread_id, {:exception, error, __STACKTRACE__}}
        )
    catch
      kind, reason ->
        send(executor, {:temporalex_thread_failed, thread_id, {kind, reason, __STACKTRACE__}})
    end
  end

  defp put_thread(state, %Thread{} = thread) do
    put_in(state.threads[thread.id], thread)
  end

  defp ready_thread(state, thread_id, resume) do
    thread = Map.fetch!(state.threads, thread_id)

    state
    |> put_thread(%{thread | status: :ready, resume: resume})
    |> enqueue_ready(thread_id)
  end

  defp enqueue_ready(%State{in_round?: true} = state, thread_id) do
    %{state | next_round: [thread_id | state.next_round]}
  end

  defp enqueue_ready(state, _thread_id), do: state

  defp append_command(%State{activation_failed: nil} = state, command) do
    append_command_open(state, command)
  end

  defp append_command(state, _command), do: state

  defp append_command_open(state, command) do
    state = %{state | commands: state.commands ++ [command]}

    case state.expected_commands do
      nil ->
        state

      expected_commands ->
        expected = Enum.at(expected_commands, state.expected_index)

        cond do
          expected == nil ->
            fail_activation(
              state,
              Nondeterminism.exception(
                message: "extra replay command",
                expected: nil,
                actual: command
              )
            )

          command_identity(expected) == command_identity(command) ->
            %{state | expected_index: state.expected_index + 1}

          true ->
            fail_activation(
              state,
              Nondeterminism.exception(
                message: "replay command mismatch",
                expected: expected,
                actual: command
              )
            )
        end
    end
  end

  defp command_identity(%Command.ScheduleActivity{} = command) do
    {:schedule_activity, command.seq, command.thread_id, command.activity_id, command.type,
     command.input, command.opts}
  end

  defp command_identity(%Command.StartTimer{} = command) do
    {:start_timer, command.seq, command.thread_id, command.duration_ms}
  end

  defp command_identity(%Command.CancelTimer{} = command), do: {:cancel_timer, command.seq}

  defp command_identity(%Command.CompleteWorkflow{} = command),
    do: {:complete_workflow, command.result}

  defp command_identity(%Command.FailWorkflow{} = command), do: {:fail_workflow, command.reason}
  defp command_identity(%Command.ContinueAsNew{} = command), do: {:continue_as_new, command.args}
  defp command_identity(%Command.CancelWorkflow{}), do: :cancel_workflow

  defp command_identity(%Command.RespondToUpdate{} = command),
    do: {:respond_update, command.protocol_instance_id, command.response}

  defp command_identity(%Command.RespondToQuery{} = command),
    do: {:respond_query, command.query_id, command.result}

  defp command_identity(%Command.UpsertSearchAttributes{} = command),
    do: {:upsert_search_attributes, command.attrs}

  defp command_identity(command), do: command

  defp fail_activation(state, reason) do
    %{state | activation_failed: reason}
  end

  defp completion_from_state(%State{activation_failed: nil} = state) do
    completion_from_state_open(state)
  end

  defp completion_from_state(%State{activation_failed: reason} = state) do
    %Completion{
      run_id: state.run_id,
      status: {:failed, reason, force_cause: failure_cause(reason)}
    }
  end

  defp completion_from_state_open(%State{expected_commands: expected_commands} = state)
       when is_list(expected_commands) do
    if state.expected_index == length(expected_commands) do
      %Completion{run_id: state.run_id, status: {:ok, state.commands}}
    else
      expected = Enum.at(expected_commands, state.expected_index)

      reason =
        Nondeterminism.exception(
          message: "missing replay command",
          expected: expected,
          actual: nil
        )

      %Completion{
        run_id: state.run_id,
        status: {:failed, reason, force_cause: :non_deterministic_error}
      }
    end
  end

  defp completion_from_state_open(state) do
    %Completion{run_id: state.run_id, status: {:ok, state.commands}}
  end

  defp failure_cause(%Nondeterminism{}), do: :non_deterministic_error
  defp failure_cause(%SchedulerViolation{}), do: :workflow_task_failed
  defp failure_cause(_reason), do: :workflow_task_failed

  defp handle_thread_exit(state, pid, reason) do
    case Enum.find(state.threads, fn {_id, thread} -> thread.pid == pid end) do
      nil ->
        state

      {_id, %Thread{status: status}} when status in [:done, :failed] ->
        state

      {thread_id, _thread} when reason in [:normal, :shutdown, :killed] ->
        thread = Map.fetch!(state.threads, thread_id)
        put_thread(state, %{thread | status: :done})

      {thread_id, _thread} ->
        fail_thread(state, thread_id, {:exit, reason})
    end
  end

  defp teardown_threads(state) do
    Enum.each(state.threads, fn {_id, thread} ->
      if is_pid(thread.pid) and Process.alive?(thread.pid) do
        Process.exit(thread.pid, :kill)
      end
    end)

    %{state | threads: %{}, pending: %{}, signal_waiters: %{}, phase: nil, parallel_scopes: %{}}
  end

  @u64_mask 0xFFFFFFFFFFFFFFFF
  @float_denominator 9_007_199_254_740_992

  defp next_random_float(seed) do
    seed = next_random_seed(seed)
    mantissa = bsr(seed, 11)
    {mantissa / @float_denominator, seed}
  end

  defp next_uuid4(seed) do
    first = next_random_seed(seed)
    second = next_random_seed(first)
    bytes = <<first::unsigned-size(64), second::unsigned-size(64)>>

    <<a::binary-size(6), _version_nibble::4, rest_nibble::4, byte7::binary-size(1),
      _variant_seed::2, variant_rest::6, tail::binary>> = bytes

    uuid_bytes =
      <<a::binary, 4::4, rest_nibble::4, byte7::binary, 2::2, variant_rest::6, tail::binary>>

    <<p1::binary-size(4), p2::binary-size(2), p3::binary-size(2), p4::binary-size(2),
      p5::binary-size(6)>> = uuid_bytes

    uuid =
      [p1, p2, p3, p4, p5]
      |> Enum.map(&Base.encode16(&1, case: :lower))
      |> Enum.join("-")

    {uuid, second}
  end

  defp next_random_seed(0), do: next_random_seed(0x9E3779B97F4A7C15)

  defp next_random_seed(seed) do
    seed = band(seed, @u64_mask)
    seed = seed |> bxor(bsl(seed, 13)) |> band(@u64_mask)
    seed = seed |> bxor(bsr(seed, 7)) |> band(@u64_mask)
    seed |> bxor(bsl(seed, 17)) |> band(@u64_mask)
  end

  defp apply_patch_check(state, id) do
    marker = {id, false}

    cond do
      MapSet.member?(state.patch_ids, id) ->
        {true, emit_patch_marker(state, marker, id, false)}

      state.is_replaying ->
        {false, state}

      true ->
        {true,
         state
         |> Map.update!(:patch_ids, &MapSet.put(&1, id))
         |> emit_patch_marker(marker, id, false)}
    end
  end

  defp apply_patch_deprecation(state, id) do
    marker = {id, true}

    cond do
      MapSet.member?(state.patch_ids, id) or not state.is_replaying ->
        state
        |> Map.update!(:patch_ids, &MapSet.put(&1, id))
        |> emit_patch_marker(marker, id, true)

      true ->
        state
    end
  end

  defp emit_patch_marker(state, marker, id, deprecated?) do
    if MapSet.member?(state.patch_markers, marker) do
      state
    else
      state
      |> Map.update!(:patch_markers, &MapSet.put(&1, marker))
      |> append_command(%Command.SetPatchMarker{id: id, deprecated: deprecated?})
    end
  end
end
