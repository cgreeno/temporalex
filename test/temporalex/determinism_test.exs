defmodule Temporalex.DeterminismTest do
  @moduledoc """
  Replay correctness — the load-bearing invariant of the entire SDK.

  These tests pin behaviors that, if broken, would cause workflows to
  silently produce different results between original execution and
  replay (corrupting state) or to fail nondeterminism mismatches that
  the user can't reason about.

  Most use the record→replay pattern: run the workflow once with a
  resolver, capture the full activation transcript, then replay and
  assert the executor's emitted commands match exactly.
  """

  use ExUnit.Case, async: false

  alias Temporalex.Core.Command
  alias Temporalex.Core.Job
  alias Temporalex.Core.Nondeterminism
  alias Temporalex.Core.TestHarness
  alias Temporalex.Workflow.API

  defmodule Activities do
    use Temporalex.Activity

    defactivity work(label), timeout: 1_000 do
      {:ok, {:done, label}}
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Patch-controlled branching
  # ────────────────────────────────────────────────────────────────────

  defmodule PatchedWorkflow do
    @moduledoc """
    A workflow that has two code paths gated on a patch. The bug class:
    if we incorrectly tell `patched?/1` that the patch is set on replay
    when history says otherwise (or vice versa), the workflow takes the
    wrong branch and emits commands history doesn't contain → silent
    corruption, then nondeterminism crash on the next activation.
    """
    use Temporalex.Workflow

    def run(_) do
      if API.patched?("use-new") do
        {:ok, _} = Activities.work(:new_path)
        {:ok, :new_path}
      else
        {:ok, _} = Activities.work(:old_path)
        {:ok, :old_path}
      end
    end
  end

  describe "patches" do
    test "patched?/1 returns true on first execution and emits SetPatchMarker" do
      assert {:ok, exec} = TestHarness.start_workflow(PatchedWorkflow, nil)

      assert {:yield,
              [
                %Command.SetPatchMarker{id: "use-new"},
                %Command.ScheduleActivity{type: type, input: [:new_path]}
              ]} = TestHarness.next(exec)

      assert type =~ "work"
    end

    test "patched?/1 returns false on replay if no patch marker recorded" do
      # Simulate the workflow being run BEFORE the patch was introduced.
      # History contains no SetPatchMarker, no NotifyHasPatch — so the
      # patched? call must return false, taking the old path.
      assert {:ok, exec} = TestHarness.start_workflow(PatchedWorkflow, nil)

      assert {:yield,
              [
                %Command.ScheduleActivity{type: type, input: [:old_path]}
              ]} =
               TestHarness.next(exec,
                 replay: true,
                 expected_commands: [
                   %Command.ScheduleActivity{
                     seq: 0,
                     thread_id: [],
                     activity_id: "activity-0",
                     type: "#{inspect(Activities)}.work",
                     input: [:old_path],
                     task_queue: nil,
                     headers: %{},
                     schedule_to_close_timeout_ms: 1_000,
                     schedule_to_start_timeout_ms: nil,
                     start_to_close_timeout_ms: 1_000,
                     heartbeat_timeout_ms: nil,
                     retry_policy: nil,
                     cancellation_type: :wait_cancellation_completed,
                     do_not_eagerly_execute: false
                   }
                 ]
               )

      assert type =~ "work"
    end

    test "patched?/1 returns true on replay if NotifyHasPatch arrived" do
      # Different scenario: patch was set on this run. NotifyHasPatch job
      # tells the executor the patch is already in history; patched? should
      # return true, taking the new path.
      assert {:ok, exec} = TestHarness.start_workflow(PatchedWorkflow, nil)

      type = "#{inspect(Activities)}.work"

      completion =
        TestHarness.activate_raw(
          exec,
          [
            %Job.NotifyPatch{id: "use-new"},
            %Job.InitializeWorkflow{
              workflow_type: inspect(PatchedWorkflow),
              workflow_id: "wf-notify",
              arguments: [nil],
              workflow_info: %{},
              randomness_seed: 0
            }
          ],
          replay: true
        )

      assert {:ok, commands} = completion.status
      activity_cmd = Enum.find(commands, &match?(%Command.ScheduleActivity{}, &1))
      assert activity_cmd.type == type
      assert activity_cmd.input == [:new_path]
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Deterministic random / uuid
  # ────────────────────────────────────────────────────────────────────

  defmodule RandomWorkflow do
    use Temporalex.Workflow

    def run(_) do
      a = API.random()
      u = API.uuid4()
      b = API.random()

      # Use the values in deterministic commands so replay mismatch would
      # surface cleanly. Activity input carries the random values.
      {:ok, _} = Activities.work({:vals, a, u, b})
      {:ok, {a, u, b}}
    end
  end

  describe "deterministic random and uuid" do
    test "random and uuid produce the same values on replay (same seed)" do
      assert {:ok, exec} = TestHarness.start_workflow(RandomWorkflow, nil)

      assert {:yield, [%Command.ScheduleActivity{seq: 0, input: [first_input]}]} =
               TestHarness.next(exec)

      # Replay the same activation. Random and UUID must derive deterministically
      # from the replayed seed and produce the same activity input.
      assert {:ok, exec2} = TestHarness.start_workflow(RandomWorkflow, nil)

      assert {:yield, [%Command.ScheduleActivity{seq: 0, input: [second_input]}]} =
               TestHarness.next(exec2)

      assert first_input == second_input,
             "random/uuid drifted between runs with same seed (first: #{inspect(first_input)}, second: #{inspect(second_input)})"
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Activity result ordering in parallel branches
  # ────────────────────────────────────────────────────────────────────

  defmodule ParallelOrderingWorkflow do
    @moduledoc """
    Two parallel branches each call an activity, then the workflow uses the
    results in order. If the executor's parallel scheduling were timing-
    dependent (the v0.2.0 bug), the order of activity commands could vary
    between original execution and replay → nondeterminism crash.
    """
    use Temporalex.Workflow

    def run(_) do
      [{:ok, a}, {:ok, b}] =
        API.parallel([
          fn -> Activities.work(:left) end,
          fn -> Activities.work(:right) end
        ])

      {:ok, {a, b}}
    end
  end

  describe "parallel branch command order" do
    test "branches emit commands in input order (left then right), consistently across runs" do
      # Run 1
      assert {:ok, exec1} = TestHarness.start_workflow(ParallelOrderingWorkflow, nil)

      assert {:yield,
              [
                %Command.ScheduleActivity{seq: 0, thread_id: [{:p, 0}], input: [:left]},
                %Command.ScheduleActivity{seq: 1, thread_id: [{:p, 1}], input: [:right]}
              ]} = TestHarness.next(exec1)

      # Run 2 (separate executor instance)
      assert {:ok, exec2} = TestHarness.start_workflow(ParallelOrderingWorkflow, nil)

      assert {:yield,
              [
                %Command.ScheduleActivity{seq: 0, thread_id: [{:p, 0}], input: [:left]},
                %Command.ScheduleActivity{seq: 1, thread_id: [{:p, 1}], input: [:right]}
              ]} = TestHarness.next(exec2)
    end

    test "swapping branch order in replay history triggers nondeterminism" do
      # If history says branch-1 first but the workflow emits branch-0
      # first, replay must detect the mismatch — this is the protection
      # against silent data corruption.
      type = "#{inspect(Activities)}.work"

      wrong_history = [
        %Command.ScheduleActivity{
          seq: 0,
          thread_id: [{:p, 1}],
          activity_id: "activity-0",
          type: type,
          input: [:right],
          task_queue: nil,
          headers: %{},
          schedule_to_close_timeout_ms: 1_000,
          schedule_to_start_timeout_ms: nil,
          start_to_close_timeout_ms: 1_000,
          heartbeat_timeout_ms: nil,
          retry_policy: nil,
          cancellation_type: :wait_cancellation_completed,
          do_not_eagerly_execute: false
        },
        %Command.ScheduleActivity{
          seq: 1,
          thread_id: [{:p, 0}],
          activity_id: "activity-1",
          type: type,
          input: [:left],
          task_queue: nil,
          headers: %{},
          schedule_to_close_timeout_ms: 1_000,
          schedule_to_start_timeout_ms: nil,
          start_to_close_timeout_ms: 1_000,
          heartbeat_timeout_ms: nil,
          retry_policy: nil,
          cancellation_type: :wait_cancellation_completed,
          do_not_eagerly_execute: false
        }
      ]

      assert {:ok, exec} = TestHarness.start_workflow(ParallelOrderingWorkflow, nil)

      assert {:failed, %Nondeterminism{}} =
               TestHarness.next(exec, replay: true, expected_commands: wrong_history)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Phase handler dispatch ordering on replay
  # ────────────────────────────────────────────────────────────────────

  defmodule PhaseOrderWorkflow do
    @moduledoc """
    Phase dispatches handlers in activation arrival order. If two signals
    arrive in one activation, their handlers must run in that exact
    arrival order on every replay — otherwise state mutations land in
    different orders and the final result diverges.
    """
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase([],
          signal: %{
            "append" => fn [value], list -> {:noreply, [value | list]} end,
            "stop" => fn _args, list -> {:stop, list} end
          }
        )

      {:ok, state}
    end
  end

  describe "phase signal dispatch order on replay" do
    test "two signals in one activation are dispatched in arrival order" do
      assert {:ok, exec} = TestHarness.start_workflow(PhaseOrderWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      # Send two appends in a single activation, then stop.
      assert {:complete, {:ok, [:b, :a]}} =
               TestHarness.activate(exec, [
                 %Job.SignalReceived{name: "append", args: [:a]},
                 %Job.SignalReceived{name: "append", args: [:b]},
                 %Job.SignalReceived{name: "stop", args: []}
               ])

      # Result is [:b, :a] because each append prepends — proves the
      # dispatch saw :a before :b.
    end

    test "different in-activation signal order produces different final state" do
      assert {:ok, exec} = TestHarness.start_workflow(PhaseOrderWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      # Swap order — final state must reflect this.
      assert {:complete, {:ok, [:a, :b]}} =
               TestHarness.activate(exec, [
                 %Job.SignalReceived{name: "append", args: [:b]},
                 %Job.SignalReceived{name: "append", args: [:a]},
                 %Job.SignalReceived{name: "stop", args: []}
               ])
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Eviction-only activation safety
  # ────────────────────────────────────────────────────────────────────

  defmodule SimpleActivityWorkflow do
    use Temporalex.Workflow

    def run(_) do
      {:ok, _} = Activities.work(:gate)
      {:ok, :done}
    end
  end

  describe "eviction-only activation" do
    test "eviction does not emit workflow commands or fire activity scheduling" do
      assert {:ok, exec} = TestHarness.start_workflow(SimpleActivityWorkflow, nil)
      assert {:yield, [%Command.ScheduleActivity{}]} = TestHarness.next(exec)

      # Eviction-only activation: workflow is removed from cache. Executor
      # must NOT emit any commands and must not re-run workflow code.
      assert {:yield, []} =
               TestHarness.resolve(exec, %Job.RemoveFromCache{reason: :cache_full, message: "."})

      # State reflects evicted? = true.
      state = Temporalex.Core.Executor.inspect_state(exec.pid)
      assert state.evicted? == true
      # Threads are torn down — the runner's process is gone or done.
      Enum.each(state.threads, fn {_id, thread} ->
        refute thread.status == :running,
               "thread #{inspect(thread.id)} still running after eviction"
      end)
    end
  end
end
