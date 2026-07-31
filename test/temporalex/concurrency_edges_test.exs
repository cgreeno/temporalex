defmodule Temporalex.ConcurrencyEdgesTest do
  @moduledoc """
  Scheduler corner cases. Each test targets a specific concurrency hazard:
  bad orderings would silently produce wrong workflow results, deadlocks,
  or executor crashes that look like "the workflow just hung."
  """

  use ExUnit.Case, async: false

  alias Temporalex.Core.Command
  alias Temporalex.Core.Job
  alias Temporalex.Core.TestHarness
  alias Temporalex.Workflow.API

  defmodule Activities do
    use Temporalex.Activity

    defactivity step(label), timeout: 1_000 do
      {:ok, label}
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Async handler interactions
  # ────────────────────────────────────────────────────────────────────

  defmodule AsyncWithUpdateStateWorkflow do
    @moduledoc """
    Async update handler whose function calls update_state. The update
    reply is the function's return value; update_state mutations must
    land in phase state. If update_state interleaves with anything,
    accumulated state diverges.
    """
    use Temporalex.Workflow

    def run(_) do
      result =
        API.phase(%{events: []},
          update: %{
            "bump" => fn [label], state ->
              {:async,
               fn ->
                 {:ok, _} = Activities.step(label)

                 API.update_state(fn s ->
                   new_state = %{s | events: [label | s.events]}
                   {:applied, new_state}
                 end)
               end, state}
            end
          },
          signal: %{"stop" => fn _args, state -> {:stop, state} end}
        )

      {:ok, result}
    end
  end

  describe "async handler + update_state" do
    test "single async update applies its state mutation atomically" do
      assert {:ok, exec} = TestHarness.start_workflow(AsyncWithUpdateStateWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      # Send the update — it spawns an async handler, immediately yields
      # the accepted response + the ScheduleActivity command from inside
      # the async function.
      assert {:yield, commands} = TestHarness.send_update(exec, "bump", [:a])
      assert Enum.any?(commands, &match?(%Command.RespondToUpdate{response: :accepted}, &1))
      activity_cmd = Enum.find(commands, &match?(%Command.ScheduleActivity{}, &1))
      assert activity_cmd != nil
      seq = activity_cmd.seq

      # Resolve the activity → async runs update_state → reply emitted.
      assert {:yield, completed_commands} =
               TestHarness.resolve(exec, %Job.ActivityResolved{seq: seq, result: {:ok, :a}})

      assert Enum.any?(
               completed_commands,
               &match?(%Command.RespondToUpdate{response: {:completed, :applied}}, &1)
             )

      # Phase state should now contain [:a]. Stop and assert.
      assert {:complete, {:ok, %{events: [:a]}}} =
               TestHarness.send_signal(exec, "stop", [])
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Async handler that raises
  # ────────────────────────────────────────────────────────────────────

  defmodule AsyncRaisesWorkflow do
    @moduledoc """
    Async update handler whose function raises. The acceptance was already
    emitted, so the update is in flight. The crash must turn into a
    structured failure response — NOT crash the executor or the parent
    workflow, NOT leave the phase indefinitely waiting on a dead handler.
    """
    use Temporalex.Workflow

    def run(_) do
      result =
        API.phase(:running,
          update: %{
            "boom" => fn _args, state ->
              {:async,
               fn ->
                 raise %Temporalex.Failure.ApplicationError{
                   message: "async raised",
                   type: "AsyncError",
                   retryable?: false
                 }
               end, state}
            end
          },
          signal: %{"done" => fn _args, state -> {:stop, state} end}
        )

      {:ok, result}
    end
  end

  describe "async update handler crash post-acceptance" do
    test "async handler raise becomes a structured update failure, phase keeps running" do
      assert {:ok, exec} = TestHarness.start_workflow(AsyncRaisesWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      assert {:yield, commands} = TestHarness.send_update(exec, "boom", [])

      # Accepted then immediately a failure response.
      assert Enum.any?(commands, &match?(%Command.RespondToUpdate{response: :accepted}, &1))

      failure_cmd =
        Enum.find(commands, &match?(%Command.RespondToUpdate{response: {:rejected, _}}, &1)) ||
          Enum.find(commands, fn
            %Command.RespondToUpdate{response: {:completed, _}} ->
              false

            %Command.RespondToUpdate{response: r} ->
              match?({:failed, _}, r) or match?({:rejected, _}, r)

            _ ->
              false
          end)

      assert failure_cmd != nil, "expected a failure RespondToUpdate, got: #{inspect(commands)}"

      # Phase still alive — send the done signal, workflow completes normally.
      assert {:complete, {:ok, :running}} = TestHarness.send_signal(exec, "done", [])
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Concurrent parallels at different nesting levels
  # ────────────────────────────────────────────────────────────────────

  defmodule MultiParallelWorkflow do
    use Temporalex.Workflow

    def run(_) do
      # Top-level parallel.
      [outer_a, outer_b] =
        API.parallel([
          fn ->
            [{:ok, x}, {:ok, y}] =
              API.parallel([
                fn -> Activities.step(:inner_a1) end,
                fn -> Activities.step(:inner_a2) end
              ])

            {:branch_a, x, y}
          end,
          fn ->
            {:ok, b} = Activities.step(:outer_b)
            {:branch_b, b}
          end
        ])

      {:ok, {outer_a, outer_b}}
    end
  end

  describe "nested parallel" do
    test "all activities emit in stable order, results assemble correctly" do
      assert {:ok, exec} = TestHarness.start_workflow(MultiParallelWorkflow, nil)

      # Expect 3 ScheduleActivity commands. Inner-A1, Inner-A2, Outer-B
      # in some stable order — branch index 0 sub-branches first, then
      # branch index 1.
      assert {:yield, commands} = TestHarness.next(exec)
      activity_cmds = Enum.filter(commands, &match?(%Command.ScheduleActivity{}, &1))
      assert length(activity_cmds) == 3

      # Thread ids tell us nesting: [{:p, 0}, {:p, 0}], [{:p, 0}, {:p, 1}], [{:p, 1}]
      thread_ids = Enum.map(activity_cmds, & &1.thread_id)
      assert [{:p, 0}, {:p, 0}] in thread_ids
      assert [{:p, 0}, {:p, 1}] in thread_ids
      assert [{:p, 1}] in thread_ids

      # Resolve all three.
      resolutions =
        Enum.map(activity_cmds, fn cmd ->
          [label] = cmd.input
          %Job.ActivityResolved{seq: cmd.seq, result: {:ok, label}}
        end)

      assert {:complete, {:ok, {{:branch_a, :inner_a1, :inner_a2}, {:branch_b, :outer_b}}}} =
               TestHarness.activate(exec, resolutions)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Signal + update in same activation
  # ────────────────────────────────────────────────────────────────────

  defmodule MixedMessagesWorkflow do
    @moduledoc """
    Both a signal and an update arrive in one activation. The phase must
    dispatch them in arrival order — interleaved differently would cause
    different state outcomes on replay.
    """
    use Temporalex.Workflow

    def handle_query("log", _args, state), do: {:reply, state}

    def run(_) do
      result =
        API.phase([],
          signal: %{
            "log_sig" => fn [val], log -> {:noreply, [{:sig, val} | log]} end,
            "done" => fn _args, log -> {:stop, Enum.reverse(log)} end
          },
          update: %{
            "log_upd" => fn [val], log ->
              new_log = [{:upd, val} | log]
              {:reply, :ok, new_log}
            end
          }
        )

      {:ok, result}
    end
  end

  describe "mixed signal/update in single activation" do
    test "signal-then-update in one activation dispatches in arrival order" do
      assert {:ok, exec} = TestHarness.start_workflow(MixedMessagesWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      # Send signal + update + signal + done in one activation.
      assert {:yield, _} =
               TestHarness.activate(exec, [
                 %Job.SignalReceived{name: "log_sig", args: [1]},
                 %Job.UpdateReceived{
                   id: "u1",
                   protocol_instance_id: "p1",
                   name: "log_upd",
                   args: [2],
                   run_validator: true
                 }
               ])

      # Finish.
      assert {:complete, {:ok, log}} =
               TestHarness.send_signal(exec, "done", [])

      # Order in log reflects dispatch order. Signal 1 came first, then
      # update 2. Reversed for output.
      assert log == [{:sig, 1}, {:upd, 2}]
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Phase stop with async handler still running
  # ────────────────────────────────────────────────────────────────────

  defmodule PhaseExitWithPendingAsyncWorkflow do
    @moduledoc """
    Structured concurrency: when a handler returns {:stop, _}, the phase
    must NOT return until in-flight async handlers complete. If we exit
    early, the async handler's update_state would silently lose its
    mutation, or worse leak as an orphan call to a dead executor.
    """
    use Temporalex.Workflow

    def run(_) do
      result =
        API.phase(%{async_done?: false},
          update: %{
            "start_async" => fn _args, state ->
              {:async,
               fn ->
                 {:ok, _} = Activities.step(:async_work)

                 API.update_state(fn s ->
                   {:applied, %{s | async_done?: true}}
                 end)
               end, state}
            end
          },
          signal: %{"stop" => fn _args, state -> {:stop, state} end}
        )

      {:ok, result}
    end
  end

  describe "phase :stop with pending async" do
    test "phase waits for in-flight async to complete before returning" do
      assert {:ok, exec} = TestHarness.start_workflow(PhaseExitWithPendingAsyncWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      # Start the async update — it accepts then parks on the activity.
      assert {:yield, commands} = TestHarness.send_update(exec, "start_async", [])
      activity_cmd = Enum.find(commands, &match?(%Command.ScheduleActivity{}, &1))
      assert activity_cmd != nil
      seq = activity_cmd.seq

      # Stop signal arrives BEFORE the activity resolves. Phase should
      # NOT complete yet — must wait for the async handler.
      assert {:waiting, _} = TestHarness.send_signal(exec, "stop", [])

      # Now resolve the activity. Async runs update_state, completes,
      # phase returns with the mutated state.
      assert {:complete, {:ok, %{async_done?: true}}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: seq,
                 result: {:ok, :async_work}
               })
    end
  end
end
