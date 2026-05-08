defmodule Temporalex.TestingTest do
  use ExUnit.Case, async: false

  import Temporalex.Testing

  alias Temporalex.Core.Command
  alias Temporalex.Failure.CancelledError
  alias Temporalex.Workflow.API

  defmodule Activities do
    use Temporalex.Activity

    defactivity echo(value), timeout: 1_000 do
      {:ok, value}
    end
  end

  defmodule ActivityWorkflow do
    use Temporalex.Workflow

    def run(value) do
      case Activities.echo(value) do
        {:ok, result} -> {:ok, result}
        other -> {:ok, other}
      end
    end
  end

  defmodule ActivityFailureWorkflow do
    use Temporalex.Workflow

    def run(value) do
      {:ok, result} = Activities.echo(value)
      {:ok, result}
    end
  end

  defmodule TimerWorkflow do
    use Temporalex.Workflow

    def run(duration_ms) do
      :ok = API.sleep!(duration_ms)
      {:ok, :slept}
    end
  end

  defmodule ParallelWorkflow do
    use Temporalex.Workflow

    def run(_) do
      results =
        API.parallel!([
          fn ->
            {:ok, a1} = Activities.echo(:a1)
            {:ok, a2} = Activities.echo(:a2)
            {:a, a1, a2}
          end,
          fn ->
            {:ok, b1} = Activities.echo(:b1)
            {:ok, b2} = Activities.echo(:b2)
            {:b, b1, b2}
          end
        ])

      {:ok, results}
    end
  end

  defmodule QueryWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(_) do
      API.publish_state(%{step: :before_activity})
      {:ok, :activity} = Activities.echo(:activity)
      API.publish_state(%{step: :after_activity})
      {:ok, :done}
    end
  end

  defmodule PhaseWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase!(0,
          signal: %{
            "inc" => fn [amount], state -> {:noreply, state + amount} end,
            "done" => fn _args, state -> {:stop, state} end
          },
          update: %{
            "add" => fn [amount], state -> {:reply, state + amount, state + amount} end,
            "stop" => fn _args, state -> {:stop, :stopped, state} end
          }
        )

      {:ok, state}
    end
  end

  defmodule CancellableTimerWorkflow do
    use Temporalex.Workflow

    def run(_) do
      try do
        API.sleep!(60_000)
        {:ok, :slept}
      rescue
        error in CancelledError -> {:cancelled, error}
      end
    end
  end

  defmodule ErrorWorkflow do
    use Temporalex.Workflow

    def run(reason), do: {:error, reason}
  end

  test "activity commands are asserted and completed through operation handles" do
    assert {:ok, run} = start_workflow(ActivityWorkflow, :value)

    activity =
      assert_next_activity(run,
        type: {Activities, :echo},
        input: [:value],
        activity_id: "activity-0",
        thread_id: []
      )

    assert activity.seq == 0
    assert_no_commands(run)

    complete_activity(run, activity, {:ok, :result})

    assert_completed(run, :result)
    assert_replay(run)
  end

  test "activity failures are driven explicitly" do
    assert {:ok, run} = start_workflow(ActivityFailureWorkflow, :value)
    activity = assert_next_activity(run, type: {Activities, :echo}, input: [:value])

    fail_activity(run, activity, :activity_failed)

    assert_failed(run)
    assert_replay(run)
  end

  test "timers are asserted and fired through operation handles" do
    assert {:ok, run} = start_workflow(TimerWorkflow, 25)

    timer = assert_next_timer(run, duration_ms: 25, thread_id: [])
    assert timer.seq == 0

    fire_timer(run, timer)

    assert_completed(run, :slept)
    assert_replay(run)
  end

  test "all emitted commands must be consumed before the next activation" do
    assert {:ok, run} = start_workflow(ParallelWorkflow, nil)

    first = assert_next_activity(run, input: [:a1], thread_id: [{:p, 0}])

    assert_raise ExUnit.AssertionError, ~r/unconsumed commands/, fn ->
      complete_activity(run, first, {:ok, :a1})
    end

    second = assert_next_activity(run, input: [:b1], thread_id: [{:p, 1}])
    assert_no_commands(run)

    complete_activity(run, second, {:ok, :b1})
    second_next = assert_next_activity(run, input: [:b2], thread_id: [{:p, 1}])
    assert_no_commands(run)

    complete_activity(run, first, {:ok, :a1})
    first_next = assert_next_activity(run, input: [:a2], thread_id: [{:p, 0}])
    assert_no_commands(run)

    complete_activity(run, first_next, {:ok, :a2})
    refute_completed(run)

    complete_activity(run, second_next, {:ok, :b2})

    assert_completed(run, [{:a, :a1, :a2}, {:b, :b1, :b2}])
    assert_replay(run)
  end

  test "queries run as explicit inputs while durable work is blocked" do
    assert {:ok, run} = start_workflow(QueryWorkflow, nil)

    activity = assert_next_activity(run, input: [:activity])
    assert_query(run, "state", [], %{step: :before_activity})

    complete_activity(run, activity, {:ok, :activity})

    assert_completed(run, :done)
    assert_replay(run)
  end

  test "signals and updates are explicit workflow inputs" do
    assert {:ok, run} = start_workflow(PhaseWorkflow, nil)
    assert_no_commands(run)

    signal(run, "inc", [2])
    assert_no_commands(run)

    update = update(run, "add", [3], protocol_instance_id: "add-3")
    assert_next_update_accepted(run, update)
    assert_next_update_completed(run, update, 5)
    assert_no_commands(run)

    stop = update(run, "stop", [], protocol_instance_id: "stop")
    assert_next_update_accepted(run, stop)
    assert_next_update_completed(run, stop, :stopped)

    assert_completed(run, 5)
    assert_replay(run)
  end

  test "workflow cancellation exposes non-terminal commands before terminal cancellation" do
    assert {:ok, run} = start_workflow(CancellableTimerWorkflow, nil)

    _timer = assert_next_timer(run, duration_ms: 60_000)
    assert_no_commands(run)

    cancel_workflow(run, "requested")

    cancel_timer = assert_next_command(run, Command.CancelTimer)
    assert %Command.CancelTimer{seq: 0} = cancel_timer

    assert %CancelledError{message: "requested"} = assert_cancelled(run)
    assert_replay(run)
  end

  test "workflow failures are terminal assertions" do
    assert {:ok, run} = start_workflow(ErrorWorkflow, :planned)

    assert_failed(run, :planned)
    assert_replay(run)
  end
end
