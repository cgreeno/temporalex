defmodule Temporalex.Testing.Runner do
  @moduledoc false

  use GenServer

  alias Temporalex.Core.Command
  alias Temporalex.Core.Job
  alias Temporalex.Core.TestHarness
  alias Temporalex.Testing.Activity
  alias Temporalex.Testing.Run
  alias Temporalex.Testing.Timer
  alias Temporalex.Testing.Update

  defmodule State do
    @moduledoc false

    defstruct [
      :harness,
      :run,
      replay_opts: [],
      queue: [],
      outstanding: %{},
      transcript: [],
      terminal: nil
    ]
  end

  def start_workflow(workflow_module, input, opts) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, {workflow_module, input, opts}) do
      {:ok, GenServer.call(pid, :run, :infinity)}
    end
  end

  def peek_next(%Run{pid: pid}), do: GenServer.call(pid, :peek_next, :infinity)
  def pop_next_command(%Run{pid: pid}), do: GenServer.call(pid, :pop_next_command, :infinity)

  def pop_next_activity(%Run{pid: pid}, opts) do
    GenServer.call(pid, {:pop_next_activity, opts}, :infinity)
  end

  def pop_next_timer(%Run{pid: pid}, opts) do
    GenServer.call(pid, {:pop_next_timer, opts}, :infinity)
  end

  def complete_activity(%Run{pid: pid}, %Activity{} = activity, result, opts) do
    GenServer.call(pid, {:complete_activity, activity, result, opts}, :infinity)
  end

  def fire_timer(%Run{pid: pid}, %Timer{} = timer, opts) do
    GenServer.call(pid, {:fire_timer, timer, opts}, :infinity)
  end

  def signal(%Run{pid: pid}, name, args, opts) do
    GenServer.call(pid, {:signal, name, args, opts}, :infinity)
  end

  def start_update(%Run{pid: pid}, name, args, opts) do
    GenServer.call(pid, {:start_update, name, args, opts}, :infinity)
  end

  def query(%Run{pid: pid}, query_type, args, opts) do
    GenServer.call(pid, {:query, query_type, args, opts}, :infinity)
  end

  def cancel_workflow(%Run{pid: pid}, reason, opts) do
    GenServer.call(pid, {:cancel_workflow, reason, opts}, :infinity)
  end

  def terminal(%Run{pid: pid}), do: GenServer.call(pid, :terminal, :infinity)
  def replay(%Run{pid: pid}), do: GenServer.call(pid, :replay, :infinity)
  def snapshot(%Run{pid: pid}), do: GenServer.call(pid, :snapshot, :infinity)

  @impl GenServer
  def init({workflow_module, input, opts}) do
    case TestHarness.start_workflow(workflow_module, input, opts) do
      {:ok, harness} ->
        run = %Run{
          pid: self(),
          workflow_module: workflow_module,
          workflow_id: harness.workflow_id,
          run_id: harness.run_id
        }

        state = %State{
          harness: harness,
          run: run,
          replay_opts: Keyword.take(opts, [:safe_mode])
        }

        {:ok, activate(state, [initialize_job(harness, opts)], opts)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:run, _from, state), do: {:reply, state.run, state}

  def handle_call(:peek_next, _from, state) do
    {:reply, peek_queue(state), state}
  end

  def handle_call(:pop_next_command, _from, state) do
    case state.queue do
      [] ->
        {:reply, {:error, "expected another workflow command, but no commands are queued"}, state}

      [command | rest] ->
        {:reply, {:ok, command}, %{state | queue: rest}}
    end
  end

  def handle_call({:pop_next_activity, opts}, _from, state) do
    case state.queue do
      [] ->
        {:reply, {:error, "expected a scheduled activity, but no commands are queued"}, state}

      [%Command.ScheduleActivity{} = command | rest] ->
        if activity_matches?(command, opts) do
          activity = activity_handle(state.run, command)
          state = put_outstanding(%{state | queue: rest}, activity.ref, :activity, activity.seq)
          {:reply, {:ok, activity}, state}
        else
          {:reply, {:error, activity_mismatch_message(command, opts)}, state}
        end

      [command | _] ->
        {:reply,
         {:error, "expected a scheduled activity, but next command is #{inspect(command)}"},
         state}
    end
  end

  def handle_call({:pop_next_timer, opts}, _from, state) do
    case state.queue do
      [] ->
        {:reply, {:error, "expected a started timer, but no commands are queued"}, state}

      [%Command.StartTimer{} = command | rest] ->
        if timer_matches?(command, opts) do
          timer = timer_handle(state.run, command)
          state = put_outstanding(%{state | queue: rest}, timer.ref, :timer, timer.seq)
          {:reply, {:ok, timer}, state}
        else
          {:reply, {:error, timer_mismatch_message(command, opts)}, state}
        end

      [command | _] ->
        {:reply, {:error, "expected a started timer, but next command is #{inspect(command)}"},
         state}
    end
  end

  def handle_call({:complete_activity, activity, result, opts}, _from, state) do
    with :ok <- ensure_queue_empty(state),
         :ok <- ensure_can_activate_after_terminal(state, opts),
         :ok <- ensure_handle_run(state, activity),
         {:ok, state} <- take_outstanding(state, activity.ref, :activity, activity.seq) do
      state =
        activate(
          state,
          [%Job.ActivityResolved{seq: activity.seq, result: result}],
          opts
        )

      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fire_timer, timer, opts}, _from, state) do
    with :ok <- ensure_queue_empty(state),
         :ok <- ensure_can_activate_after_terminal(state, opts),
         :ok <- ensure_handle_run(state, timer),
         {:ok, state} <- take_outstanding(state, timer.ref, :timer, timer.seq) do
      state = activate(state, [%Job.TimerFired{seq: timer.seq}], opts)
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:signal, name, args, opts}, _from, state) do
    with :ok <- ensure_queue_empty(state),
         :ok <- ensure_not_terminal(state) do
      signal = %Job.SignalReceived{
        name: name,
        args: List.wrap(args),
        headers: Keyword.get(opts, :headers, %{}),
        identity: Keyword.get(opts, :identity)
      }

      {:reply, :ok, activate(state, [signal], opts)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_update, name, args, opts}, _from, state) do
    with :ok <- ensure_queue_empty(state),
         :ok <- ensure_not_terminal(state) do
      update = %Update{
        run: state.run.pid,
        id: Keyword.get(opts, :id, "update-#{System.unique_integer([:positive])}"),
        protocol_instance_id:
          Keyword.get(
            opts,
            :protocol_instance_id,
            "protocol-#{System.unique_integer([:positive])}"
          ),
        name: name
      }

      job = %Job.UpdateReceived{
        id: update.id,
        protocol_instance_id: update.protocol_instance_id,
        name: name,
        args: List.wrap(args),
        headers: Keyword.get(opts, :headers, %{}),
        meta: Keyword.get(opts, :meta),
        run_validator: Keyword.get(opts, :run_validator, true)
      }

      {:reply, {:ok, update}, activate(state, [job], opts)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, query_type, args, opts}, _from, state) do
    with :ok <- ensure_queue_empty(state) do
      query_id = Keyword.get(opts, :query_id, "query-#{System.unique_integer([:positive])}")

      job = %Job.QueryReceived{
        query_id: query_id,
        query_type: query_type,
        args: List.wrap(args),
        headers: Keyword.get(opts, :headers, %{})
      }

      state = activate(state, [job], opts)

      case state.queue do
        [%Command.RespondToQuery{query_id: ^query_id, result: result} | rest] ->
          {:reply, result, %{state | queue: rest}}

        [command | _] ->
          {:reply,
           {:error,
            "expected query response #{inspect(query_id)}, but next command is #{inspect(command)}"},
           state}

        [] ->
          {:reply,
           {:error, "expected query response #{inspect(query_id)}, but no command was emitted"},
           state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_workflow, reason, opts}, _from, state) do
    with :ok <- ensure_queue_empty(state),
         :ok <- ensure_not_terminal(state) do
      {:reply, :ok, activate(state, [%Job.CancelWorkflow{reason: reason}], opts)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:terminal, _from, state), do: {:reply, state.terminal, state}

  def handle_call(:replay, _from, state) do
    {:reply, replay_transcript(state), state}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      run: state.run,
      queue: state.queue,
      outstanding: state.outstanding,
      terminal: state.terminal,
      transcript: state.transcript
    }

    {:reply, snapshot, state}
  end

  defp activate(%State{} = state, jobs, opts) do
    activation_opts = activation_opts(opts)
    completion = TestHarness.activate_raw(state.harness, jobs, activation_opts)
    commands = completion_commands(completion)

    state
    |> record_transcript(jobs, commands, activation_opts)
    |> apply_completion(completion, commands)
  end

  defp completion_commands(%{status: {:ok, commands}}), do: commands
  defp completion_commands(_completion), do: []

  defp record_transcript(state, jobs, commands, activation_opts) do
    step = %{jobs: jobs, commands: commands, opts: activation_opts}
    %{state | transcript: state.transcript ++ [step]}
  end

  defp apply_completion(state, %{status: {:failed, reason, _opts}}, _commands) do
    %{state | terminal: {:failed, reason}}
  end

  defp apply_completion(state, %{status: {:ok, commands}}, _commands) do
    {terminal, non_terminal_commands} = split_terminal(commands)

    state
    |> enqueue_commands(non_terminal_commands)
    |> put_terminal(terminal)
  end

  defp split_terminal(commands) do
    terminal = Enum.find(commands, &terminal_command?/1)
    non_terminal = Enum.reject(commands, &terminal_command?/1)
    {terminal, non_terminal}
  end

  defp terminal_command?(%Command.CompleteWorkflow{}), do: true
  defp terminal_command?(%Command.FailWorkflow{}), do: true
  defp terminal_command?(%Command.ContinueAsNew{}), do: true
  defp terminal_command?(%Command.CancelWorkflow{}), do: true
  defp terminal_command?(_command), do: false

  defp enqueue_commands(state, []), do: state
  defp enqueue_commands(state, commands), do: %{state | queue: state.queue ++ commands}

  defp put_terminal(state, nil), do: state

  defp put_terminal(state, %Command.CompleteWorkflow{result: result}),
    do: %{state | terminal: {:completed, result}}

  defp put_terminal(state, %Command.FailWorkflow{reason: reason}),
    do: %{state | terminal: {:failed_workflow, reason}}

  defp put_terminal(state, %Command.ContinueAsNew{} = command),
    do: %{state | terminal: {:continue_as_new, command}}

  defp put_terminal(state, %Command.CancelWorkflow{reason: reason}),
    do: %{state | terminal: {:cancelled, reason}}

  defp peek_queue(%State{queue: []}), do: :empty
  defp peek_queue(%State{queue: [command | _]}), do: {:ok, command}

  defp put_outstanding(state, ref, kind, seq) do
    put_in(state.outstanding[ref], %{kind: kind, seq: seq})
  end

  defp take_outstanding(state, ref, kind, seq) do
    case Map.pop(state.outstanding, ref) do
      {nil, _outstanding} ->
        {:error, "unknown or already resolved #{kind} handle #{inspect(ref)}"}

      {%{kind: ^kind, seq: ^seq}, outstanding} ->
        {:ok, %{state | outstanding: outstanding}}

      {%{kind: other_kind, seq: other_seq}, _outstanding} ->
        {:error,
         "handle #{inspect(ref)} identifies #{inspect(other_kind)} sequence #{inspect(other_seq)}, not #{inspect(kind)} sequence #{inspect(seq)}"}
    end
  end

  defp ensure_queue_empty(%State{queue: []}), do: :ok

  defp ensure_queue_empty(%State{queue: [command | _]}) do
    {:error,
     "workflow has unconsumed commands; consume #{inspect(command)} before sending another activation"}
  end

  defp ensure_not_terminal(%State{terminal: nil}), do: :ok

  defp ensure_not_terminal(%State{terminal: terminal}) do
    {:error, "workflow run is already terminal: #{inspect(terminal)}"}
  end

  defp ensure_can_activate_after_terminal(%State{terminal: nil}, _opts), do: :ok

  defp ensure_can_activate_after_terminal(%State{terminal: terminal}, opts) do
    if Keyword.get(opts, :allow_after_terminal, false) do
      :ok
    else
      {:error, "workflow run is already terminal: #{inspect(terminal)}"}
    end
  end

  defp ensure_handle_run(%State{} = state, %{run: run_pid}) when run_pid == state.run.pid, do: :ok

  defp ensure_handle_run(%State{} = state, handle) do
    {:error, "handle #{inspect(handle)} does not belong to run #{inspect(state.run.pid)}"}
  end

  defp activity_handle(%Run{} = run, %Command.ScheduleActivity{} = command) do
    %Activity{
      run: run.pid,
      ref: make_ref(),
      seq: command.seq,
      thread_id: command.thread_id,
      activity_id: command.activity_id,
      type: command.type,
      input: command.input,
      opts: command.opts
    }
  end

  defp timer_handle(%Run{} = run, %Command.StartTimer{} = command) do
    %Timer{
      run: run.pid,
      ref: make_ref(),
      seq: command.seq,
      thread_id: command.thread_id,
      duration_ms: command.duration_ms
    }
  end

  defp activity_matches?(command, opts) do
    Enum.all?(opts, fn
      {:type, expected} -> command.type == normalize_activity_type(expected)
      {:input, expected} -> command.input == expected
      {:activity_id, expected} -> command.activity_id == expected
      {:thread_id, expected} -> command.thread_id == expected
      {:opts, expected} -> command.opts == expected
      {_key, _expected} -> false
    end)
  end

  defp activity_mismatch_message(command, opts) do
    "scheduled activity did not match #{inspect(opts)}; next activity is #{inspect(command)}"
  end

  defp normalize_activity_type(type) when is_binary(type), do: type

  defp normalize_activity_type({module, name}) when is_atom(module),
    do: "#{inspect(module)}.#{name}"

  defp normalize_activity_type(module) when is_atom(module), do: inspect(module)

  defp timer_matches?(command, opts) do
    Enum.all?(opts, fn
      {:duration_ms, expected} -> command.duration_ms == expected
      {:duration, expected} -> command.duration_ms == expected
      {:thread_id, expected} -> command.thread_id == expected
      {_key, _expected} -> false
    end)
  end

  defp timer_mismatch_message(command, opts) do
    "started timer did not match #{inspect(opts)}; next timer is #{inspect(command)}"
  end

  defp replay_transcript(%State{} = state) do
    with {:ok, harness} <-
           TestHarness.start_workflow(
             state.run.workflow_module,
             state.harness.input,
             state.replay_opts
           ) do
      Enum.reduce_while(state.transcript, :ok, fn step, _acc ->
        opts =
          step.opts
          |> Keyword.put(:replay, true)
          |> Keyword.put(:expected_commands, step.commands)

        case TestHarness.activate(harness, step.jobs, opts) do
          {:failed, reason} -> {:halt, {:error, reason}}
          _step -> {:cont, :ok}
        end
      end)
    end
  end

  defp activation_opts(opts) do
    Keyword.take(opts, [
      :timestamp,
      :history_length,
      :history_size_bytes,
      :continue_as_new_suggested,
      :replay,
      :expected_commands
    ])
  end

  defp initialize_job(harness, opts) do
    workflow_type =
      if function_exported?(harness.workflow_module, :__workflow_type__, 0) do
        harness.workflow_module.__workflow_type__()
      else
        inspect(harness.workflow_module)
      end

    %Job.InitializeWorkflow{
      workflow_type: workflow_type,
      workflow_id: harness.workflow_id,
      arguments: [harness.input],
      headers: Keyword.get(opts, :headers, %{}),
      workflow_info: Keyword.get(opts, :workflow_info, %{}),
      randomness_seed: Keyword.get(opts, :randomness_seed, 0)
    }
  end
end
