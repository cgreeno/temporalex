defmodule Temporalex.WorkflowTaskExecutor do
  @moduledoc """
  GenServer that drives execution of a single Temporal workflow task.

  Spawned by the Server when a new workflow activation arrives. Spawns
  a runner process for the user's workflow code. The runner's `defactivity`
  calls come back here via GenServer.call — we either return a replay
  result (from Temporal's history) or schedule the activity and wait.

  ## Lifecycle

      Server                    Executor                   Runner
        |                         |                          |
        |--{:start, args}------->|                          |
        |                         |--spawn_link------------>|
        |                         |                          |--runs workflow
        |                         |                          |--defactivity(...)
        |                         |<--GenServer.call---------|  (blocks)
        |<--{:executor_cmds}-----|                          |
        |  send completion        |                          |
        |  ...poll...             |                          |
        |--{:resolve, seq, val}->|                          |
        |                         |--GenServer.reply-------->|  (resumes)
        |                         |                          |--returns {:ok, val}
        |                         |<--{:runner_done}---------|
        |<--{:executor_cmds}-----|                          |
  """
  use GenServer
  import Bitwise
  require Logger

  alias Coresdk.WorkflowCommands.{WorkflowCommand, CompleteWorkflowExecution, ScheduleActivity}
  alias Coresdk.WorkflowCommands.{FailWorkflowExecution, StartTimer}
  alias Coresdk.WorkflowCommands.{ContinueAsNewWorkflowExecution, StartChildWorkflowExecution}

  defstruct [
    :server_pid,
    :runner_pid,
    :monitor_ref,
    :run_id,
    :task_queue,
    :run_fn,
    :module,
    workflow_info: %{},
    workflow_state: nil,
    pending_calls: %{},
    replay_results: %{},
    seq: 0,
    commands: [],
    status: :idle
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      server_pid: Keyword.fetch!(opts, :server_pid),
      run_id: Keyword.fetch!(opts, :run_id),
      task_queue: Keyword.get(opts, :task_queue, "default"),
      run_fn: Keyword.fetch!(opts, :run_fn),
      module: Keyword.get(opts, :module),
      workflow_info: Keyword.get(opts, :workflow_info, %{}),
      replay_results: Keyword.get(opts, :replay_results, %{})
    }

    {:ok, state}
  end

  # ============================================================
  # Runner → Executor (GenServer.call from runner process)
  # ============================================================

  @impl true
  def handle_call({:execute_activity, activity_type, input, opts}, from, state) do
    seq = state.seq

    case Map.pop(state.replay_results, seq) do
      {nil, _} ->
        # First execution: build command, block runner until result arrives
        command = build_schedule_activity(seq, activity_type, state.task_queue, input, opts)

        state = %{
          state
          | seq: seq + 1,
            pending_calls: Map.put(state.pending_calls, seq, from),
            commands: [command | state.commands],
            status: :yielded
        }

        flush_commands(state)
        {:noreply, %{state | commands: []}}

      {{:activity, result}, remaining} ->
        # Replay: Temporal says this activity already completed with this result
        {:reply, result, %{state | seq: seq + 1, replay_results: remaining}}

      {{:timer, _}, _} ->
        # Divergence: workflow code calls an activity where a timer was expected
        handle_nondeterminism(state, seq, :activity, activity_type, :timer)
    end
  end

  # Runner is about to block on a receive (e.g., wait_for_signal) — flush commands and yield
  def handle_call({:yield, wf_state}, _from, state) do
    state = %{state | status: :yielded, workflow_state: wf_state}
    flush_commands(state)
    {:reply, :ok, %{state | commands: []}}
  end

  def handle_call(:yield, _from, state) do
    state = %{state | status: :yielded}
    flush_commands(state)
    {:reply, :ok, %{state | commands: []}}
  end

  # Side effects: execute on first run, return error on replay (values not yet persisted)
  def handle_call({:side_effect, fun}, _from, state) do
    seq = state.seq

    case Map.get(state.replay_results, seq) do
      nil ->
        value = fun.()
        {:reply, value, %{state | seq: seq + 1}}

      _recorded ->
        # A side_effect at this seq means the workflow diverged — on replay
        # we have no recorded side_effect value, only activity/timer results.
        # Return error instead of raising to keep the executor alive.
        msg =
          "side_effect replay not yet supported — side_effect values are not recorded. " <>
            "This will be implemented in a future release."

        Logger.error(msg, run_id: state.run_id, seq: seq)
        {:reply, {:error, msg}, %{state | seq: seq + 1}}
    end
  end

  # Local activity — same as regular activity for now (Core SDK handles the optimization)
  def handle_call({:execute_local_activity, activity_type, input, opts}, from, state) do
    handle_call({:execute_activity, activity_type, input, opts}, from, state)
  end

  # Child workflow — schedule and block until result
  def handle_call({:execute_child_workflow, workflow_type, input, opts}, from, state) do
    seq = state.seq

    case Map.pop(state.replay_results, seq) do
      {nil, _} ->
        workflow_id = Keyword.fetch!(opts, :id)
        task_queue = Keyword.get(opts, :task_queue, state.task_queue)

        command =
          build_start_child_workflow(seq, workflow_id, workflow_type, task_queue, input, opts)

        state = %{
          state
          | seq: seq + 1,
            pending_calls: Map.put(state.pending_calls, seq, from),
            commands: [command | state.commands],
            status: :yielded
        }

        flush_commands(state)
        {:noreply, %{state | commands: []}}

      {{:activity, result}, remaining} ->
        {:reply, result, %{state | seq: seq + 1, replay_results: remaining}}

      {{:timer, _}, _} ->
        handle_nondeterminism(state, seq, :child_workflow, workflow_type, :timer)
    end
  end

  # Deterministic random — uses run_id + seq for reproducibility
  def handle_call(:random, _from, state) do
    seq = state.seq
    hash = :erlang.phash2({state.run_id, seq}, 1_000_000)
    value = hash / 1_000_000
    {:reply, value, %{state | seq: seq + 1}}
  end

  # Deterministic UUID v4 — uses run_id + seq for reproducibility
  def handle_call(:uuid4, _from, state) do
    seq = state.seq

    # Generate 4 hashes to get 128 bits of deterministic data
    h1 = :erlang.phash2({state.run_id, "u1", seq}, 0xFFFF_FFFF)
    h2 = :erlang.phash2({state.run_id, "u2", seq}, 0xFFFF_FFFF)
    h3 = :erlang.phash2({state.run_id, "u3", seq}, 0xFFFF_FFFF)
    h4 = :erlang.phash2({state.run_id, "u4", seq}, 0xFFFF_FFFF)

    # Pack into 16 bytes, set version (4) and variant (RFC 4122)
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> =
      <<h1::32, h2::32, h3::32, h4::32>>

    uuid =
      :io_lib.format(
        "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [a, b, c, 0x8000 ||| d, e]
      )
      |> IO.iodata_to_binary()
      |> String.downcase()

    {:reply, uuid, %{state | seq: seq + 1}}
  end

  # Fire-and-forget commands (patches, search attributes, etc.)
  def handle_call({:add_command, command}, _from, state) do
    {:reply, :ok, %{state | commands: [command | state.commands]}}
  end

  def handle_call({:sleep, duration_ms}, from, state) do
    seq = state.seq

    case Map.pop(state.replay_results, seq) do
      {nil, _} ->
        command = build_start_timer(seq, duration_ms)

        state = %{
          state
          | seq: seq + 1,
            pending_calls: Map.put(state.pending_calls, seq, from),
            commands: [command | state.commands],
            status: :yielded
        }

        flush_commands(state)
        {:noreply, %{state | commands: []}}

      {{:timer, _result}, remaining} ->
        {:reply, :ok, %{state | seq: seq + 1, replay_results: remaining}}

      {{:activity, _}, _} ->
        handle_nondeterminism(state, seq, :timer, nil, :activity)
    end
  end

  # ============================================================
  # Server → Executor (messages)
  # ============================================================

  @impl true
  def handle_info({:start, args, opts}, state) do
    executor_pid = self()
    patch_ids = Keyword.get(opts, :patches, MapSet.new())

    pid =
      spawn_link(fn ->
        Process.put(:__temporal_executor__, executor_pid)
        Process.put(:__temporal_state__, nil)
        Process.put(:__temporal_patches__, patch_ids)
        Process.put(:__temporal_cancelled__, false)
        Process.put(:__temporal_activity_stubs__, %{})
        Process.put(:__temporal_activity_calls__, [])
        Process.put(:__temporal_workflow_info__, state.workflow_info)

        try do
          result = state.run_fn.(args)
          wf_state = Process.get(:__temporal_state__)
          send(executor_pid, {:runner_done, result, wf_state})
        rescue
          can in [Temporalex.Error.ContinueAsNew] ->
            send(executor_pid, {:runner_continue_as_new, can})

          e ->
            Logger.error("Workflow runner crashed",
              run_id: state.run_id,
              error: Exception.message(e)
            )

            send(executor_pid, {:runner_error, Exception.message(e)})
        end
      end)

    ref = Process.monitor(pid)

    {:noreply, %{state | runner_pid: pid, monitor_ref: ref, status: :running}}
  end

  # Activity result delivered by Server
  def handle_info({:resolve_activity, seq, result}, state) do
    case Map.pop(state.pending_calls, seq) do
      {nil, _} ->
        Logger.warning("Resolve for unknown seq", seq: seq, run_id: state.run_id)
        {:noreply, state}

      {from, remaining} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending_calls: remaining, status: :running}}
    end
  end

  # Timer fired
  def handle_info({:fire_timer, seq}, state) do
    case Map.pop(state.pending_calls, seq) do
      {nil, _} ->
        {:noreply, state}

      {from, remaining} ->
        GenServer.reply(from, :ok)
        {:noreply, %{state | pending_calls: remaining, status: :running}}
    end
  end

  # Signal — forward to runner process
  def handle_info({:signal, name, payload}, state) do
    if state.runner_pid && Process.alive?(state.runner_pid) do
      send(state.runner_pid, {:signal, name, payload})
    end

    {:noreply, state}
  end

  # Patch notification — forward to runner
  def handle_info({:notify_has_patch, patch_id}, state) do
    if state.runner_pid && Process.alive?(state.runner_pid) do
      send(state.runner_pid, {:notify_has_patch, patch_id})
    end

    {:noreply, state}
  end

  # Cancel — forward to runner
  def handle_info({:cancel_workflow}, state) do
    if state.runner_pid && Process.alive?(state.runner_pid) do
      send(state.runner_pid, {:cancel_workflow})
    end

    {:noreply, state}
  end

  # Runner completed successfully
  def handle_info({:runner_done, result, wf_state}, state) do
    command = build_complete_workflow(result)

    state = %{
      state
      | workflow_state: wf_state,
        commands: [command | state.commands],
        status: :done
    }

    flush_commands(state)
    {:noreply, %{state | commands: []}}
  end

  # Runner wants to continue as new
  def handle_info({:runner_continue_as_new, %Temporalex.Error.ContinueAsNew{} = can}, state) do
    command = build_continue_as_new_command(can)
    state = %{state | commands: [command | state.commands], status: :done}
    flush_commands(state)
    {:noreply, %{state | commands: []}}
  end

  # Runner returned an error
  def handle_info({:runner_error, reason}, state) do
    command = build_fail_workflow(reason)
    state = %{state | commands: [command | state.commands], status: :done}
    flush_commands(state)
    {:noreply, %{state | commands: []}}
  end

  # Runner process crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state)
      when reason not in [:normal, :shutdown] do
    command = build_fail_workflow("Workflow crashed: #{inspect(reason)}")
    state = %{state | commands: [command | state.commands], status: :done}
    flush_commands(state)
    {:noreply, %{state | commands: [], runner_pid: nil}}
  end

  def handle_info({:DOWN, _, :process, _, _}, state) do
    {:noreply, %{state | runner_pid: nil}}
  end

  # ============================================================
  # Nondeterminism detection
  # ============================================================

  defp handle_nondeterminism(state, seq, got_kind, got_type, expected_kind) do
    msg =
      "Nondeterminism detected at seq #{seq}: " <>
        "workflow called #{format_kind(got_kind, got_type)} " <>
        "but replay history has #{format_kind(expected_kind, nil)}"

    Logger.error(msg, run_id: state.run_id)

    command = build_fail_workflow(msg)
    state = %{state | commands: [command | state.commands], status: :done}
    flush_commands(state)

    # Kill the runner — it's in an invalid state
    if state.runner_pid && Process.alive?(state.runner_pid) do
      Process.exit(state.runner_pid, :kill)
    end

    {:noreply, %{state | commands: [], runner_pid: nil}}
  end

  defp format_kind(:activity, nil), do: "activity"
  defp format_kind(:activity, type), do: "activity(#{type})"
  defp format_kind(:timer, _), do: "timer"
  defp format_kind(:child_workflow, nil), do: "child_workflow"
  defp format_kind(:child_workflow, type), do: "child_workflow(#{type})"

  # ============================================================
  # Command builders
  # ============================================================

  defp flush_commands(state) do
    commands = Enum.reverse(state.commands)

    send(
      state.server_pid,
      {:executor_commands, state.run_id, commands, state.workflow_state, state.status}
    )
  end

  defp build_schedule_activity(seq, activity_type, task_queue, input, opts) do
    retry_proto = build_retry_policy(Keyword.get(opts, :retry_policy))

    %WorkflowCommand{
      variant:
        {:schedule_activity,
         %ScheduleActivity{
           seq: seq,
           activity_id: to_string(seq),
           activity_type: activity_type,
           task_queue: task_queue,
           arguments: Temporalex.Converter.to_payloads(List.wrap(input)),
           schedule_to_start_timeout:
             to_duration(Keyword.get(opts, :schedule_to_start_timeout, 30_000)),
           start_to_close_timeout:
             to_duration(Keyword.get(opts, :start_to_close_timeout, 30_000)),
           schedule_to_close_timeout:
             to_duration(Keyword.get(opts, :schedule_to_close_timeout, 60_000)),
           heartbeat_timeout: to_duration(Keyword.get(opts, :heartbeat_timeout)),
           retry_policy: retry_proto
         }}
    }
  end

  defp build_start_timer(seq, duration_ms) do
    %WorkflowCommand{
      variant:
        {:start_timer,
         %StartTimer{
           seq: seq,
           start_to_fire_timeout: to_duration(duration_ms)
         }}
    }
  end

  defp build_complete_workflow({:error, reason}) when is_binary(reason) do
    build_fail_workflow(reason)
  end

  defp build_complete_workflow({:error, %{message: msg}}) do
    build_fail_workflow(msg)
  end

  defp build_complete_workflow({:error, reason}) do
    build_fail_workflow(inspect(reason))
  end

  defp build_complete_workflow({:ok, value}) do
    payload = Temporalex.Converter.to_payload(value)

    %WorkflowCommand{
      variant: {:complete_workflow_execution, %CompleteWorkflowExecution{result: payload}}
    }
  end

  defp build_complete_workflow(value) do
    payload = Temporalex.Converter.to_payload(value)

    %WorkflowCommand{
      variant: {:complete_workflow_execution, %CompleteWorkflowExecution{result: payload}}
    }
  end

  defp build_fail_workflow(reason) do
    %WorkflowCommand{
      variant:
        {:fail_workflow_execution,
         %FailWorkflowExecution{
           failure: %Temporal.Api.Failure.V1.Failure{message: to_string(reason)}
         }}
    }
  end

  defp build_continue_as_new_command(%Temporalex.Error.ContinueAsNew{} = can) do
    %WorkflowCommand{
      variant:
        {:continue_as_new_workflow_execution,
         %ContinueAsNewWorkflowExecution{
           workflow_type: can.workflow_type || "",
           task_queue: can.task_queue || "",
           arguments: Temporalex.Converter.to_payloads(List.wrap(can.args))
         }}
    }
  end

  defp build_start_child_workflow(seq, workflow_id, workflow_type, task_queue, input, opts) do
    retry_proto = build_retry_policy(Keyword.get(opts, :retry_policy))

    parent_close_policy =
      case Keyword.get(opts, :parent_close_policy) do
        :terminate -> :PARENT_CLOSE_POLICY_TERMINATE
        :abandon -> :PARENT_CLOSE_POLICY_ABANDON
        :request_cancel -> :PARENT_CLOSE_POLICY_REQUEST_CANCEL
        _ -> :PARENT_CLOSE_POLICY_TERMINATE
      end

    %WorkflowCommand{
      variant:
        {:start_child_workflow_execution,
         %StartChildWorkflowExecution{
           seq: seq,
           workflow_id: workflow_id,
           workflow_type: workflow_type,
           task_queue: task_queue,
           input: Temporalex.Converter.to_payloads(List.wrap(input)),
           workflow_execution_timeout:
             to_duration(Keyword.get(opts, :workflow_execution_timeout)),
           workflow_run_timeout: to_duration(Keyword.get(opts, :workflow_run_timeout)),
           parent_close_policy: parent_close_policy,
           retry_policy: retry_proto
         }}
    }
  end

  defp build_retry_policy(nil), do: nil

  defp build_retry_policy(policy) do
    Temporalex.RetryPolicy.from_opts(policy) |> Temporalex.RetryPolicy.to_proto()
  end

  defp to_duration(nil), do: nil

  defp to_duration(ms) when is_integer(ms) do
    %Google.Protobuf.Duration{seconds: div(ms, 1000), nanos: rem(ms, 1000) * 1_000_000}
  end
end
