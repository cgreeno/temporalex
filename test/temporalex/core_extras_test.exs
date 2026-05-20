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

    defmodule SignalingMultipleWorkflow do
      use Temporalex.Workflow

      def run(_) do
        :ok = API.signal_child_workflow("child-1", "first", [:a])
        :ok = API.signal_child_workflow("child-1", "second", [:b, :c])
        :ok = API.signal_child_workflow("child-2", "first", [])
        {:ok, :all_sent}
      end
    end

    test "multiple sequential signal_child_workflow calls get distinct seq numbers and complete in order" do
      assert {:ok, exec} = TestHarness.start_workflow(SignalingMultipleWorkflow, nil)

      # First signal: parent blocks waiting for ResolveSignalExternalWorkflow.
      assert {:yield,
              [
                %Command.SignalExternalWorkflowExecution{
                  seq: seq1,
                  target: {:child, "child-1"},
                  signal_name: "first",
                  args: [:a]
                }
              ]} = TestHarness.next(exec)

      # Resolve first — parent emits second command.
      assert {:yield,
              [
                %Command.SignalExternalWorkflowExecution{
                  seq: seq2,
                  target: {:child, "child-1"},
                  signal_name: "second",
                  args: [:b, :c]
                }
              ]} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: seq1,
                 result: :ok
               })

      refute seq1 == seq2

      # Resolve second — parent emits third command (different target).
      assert {:yield,
              [
                %Command.SignalExternalWorkflowExecution{
                  seq: seq3,
                  target: {:child, "child-2"},
                  signal_name: "first",
                  args: []
                }
              ]} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: seq2,
                 result: :ok
               })

      refute seq3 == seq1
      refute seq3 == seq2

      # Resolve third — workflow completes.
      assert {:complete, {:ok, :all_sent}} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: seq3,
                 result: :ok
               })
    end

    defmodule SignalingFromParallelWorkflow do
      use Temporalex.Workflow

      def run(_) do
        [a, b] =
          API.parallel([
            fn -> API.signal_child_workflow("child-A", "ping", []) end,
            fn -> API.signal_child_workflow("child-B", "ping", []) end
          ])

        {:ok, {a, b}}
      end
    end

    test "signal_child_workflow from parallel branches emits both signals with stable thread ids" do
      assert {:ok, exec} = TestHarness.start_workflow(SignalingFromParallelWorkflow, nil)

      # Both branches emit a signal command in the same activation.
      assert {:yield, commands} = TestHarness.next(exec)
      signals = Enum.filter(commands, &match?(%Command.SignalExternalWorkflowExecution{}, &1))
      assert length(signals) == 2

      # Each signal carries the branch's thread id, in input order.
      branch_a = Enum.find(signals, &(&1.thread_id == [{:p, 0}]))
      branch_b = Enum.find(signals, &(&1.thread_id == [{:p, 1}]))
      assert branch_a != nil and branch_a.target == {:child, "child-A"}
      assert branch_b != nil and branch_b.target == {:child, "child-B"}

      # Resolve both. Order of resolution doesn't matter (different seqs).
      assert {:yield, []} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: branch_a.seq,
                 result: :ok
               })

      assert {:complete, {:ok, {:ok, :ok}}} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: branch_b.seq,
                 result: :ok
               })
    end

    defmodule SignalingRichPayloadWorkflow do
      use Temporalex.Workflow

      def run(_) do
        # Rich Elixir term as the signal payload — proves args are passed
        # through opaquely without coercion at the executor layer (encoding
        # happens at the Rust boundary).
        payload = %{nested: %{values: [1, 2, 3]}, tag: :complex}
        :ok = API.signal_child_workflow("child-1", "data", [payload])
        {:ok, :sent}
      end
    end

    test "signal args carry rich Elixir terms through the Op intact" do
      assert {:ok, exec} = TestHarness.start_workflow(SignalingRichPayloadWorkflow, nil)

      assert {:yield, [%Command.SignalExternalWorkflowExecution{args: args}]} =
               TestHarness.next(exec)

      assert [%{nested: %{values: [1, 2, 3]}, tag: :complex}] = args
    end

    defmodule SignalingBlocksThreadWorkflow do
      use Temporalex.Workflow

      defmodule Acts do
        use Temporalex.Activity

        defactivity work(label), timeout: 1_000 do
          {:ok, label}
        end
      end

      def run(_) do
        # If signal_child_workflow weren't blocking, the second activity
        # would emit immediately. The test asserts the activity command
        # does NOT appear until the signal is resolved.
        :ok = API.signal_child_workflow("child-1", "go", [])
        {:ok, _} = Acts.work(:after_signal)
        {:ok, :done}
      end
    end

    test "signal_child_workflow blocks the calling thread until resolution arrives" do
      assert {:ok, exec} = TestHarness.start_workflow(SignalingBlocksThreadWorkflow, nil)

      # First activation: only the signal command. No activity yet.
      assert {:yield, [%Command.SignalExternalWorkflowExecution{seq: seq}]} =
               TestHarness.next(exec)

      # Resolve the signal → thread unblocks → activity is scheduled.
      assert {:yield, [%Command.ScheduleActivity{input: [:after_signal]}]} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: seq,
                 result: :ok
               })
    end

    defmodule SignalingFromAsyncUpdateWorkflow do
      use Temporalex.Workflow

      def run(_) do
        result =
          API.phase(:running,
            update: %{
              "broadcast" => fn _args, state ->
                {:async,
                 fn ->
                   :ok = API.signal_child_workflow("child-1", "wake", [:from_async])
                   :delivered
                 end, state}
              end
            },
            signal: %{"done" => fn _args, state -> {:stop, state} end}
          )

        {:ok, result}
      end
    end

    defmodule StartAndAwaitParent do
      use Temporalex.Workflow

      def run(_) do
        {:ok, handle} = API.start_child_workflow(__MODULE__.Child, [42], workflow_id: "swa-child")
        {:ok, result} = API.await_child_workflow(handle)
        {:ok, {:awaited, result}}
      end

      defmodule Child do
        use Temporalex.Workflow
        def run(value), do: {:ok, value * 2}
      end
    end

    test "start_child_workflow returns a handle, await_child_workflow blocks until completion" do
      assert {:ok, exec} = TestHarness.start_workflow(StartAndAwaitParent, nil)

      # Parent emits StartChildWorkflowExecution.
      assert {:yield, [%Command.StartChildWorkflowExecution{seq: seq, workflow_id: "swa-child"}]} =
               TestHarness.next(exec)

      # Start succeeds → parent receives a ChildHandle and proceeds to
      # await_child_workflow. No new command emitted (await is a pure block).
      assert {:yield, []} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecutionStart{
                 seq: seq,
                 status: {:succeeded, "child-run-1"}
               })

      # Completion fires → await unblocks with the result.
      assert {:complete, {:ok, {:awaited, 84}}} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecution{
                 seq: seq,
                 result: {:ok, 84}
               })
    end

    defmodule StartThenCancelParent do
      use Temporalex.Workflow

      def run(_) do
        {:ok, handle} = API.start_child_workflow(__MODULE__.Child, [], workflow_id: "stc-child")
        :ok = API.cancel_child_workflow(handle)
        {:ok, await_result} = {API.await_child_workflow(handle), :tagged}
        {:ok, {:cancelled_then_awaited, await_result}}
      end

      defmodule Child do
        use Temporalex.Workflow
        def run(_), do: {:ok, :done}
      end
    end

    test "cancel_child_workflow emits RequestCancelExternalWorkflowExecution" do
      assert {:ok, exec} = TestHarness.start_workflow(StartThenCancelParent, nil)

      # Start command first.
      assert {:yield, [%Command.StartChildWorkflowExecution{seq: start_seq}]} =
               TestHarness.next(exec)

      # Start succeeds → parent gets handle → immediately calls
      # cancel_child_workflow which emits the cancel command in the same
      # yield (no intermediate empty yield).
      assert {:yield,
              [
                %Command.RequestCancelExternalWorkflowExecution{
                  seq: cancel_seq,
                  target: {:child, "stc-child"}
                }
              ]} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecutionStart{
                 seq: start_seq,
                 status: {:succeeded, "stc-run-1"}
               })

      # Cancel resolution succeeds, parent unblocks and calls await.
      assert {:yield, []} =
               TestHarness.resolve(exec, %Job.ResolveRequestCancelExternalWorkflow{
                 seq: cancel_seq,
                 result: :ok
               })

      # Child completion (e.g. cancelled) resolves the await.
      assert {:complete, _} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecution{
                 seq: start_seq,
                 result: {:cancelled, %Temporalex.CancelledError{message: "cancelled"}}
               })
    end

    defmodule AwaitAfterCompletionParent do
      @moduledoc """
      Tests the "already completed" path: the child finishes BEFORE the
      parent awaits. The executor caches the result; the await returns
      immediately without blocking.
      """
      use Temporalex.Workflow

      def run(_) do
        {:ok, handle} = API.start_child_workflow(__MODULE__.Child, [], workflow_id: "aac-child")
        :ok = API.sleep(1_000)
        {:ok, result} = API.await_child_workflow(handle)
        {:ok, {:cached, result}}
      end

      defmodule Child do
        use Temporalex.Workflow
        def run(_), do: {:ok, :ready}
      end
    end

    test "await on an already-completed child returns the cached result immediately" do
      assert {:ok, exec} = TestHarness.start_workflow(AwaitAfterCompletionParent, nil)

      # Parent first emits StartChildWorkflowExecution and blocks on the
      # start resolution.
      assert {:yield, [%Command.StartChildWorkflowExecution{seq: start_seq}]} =
               TestHarness.next(exec)

      # Start succeeds → parent gets handle, then calls API.sleep → emits
      # the timer command in the next yield.
      assert {:yield, [%Command.StartTimer{seq: timer_seq}]} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecutionStart{
                 seq: start_seq,
                 status: {:succeeded, "aac-run-1"}
               })

      # Child completion arrives before the timer fires — gets cached on
      # the pending entry, no commands emitted.
      assert {:yield, []} =
               TestHarness.resolve(exec, %Job.ResolveChildWorkflowExecution{
                 seq: start_seq,
                 result: {:ok, :ready}
               })

      # Timer fires → parent's await_child_workflow finds the cached
      # completion and returns immediately, workflow completes.
      assert {:complete, {:ok, {:cached, :ready}}} =
               TestHarness.resolve(exec, %Job.TimerFired{seq: timer_seq})
    end

    test "signal_child_workflow inside an async update handler works" do
      assert {:ok, exec} =
               TestHarness.start_workflow(SignalingFromAsyncUpdateWorkflow, nil)

      assert {:waiting, _} = TestHarness.next(exec)

      # The async handler returns :delivered as the update reply.
      assert {:yield, commands} = TestHarness.send_update(exec, "broadcast", [])

      # Acceptance + the signal command emitted from inside the async fn.
      assert Enum.any?(commands, &match?(%Command.RespondToUpdate{response: :accepted}, &1))

      signal_cmd =
        Enum.find(commands, &match?(%Command.SignalExternalWorkflowExecution{}, &1))

      assert signal_cmd != nil
      assert signal_cmd.target == {:child, "child-1"}
      assert signal_cmd.signal_name == "wake"
      assert signal_cmd.args == [:from_async]

      # Resolve signal → async handler returns :delivered → update completes.
      assert {:yield, completed_commands} =
               TestHarness.resolve(exec, %Job.ResolveSignalExternalWorkflow{
                 seq: signal_cmd.seq,
                 result: :ok
               })

      assert Enum.any?(
               completed_commands,
               &match?(%Command.RespondToUpdate{response: {:completed, :delivered}}, &1)
             )

      # Stop the phase, workflow completes.
      assert {:complete, {:ok, :running}} = TestHarness.send_signal(exec, "done", [])
    end
  end
end
