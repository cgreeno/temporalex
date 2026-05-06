defmodule Temporalex.ReceiveApiTest do
  @moduledoc """
  Priority 3 — API.receive (RC1-RC14) from TESTS_V2.md.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test activities ---

  defmodule Acts do
    use Temporalex.Activity

    defactivity(echo(x), do: {:ok, x})
  end

  # --- Test workflows ---

  defmodule BasicReceiveWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:initial,
          signal: %{
            "done" => fn _payload, _state -> {:stop, :stopped_by_signal} end
          }
        )

      {:ok, result}
    end
  end

  defmodule TimeoutDescriptorWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:initial,
          signal: %{"done" => fn _payload, s -> {:stop, s} end},
          timeout: 60_000
        )

      {:ok, result}
    end
  end

  defmodule MixedHandlersWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{signals: 0, updates: 0},
          signal: %{
            "tick" => fn _payload, s -> {:noreply, %{s | signals: s.signals + 1}} end,
            "done" => fn _payload, s -> {:stop, s} end
          },
          update: %{
            "bump" => fn _args, s -> {:reply, :bumped, %{s | updates: s.updates + 1}} end
          }
        )

      {:ok, result}
    end
  end

  defmodule IndependentStatesWorkflow do
    use Temporalex.Workflow

    def handle_query("published", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(:outer_state)

      result =
        API.receive(:receive_state_value,
          signal: %{"done" => fn _payload, s -> {:stop, s} end}
        )

      {:ok, result}
    end
  end

  defmodule SequentialReceivesWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      phase1 =
        API.receive(:phase1_initial,
          signal: %{
            "next" => fn _payload, _state -> {:stop, :phase1_done} end
          }
        )

      phase2 =
        API.receive(:phase2_initial,
          signal: %{
            "finish" => fn _payload, _state -> {:stop, :phase2_done} end
          }
        )

      {:ok, {phase1, phase2}}
    end
  end

  defmodule HandlerActivityWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(nil,
          signal: %{
            "compute" => fn value, _s ->
              {:ok, doubled} = Acts.echo(value * 2)
              {:noreply, doubled}
            end,
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule HandlerSleepWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:not_yet,
          signal: %{
            "go" => fn _payload, _s ->
              API.sleep(100)
              {:noreply, :after_sleep}
            end,
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule HandlerParallelWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(nil,
          signal: %{
            "fan" => fn _payload, _s ->
              results =
                API.parallel([
                  fn -> Acts.echo(:a) end,
                  fn -> Acts.echo(:b) end
                ])

              {:noreply, results}
            end,
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule AsyncCompletionWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{count: 0},
          update: %{
            "slow" => fn _args, state ->
              {:async,
               fn ->
                 {:ok, v} = Acts.echo(:done)
                 API.update_state(fn s -> {v, %{s | count: s.count + 1}} end)
               end, state}
            end
          },
          signal: %{
            "stop" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule AsyncUpdateStateAtomicWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{counter: 0},
          update: %{
            "inc" => fn _args, state ->
              {:async,
               fn ->
                 API.update_state(fn s ->
                   n = s.counter + 1
                   {n, %{s | counter: n}}
                 end)
               end, state}
            end
          },
          signal: %{
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  # Receive with an async handler that mutates state via update_state
  # AFTER a stop signal has fired. The stop signal returns a constant
  # `:frozen` (not current state) — the contract is the receive must
  # return `:frozen` regardless of subsequent state mutations.
  defmodule StopFreezesValueWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:initial,
          update: %{
            "slow" => fn _args, state ->
              {:async,
               fn ->
                 # Park on an activity so the async is in-flight when stop arrives.
                 {:ok, _} = Acts.echo(:wait)
                 # After stop has fired, mutate receive_state. With the
                 # bug, this mutation perturbs the value `complete_receive`
                 # eventually returns. Without the bug, the stop's `:frozen`
                 # is preserved.
                 API.update_state(fn _s -> {:ok, :polluted_after_stop} end)
               end, state}
            end
          },
          signal: %{
            "stop" => fn _payload, _state -> {:stop, :frozen} end
          }
        )

      {:ok, result}
    end
  end

  defmodule NestedReceiveWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:outer,
          signal: %{
            "try_nested" => fn _payload, _state ->
              # This must raise because we're inside a handler.
              API.receive(:inner, signal: %{"x" => fn _p, s -> {:stop, s} end})
              {:noreply, :should_not_reach}
            end,
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule HandlerSerializationWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive([],
          signal: %{
            "slow" => fn id, acc ->
              # Simulate work — handler takes time. Two "slow" signals in
              # flight should not run concurrently; they should append in
              # FIFO order.
              API.sleep(50)
              {:noreply, [id | acc]}
            end,
            "done" => fn _payload, acc -> {:stop, Enum.reverse(acc)} end
          }
        )

      {:ok, result}
    end
  end

  # --- Tests ---

  describe "RC1 — receive blocks, stops on :stop" do
    test "caller of receive is unblocked with the :stop state" do
      {:ok, exec} = Testing.start_workflow(BasicReceiveWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, :stopped_by_signal} = Testing.next(exec)
    end
  end

  describe "RC2 — receive auto-fires on timeout" do
    test "receive_opts timeout surfaces in the descriptor" do
      {:ok, exec} = Testing.start_workflow(TimeoutDescriptorWorkflow, %{})
      assert {:receive, info} = Testing.next(exec)
      assert info.timeout == 60_000

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, :initial} = Testing.next(exec)
    end

    defmodule QuickTimeoutWorkflow do
      use Temporalex.Workflow

      def run(_args) do
        result =
          API.receive(0,
            signal: %{
              "tick" => fn _payload, count -> {:noreply, count + 1} end
            },
            timeout: 50
          )

        {:ok, result}
      end
    end

    test "no signal arrives within the timeout → {:timeout, state} returned" do
      {:ok, exec} = Testing.start_workflow(QuickTimeoutWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # Wait for the auto-fire.
      Process.sleep(120)

      assert {:ok, {:timeout, 0}} = Testing.next(exec)
    end

    test "signal cancels the timer and the receive stops normally" do
      defmodule TimeoutOrSignalWorkflow do
        use Temporalex.Workflow

        def run(_args) do
          result =
            API.receive(:waiting,
              signal: %{
                "go" => fn _payload, _state -> {:stop, :got_signal} end
              },
              timeout: 5_000
            )

          {:ok, result}
        end
      end

      {:ok, exec} = Testing.start_workflow(TimeoutOrSignalWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "go", nil)
      Process.sleep(20)

      # Stopped via signal — NOT a timeout, even though we let some time pass.
      assert {:ok, :got_signal} = Testing.next(exec)

      # And the timer stays cancelled — no stale {:timeout, _} message.
      Process.sleep(50)
      refute_received _
    end
  end

  describe "RC3 — signal + update handlers coexist" do
    test "both handler types are registered and dispatchable" do
      {:ok, exec} = Testing.start_workflow(MixedHandlersWorkflow, %{})
      assert {:receive, info} = Testing.next(exec)

      assert "tick" in info.signals
      assert "bump" in info.updates

      Testing.send_signal(exec, "tick", nil)
      Process.sleep(10)
      assert :bumped = Testing.send_update(exec, "bump", [])
      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, %{signals: 1, updates: 1}} = Testing.next(exec)
    end
  end

  describe "RC4 — receive state independent from published state" do
    test "published_state and receive_state are distinct" do
      {:ok, exec} = Testing.start_workflow(IndependentStatesWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:reply, :outer_state} = Testing.query(exec, "published")

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, :receive_state_value} = Testing.next(exec)
    end
  end

  describe "RC5 — receive state scoped to one receive" do
    test "each receive starts with its own initial_state" do
      {:ok, exec} = Testing.start_workflow(SequentialReceivesWorkflow, %{})

      assert {:receive, _} = Testing.next(exec)
      Testing.send_signal(exec, "next", nil)
      Process.sleep(20)

      assert {:receive, _} = Testing.next(exec)
      Testing.send_signal(exec, "finish", nil)
      Process.sleep(20)

      assert {:ok, {:phase1_done, :phase2_done}} = Testing.next(exec)
    end
  end

  describe "RC6 — sequential receives (phase transitions)" do
    test "workflow uses one receive per phase; handlers from earlier phase do not leak" do
      {:ok, exec} = Testing.start_workflow(SequentialReceivesWorkflow, %{})

      assert {:receive, info1} = Testing.next(exec)
      assert "next" in info1.signals

      Testing.send_signal(exec, "next", nil)
      Process.sleep(20)

      assert {:receive, info2} = Testing.next(exec)
      assert "finish" in info2.signals
      refute "next" in info2.signals

      Testing.send_signal(exec, "finish", nil)
      Process.sleep(20)

      assert {:ok, _} = Testing.next(exec)
    end
  end

  describe "RC7 — sync handler can call activities" do
    test "signal handler issues execute_activity and uses the result" do
      {:ok, exec} = Testing.start_workflow(HandlerActivityWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "compute", 7)
      Process.sleep(20)

      assert {:activity, call} = Testing.next(exec)
      assert call.input == [14]

      assert {:receive, _} = Testing.resolve(exec, {:ok, 14})

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, 14} = Testing.next(exec)
    end
  end

  describe "RC8 — sync handler can call API.sleep" do
    test "signal handler blocks on sleep, receive stays open" do
      {:ok, exec} = Testing.start_workflow(HandlerSleepWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "go", nil)
      Process.sleep(20)

      assert {:sleep, 100} = Testing.next(exec)
      assert {:receive, _} = Testing.resolve(exec, :ok)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, :after_sleep} = Testing.next(exec)
    end
  end

  describe "RC9 — sync handler can call API.parallel" do
    test "signal handler fans out and collects results" do
      {:ok, exec} = Testing.start_workflow(HandlerParallelWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "fan", nil)
      Process.sleep(20)

      # Two parallel branches each hit execute_activity. Resolve each with
      # its own input so results are correct regardless of arrival order.
      assert {:activity, c1} = Testing.next(exec)
      assert {:activity, c2} = Testing.resolve(exec, {:ok, hd(c1.input)})
      assert {:receive, _} = Testing.resolve(exec, {:ok, hd(c2.input)})

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, [{:ok, :a}, {:ok, :b}]} = Testing.next(exec)
    end
  end

  describe "RC10 — sync handlers serialize" do
    test "two slow signals fire handlers one at a time, preserving FIFO" do
      {:ok, exec} = Testing.start_workflow(HandlerSerializationWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # Two signals in flight — the second one queues behind the first.
      Testing.send_signal(exec, "slow", :first)
      Testing.send_signal(exec, "slow", :second)

      # First handler's sleep. Resolving it completes handler 1 and the
      # queued second handler immediately starts its own sleep.
      assert {:sleep, _} = Testing.next(exec)
      assert {:sleep, _} = Testing.resolve(exec, :ok)
      assert {:receive, _} = Testing.resolve(exec, :ok)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, [:first, :second]} = Testing.next(exec)
    end
  end

  describe "RC11 — async handlers must finish before receive returns" do
    test "stop signal waits on outstanding async handler before surfacing result" do
      {:ok, exec} = Testing.start_workflow(AsyncCompletionWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      update_task = Task.async(fn -> Testing.send_update(exec, "slow", []) end)

      Process.sleep(20)
      assert {:activity, _} = Testing.next(exec)

      # Stop the receive via signal while the async is still pending.
      # The receive should not complete until the async handler finishes.
      Testing.send_signal(exec, "stop", nil)
      Process.sleep(20)

      # Verify the workflow is *still* parked — receive has not returned.
      # If it had, the call below would have produced {:ok, _} or another
      # descriptor; instead it times out.
      catch_exit(GenServer.call(exec, :next, 100))

      # Complete the activity → async handler finishes → receive can exit.
      Testing.resolve(exec, {:ok, :done})
      _ = Task.await(update_task, 1_000)

      # Stop captured state at the moment :stop fired (count: 0). The
      # async handler's post-stop mutation must not perturb this value.
      assert {:ok, %{count: 0}} = Testing.next(exec)
    end
  end

  describe "RC12 — async handler can call API.update_state" do
    test "update_state inside an async handler mutates the receive state" do
      {:ok, exec} = Testing.start_workflow(AsyncUpdateStateAtomicWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      update_task = Task.async(fn -> Testing.send_update(exec, "inc", []) end)
      Process.sleep(20)
      assert 1 = Task.await(update_task, 1_000)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, %{counter: 1}} = Testing.next(exec)
    end
  end

  describe "RC13 — update_state is atomic" do
    test "two async updates increment serially, no lost updates" do
      {:ok, exec} = Testing.start_workflow(AsyncUpdateStateAtomicWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> Testing.send_update(exec, "inc", []) end)
        end

      results = Task.await_many(tasks, 2_000) |> Enum.sort()

      assert results == [1, 2, 3, 4, 5]

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, %{counter: 5}} = Testing.next(exec)
    end
  end

  describe "RC15 — :stop value is frozen at the moment of stop" do
    test "stop value is preserved even if a pending async handler mutates state afterwards" do
      {:ok, exec} = Testing.start_workflow(StopFreezesValueWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # Trigger the async handler — it parks on Acts.echo.
      update_task = Task.async(fn -> Testing.send_update(exec, "slow", []) end)
      Process.sleep(20)
      assert {:activity, _} = Testing.next(exec)

      # Stop the receive while the async is still pending. Receive transitions
      # to :receive_stopping; stop value should be captured as :frozen.
      Testing.send_signal(exec, "stop", nil)
      Process.sleep(20)

      # Resolve the activity → async runs `update_state` → receive completes.
      Testing.resolve(exec, {:ok, :wait})
      _ = Task.await(update_task, 1_000)

      # Without the fix, the receive returns :polluted_after_stop because
      # complete_receive dropped :frozen and maybe_complete_receive falls
      # back to receive_state.
      assert {:ok, :frozen} = Testing.next(exec)
    end
  end

  describe "RC16 — timer fires while sync handler is mid-flight" do
    # Race: receive_timer fires AND a sync handler is still running.
    # Status transitions:
    #   1. Receive entered (:in_receive, sync_handler_pid set, receive_from set)
    #   2. Timer fires → do_complete_receive runs (status -> :running,
    #      receive_from cleared)
    #   3. Sync handler returns {:stop, _} → apply_handler_return →
    #      complete_receive
    # Without the receive_from-nil guard, step 3 calls
    # `GenServer.reply(nil, ...)` which raises FunctionClauseError and
    # crashes the executor. The contract: timer wins (first stop wins).
    defmodule TimerVsSlowHandlerWorkflow do
      use Temporalex.Workflow

      def run(_args) do
        result =
          API.receive(:initial,
            signal: %{
              "go" => fn _payload, _state ->
                # Sleep past the timeout. The timer should fire while
                # we're sleeping. When we then return {:stop, _}, the
                # executor must NOT try to reply to a cleared receive_from.
                Process.sleep(80)
                {:stop, :handler_won}
              end
            },
            timeout: 30
          )

        {:ok, result}
      end
    end

    test "timer fires while handler is running: timer wins, no executor crash" do
      Process.flag(:trap_exit, true)
      {:ok, exec} = Testing.start_workflow(TimerVsSlowHandlerWorkflow, %{})
      monitor_ref = Process.monitor(exec)
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "go", nil)

      # Wait for both the 30ms timer AND the 80ms handler sleep to elapse.
      Process.sleep(150)

      # Executor must still be alive. If the cleared receive_from caused
      # a crash, this would have failed with FunctionClauseError.
      refute_received {:DOWN, ^monitor_ref, :process, ^exec, _}

      # First stop wins: timer fired before the handler returned, so
      # the receive's value is the timer's {:timeout, :initial}.
      assert {:ok, {:timeout, :initial}} = Testing.next(exec)
    end
  end

  describe "RC17 — sync handler clobbers concurrent async update_state writes" do
    # Documented gotcha pinned in code: sync handlers capture receive_state
    # at spawn time and full-state-replace it on return. If an async
    # handler's spawned fn runs `update_state` DURING the sync handler's
    # execution, the async's mutation is silently lost.
    #
    # The sequence:
    #   1. Update handler returns {:async, fn, _} — async fn spawned,
    #      not queued.
    #   2. Sync signal handler dispatched while async fn is in flight.
    #      Sync handler captures state at spawn time.
    #   3. Async fn calls update_state — mutation lands in receive_state.
    #   4. Sync handler returns {:noreply, computed_state} where
    #      computed_state was derived from the captured (stale) state.
    #   5. apply_handler_return replaces receive_state with the sync
    #      handler's value, dropping the async's mutation.
    defmodule SyncClobbersAsyncWorkflow do
      use Temporalex.Workflow

      def run(_args) do
        result =
          API.receive(%{count: 0},
            update: %{
              # Returns :async — the async fn runs in its own process,
              # NOT queued. Sleeps before calling update_state to widen
              # the race window.
              "trigger_async" => fn _args, state ->
                {:async,
                 fn ->
                   Process.sleep(40)
                   API.update_state(fn s -> {:ok, %{count: s.count + 100}} end)
                 end, state}
              end
            },
            signal: %{
              # Captures state at spawn, sleeps long enough for the async
              # to run its update_state, then full-state-replaces. The
              # async's +100 is clobbered.
              "slow_sync" => fn _payload, state ->
                Process.sleep(60)
                {:noreply, %{count: state.count + 1}}
              end,
              "done" => fn _payload, state -> {:stop, state} end
            }
          )

        {:ok, result}
      end
    end

    test "sync handler returning while async update_state is in flight clobbers async write" do
      {:ok, exec} = Testing.start_workflow(SyncClobbersAsyncWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # Trigger async update — handler returns :async, spawning the
      # background fn that sleeps 40ms before update_state.
      update_task = Task.async(fn -> Testing.send_update(exec, "trigger_async", []) end)
      Process.sleep(5)

      # While the async fn is still sleeping (no update_state yet),
      # dispatch the slow_sync handler. It captures state %{count: 0}
      # at spawn time.
      Testing.send_signal(exec, "slow_sync", nil)
      Process.sleep(10)

      # Wait for the async to finish, ensuring its update_state ran.
      _ = Task.await(update_task, 500)

      # Wait for the sync handler to finish and replace state.
      Process.sleep(100)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      # The clobber: async's +100 was overwritten by sync's
      # `state.count + 1` where state.count was 0 at spawn time.
      # Final state = %{count: 1}, not %{count: 101}.
      assert {:ok, %{count: 1}} = Testing.next(exec)
    end
  end

  describe "RC14 — nested receive not allowed" do
    test "calling API.receive from inside a handler raises ArgumentError" do
      {:ok, exec} = Testing.start_workflow(NestedReceiveWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # The handler invokes API.receive, which will raise. The handler's
      # spawned process crashes, but the workflow itself continues.
      Testing.send_signal(exec, "try_nested", nil)
      Process.sleep(30)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, :outer} = Testing.next(exec)
    end
  end
end
