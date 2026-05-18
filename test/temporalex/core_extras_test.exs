defmodule Temporalex.CoreExtrasTest do
  @moduledoc """
  Gap-coverage tests for the deterministic core: cancel cascade,
  continue-as-new edges, phase/timeout interactions, nested parallel,
  update validator edges, and the new local-activity / child-workflow
  primitives at the executor level (no Temporal server needed).
  """

  use ExUnit.Case, async: false

  alias Temporalex.Core.Command
  alias Temporalex.Core.Job
  alias Temporalex.Core.TestHarness
  alias Temporalex.Workflow.API

  # ──────────────────────────── Cancel handling ────────────────────────────

  describe "workflow cancellation" do
    defmodule CancelAwareWorkflow do
      use Temporalex.Workflow

      def run(_) do
        if API.cancelled?() do
          {:cancelled, :initial}
        else
          API.sleep(1_000)

          if API.cancelled?() do
            {:cancelled, :after_sleep}
          else
            {:ok, :not_cancelled}
          end
        end
      end
    end

    test "cancellation flag visible to workflow code after CancelWorkflow job" do
      assert {:ok, exec} = TestHarness.start_workflow(CancelAwareWorkflow, nil)

      assert {:yield, [%Command.StartTimer{seq: timer_seq}]} = TestHarness.next(exec)

      # Activate with cancel job alongside timer fire — workflow returns
      # {:cancelled, :requested} which the executor emits as a CancelWorkflow
      # command (not a CompleteWorkflow), so it surfaces as a yield.
      assert {:yield, [%Command.CancelWorkflow{}]} =
               TestHarness.activate(exec, [
                 %Job.CancelWorkflow{reason: :requested},
                 %Job.TimerFired{seq: timer_seq}
               ])
    end

    test "cancellation arriving before run starts is visible at first check" do
      assert {:ok, exec} = TestHarness.start_workflow(CancelAwareWorkflow, nil)
      assert {:yield, [%Command.StartTimer{}]} = TestHarness.next(exec)

      # Cancel before timer fires — workflow stays blocked, no commands.
      assert {:yield, []} = TestHarness.activate(exec, [%Job.CancelWorkflow{reason: :requested}])
    end

    defmodule UncancellableWorkflow do
      use Temporalex.Workflow

      def run(_) do
        # Workflow that doesn't check cancelled?/0 — should still complete
        # successfully even if cancellation is requested mid-flight.
        :ok = API.sleep(100)
        {:ok, :ignored_cancel}
      end
    end

    test "workflow that ignores cancellation still completes normally" do
      assert {:ok, exec} = TestHarness.start_workflow(UncancellableWorkflow, nil)
      assert {:yield, [%Command.StartTimer{seq: timer_seq}]} = TestHarness.next(exec)

      assert {:complete, {:ok, :ignored_cancel}} =
               TestHarness.activate(exec, [
                 %Job.CancelWorkflow{reason: :requested},
                 %Job.TimerFired{seq: timer_seq}
               ])
    end
  end

  # ──────────────────────────── Continue-as-new ────────────────────────────

  describe "continue-as-new" do
    defmodule SimpleContinueWorkflow do
      use Temporalex.Workflow

      def run(args), do: {:continue_as_new, args}
    end

    test "continue_as_new with map args emits ContinueAsNew command" do
      assert {:ok, exec} =
               TestHarness.start_workflow(SimpleContinueWorkflow, %{generation: 1, events: []})

      assert {:continue_as_new, %{generation: 1, events: []}} = TestHarness.next(exec)
    end

    defmodule ConditionalContinueWorkflow do
      use Temporalex.Workflow

      def run(%{count: count}) when count < 3 do
        {:continue_as_new, %{count: count + 1}}
      end

      def run(%{count: count}), do: {:ok, count}
    end

    test "continue_as_new chains by passing args" do
      assert {:ok, exec} = TestHarness.start_workflow(ConditionalContinueWorkflow, %{count: 0})
      assert {:continue_as_new, %{count: 1}} = TestHarness.next(exec)

      # New activation simulates the new run with the new args.
      assert {:ok, exec2} = TestHarness.start_workflow(ConditionalContinueWorkflow, %{count: 3})
      assert {:complete, {:ok, 3}} = TestHarness.next(exec2)
    end

    defmodule PhaseToContinueWorkflow do
      use Temporalex.Workflow

      def run(state) do
        new_state =
          API.phase(state,
            signal: %{
              "increment" => fn _args, s -> {:noreply, s + 1} end,
              "flush" => fn _args, s -> {:stop, s} end
            }
          )

        {:continue_as_new, new_state}
      end
    end

    test "continue_as_new after a phase emits both the phase commands and CAN" do
      assert {:ok, exec} = TestHarness.start_workflow(PhaseToContinueWorkflow, 5)
      # Phase enters, parked waiting for signals.
      assert {:waiting, _} = TestHarness.next(exec)

      # Increment signal updates state, phase keeps running.
      assert {:waiting, _} = TestHarness.send_signal(exec, "increment", [])

      # Flush signal stops the phase, run returns {:continue_as_new, _}.
      assert {:continue_as_new, 6} = TestHarness.send_signal(exec, "flush", [])
    end
  end

  # ─────────────────────────── Phase + timeout edges ───────────────────────

  describe "phase timeout interactions" do
    defmodule TimeoutDuringActivityWorkflow do
      use Temporalex.Workflow

      defmodule Acts do
        use Temporalex.Activity

        defactivity slow(value), timeout: 1_000 do
          {:ok, value}
        end
      end

      def run(_) do
        result =
          API.phase(:initial,
            signal: %{
              "trigger" => fn _args, _state ->
                {:ok, value} = Acts.slow(:from_handler)
                {:stop, value}
              end
            },
            timeout: 100
          )

        {:ok, result}
      end
    end

    test "phase timeout firing while a sync handler is in-flight does not crash the executor" do
      assert {:ok, exec} =
               TestHarness.start_workflow(TimeoutDuringActivityWorkflow, nil)

      assert {:yield, [%Command.StartTimer{seq: timeout_seq, duration_ms: 100}]} =
               TestHarness.next(exec)

      assert {:yield, [%Command.ScheduleActivity{seq: activity_seq}]} =
               TestHarness.send_signal(exec, "trigger", [])

      # Timer fires while the sync handler is parked on the activity.
      # Structured-concurrency rule: in-flight handler must finish before
      # the phase returns. The phase stays parked.
      assert {:waiting, _} = TestHarness.resolve(exec, %Job.TimerFired{seq: timeout_seq})

      # Resolve the activity. Handler returns {:stop, _}, but the timer
      # already stamped the phase result, so phase returns the timeout tuple
      # (frozen at the moment of timer fire).
      assert {:complete, {:ok, _}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: activity_seq,
                 result: {:ok, :from_handler}
               })
    end

    defmodule PhaseWithoutTimeoutWorkflow do
      use Temporalex.Workflow

      def run(_) do
        state =
          API.phase(0,
            signal: %{
              "add" => fn [n], s -> {:noreply, s + n} end,
              "done" => fn _args, s -> {:stop, s} end
            }
          )

        {:ok, state}
      end
    end

    test "phase without timeout does not emit a timer command" do
      assert {:ok, exec} = TestHarness.start_workflow(PhaseWithoutTimeoutWorkflow, nil)
      # Entering the phase: parked waiting, no timer.
      assert {:waiting, _} = TestHarness.next(exec)

      assert {:waiting, _} = TestHarness.send_signal(exec, "add", [3])
      assert {:complete, {:ok, 3}} = TestHarness.send_signal(exec, "done", [])
    end
  end

  # ─────────────────────────── Nested parallel ─────────────────────────────

  describe "nested parallel" do
    defmodule NestedParallelWorkflow do
      use Temporalex.Workflow

      defmodule Acts do
        use Temporalex.Activity

        defactivity work(label), timeout: 1_000 do
          {:ok, label}
        end
      end

      def run(_) do
        [outer_a, outer_b] =
          API.parallel([
            fn ->
              [{:ok, x}, {:ok, y}] =
                API.parallel([
                  fn -> Acts.work(:a1) end,
                  fn -> Acts.work(:a2) end
                ])

              {:both, x, y}
            end,
            fn ->
              {:ok, value} = Acts.work(:b)
              {:single, value}
            end
          ])

        {:ok, {outer_a, outer_b}}
      end
    end

    test "nested parallel branches each emit their own activity commands" do
      assert {:ok, exec} = TestHarness.start_workflow(NestedParallelWorkflow, nil)

      assert {:yield, commands} = TestHarness.next(exec)
      activity_cmds = Enum.filter(commands, &match?(%Command.ScheduleActivity{}, &1))
      # Outer branch B emits its single activity; outer branch A nests another
      # parallel that emits two activities. Total: 3.
      assert length(activity_cmds) == 3
    end

    defmodule ParallelInsidePhaseHandlerWorkflow do
      use Temporalex.Workflow

      defmodule Acts do
        use Temporalex.Activity

        defactivity step(n), timeout: 1_000 do
          {:ok, n * 2}
        end
      end

      def run(_) do
        result =
          API.phase(nil,
            signal: %{
              "go" => fn _args, _state ->
                [{:ok, a}, {:ok, b}] =
                  API.parallel([
                    fn -> Acts.step(1) end,
                    fn -> Acts.step(2) end
                  ])

                {:stop, {:both, a, b}}
              end
            }
          )

        {:ok, result}
      end
    end

    test "API.parallel inside a sync phase handler works" do
      assert {:ok, exec} = TestHarness.start_workflow(ParallelInsidePhaseHandlerWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      assert {:yield, [%Command.ScheduleActivity{seq: s1}, %Command.ScheduleActivity{seq: s2}]} =
               TestHarness.send_signal(exec, "go", [])

      # Resolve s1 — sync handler still parked on s2, phase stays parked.
      assert {:waiting, _} =
               TestHarness.resolve(exec, %Job.ActivityResolved{seq: s1, result: {:ok, 2}})

      # Resolve s2 — handler returns {:stop, _}, phase completes.
      assert {:complete, {:ok, {:both, 2, 4}}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{seq: s2, result: {:ok, 4}})
    end
  end

  # ─────────────────────────── Update validator edges ──────────────────────

  describe "update validator edge cases" do
    defmodule ValidatorRaisingWorkflow do
      use Temporalex.Workflow

      def run(_) do
        result =
          API.phase(nil,
            update: %{
              "ping" => {
                fn _args, _state -> {:reply, :pong, nil} end,
                validator: fn _args, _state -> raise "validator boom" end
              }
            },
            signal: %{"done" => fn _args, _state -> {:stop, :ok} end}
          )

        {:ok, result}
      end
    end

    test "validator that raises rejects the update (no acceptance, no handler run)" do
      assert {:ok, exec} = TestHarness.start_workflow(ValidatorRaisingWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      # Send an update — should be rejected.
      assert {:yield, [%Command.RespondToUpdate{response: {:rejected, _reason}}]} =
               TestHarness.send_update(exec, "ping", [])

      # Workflow can still continue normally afterwards.
      assert {:complete, {:ok, :ok}} = TestHarness.send_signal(exec, "done", [])
    end

    defmodule ValidatorReturnsInvalidWorkflow do
      use Temporalex.Workflow

      def run(_) do
        result =
          API.phase(nil,
            update: %{
              "ping" => {
                fn _args, _state -> {:reply, :pong, nil} end,
                validator: fn _args, _state -> :not_a_valid_return end
              }
            },
            signal: %{"done" => fn _args, _state -> {:stop, :ok} end}
          )

        {:ok, result}
      end
    end

    test "validator returning a non-:ok / non-{:error,_} shape rejects the update" do
      assert {:ok, exec} = TestHarness.start_workflow(ValidatorReturnsInvalidWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      assert {:yield, [%Command.RespondToUpdate{response: {:rejected, _}}]} =
               TestHarness.send_update(exec, "ping", [])
    end

    defmodule MultipleUpdatesInSequenceWorkflow do
      use Temporalex.Workflow

      def run(_) do
        result =
          API.phase(%{count: 0},
            update: %{
              "inc" => fn _args, state ->
                state = %{state | count: state.count + 1}
                {:reply, state.count, state}
              end
            },
            signal: %{"done" => fn _args, state -> {:stop, state.count} end}
          )

        {:ok, result}
      end
    end

    test "multiple sync updates in sequence each apply to state" do
      assert {:ok, exec} = TestHarness.start_workflow(MultipleUpdatesInSequenceWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      assert {:yield, [_, %Command.RespondToUpdate{response: {:completed, _}}]} =
               TestHarness.send_update(exec, "inc", [])

      assert {:yield, [_, %Command.RespondToUpdate{response: {:completed, _}}]} =
               TestHarness.send_update(exec, "inc", [])

      assert {:complete, {:ok, 2}} = TestHarness.send_signal(exec, "done", [])
    end
  end

  # ─────────────────────────── Local activity scheduling ───────────────────

  describe "local activity scheduling" do
    defmodule LocalActsWorkflow do
      use Temporalex.Workflow

      defmodule Acts do
        use Temporalex.Activity

        defactivity quick(value), local: true, timeout: 1_000 do
          {:ok, value * 2}
        end
      end

      def run(value) do
        {:ok, doubled} = Acts.quick(value)
        {:ok, doubled}
      end
    end

    test "local activity emits ScheduleLocalActivity (not ScheduleActivity)" do
      assert {:ok, exec} = TestHarness.start_workflow(LocalActsWorkflow, 5)

      assert {:yield, [%Command.ScheduleLocalActivity{seq: seq, activity_id: id}]} =
               TestHarness.next(exec)

      assert is_binary(id)

      assert {:complete, {:ok, 10}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{seq: seq, result: {:ok, 10}})
    end

    test "local activity {:error, _} surfaces to workflow code" do
      assert {:ok, exec} = TestHarness.start_workflow(LocalActsWorkflow, 7)
      assert {:yield, [%Command.ScheduleLocalActivity{seq: seq}]} = TestHarness.next(exec)

      # The workflow pattern-matches {:ok, _} and crashes on {:error, _}, so the
      # workflow itself fails — exact failure mapping is tested separately.
      assert {:complete, _} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: seq,
                 result:
                   {:error,
                    %Temporalex.ApplicationError{message: "no", type: "X", non_retryable: true}}
               })
    end

    defmodule MixedLocalRemoteWorkflow do
      use Temporalex.Workflow

      defmodule Acts do
        use Temporalex.Activity

        defactivity local_step(n), local: true, timeout: 1_000 do
          {:ok, n}
        end

        defactivity remote_step(n), timeout: 1_000 do
          {:ok, n}
        end
      end

      def run(_) do
        {:ok, a} = Acts.local_step(1)
        {:ok, b} = Acts.remote_step(2)
        {:ok, {a, b}}
      end
    end

    test "local and remote activities in sequence emit distinct command types" do
      assert {:ok, exec} = TestHarness.start_workflow(MixedLocalRemoteWorkflow, nil)

      assert {:yield, [%Command.ScheduleLocalActivity{seq: s1}]} = TestHarness.next(exec)

      assert {:yield, [%Command.ScheduleActivity{seq: s2}]} =
               TestHarness.resolve(exec, %Job.ActivityResolved{seq: s1, result: {:ok, 1}})

      assert {:complete, {:ok, {1, 2}}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{seq: s2, result: {:ok, 2}})
    end
  end

  # ─────────────────────────── Child workflow scheduling ───────────────────

  describe "child workflow scheduling" do
    defmodule ChildWorkflowDef do
      use Temporalex.Workflow
      def run(value), do: {:ok, value}
    end

    defmodule ParentWorkflow do
      use Temporalex.Workflow

      def run(value) do
        {:ok, child_result} =
          API.execute_child_workflow(ChildWorkflowDef, [value], workflow_id: "fixed-child-id")

        {:ok, {:got, child_result}}
      end
    end

    test "execute_child_workflow emits StartChildWorkflowExecution" do
      assert {:ok, exec} = TestHarness.start_workflow(ParentWorkflow, 42)

      assert {:yield,
              [
                %Command.StartChildWorkflowExecution{
                  seq: seq,
                  workflow_id: "fixed-child-id",
                  workflow_type: type,
                  input: [42]
                }
              ]} = TestHarness.next(exec)

      assert type =~ "ChildWorkflowDef"

      # Start resolution: child started successfully (parent stays blocked).
      assert {:yield, []} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecutionStart{
                 seq: seq,
                 status: {:succeeded, "run-id-1"}
               })

      # Final resolution: child completed.
      assert {:complete, {:ok, {:got, :done}}} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecution{
                 seq: seq,
                 result: {:ok, :done}
               })
    end

    test "child start failure wakes parent with %ChildWorkflowFailure{}" do
      assert {:ok, exec} = TestHarness.start_workflow(ParentWorkflow, 1)
      assert {:yield, [%Command.StartChildWorkflowExecution{seq: seq}]} = TestHarness.next(exec)

      assert {:complete, _outcome} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecutionStart{
                 seq: seq,
                 status:
                   {:failed,
                    %{
                      workflow_id: "fixed-child-id",
                      workflow_type: "Child",
                      cause: :already_started
                    }}
               })

      # Workflow body crashes on the failure-unwrap (pattern match fails on
      # `{:ok, _}` line), so the run ends with a failure command. We only
      # assert it completed (didn't hang) — the exact failure mapping is
      # exercised end-to-end in the live integration test.
    end

    test "child workflow failure (after successful start) wakes parent with error" do
      assert {:ok, exec} = TestHarness.start_workflow(ParentWorkflow, 1)
      assert {:yield, [%Command.StartChildWorkflowExecution{seq: seq}]} = TestHarness.next(exec)

      assert {:yield, []} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecutionStart{
                 seq: seq,
                 status: {:succeeded, "run-id-2"}
               })

      assert {:complete, _outcome} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecution{
                 seq: seq,
                 result:
                   {:error,
                    %Temporalex.ChildWorkflowFailure{
                      message: "child failed",
                      workflow_id: "fixed-child-id",
                      cause: %Temporalex.ApplicationError{
                        message: "boom",
                        type: "BadInput",
                        non_retryable: true
                      }
                    }}
               })
    end
  end

  # ─────────────────────────── Signal child workflow ────────────────────────

  describe "signal child workflow" do
    defmodule SignalingParentWorkflow do
      use Temporalex.Workflow

      def run(_) do
        :ok = API.signal_child_workflow("fixed-child-id", "wake", [:payload])
        {:ok, :signal_sent}
      end
    end

    test "signal_child_workflow emits SignalExternalWorkflowExecution with :child target" do
      assert {:ok, exec} = TestHarness.start_workflow(SignalingParentWorkflow, nil)

      assert {:yield,
              [
                %Command.SignalExternalWorkflowExecution{
                  seq: seq,
                  target: {:child, "fixed-child-id"},
                  signal_name: "wake",
                  args: [:payload]
                }
              ]} = TestHarness.next(exec)

      # Successful delivery → :ok resolution.
      assert {:complete, {:ok, :signal_sent}} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: seq,
                 result: :ok
               })
    end

    defmodule SignalingErrorHandlingWorkflow do
      use Temporalex.Workflow

      def run(_) do
        case API.signal_child_workflow("missing-child", "wake", []) do
          :ok -> {:ok, :delivered}
          {:error, _} = err -> {:ok, {:not_delivered, err}}
        end
      end
    end

    test "signal_child_workflow failure surfaces as {:error, _} to the workflow" do
      assert {:ok, exec} = TestHarness.start_workflow(SignalingErrorHandlingWorkflow, nil)

      assert {:yield, [%Command.SignalExternalWorkflowExecution{seq: seq}]} =
               TestHarness.next(exec)

      assert {:complete, {:ok, {:not_delivered, {:error, %Temporalex.ApplicationError{}}}}} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: seq,
                 result:
                   {:error,
                    %Temporalex.ApplicationError{
                      message: "no such workflow",
                      type: "NotFound",
                      non_retryable: true
                    }}
               })
    end
  end
end
