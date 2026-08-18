defmodule Temporalex.Replay do
  @moduledoc """
  Replays a recorded workflow history against current workflow code.

  The pre-deploy compatibility check: fetch a real execution's history, run
  it through the deterministic executor with the code you are *about* to
  ship, and learn whether in-flight workflows would survive the deploy —
  before the deploy.

      {:ok, history} = Temporalex.Client.fetch_workflow_history(handle)
      :ok = Temporalex.Replay.replay(history, workflows: [Checkout])

  A divergence — the code scheduling a different activity, a different
  timer, or completing differently than the record — returns
  `{:error, {:nondeterminism, detail}}`. That is exactly the error those
  workflows would hit in production, surfaced in CI instead.

  ## Coverage

  Replays histories built from: workflow start, activity schedule /
  completion / failure, timers, signals, cancellation, and terminal
  completion / failure / cancellation. Any other event kind returns
  `{:error, {:unsupported_event, type, event_id}}` rather than being
  silently skipped — a replay that ignores part of the record proves
  nothing. Notable not-yet-supported: patch markers, child workflows,
  updates, continue-as-new, local activities.

  Activity inputs are compared as decoded terms (ETF payloads compare
  exactly; a lossy codec could round-trip differently). Only the first
  workflow-input payload is used — Temporalex workflows take one input
  term; multi-payload starts from non-Elixir clients are truncated to it.

  Activation-grouping drift is caught even though the model is flat: the
  runner refuses to deliver an outcome while commands sit unconsumed, so
  refactoring sequential work into parallel (or back) diverges loudly even
  when the global command order is unchanged.

  Fixtures must be the protobuf form (`fetch_workflow_history(handle,
  raw: true)`). `temporal workflow show --output json` files are NOT
  replayable: `.temporal.api.history` is absent from temporalio-common's
  pbjson list, so proto-JSON does not round-trip (the same reason the NIF
  returns bytes).

  Typical CI shape: check fixture files in with
  `fetch_workflow_history(handle, raw: true)`, and replay them in a test:

      for fixture <- Path.wildcard("test/fixtures/histories/*.binpb") do
        {:ok, history} = Temporalex.Replay.decode(File.read!(fixture))
        assert :ok = Temporalex.Replay.replay(history, workflows: [Checkout])
      end
  """

  alias Temporalex.Backend.TemporalCore.Codec
  alias Temporalex.Backend.TemporalCore.PayloadConverter
  alias Temporalex.History
  alias Temporalex.History.Event
  alias Temporalex.Testing.Runner

  @doc """
  Decodes a raw history fixture (the `raw: true` fetch shape) into a
  `Temporalex.History`.
  """
  @spec decode(binary()) :: {:ok, History.t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, events} <- Codec.history_from_bytes(bytes) do
      {:ok, %History{events: Enum.map(events, &struct!(Event, &1))}}
    end
  end

  @doc """
  Replays `history` against the current code of one of `workflows:`.

  The module is resolved by the recorded workflow type (respecting `name:`
  overrides). Returns `:ok` when every recorded decision matches what the
  current code decides, `{:error, {:nondeterminism, detail}}` on divergence,
  and `{:error, {:unsupported_event, type, event_id}}` for history the
  replayer cannot yet drive.
  """
  @spec replay(History.t(), keyword()) :: :ok | {:error, term()}
  def replay(%History{events: events}, opts) when is_list(opts) do
    workflows = Keyword.fetch!(opts, :workflows)

    with {:ok, started, rest} <- pop_started(events),
         {:ok, module} <- resolve_module(workflows, started),
         {:ok, input} <- decode_input(started),
         {:ok, run} <- Runner.start_workflow(module, input, safe_mode: :fail) do
      drive(rest, run, %{activities: %{}, timers: %{}})
    end
  end

  ## Event loop — each recorded event either consumes a command the current
  ## code must have emitted, feeds the current code a recorded outcome, or is
  ## a task-boundary event the runner handles implicitly.

  defp drive([], run, _refs), do: finish(run, nil)

  defp drive([%Event{type: type} = event | rest], run, refs) do
    case step(type, event, run, refs) do
      {:cont, refs} -> drive(rest, run, refs)
      {:done, expected_terminal} -> finish(run, expected_terminal)
      {:error, _} = error -> error
    end
  end

  # Task boundaries: the runner activates on its own cadence; workflow task
  # failures/timeouts are retries of the same decisions, nothing to drive.
  defp step(type, _event, _run, refs)
       when type in [
              :workflow_task_scheduled,
              :workflow_task_started,
              :workflow_task_completed,
              :workflow_task_failed,
              :workflow_task_timed_out
            ],
       do: {:cont, refs}

  defp step(:activity_task_scheduled, %Event{} = event, run, refs) do
    with {:ok, recorded_type} <- required(event, :activity_type),
         {:ok, recorded_input} <- decode_payloads(event.attributes[:input]) do
      case Runner.pop_next_activity(run, type: recorded_type, input: recorded_input) do
        {:ok, activity} ->
          {:cont, put_in(refs.activities[event.id], activity)}

        {:error, detail} ->
          nondeterminism(
            event,
            "expected the code to schedule activity #{recorded_type} " <>
              "with input #{inspect(recorded_input, limit: 5)}",
            detail
          )
      end
    end
  end

  defp step(:activity_task_started, _event, _run, refs), do: {:cont, refs}

  defp step(:activity_task_completed, %Event{} = event, run, refs) do
    with {:ok, activity, refs} <- take_activity(refs, event, :scheduled_event_id),
         {:ok, result} <- decode_first_payload(event.attributes[:result]) do
      case Runner.complete_activity(run, activity, {:ok, result}, []) do
        :ok -> {:cont, refs}
        {:error, detail} -> nondeterminism(event, "activity completion was refused", detail)
      end
    end
  end

  defp step(:activity_task_failed, %Event{} = event, run, refs) do
    with {:ok, activity, refs} <- take_activity(refs, event, :scheduled_event_id) do
      reason = get_in(event.attributes, [:failure, :message]) || "activity failed"

      case Runner.complete_activity(run, activity, {:error, reason}, []) do
        :ok -> {:cont, refs}
        {:error, detail} -> nondeterminism(event, "activity failure was refused", detail)
      end
    end
  end

  defp step(:timer_started, %Event{} = event, run, refs) do
    duration_ms = event.attributes[:start_to_fire_timeout]

    case Runner.pop_next_timer(run, duration_ms: duration_ms) do
      {:ok, timer} ->
        {:cont, put_in(refs.timers[event.id], timer)}

      {:error, detail} ->
        nondeterminism(event, "expected the code to start a #{duration_ms}ms timer", detail)
    end
  end

  defp step(:timer_fired, %Event{} = event, run, refs) do
    started_id = event.attributes[:started_event_id]

    case Map.pop(refs.timers, started_id) do
      {nil, _} ->
        nondeterminism(event, "timer fired for an unknown started_event_id", started_id)

      {timer, timers} ->
        case Runner.fire_timer(run, timer, []) do
          :ok -> {:cont, %{refs | timers: timers}}
          {:error, detail} -> nondeterminism(event, "timer fire was refused", detail)
        end
    end
  end

  defp step(:workflow_execution_signaled, %Event{} = event, run, refs) do
    with {:ok, signal_name} <- required(event, :signal_name),
         {:ok, args} <- decode_payloads(event.attributes[:input]) do
      case Runner.signal(run, signal_name, args, []) do
        :ok -> {:cont, refs}
        {:error, detail} -> nondeterminism(event, "signal was refused", detail)
      end
    end
  end

  defp step(:workflow_execution_cancel_requested, %Event{} = event, run, refs) do
    reason = event.attributes[:cause] || "cancel requested"

    case Runner.cancel_workflow(run, reason, []) do
      :ok -> {:cont, refs}
      {:error, detail} -> nondeterminism(event, "cancellation was refused", detail)
    end
  end

  defp step(:workflow_execution_completed, _event, _run, _refs), do: {:done, :completed}
  defp step(:workflow_execution_failed, _event, _run, _refs), do: {:done, :failed}
  defp step(:workflow_execution_canceled, _event, _run, _refs), do: {:done, :cancelled}

  defp step(type, %Event{id: id}, _run, _refs), do: {:error, {:unsupported_event, type, id}}

  # The recorded terminal kind and the replayed terminal kind must agree.
  # Result VALUES are deliberately not compared: they may embed run-specific
  # data, and value drift is not nondeterminism.
  defp finish(run, expected) do
    case {expected, Runner.terminal(run)} do
      {nil, _} ->
        :ok

      {:completed, {:completed, _result}} ->
        :ok

      {:failed, {:failed_workflow, _reason}} ->
        :ok

      {:cancelled, {:cancelled, _reason}} ->
        :ok

      {expected, actual} ->
        {:error,
         {:nondeterminism,
          "recorded terminal #{inspect(expected)} but the current code produced " <>
            inspect(actual)}}
    end
  end

  ## Resolution and decoding

  defp pop_started([%Event{type: :workflow_execution_started} = started | rest]),
    do: {:ok, started, rest}

  defp pop_started([%Event{type: type, id: id} | _]),
    do: {:error, {:malformed_history, "history begins with #{inspect(type)} (event #{id})"}}

  defp pop_started([]), do: {:error, {:malformed_history, "history has no events"}}

  defp resolve_module(workflows, %Event{} = started) do
    with {:ok, recorded} <- required(started, :workflow_type) do
      find_by_type(workflows, recorded)
    end
  end

  defp find_by_type(workflows, recorded) do
    Enum.find_value(
      workflows,
      {:error, {:unknown_workflow_type, recorded, workflows}},
      fn mod -> if mod.__workflow_type__() == recorded, do: {:ok, mod} end
    )
  end

  defp required(%Event{id: id, type: type, attributes: attributes}, key) do
    case attributes[key] do
      nil -> {:error, {:malformed_history, "event #{id} (#{type}) lacks #{inspect(key)}"}}
      value -> {:ok, value}
    end
  end

  defp decode_input(%Event{attributes: attributes}),
    do: decode_first_payload(attributes[:input])

  defp decode_first_payload(%{payloads: [payload | _]}),
    do: PayloadConverter.payload_to_term(payload)

  defp decode_first_payload(_), do: {:ok, nil}

  defp decode_payloads(%{payloads: payloads}), do: PayloadConverter.payloads_to_terms(payloads)
  defp decode_payloads(_), do: {:ok, []}

  defp take_activity(refs, %Event{} = event, key) do
    scheduled_id = event.attributes[key]

    case Map.pop(refs.activities, scheduled_id) do
      {nil, _} ->
        nondeterminism(event, "outcome for an activity the code never scheduled", scheduled_id)

      {activity, activities} ->
        {:ok, activity, %{refs | activities: activities}}
    end
  end

  defp nondeterminism(%Event{id: id, type: type}, what, detail) do
    {:error, {:nondeterminism, "event #{id} (#{type}): #{what} — #{inspect(detail)}"}}
  end
end
