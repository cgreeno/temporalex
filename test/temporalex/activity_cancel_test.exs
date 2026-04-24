defmodule Temporalex.ActivityCancelTest do
  @moduledoc """
  Priority 5 — Activity Cancellation (AC1-AC6) from TESTS_V2.md.

  Activity cancellation flow:

  1. Server sends a `:cancel` activity task variant to the worker.
  2. `Temporalex.Worker.Server.handle_activity_cancel/3` sets the atomic
     cancel flag on the activity's context AND sends `Process.exit(pid,
     :shutdown)` to the task process.
  3. Heartbeating activities can poll `Context.cancelled?/0` (checks the
     atomic) to exit early. Non-heartbeating activities get killed.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Activity.Context

  # --- Test activity ---

  defmodule Acts do
    use Temporalex.Activity

    defactivity polls_cancelled(tag) do
      # Poll the cancel flag. Returns a cancelled-at-N marker if the flag
      # was seen, otherwise :finished. Avoids calling the heartbeat NIF
      # so this activity can be run directly in a unit test.
      Enum.reduce_while(1..100, nil, fn i, _acc ->
        if Context.cancelled?() do
          {:halt, {:cancelled, tag, i}}
        else
          {:cont, nil}
        end
      end) || {:ok, :finished}
    end
  end

  # --- Helpers ---

  # Install a context in the process dict so Context.current/0 / heartbeat/0
  # work during a direct activity test run. Cancel flag is a fresh atomic ref.
  defp with_activity_context(fun) do
    ref = Context.new_cancel_ref()

    ctx = %Context{
      task_token: <<0>>,
      activity_type: "test",
      activity_id: "a",
      attempt: 1,
      worker: nil,
      cancel_ref: ref
    }

    Process.put(:__temporal_activity_context__, ctx)

    try do
      fun.(ref)
    after
      Process.delete(:__temporal_activity_context__)
    end
  end

  # --- Tests ---

  describe "AC1 — cancel sets the atomic flag" do
    test "set_cancelled writes 1 into the atomics ref" do
      ref = Context.new_cancel_ref()

      assert :atomics.get(ref, 1) == 0
      Context.set_cancelled(ref)
      assert :atomics.get(ref, 1) == 1
    end
  end

  describe "AC2 — cancel short-circuits activity body" do
    test "heartbeat short-circuits once cancelled? is true" do
      with_activity_context(fn ref ->
        Context.set_cancelled(ref)
        assert {:cancelled, :activity_cancelled} = Context.heartbeat(:anything)
      end)
    end

    test "polling activity exits on first cancel check" do
      with_activity_context(fn ref ->
        # Cancel arrives before the activity body runs.
        Context.set_cancelled(ref)

        # The activity polls on iteration 1 and sees the cancel.
        assert {:cancelled, :tag1, 1} = Acts.__polls_cancelled__(:tag1)
      end)
    end
  end

  describe "AC3 — non-heartbeating activity killed via Process.exit" do
    # `handle_activity_cancel/3` calls `Process.exit(pid, :shutdown)` to
    # kill activities that don't heartbeat. The mechanism is stdlib; we
    # verify the contract: a task linked via Task.async_nolink exits with
    # the given reason and surfaces as a DOWN message.
    test "Process.exit(pid, :shutdown) causes a monitored process to exit with :shutdown" do
      parent = self()

      # Plain spawn (not linked) so the :shutdown exit doesn't propagate
      # to the test process. This mirrors the production path: activities
      # run under Task.Supervisor.async_nolink.
      pid =
        spawn(fn ->
          receive do
          after
            5_000 -> send(parent, :never)
          end
        end)

      ref = Process.monitor(pid)

      # Mirror Worker.Server.handle_activity_cancel/3 — unconditional kill.
      Process.exit(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 500
    end
  end

  describe "AC4 — activity cancel during retry" do
    # Retry is Core-SDK controlled: after an activity fails, the server
    # schedules a new attempt with a fresh cancel_ref. Cancel between
    # attempts is enforced by the server, which refuses to schedule
    # attempt N+1. From the SDK side, this is transparent — there's nothing
    # user code sees. We sanity-check that each activity context gets a
    # fresh atomic ref (so a previous attempt's cancel doesn't leak).
    test "each activity context gets a distinct cancel_ref atomic" do
      ref1 = Context.new_cancel_ref()
      ref2 = Context.new_cancel_ref()

      refute ref1 == ref2
      Context.set_cancelled(ref1)
      assert :atomics.get(ref2, 1) == 0
    end
  end

  describe "AC5 — cancelled? check without heartbeat" do
    test "cancelled?/0 returns the current flag state without heartbeating" do
      with_activity_context(fn ref ->
        refute Context.cancelled?()

        Context.set_cancelled(ref)
        assert Context.cancelled?()
      end)
    end
  end

  describe "AC6 — cancel race: activity completes before cancel arrives" do
    # If the activity's implementation returns before the server-delivered
    # cancel is applied, no cancellation occurs. The atomic flag exists
    # but is never observed. The activity result is reported normally.
    test "cancel flag set after activity return has no effect on the return value" do
      with_activity_context(fn ref ->
        # Activity body runs to completion without a cancel.
        assert {:ok, :finished} = Acts.__polls_cancelled__(:never)

        # Cancel arriving after: the flag flips but the result is already
        # in hand.
        Context.set_cancelled(ref)
        assert :atomics.get(ref, 1) == 1
      end)
    end
  end
end
