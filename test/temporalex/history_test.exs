defmodule Temporalex.HistoryTest do
  @moduledoc """
  Unit coverage for `Temporalex.History` helpers on synthetic events. The
  decode path itself is covered live in
  `test/temporalex/integration/fetch_history_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Temporalex.History
  alias Temporalex.History.Event

  defp history(events), do: %History{workflow_id: "w", run_id: "r", events: events}

  defp event(id, type, attributes \\ nil),
    do: %Event{id: id, time: ~U[2026-08-18 12:00:00Z], type: type, attributes: attributes}

  test "events/2 filters by type in order" do
    h =
      history([
        event(1, :workflow_execution_started),
        event(2, :activity_task_scheduled),
        event(5, :activity_task_scheduled)
      ])

    assert [%Event{id: 2}, %Event{id: 5}] = History.events(h, :activity_task_scheduled)
    assert History.events(h, :timer_started) == []
  end

  test "last/2 returns the latest of a type, or nil" do
    h = history([event(1, :workflow_task_failed), event(9, :workflow_task_failed)])
    assert %Event{id: 9} = History.last(h, :workflow_task_failed)
    assert History.last(h, :timer_started) == nil
  end

  test "stuck_reason/1 is nil when no workflow task ever failed" do
    h = history([event(1, :workflow_execution_started), event(2, :workflow_execution_completed)])
    assert History.stuck_reason(h) == nil
  end

  test "stuck_reason/1 surfaces the LATEST failed task's failure" do
    h =
      history([
        event(3, :workflow_task_failed, %{
          failure: %{message: "old attempt"},
          cause: :WORKFLOW_TASK_FAILED_CAUSE_UNSPECIFIED
        }),
        event(7, :workflow_task_failed, %{
          failure: %{message: "replay command mismatch"},
          cause: :WORKFLOW_TASK_FAILED_CAUSE_NON_DETERMINISTIC_ERROR
        })
      ])

    assert %{
             message: "replay command mismatch",
             cause: :WORKFLOW_TASK_FAILED_CAUSE_NON_DETERMINISTIC_ERROR,
             event_id: 7
           } = History.stuck_reason(h)
  end

  test "stuck_reason/1 tolerates a failed task without failure details" do
    h = history([event(4, :workflow_task_failed, %{})])
    assert %{message: nil, cause: nil, event_id: 4} = History.stuck_reason(h)
  end
end
