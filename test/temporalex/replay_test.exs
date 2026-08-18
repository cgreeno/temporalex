defmodule Temporalex.ReplayTest do
  @moduledoc """
  Unit coverage for `Temporalex.Replay` on synthetic histories — no server.
  The wire-shape truth (real payload encodings, real durations) is covered by
  the live round-trip in `test/temporalex/integration/fetch_history_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Backend.TemporalCore.PayloadConverter
  alias Temporalex.History
  alias Temporalex.History.Event
  alias Temporalex.Replay
  alias Temporalex.Workflow.API

  defmodule Flow do
    use Temporalex.Workflow

    def run(n) do
      {:ok, doubled} = API.execute_activity("replay.double", [n], timeout: 5_000)
      :ok = API.sleep(1_000)
      {:ok, args} = API.wait_for_signal("go")
      {:ok, {doubled, args}}
    end
  end

  defmodule DriftedFlow do
    use Temporalex.Workflow

    # Same wire type as what the fixture records — name: pins it — but the
    # code now schedules a DIFFERENT activity: the classic bad deploy.
    def run(n) do
      {:ok, doubled} = API.execute_activity("replay.tripled", [n], timeout: 5_000)
      {:ok, doubled}
    end
  end

  defp payloads(terms), do: %{payloads: Enum.map(terms, &PayloadConverter.term_to_payload/1)}

  defp happy_events(workflow_type) do
    [
      %Event{
        id: 1,
        type: :workflow_execution_started,
        attributes: %{workflow_type: workflow_type, input: payloads([2])}
      },
      %Event{id: 2, type: :workflow_task_scheduled, attributes: %{}},
      %Event{id: 3, type: :workflow_task_started, attributes: %{}},
      %Event{id: 4, type: :workflow_task_completed, attributes: %{}},
      %Event{
        id: 5,
        type: :activity_task_scheduled,
        attributes: %{activity_type: "replay.double", input: payloads([2])}
      },
      %Event{id: 6, type: :activity_task_started, attributes: %{}},
      %Event{
        id: 7,
        type: :activity_task_completed,
        attributes: %{scheduled_event_id: 5, result: payloads([4])}
      },
      %Event{id: 8, type: :timer_started, attributes: %{start_to_fire_timeout: 1_000}},
      %Event{id: 9, type: :timer_fired, attributes: %{started_event_id: 8}},
      %Event{
        id: 10,
        type: :workflow_execution_signaled,
        attributes: %{signal_name: "go", input: payloads([:hi])}
      },
      %Event{id: 11, type: :workflow_execution_completed, attributes: %{}}
    ]
  end

  defp history(events), do: %History{workflow_id: "w", run_id: "r", events: events}

  test "a faithful history replays clean against the current code" do
    assert :ok = Replay.replay(history(happy_events(inspect(Flow))), workflows: [Flow])
  end

  test "code that schedules a different activity than recorded is nondeterminism" do
    events =
      happy_events(inspect(DriftedFlow))
      |> Enum.take(7)

    assert {:error, {:nondeterminism, detail}} =
             Replay.replay(history(events), workflows: [DriftedFlow])

    assert detail =~ "replay.double"
  end

  test "a recorded outcome for an activity the code never scheduled is nondeterminism" do
    [started | _] = happy_events(inspect(Flow))

    events = [
      started,
      %Event{
        id: 7,
        type: :activity_task_completed,
        attributes: %{scheduled_event_id: 99, result: payloads([4])}
      }
    ]

    assert {:error, {:nondeterminism, detail}} = Replay.replay(history(events), workflows: [Flow])
    assert detail =~ "never scheduled"
  end

  test "an unsupported event refuses loudly instead of skipping" do
    [started | _] = happy_events(inspect(Flow))
    events = [started, %Event{id: 2, type: :marker_recorded, attributes: %{}}]

    assert {:error, {:unsupported_event, :marker_recorded, 2}} =
             Replay.replay(history(events), workflows: [Flow])
  end

  defmodule ParallelFlow do
    use Temporalex.Workflow

    # Each branch schedules a follow-up whose type names the branch AND the
    # outcome it received — so if outcomes get delivered to the wrong branch,
    # the code schedules an activity type the history never recorded.
    def run(n) do
      [a, b] =
        API.parallel!([
          fn ->
            {:ok, r} = API.execute_activity("replay.left", [n], timeout: 5_000)
            {:ok, _} = API.execute_activity("replay.left.saw.#{r}", [n], timeout: 5_000)
            r
          end,
          fn ->
            {:ok, r} = API.execute_activity("replay.right", [n], timeout: 5_000)
            {:ok, _} = API.execute_activity("replay.right.saw.#{r}", [n], timeout: 5_000)
            r
          end
        ])

      {:ok, {a, b}}
    end
  end

  test "parallel activities completing out of recorded-schedule order replay clean" do
    # Both scheduled up front; the SECOND completes first. Outcomes are keyed
    # by scheduled_event_id — and the follow-up activity types (which encode
    # what each branch SAW) make mis-pairing produce commands the history
    # lacks, so a FIFO-keyed mutation fails this test.
    events = [
      %Event{
        id: 1,
        type: :workflow_execution_started,
        attributes: %{workflow_type: inspect(ParallelFlow), input: payloads([1])}
      },
      %Event{
        id: 2,
        type: :activity_task_scheduled,
        attributes: %{activity_type: "replay.left", input: payloads([1])}
      },
      %Event{
        id: 3,
        type: :activity_task_scheduled,
        attributes: %{activity_type: "replay.right", input: payloads([1])}
      },
      %Event{
        id: 4,
        type: :activity_task_completed,
        attributes: %{scheduled_event_id: 3, result: payloads([:right_done])}
      },
      %Event{
        id: 5,
        type: :activity_task_scheduled,
        attributes: %{activity_type: "replay.right.saw.right_done", input: payloads([1])}
      },
      %Event{
        id: 6,
        type: :activity_task_completed,
        attributes: %{scheduled_event_id: 2, result: payloads([:left_done])}
      },
      %Event{
        id: 7,
        type: :activity_task_scheduled,
        attributes: %{activity_type: "replay.left.saw.left_done", input: payloads([1])}
      },
      %Event{
        id: 8,
        type: :activity_task_completed,
        attributes: %{scheduled_event_id: 5, result: payloads([:ok2])}
      },
      %Event{
        id: 9,
        type: :activity_task_completed,
        attributes: %{scheduled_event_id: 7, result: payloads([:ok2])}
      },
      %Event{id: 10, type: :workflow_execution_completed, attributes: %{}}
    ]

    assert :ok = Replay.replay(history(events), workflows: [ParallelFlow])
  end

  defmodule FailingActivityFlow do
    use Temporalex.Workflow

    def run(n) do
      case API.execute_activity("replay.flaky", [n], timeout: 5_000) do
        {:ok, v} -> {:ok, v}
        {:error, _reason} -> {:ok, :fell_back}
      end
    end
  end

  test "a recorded activity failure replays into the code's error branch" do
    events = [
      %Event{
        id: 1,
        type: :workflow_execution_started,
        attributes: %{workflow_type: inspect(FailingActivityFlow), input: payloads([1])}
      },
      %Event{
        id: 2,
        type: :activity_task_scheduled,
        attributes: %{activity_type: "replay.flaky", input: payloads([1])}
      },
      %Event{
        id: 3,
        type: :activity_task_failed,
        attributes: %{scheduled_event_id: 2, failure: %{message: "gateway down"}}
      },
      %Event{id: 4, type: :workflow_execution_completed, attributes: %{}}
    ]

    assert :ok = Replay.replay(history(events), workflows: [FailingActivityFlow])
  end

  test "input drift is nondeterminism — the recorded input is compared" do
    events = [
      %Event{
        id: 1,
        type: :workflow_execution_started,
        attributes: %{workflow_type: inspect(FailingActivityFlow), input: payloads([1])}
      },
      # Recorded with input [999]; the code passes [1].
      %Event{
        id: 2,
        type: :activity_task_scheduled,
        attributes: %{activity_type: "replay.flaky", input: payloads([999])}
      }
    ]

    assert {:error, {:nondeterminism, detail}} =
             Replay.replay(history(events), workflows: [FailingActivityFlow])

    assert detail =~ "999"
  end

  defmodule CancellableFlow do
    use Temporalex.Workflow

    def run(_n) do
      case API.sleep(60_000) do
        :ok -> {:ok, :slept}
        {:cancelled, _} = cancelled -> cancelled
      end
    end
  end

  test "a recorded cancellation replays clean" do
    events = [
      %Event{
        id: 1,
        type: :workflow_execution_started,
        attributes: %{workflow_type: inspect(CancellableFlow), input: payloads([1])}
      },
      %Event{id: 2, type: :timer_started, attributes: %{start_to_fire_timeout: 60_000}},
      %Event{id: 3, type: :workflow_execution_cancel_requested, attributes: %{cause: "operator"}},
      %Event{id: 4, type: :workflow_execution_canceled, attributes: %{}}
    ]

    assert :ok = Replay.replay(history(events), workflows: [CancellableFlow])
  end

  test "a workflow type none of the given modules answer to is an error" do
    assert {:error, {:unknown_workflow_type, "Ghost", [Flow]}} =
             Replay.replay(history(happy_events("Ghost")), workflows: [Flow])
  end

  test "a history that does not begin at the beginning is malformed" do
    assert {:error, {:malformed_history, message}} =
             Replay.replay(history(tl(happy_events(inspect(Flow)))), workflows: [Flow])

    assert message =~ "begins with"
  end

  test "a recorded completion against code that no longer completes is caught" do
    # The recorded history completes, but DriftedFlow's type is pinned to a
    # different module below — instead exercise terminal mismatch directly:
    # recorded says :completed, the code (waiting on a signal that never
    # arrives in this truncated record) is still running.
    events =
      happy_events(inspect(Flow))
      |> List.delete_at(9)

    assert {:error, {:nondeterminism, detail}} = Replay.replay(history(events), workflows: [Flow])
    assert detail =~ "recorded terminal :completed"
  end
end
