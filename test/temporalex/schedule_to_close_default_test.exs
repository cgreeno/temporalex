defmodule Temporalex.ScheduleToCloseDefaultTest do
  @moduledoc """
  Regression for #22: `schedule_to_close_timeout` must not default to
  `start_to_close_timeout`.

  ScheduleToClose caps total time across all retry attempts; defaulting it to
  one attempt's budget meant a timed-out attempt consumed the whole cap and
  could never retry. The live retry-after-timeout proof is
  `test/temporalex/integration/timeout_retry_test.exs`; this pins the wire
  shape without a server.
  """

  use ExUnit.Case, async: true

  defmodule Acts do
    use Temporalex.Activity

    defactivity ping(x), start_to_close_timeout: 2_000 do
      {:ok, x}
    end

    defactivity capped(x), start_to_close_timeout: 2_000, schedule_to_close_timeout: 9_000 do
      {:ok, x}
    end
  end

  defmodule WF do
    use Temporalex.Workflow

    def run(which) do
      case which do
        :ping -> {:ok, Acts.ping!(1)}
        :capped -> {:ok, Acts.capped!(1)}
      end
    end
  end

  test "schedule_to_close stays unset unless the caller sets it" do
    {:ok, run} = Temporalex.Testing.start_workflow(WF, :ping)

    activity = Temporalex.Testing.assert_next_activity(run)
    assert activity.start_to_close_timeout_ms == 2_000

    assert activity.schedule_to_close_timeout_ms == nil,
           "schedule_to_close defaulted to #{inspect(activity.schedule_to_close_timeout_ms)} — " <>
             "that cap spans ALL retry attempts, so equalling one attempt's " <>
             "budget makes every timeout non-retryable (#22)"

    Temporalex.Testing.complete_activity(run, activity, {:ok, 1})
    Temporalex.Testing.assert_completed(run, 1)
    Temporalex.Testing.assert_replay(run)
  end

  test "an explicit schedule_to_close is honoured verbatim" do
    {:ok, run} = Temporalex.Testing.start_workflow(WF, :capped)

    activity = Temporalex.Testing.assert_next_activity(run)
    assert activity.schedule_to_close_timeout_ms == 9_000
    assert activity.start_to_close_timeout_ms == 2_000

    Temporalex.Testing.complete_activity(run, activity, {:ok, 1})
    Temporalex.Testing.assert_completed(run, 1)
    Temporalex.Testing.assert_replay(run)
  end
end
