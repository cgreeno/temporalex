defmodule Temporalex.Core.TestHarness do
  @moduledoc """
  Pure core test harness that drives executors with core activations.
  """

  alias Temporalex.Core.Activation
  alias Temporalex.Core.Command
  alias Temporalex.Core.Executor
  alias Temporalex.Core.Job

  defstruct [:pid, :workflow_module, :input, :run_id, :workflow_id, :timestamp]

  def start_workflow(workflow_module, input, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "run-#{System.unique_integer([:positive])}")

    with {:ok, pid} <-
           Executor.start_link(
             workflow_module: workflow_module,
             run_id: run_id,
             safe_mode: Keyword.get(opts, :safe_mode, :fail)
           ) do
      {:ok,
       %__MODULE__{
         pid: pid,
         workflow_module: workflow_module,
         input: input,
         run_id: run_id,
         workflow_id:
           Keyword.get(opts, :workflow_id, "workflow-#{System.unique_integer([:positive])}"),
         timestamp: Keyword.get(opts, :timestamp, ~U[2026-01-01 00:00:00Z])
       }}
    end
  end

  def next(%__MODULE__{} = harness, opts \\ []) do
    jobs =
      if initialized?(harness) do
        []
      else
        [initialize_job(harness, opts)]
      end

    activate(harness, jobs, opts)
  end

  def resolve(%__MODULE__{} = harness, jobs, opts \\ []) do
    activate(harness, List.wrap(jobs), opts)
  end

  def send_signal(%__MODULE__{} = harness, name, args \\ [], opts \\ []) do
    signal = %Job.SignalReceived{
      name: name,
      args: List.wrap(args),
      headers: Keyword.get(opts, :headers, %{}),
      identity: Keyword.get(opts, :identity)
    }

    resolve(harness, signal, opts)
  end

  def send_update(%__MODULE__{} = harness, name, args \\ [], opts \\ []) do
    update = %Job.UpdateReceived{
      id: Keyword.get(opts, :id, "update-#{System.unique_integer([:positive])}"),
      protocol_instance_id:
        Keyword.get(opts, :protocol_instance_id, "protocol-#{System.unique_integer([:positive])}"),
      name: name,
      args: List.wrap(args),
      headers: Keyword.get(opts, :headers, %{}),
      meta: Keyword.get(opts, :meta),
      run_validator: Keyword.get(opts, :run_validator, true)
    }

    resolve(harness, update, opts)
  end

  def query(%__MODULE__{} = harness, query_type, args \\ [], opts \\ []) do
    query = %Job.QueryReceived{
      query_id: Keyword.get(opts, :query_id, "query-#{System.unique_integer([:positive])}"),
      query_type: query_type,
      args: List.wrap(args),
      headers: Keyword.get(opts, :headers, %{})
    }

    resolve(harness, query, opts)
  end

  def activate(%__MODULE__{} = harness, jobs, opts \\ []) do
    completion = activate_raw(harness, jobs, opts)
    normalize(harness, completion)
  end

  def activate_raw(%__MODULE__{} = harness, jobs, opts \\ []) do
    activation = %Activation{
      run_id: harness.run_id,
      timestamp: Keyword.get(opts, :timestamp, harness.timestamp),
      is_replaying: Keyword.get(opts, :replay, false),
      history_length: Keyword.get(opts, :history_length, 0),
      history_size_bytes: Keyword.get(opts, :history_size_bytes),
      continue_as_new_suggested: Keyword.get(opts, :continue_as_new_suggested, false),
      jobs: jobs
    }

    Executor.activate(harness.pid, activation,
      expected_commands: Keyword.get(opts, :expected_commands)
    )
  end

  def commands(%__MODULE__{} = harness), do: Executor.inspect_state(harness.pid).commands
  def pending_calls(%__MODULE__{} = harness), do: Executor.inspect_state(harness.pid).pending

  def published_state(%__MODULE__{} = harness),
    do: Executor.inspect_state(harness.pid).published_state

  def phase_state(%__MODULE__{} = harness),
    do:
      Executor.inspect_state(harness.pid).phase && Executor.inspect_state(harness.pid).phase.state

  def thread_states(%__MODULE__{} = harness) do
    harness.pid
    |> Executor.inspect_state()
    |> Map.fetch!(:threads)
    |> Map.new(fn {id, thread} -> {id, thread.status} end)
  end

  def record(workflow_module, input, resolver, opts \\ []) when is_function(resolver, 1) do
    {:ok, harness} = start_workflow(workflow_module, input, opts)
    record_loop(harness, resolver, [], :next)
  end

  def replay(workflow_module, input, transcript, opts \\ []) do
    {:ok, harness} = start_workflow(workflow_module, input, opts)

    result =
      Enum.reduce_while(transcript, nil, fn %{jobs: jobs, commands: commands}, _last ->
        case activate(harness, jobs, replay: true, expected_commands: commands) do
          {:failed, reason} -> {:halt, {:failed, reason}}
          {:complete, result} -> {:cont, {:ok, result}}
          {:continue_as_new, input} -> {:cont, {:continue_as_new, input}}
          other -> {:cont, other}
        end
      end)

    case result do
      {:ok, completion_result} -> {:ok, completion_result}
      {:failed, reason} -> {:failed, reason}
      other -> other
    end
  end

  defp record_loop(harness, resolver, transcript, :next) do
    jobs = [initialize_job(harness, [])]
    completion = activate_raw(harness, jobs)
    step = normalize(harness, completion)
    record_step(harness, resolver, transcript, jobs, completion, step)
  end

  defp record_loop(harness, resolver, transcript, jobs) do
    completion = activate_raw(harness, jobs)
    step = normalize(harness, completion)
    record_step(harness, resolver, transcript, jobs, completion, step)
  end

  defp record_step(harness, resolver, transcript, jobs, completion, step) do
    commands =
      case completion.status do
        {:ok, commands} -> commands
        _ -> []
      end

    transcript = transcript ++ [%{jobs: jobs, commands: commands}]

    case step do
      {:yield, commands} ->
        resolution_jobs = commands |> Enum.flat_map(&resolution_jobs(&1, resolver))
        record_loop(harness, resolver, transcript, resolution_jobs)

      {:complete, {:ok, result}} ->
        {:ok, transcript, result}

      {:complete, {:error, reason}} ->
        {:ok, transcript, {:error, reason}}

      {:continue_as_new, input} ->
        {:ok, transcript, {:continue_as_new, input}}

      {:failed, reason} ->
        {:failed, reason, transcript}

      {:waiting, _info} ->
        {:waiting, transcript}
    end
  end

  defp resolution_jobs(%Command.ScheduleActivity{seq: seq} = command, resolver) do
    [%Job.ActivityResolved{seq: seq, result: resolver.(command)}]
  end

  defp resolution_jobs(%Command.StartTimer{seq: seq}, _resolver) do
    [%Job.TimerFired{seq: seq}]
  end

  defp resolution_jobs(_command, _resolver), do: []

  defp normalize(harness, completion) do
    case completion.status do
      {:failed, reason, _opts} ->
        {:failed, reason}

      {:ok, commands} ->
        normalize_success(harness, commands)
    end
  end

  defp normalize_success(harness, commands) do
    case terminal_command(commands) do
      %Command.CompleteWorkflow{result: result} ->
        {:complete, {:ok, result}}

      %Command.FailWorkflow{reason: reason} ->
        {:complete, {:error, reason}}

      %Command.ContinueAsNew{input: input} ->
        {:continue_as_new, input}

      nil when commands != [] ->
        {:yield, commands}

      nil ->
        case Executor.inspect_state(harness.pid).phase do
          nil -> {:yield, []}
          phase -> {:waiting, phase_info(phase)}
        end
    end
  end

  defp terminal_command(commands) do
    Enum.find(commands, fn
      %Command.CompleteWorkflow{} -> true
      %Command.FailWorkflow{} -> true
      %Command.ContinueAsNew{} -> true
      _ -> false
    end)
  end

  defp phase_info(phase) do
    %{
      signals: Map.keys(phase.signal_handlers),
      updates: Map.keys(phase.update_handlers),
      state: phase.state,
      async_handlers: MapSet.to_list(phase.async_threads)
    }
  end

  defp initialized?(harness) do
    Executor.inspect_state(harness.pid).initialized?
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
