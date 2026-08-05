defmodule Temporalex.Testing do
  @moduledoc """
  Workflow testing helpers built on the real Temporalex executor.

  These helpers run workflow code without a Temporal server. Tests observe
  Temporal-visible commands, consume them in deterministic emission order, and
  decide when durable operations complete.
  """

  import ExUnit.Assertions

  alias Temporalex.Core.Command
  alias Temporalex.Testing.Activity
  alias Temporalex.Testing.Run
  alias Temporalex.Testing.Runner
  alias Temporalex.Testing.Timer
  alias Temporalex.Testing.Update

  @doc """
  Starts a workflow run in the testing runner.

  The workflow is initialized immediately. Any commands emitted by the first
  activation are available through `assert_next_activity/2`,
  `assert_next_timer/2`, or `assert_next_command/2`.
  """
  def start_workflow(workflow_module, input, opts \\ []) when is_atom(workflow_module) do
    Runner.start_workflow(workflow_module, input, Keyword.put_new(opts, :safe_mode, :fail))
  end

  @doc """
  Runs an activity's real implementation directly — no Temporal anywhere.

  This is the unit-test entry point for activity bodies (the workflow-side
  `assert_next_activity`/`complete_activity` kit is the complement: it tests
  the workflow by mocking the activity; this runs the activity itself).

      assert {:ok, receipt} = Temporalex.Testing.run_activity(Activities, :charge, [100])

  For activities that declare a `ctx` argument, a `Temporalex.Activity.Context`
  is fabricated with honest defaults (`attempt: 1`, the real wire type, no
  worker — so `heartbeat/2` is a no-op) and `context:` merges overrides:

      Temporalex.Testing.run_activity(Activities, :poll, [job],
        context: [attempt: 3, cancelled: true]
      )

  `cancelled: true` seeds the cancellation flag so `Activity.cancelled?/1`
  and heartbeats report cancellation. Passing `context:` to an activity that
  never declares `ctx` raises — that test would be asserting fiction.

  Returns whatever the implementation returns, untouched.
  """
  def run_activity(module, name, args, opts \\ [])
      when is_atom(module) and is_atom(name) and is_list(args) and is_list(opts) do
    activity = fetch_activity!(module, name, length(args))
    context_overrides = Keyword.get(opts, :context)

    cond do
      activity.context? ->
        context = test_activity_context(activity, context_overrides || [])
        apply(module, activity.implementation, [context | args])

      is_nil(context_overrides) ->
        apply(module, activity.implementation, args)

      true ->
        raise ArgumentError,
              "#{inspect(module)}.#{name} does not declare a ctx argument — " <>
                "drop context: or add ctx as the first defactivity argument"
    end
  end

  defp fetch_activity!(module, name, arity) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :__temporal_activities__, 0) do
      raise ArgumentError,
            "#{inspect(module)} is not an activity module — expected `use Temporalex.Activity`"
    end

    activities = module.__temporal_activities__()

    case Enum.find(activities, &(&1.name == name and &1.arity == arity)) do
      nil ->
        available =
          Enum.map_join(activities, ", ", fn a -> "#{a.name}/#{a.arity}" end)

        raise ArgumentError,
              "no activity #{name}/#{arity} in #{inspect(module)} — defined: #{available}"

      activity ->
        activity
    end
  end

  defp test_activity_context(activity, overrides) do
    valid_keys = Map.keys(%Temporalex.Activity.Context{}) -- [:__struct__]

    case Keyword.keys(overrides) -- valid_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown context field(s) #{inspect(unknown)} for " <>
                "run_activity #{activity.name} — valid: #{inspect(valid_keys)}"
    end

    overrides =
      case Keyword.fetch(overrides, :cancelled) do
        {:ok, cancelled} when is_boolean(cancelled) ->
          flag = :atomics.new(1, signed: false)
          if cancelled, do: :atomics.put(flag, 1, 1)
          Keyword.put(overrides, :cancelled, flag)

        _ ->
          # absent (cancelled?/1 treats nil as false) or a raw atomics ref
          overrides
      end

    struct!(
      Temporalex.Activity.Context,
      Keyword.merge([activity_type: activity.type, attempt: 1], overrides)
    )
  end

  @doc """
  Consumes and returns the next scheduled activity command.
  """
  def assert_next_activity(%Run{} = run, opts \\ []) when is_list(opts) do
    case Runner.pop_next_activity(run, opts) do
      {:ok, %Activity{} = activity} -> activity
      {:error, message} -> flunk(message)
    end
  end

  @doc """
  Consumes and returns the next started timer command.
  """
  def assert_next_timer(%Run{} = run, opts \\ []) when is_list(opts) do
    case Runner.pop_next_timer(run, opts) do
      {:ok, %Timer{} = timer} -> timer
      {:error, message} -> flunk(message)
    end
  end

  @doc """
  Consumes and returns the next raw core command.

  `expected` may be omitted, a command module, a full struct, or a one-argument
  predicate function.
  """
  def assert_next_command(%Run{} = run, expected \\ nil) do
    case Runner.peek_next(run) do
      :empty ->
        flunk("expected another workflow command, but no commands are queued")

      {:ok, command} ->
        if command_matches?(command, expected) do
          {:ok, ^command} = Runner.pop_next_command(run)
          command
        else
          flunk("next command #{inspect(command)} did not match #{inspect(expected)}")
        end
    end
  end

  @doc """
  Asserts that the current activation has no unconsumed commands.
  """
  def assert_no_commands(%Run{} = run) do
    case Runner.peek_next(run) do
      :empty ->
        :ok

      {:ok, command} ->
        flunk("expected no queued workflow commands, but found #{inspect(command)}")
    end
  end

  @doc """
  Resolves a scheduled activity handle with a workflow-visible result.
  """
  def complete_activity(%Run{} = run, %Activity{} = activity, result, opts \\ []) do
    case Runner.complete_activity(run, activity, result, opts) do
      :ok -> :ok
      {:error, message} -> flunk(message)
    end
  end

  @doc """
  Resolves a scheduled activity as failed.
  """
  def fail_activity(%Run{} = run, %Activity{} = activity, reason, opts \\ []) do
    complete_activity(run, activity, {:error, reason}, opts)
  end

  @doc """
  Resolves a scheduled activity as cancelled.
  """
  def cancel_activity(%Run{} = run, %Activity{} = activity, reason, opts \\ []) do
    complete_activity(run, activity, {:cancelled, reason}, opts)
  end

  @doc """
  Fires a started timer handle.
  """
  def fire_timer(%Run{} = run, %Timer{} = timer, opts \\ []) do
    case Runner.fire_timer(run, timer, opts) do
      :ok -> :ok
      {:error, message} -> flunk(message)
    end
  end

  @doc """
  Delivers a signal to the workflow run.
  """
  def signal(%Run{} = run, name, args \\ [], opts \\ []) when is_binary(name) do
    case Runner.signal(run, name, args, opts) do
      :ok -> :ok
      {:error, message} -> flunk(message)
    end
  end

  @doc """
  Delivers an update to the workflow run and returns an update handle.
  """
  def update(%Run{} = run, name, args \\ [], opts \\ []) when is_binary(name) do
    case Runner.start_update(run, name, args, opts) do
      {:ok, %Update{} = update} -> update
      {:error, message} -> flunk(message)
    end
  end

  @doc """
  Asserts that the next command accepts the given update.
  """
  def assert_next_update_accepted(%Run{} = run, %Update{} = update) do
    assert_next_update_response(run, update, :accepted)
  end

  @doc """
  Asserts that the next command completes the given update.
  """
  def assert_next_update_completed(%Run{} = run, %Update{} = update, result) do
    assert_next_update_response(run, update, {:completed, result})
  end

  @doc """
  Asserts that the next command rejects the given update.
  """
  def assert_next_update_rejected(%Run{} = run, %Update{} = update, reason) do
    assert_next_update_response(run, update, {:rejected, reason})
  end

  @doc """
  Runs a query activation and returns the query result.
  """
  def query(%Run{} = run, query_type, args \\ [], opts \\ []) when is_binary(query_type) do
    case Runner.query(run, query_type, args, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      message when is_binary(message) -> flunk(message)
    end
  end

  @doc """
  Runs a query activation and asserts its successful result.
  """
  def assert_query(%Run{} = run, query_type, args, expected, opts \\ []) do
    assert {:ok, result} = query(run, query_type, args, opts)
    assert result == expected
    result
  end

  @doc """
  Delivers workflow cancellation.
  """
  def cancel_workflow(%Run{} = run, reason \\ "requested", opts \\ []) do
    case Runner.cancel_workflow(run, reason, opts) do
      :ok -> :ok
      {:error, message} -> flunk(message)
    end
  end

  @doc """
  Asserts that the workflow completed successfully.
  """
  def assert_completed(%Run{} = run) do
    assert_no_commands(run)

    case Runner.terminal(run) do
      {:completed, result} ->
        result

      nil ->
        flunk("expected workflow to be completed, but it is still running")

      terminal ->
        flunk("expected workflow to be completed, but terminal state is #{inspect(terminal)}")
    end
  end

  def assert_completed(%Run{} = run, expected) do
    result = assert_completed(run)
    assert result == expected
    result
  end

  @doc """
  Asserts that the workflow has not completed successfully.
  """
  def refute_completed(%Run{} = run) do
    case Runner.terminal(run) do
      {:completed, result} ->
        flunk("expected workflow not to be completed, but got #{inspect(result)}")

      _other ->
        :ok
    end
  end

  @doc """
  Asserts that the workflow failed.
  """
  def assert_failed(%Run{} = run) do
    assert_no_commands(run)

    case Runner.terminal(run) do
      {:failed_workflow, reason} ->
        reason

      {:failed, reason} ->
        reason

      nil ->
        flunk("expected workflow to be failed, but it is still running")

      terminal ->
        flunk("expected workflow to be failed, but terminal state is #{inspect(terminal)}")
    end
  end

  def assert_failed(%Run{} = run, expected) do
    reason = assert_failed(run)
    assert reason == expected
    reason
  end

  @doc """
  Asserts that the workflow cancelled.
  """
  def assert_cancelled(%Run{} = run) do
    assert_no_commands(run)

    case Runner.terminal(run) do
      {:cancelled, reason} ->
        reason

      nil ->
        flunk("expected workflow to be cancelled, but it is still running")

      terminal ->
        flunk("expected workflow to be cancelled, but terminal state is #{inspect(terminal)}")
    end
  end

  @doc """
  Asserts that the workflow continued as new and returns the command.
  """
  def assert_continue_as_new(%Run{} = run) do
    assert_no_commands(run)

    case Runner.terminal(run) do
      {:continue_as_new, %Command.ContinueAsNew{} = command} ->
        command

      nil ->
        flunk("expected workflow to continue as new, but it is still running")

      terminal ->
        flunk("expected workflow to continue as new, but terminal state is #{inspect(terminal)}")
    end
  end

  def assert_continue_as_new(%Run{} = run, expected_input) do
    command = assert_continue_as_new(run)
    assert command.input == expected_input
    command
  end

  @doc """
  Replays the recorded activation transcript and asserts deterministic command emission.
  """
  def assert_replay(%Run{} = run) do
    case Runner.replay(run) do
      :ok -> :ok
      {:error, reason} -> flunk("workflow replay failed: #{inspect(reason)}")
    end
  end

  @doc """
  Returns a debugging snapshot of the testing runner.
  """
  def snapshot(%Run{} = run), do: Runner.snapshot(run)

  defp assert_next_update_response(run, update, response) do
    assert_next_command(run, fn
      %Command.RespondToUpdate{
        protocol_instance_id: protocol_instance_id,
        response: actual_response
      } ->
        protocol_instance_id == update.protocol_instance_id and actual_response == response

      _command ->
        false
    end)
  end

  defp command_matches?(_command, nil), do: true

  defp command_matches?(command, module) when is_atom(module) do
    match?(%{__struct__: ^module}, command)
  end

  defp command_matches?(command, expected) when is_struct(expected), do: command == expected

  defp command_matches?(command, predicate) when is_function(predicate, 1),
    do: predicate.(command)

  defp command_matches?(_command, _expected), do: false
end
