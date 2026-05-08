defmodule Temporalex.TestingWorkflowBehaviorTest do
  use ExUnit.Case, async: false

  import Temporalex.Testing

  alias Temporalex.Core.Command
  alias Temporalex.Core.TraceGuard.Violation, as: TraceViolation
  alias Temporalex.Failure
  alias Temporalex.Failure.CancelledError
  alias Temporalex.Workflow.API

  defmodule Activities do
    use Temporalex.Activity

    defactivity echo(value), timeout: 1_000 do
      {:ok, value}
    end
  end

  defmodule WaitSignalWorkflow do
    use Temporalex.Workflow

    def run(_) do
      args = API.wait_for_signal!("go")
      {:ok, args}
    end
  end

  defmodule ContinueWorkflow do
    use Temporalex.Workflow

    def run(input) do
      API.continue_as_new!(%{next: input},
        task_queue: "continued",
        headers: %{trace: "testing"}
      )
    end
  end

  defmodule NonCancellableCleanupWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state = %{reserved: true}

      try do
        API.sleep!(60_000)
        {:ok, :slept}
      rescue
        error in CancelledError ->
          API.non_cancellable(fn ->
            {:ok, _cleanup} = Activities.echo({:cleanup, state})
            :ok
          end)

          {:cancelled, error}
      end
    end
  end

  defmodule CancellableCleanupWorkflow do
    use Temporalex.Workflow

    def run(_) do
      try do
        try do
          API.sleep!(60_000)
          {:ok, :slept}
        rescue
          _error in CancelledError ->
            API.sleep!(1)
            {:ok, :cleanup_completed}
        end
      rescue
        error in CancelledError ->
          {:ok, {:cleanup_blocked, error.message}}
      end
    end
  end

  defmodule ActivityWaitCancellationWorkflow do
    use Temporalex.Workflow

    def run(_) do
      try do
        API.execute_activity!("#{inspect(Activities)}.echo", [:work],
          cancellation_type: :wait_cancellation_completed
        )

        {:ok, :activity_completed}
      rescue
        error in CancelledError -> {:cancelled, error}
      end
    end
  end

  defmodule ActivityTryCancelWorkflow do
    use Temporalex.Workflow

    def run(_) do
      try do
        API.execute_activity!("#{inspect(Activities)}.echo", [:work],
          cancellation_type: :try_cancel
        )

        {:ok, :activity_completed}
      rescue
        error in CancelledError -> {:cancelled, error}
      end
    end
  end

  defmodule ActivityAbandonWorkflow do
    use Temporalex.Workflow

    def run(_) do
      try do
        API.execute_activity!("#{inspect(Activities)}.echo", [:work], cancellation_type: :abandon)

        {:ok, :activity_completed}
      rescue
        error in CancelledError -> {:cancelled, error}
      end
    end
  end

  defmodule ParallelCancellationWorkflow do
    use Temporalex.Workflow

    def run(_) do
      try do
        API.parallel!([
          fn ->
            API.sleep!(10_000)
            :a
          end,
          fn ->
            API.sleep!(20_000)
            :b
          end
        ])

        {:ok, :parallel_completed}
      rescue
        error in CancelledError -> {:cancelled, error}
      end
    end
  end

  defmodule AsyncSignalWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase!(0,
          signal: %{
            "slow" => fn _args, state ->
              {:async,
               fn ->
                 :ok = API.sleep!(10)
                 API.update_state(fn current -> {:updated, current + 1} end)
                 :done
               end, state}
            end,
            "done" => fn _args, state -> {:stop, state} end
          }
        )

      {:ok, state}
    end
  end

  defmodule AsyncUpdateWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase!(0,
          update: %{
            "slow" => fn [amount], state ->
              {:async,
               fn ->
                 :ok = API.sleep!(10)
                 API.update_state(fn current -> {current + amount, current + amount} end)
               end, state}
            end,
            "stop" => fn _args, state -> {:stop, :stopped, state} end
          }
        )

      {:ok, state}
    end
  end

  defmodule ValidatedUpdateWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase!(0,
          update: %{
            "add" =>
              {fn [amount], state -> {:reply, state + amount, state + amount} end,
               validator: fn
                 [amount], _state when amount > 0 -> :ok
                 _args, _state -> {:error, :invalid_amount}
               end}
          },
          signal: %{"done" => fn _args, state -> {:stop, state} end}
        )

      {:ok, state}
    end
  end

  defmodule UnsafeTimeWorkflow do
    use Temporalex.Workflow

    def run(_) do
      {:ok, DateTime.utc_now()}
    end
  end

  test "signal wait workflows can be driven linearly" do
    assert {:ok, run} = start_workflow(WaitSignalWorkflow, nil)
    assert_no_commands(run)

    signal(run, "go", [:payload])

    assert_completed(run, [:payload])
    assert_replay(run)
  end

  test "continue-as-new is asserted as terminal workflow behavior" do
    assert {:ok, run} = start_workflow(ContinueWorkflow, :input)

    command = assert_continue_as_new(run, %{next: :input})

    assert command.task_queue == "continued"
    assert command.opts[:headers] == %{"trace" => "testing"}
    assert_replay(run)
  end

  test "non-cancellable cleanup can schedule durable work after cancellation" do
    assert {:ok, run} = start_workflow(NonCancellableCleanupWorkflow, nil)

    _timer = assert_next_timer(run, duration_ms: 60_000)
    assert_no_commands(run)

    cancel_workflow(run, "cleanup requested")

    assert %Command.CancelTimer{} = assert_next_command(run, Command.CancelTimer)

    cleanup =
      assert_next_activity(run,
        type: {Activities, :echo},
        input: [cleanup: %{reserved: true}]
      )

    assert_no_commands(run)

    complete_activity(run, cleanup, {:ok, {:cleanup, %{reserved: true}}})

    assert %CancelledError{message: "cleanup requested"} = assert_cancelled(run)
    assert_replay(run)
  end

  test "cancellable cleanup work is blocked by cancellation" do
    assert {:ok, run} = start_workflow(CancellableCleanupWorkflow, nil)

    _timer = assert_next_timer(run, duration_ms: 60_000)
    assert_no_commands(run)

    cancel_workflow(run, "requested")

    assert %Command.CancelTimer{} = assert_next_command(run, Command.CancelTimer)
    assert_completed(run, {:cleanup_blocked, "requested"})
    assert_replay(run)
  end

  test "wait-cancellation-completed activities finish cancellation after activity cancellation arrives" do
    assert {:ok, run} = start_workflow(ActivityWaitCancellationWorkflow, nil)

    activity = assert_next_activity(run, input: [:work])
    assert_no_commands(run)

    cancel_workflow(run, "requested")

    request_cancel = assert_next_command(run, Command.RequestCancelActivity)
    assert request_cancel.seq == activity.seq
    assert_no_commands(run)

    cancel_activity(run, activity, Failure.cancelled("activity cancelled"))

    assert %CancelledError{message: "activity cancelled"} = assert_cancelled(run)
    assert_replay(run)
  end

  test "try-cancel activities cancel workflow immediately and ignore late completion" do
    assert {:ok, run} = start_workflow(ActivityTryCancelWorkflow, nil)

    activity = assert_next_activity(run, input: [:work])
    assert_no_commands(run)

    cancel_workflow(run, "requested")

    request_cancel = assert_next_command(run, Command.RequestCancelActivity)
    assert request_cancel.seq == activity.seq

    assert %CancelledError{message: "requested"} = assert_cancelled(run)

    complete_activity(run, activity, {:ok, :late}, allow_after_terminal: true)

    assert_no_commands(run)
    assert %CancelledError{message: "requested"} = assert_cancelled(run)
    assert_replay(run)
  end

  test "abandon activities cancel workflow without emitting activity cancellation command" do
    assert {:ok, run} = start_workflow(ActivityAbandonWorkflow, nil)

    _activity = assert_next_activity(run, input: [:work])
    assert_no_commands(run)

    cancel_workflow(run, "requested")

    assert %CancelledError{message: "requested"} = assert_cancelled(run)
    assert_replay(run)
  end

  test "parallel cancellation exposes cancellation for every branch timer" do
    assert {:ok, run} = start_workflow(ParallelCancellationWorkflow, nil)

    first = assert_next_timer(run, duration_ms: 10_000, thread_id: [{:p, 0}])
    second = assert_next_timer(run, duration_ms: 20_000, thread_id: [{:p, 1}])
    assert_no_commands(run)

    cancel_workflow(run, "requested")

    first_cancel = assert_next_command(run, Command.CancelTimer)
    second_cancel = assert_next_command(run, Command.CancelTimer)

    assert first_cancel.seq == first.seq
    assert second_cancel.seq == second.seq
    assert %CancelledError{message: "requested"} = assert_cancelled(run)
    assert_replay(run)
  end

  test "async signal handlers can be driven through timer handles" do
    assert {:ok, run} = start_workflow(AsyncSignalWorkflow, nil)
    assert_no_commands(run)

    signal(run, "slow", [])

    timer = assert_next_timer(run, duration_ms: 10, thread_id: [{:h, 0}, {:a, 0}])
    assert_no_commands(run)

    fire_timer(run, timer)
    assert_no_commands(run)

    signal(run, "done", [])

    assert_completed(run, 1)
    assert_replay(run)
  end

  test "async update handlers expose accepted, durable work, and completed responses" do
    assert {:ok, run} = start_workflow(AsyncUpdateWorkflow, nil)
    assert_no_commands(run)

    update = update(run, "slow", [3], protocol_instance_id: "slow")
    assert_next_update_accepted(run, update)

    timer = assert_next_timer(run, duration_ms: 10, thread_id: [{:h, 0}, {:a, 0}])
    assert_no_commands(run)

    fire_timer(run, timer)

    assert_next_update_completed(run, update, 3)
    assert_no_commands(run)

    stop = update(run, "stop", [], protocol_instance_id: "stop")
    assert_next_update_accepted(run, stop)
    assert_next_update_completed(run, stop, :stopped)

    assert_completed(run, 3)
    assert_replay(run)
  end

  test "update rejection is visible through update response commands" do
    assert {:ok, run} = start_workflow(ValidatedUpdateWorkflow, nil)
    assert_no_commands(run)

    update = update(run, "add", [-1], protocol_instance_id: "bad")
    assert_next_update_rejected(run, update, :invalid_amount)
    assert_no_commands(run)

    signal(run, "done", [])

    assert_completed(run, 0)
    assert_replay(run)
  end

  test "safe mode failures are visible through terminal failure assertions" do
    assert {:ok, run} = start_workflow(UnsafeTimeWorkflow, nil)

    assert %TraceViolation{
             kind: :unsafe_call,
             thread_id: []
           } = assert_failed(run)
  end
end
