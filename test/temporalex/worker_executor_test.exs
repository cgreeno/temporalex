defmodule Temporalex.WorkerExecutorTest do
  @moduledoc """
  Direct unit tests for `Temporalex.Worker.Executor` — the production
  executor — driven via the `flush_to` test seam so we can assert on the
  command stream that would have been sent to Temporal.
  """

  use ExUnit.Case, async: true

  import Temporalex.Test.ExecutorHelpers

  alias Temporalex.Worker.Replay

  # --- Test workflows ---

  defmodule TrivialWorkflow do
    use Temporalex.Workflow
    def run(_args), do: {:ok, :done}
  end

  defmodule TickCounterWorkflow do
    # Receive with a "tick" handler that increments a counter.
    # Used to verify that multiple signals delivered in the SAME activation
    # all run their handlers and all state mutations land.
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{count: 0},
          signal: %{
            "tick" => fn _payload, s -> {:noreply, %{s | count: s.count + 1}} end,
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule UpdateRespondingWorkflow do
    # Receive with an "echo" update handler that returns the args. The
    # handler's return value MUST surface to Temporal as an UpdateResponse
    # command (accepted + completed) — otherwise the Update API caller
    # times out even though the handler ran.
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:initial,
          update: %{
            "echo" => fn args, state -> {:reply, args, state} end,
            "stopper" => fn args, state -> {:stop, args, state} end,
            "rejected" => {
              fn _args, state -> {:reply, :should_not_run, state} end,
              validator: fn _args, _state -> {:error, :nope} end
            }
          },
          signal: %{
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule ChildCallerWorkflow do
    # Calls a child workflow, returns the result. Verifies that a
    # cancelled child workflow surfaces as {:error, {:cancelled, _}} to
    # the runner — currently the executor's apply_resolutions has no
    # arm for {:cancelled, _} on child workflows, so the runner hangs.
    use Temporalex.Workflow

    def run(_args) do
      result = API.start_child_workflow(TrivialWorkflow, %{})
      {:ok, {:child_returned, result}}
    end
  end

  # --- Smoke test: seam works ---

  describe "test seam" do
    test "executor with flush_to: self() sends commands as messages" do
      {:ok, exec} = start_executor(TrivialWorkflow)
      send_activation(exec, init_activation(TrivialWorkflow))

      assert_receive {:flushed, _run_id, commands}, 500
      # Trivial workflow returns {:ok, :done} → complete_workflow_execution
      assert [{:complete_workflow_execution, %{result: _}}] = commands
    end
  end

  # --- Bug #3 (runtime side): cancelled child workflow ---

  describe "cancelled child workflow resolution unblocks runner" do
    test "child workflow cancellation surfaces to caller as {:error, {:cancelled, _}}" do
      {:ok, exec} = start_executor(ChildCallerWorkflow)

      # First activation: initialize. Runner schedules a child, parks.
      send_activation(exec, init_activation(ChildCallerWorkflow))
      assert_receive {:flushed, _, [{:start_child_workflow_execution, %{seq: seq}}]}, 500

      # Second activation: child workflow was cancelled.
      send_activation(
        exec,
        activation([
          {:resolve_child_workflow_execution,
           %{seq: seq, result: {:cancelled, %{message: "cancelled by parent"}}}}
        ])
      )

      # Workflow body re-receives the result, returns {:ok, {:child_returned,
      # {:error, {:cancelled, ...}}}} → complete_workflow_execution emitted.
      assert_receive {:flushed, _, commands}, 500
      assert [{:complete_workflow_execution, _}] = commands
    end
  end

  # --- Bug #3 confirmation: cancelled activity replay log construction ---

  describe "replay log handles cancelled activity end-to-end" do
    # Verifies the public Replay module's contract — no executor needed.
    test "cancelled activity in history converts to error tuple" do
      jobs = [{:resolve_activity, %{seq: 1, result: {:cancelled, %{message: "cancel"}}}}]
      assert [{:activity, 1, {:error, {:cancelled, _}}}] = Replay.build_log(jobs)
    end
  end

  # --- Bug #2: multi-signal in single activation ---

  describe "multiple signals in a single activation all run their handlers" do
    # When Temporal Core delivers two `:signal_workflow` jobs in one
    # activation, both handlers must run and both state mutations must
    # land in the receive's accumulator.
    test "two ticks + one done in one activation yields count: 2" do
      {:ok, exec} = start_executor(TickCounterWorkflow)

      send_activation(exec, init_activation(TickCounterWorkflow))
      assert_receive {:flushed, _, []}, 500

      send_activation(
        exec,
        activation([
          {:signal_workflow, %{signal_name: "tick", input: [], identity: ""}},
          {:signal_workflow, %{signal_name: "tick", input: [], identity: ""}},
          {:signal_workflow, %{signal_name: "done", input: [], identity: ""}}
        ])
      )

      result = drain_until_complete(800)

      [{:complete_workflow_execution, %{result: payload}}] = result
      assert %{count: 2} = Temporalex.Converter.decode(payload)
    end

    test "handlers run in dispatch order — five ticks then done yields count: 5" do
      {:ok, exec} = start_executor(TickCounterWorkflow)
      send_activation(exec, init_activation(TickCounterWorkflow))
      assert_receive {:flushed, _, []}, 500

      ticks =
        for _ <- 1..5, do: {:signal_workflow, %{signal_name: "tick", input: [], identity: ""}}

      done = [{:signal_workflow, %{signal_name: "done", input: [], identity: ""}}]
      send_activation(exec, activation(ticks ++ done))

      [{:complete_workflow_execution, %{result: payload}}] = drain_until_complete(800)
      assert %{count: 5} = Temporalex.Converter.decode(payload)
    end

    test "done first, then two ticks: receive stops at first done with count: 0" do
      # Stops immediately on done; the queued ticks should not run because
      # the receive has already exited.
      {:ok, exec} = start_executor(TickCounterWorkflow)
      send_activation(exec, init_activation(TickCounterWorkflow))
      assert_receive {:flushed, _, []}, 500

      send_activation(
        exec,
        activation([
          {:signal_workflow, %{signal_name: "done", input: [], identity: ""}},
          {:signal_workflow, %{signal_name: "tick", input: [], identity: ""}},
          {:signal_workflow, %{signal_name: "tick", input: [], identity: ""}}
        ])
      )

      [{:complete_workflow_execution, %{result: payload}}] = drain_until_complete(800)
      assert %{count: 0} = Temporalex.Converter.decode(payload)
    end
  end

  # --- Bug #1: updates respond to Temporal ---

  describe "update handler responses are emitted as UpdateResponse commands" do
    test "{:reply, response, state} emits accepted + completed UpdateResponse" do
      {:ok, exec} = start_executor(UpdateRespondingWorkflow)
      send_activation(exec, init_activation(UpdateRespondingWorkflow))
      assert_receive {:flushed, _, []}, 500

      send_activation(
        exec,
        activation([
          {:do_update,
           %{
             id: "u1",
             protocol_instance_id: "proto-u1",
             name: "echo",
             input: [Temporalex.Converter.encode(:hello)]
           }}
        ])
      )

      cmds = collect_update_responses(800)

      assert Enum.any?(
               cmds,
               &match?(
                 {:update_response,
                  %{protocol_instance_id: "proto-u1", response: {:accepted, _}}},
                 &1
               )
             ),
             "expected an :accepted UpdateResponse for proto-u1 in #{inspect(cmds)}"

      assert Enum.any?(
               cmds,
               &match?(
                 {:update_response,
                  %{protocol_instance_id: "proto-u1", response: {:completed, _}}},
                 &1
               )
             ),
             "expected a :completed UpdateResponse for proto-u1 in #{inspect(cmds)}"
    end

    test "handler crash post-acceptance emits :accepted then :rejected with crash detail" do
      # Handler that raises after the dispatcher has emitted :accepted.
      # We verify the SDK still produces an UpdateResponse so the caller
      # doesn't hang on update timeout. The Accept→Reject transition is
      # documented as risky against Core's state machine in the audit;
      # this test pins the SDK-side contract so we notice if we regress.
      defmodule HandlerCrashUpdateWorkflow do
        use Temporalex.Workflow

        def run(_args) do
          result =
            API.receive(:initial,
              update: %{"explode" => fn _args, _state -> raise("handler boom") end},
              signal: %{"done" => fn _payload, s -> {:stop, s} end}
            )

          {:ok, result}
        end
      end

      {:ok, exec} = start_executor(HandlerCrashUpdateWorkflow)
      send_activation(exec, init_activation(HandlerCrashUpdateWorkflow))
      assert_receive {:flushed, _, []}, 500

      send_activation(
        exec,
        activation([
          {:do_update, %{id: "u3", protocol_instance_id: "proto-u3", name: "explode", input: []}}
        ])
      )

      cmds = collect_update_responses(800)

      assert Enum.any?(
               cmds,
               &match?(
                 {:update_response,
                  %{protocol_instance_id: "proto-u3", response: {:accepted, _}}},
                 &1
               )
             ),
             "expected :accepted before the crash; got #{inspect(cmds)}"

      assert Enum.any?(
               cmds,
               &match?(
                 {:update_response,
                  %{
                    protocol_instance_id: "proto-u3",
                    response: {:rejected, %{message: "handler crashed:" <> _}}
                  }},
                 &1
               )
             ),
             "expected :rejected after the crash; got #{inspect(cmds)}"
    end

    test "validator rejection emits a rejected UpdateResponse" do
      {:ok, exec} = start_executor(UpdateRespondingWorkflow)
      send_activation(exec, init_activation(UpdateRespondingWorkflow))
      assert_receive {:flushed, _, []}, 500

      send_activation(
        exec,
        activation([
          {:do_update,
           %{
             id: "u2",
             protocol_instance_id: "proto-u2",
             name: "rejected",
             input: [Temporalex.Converter.encode(:whatever)]
           }}
        ])
      )

      cmds = collect_update_responses(800)

      assert Enum.any?(
               cmds,
               &match?(
                 {:update_response,
                  %{protocol_instance_id: "proto-u2", response: {:rejected, _}}},
                 &1
               )
             ),
             "expected a :rejected UpdateResponse for proto-u2 in #{inspect(cmds)}"
    end
  end

  # Collect update_response commands across multiple flushes within `timeout`.
  # The accepted command is emitted in the first flush (after activation
  # processing); completed/rejected arrive in a later flush after the
  # handler/validator returns.
  defp collect_update_responses(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_update_responses([], deadline)
  end

  defp do_collect_update_responses(acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:flushed, _, cmds} ->
        update_cmds = Enum.filter(cmds, &match?({:update_response, _}, &1))
        do_collect_update_responses(acc ++ update_cmds, deadline)
    after
      remaining -> acc
    end
  end

  # Drain flushes until we see one containing any update_response command.
  defp drain_until_emits_update_response(timeout) do
    receive do
      {:flushed, _, cmds} ->
        if Enum.any?(cmds, fn
             {:update_response, _} -> true
             _ -> false
           end) do
          cmds
        else
          drain_until_emits_update_response(timeout)
        end
    after
      timeout -> flunk("did not see an UpdateResponse command within #{timeout}ms")
    end
  end

  # Drain {:flushed, _, commands} messages until we see a terminal command
  # (complete_workflow_execution / fail_workflow_execution / continue_as_new).
  # Returns the commands list from the terminal flush.
  defp drain_until_complete(timeout), do: drain_until_complete([], timeout)

  defp drain_until_complete(seen, timeout) do
    receive do
      {:flushed, _, [{:complete_workflow_execution, _}] = cmds} -> cmds
      {:flushed, _, [{:fail_workflow_execution, _}] = cmds} -> cmds
      {:flushed, _, [{:continue_as_new, _}] = cmds} -> cmds
      {:flushed, _, other} -> drain_until_complete([other | seen], timeout)
    after
      timeout ->
        flunk(
          "did not see terminal flush within #{timeout}ms; saw: #{inspect(Enum.reverse(seen))}"
        )
    end
  end

  # --- Bug #1: eviction must terminate the executor promptly ---

  describe "executor honors :shutdown EXIT promptly" do
    # When a DynamicSupervisor calls terminate_child, the executor receives
    # an EXIT signal with reason :shutdown. Because the executor traps
    # exits, that signal must be handled explicitly — otherwise the
    # supervisor waits 5 seconds before sending :kill, blocking the entire
    # Server's gen_server loop.
    test "executor exits within 100ms when sent a :shutdown EXIT" do
      Process.flag(:trap_exit, true)
      {:ok, exec} = start_executor(TrivialWorkflow)
      ref = Process.monitor(exec)

      # Drain init flush.
      send_activation(exec, init_activation(TrivialWorkflow))
      assert_receive {:flushed, _, _}, 500

      start = System.monotonic_time(:millisecond)
      Process.exit(exec, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^exec, :shutdown}, 500
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 100,
             "executor took #{elapsed}ms to honor :shutdown — supervisor would block this long"
    end

    test "executor exits promptly even with an in-flight runner parked on a call" do
      # Workflow that parks on a sleep — runner is in GenServer.call to executor.
      defmodule ParkedWorkflow do
        use Temporalex.Workflow
        def run(_args), do: API.sleep(:timer.minutes(10))
      end

      Process.flag(:trap_exit, true)
      {:ok, exec} = start_executor(ParkedWorkflow)
      ref = Process.monitor(exec)

      send_activation(exec, init_activation(ParkedWorkflow))
      assert_receive {:flushed, _, [{:start_timer, _}]}, 500

      start = System.monotonic_time(:millisecond)
      Process.exit(exec, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^exec, :shutdown}, 500
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 100,
             "executor with parked runner took #{elapsed}ms to honor :shutdown"
    end
  end

  # --- Bug #4 + #5: bounded queues ---

  describe "signal_buffer is bounded — drops oldest at the cap" do
    # Workflow that never enters a receive — signals accumulate in
    # signal_buffer indefinitely. Without a cap, a flooding client could
    # exhaust the worker's heap.
    defmodule NeverReceivesWorkflow do
      use Temporalex.Workflow
      def run(_args), do: API.sleep(:timer.hours(1))
    end

    test "signals beyond the cap drop the oldest entries with a warning" do
      cap = 3
      {:ok, exec} = start_executor(NeverReceivesWorkflow, max_signal_buffer: cap)
      send_activation(exec, init_activation(NeverReceivesWorkflow))
      assert_receive {:flushed, _, [{:start_timer, _}]}, 500

      # Pump cap+2 signal activations into a workflow that's parked on sleep
      # and will never consume them in a receive.
      for i <- 1..(cap + 2) do
        send_activation(
          exec,
          activation([
            {:signal_workflow,
             %{signal_name: "ping", input: [Temporalex.Converter.encode(i)], identity: ""}}
          ])
        )
      end

      # `:sys.get_state` synchronizes with the executor's mailbox — by the
      # time it returns, all activations above have been processed.
      state = :sys.get_state(exec)
      assert state.signal_buffer_size == cap
      assert length(state.signal_buffer) == cap

      # Verify the OLDEST were dropped, NEWEST kept (FIFO drop policy).
      # Buffer holds {name, decoded_payload} — payloads are decoded by
      # dispatch_signals before reaching the buffer.
      payloads = Enum.map(state.signal_buffer, fn {_n, payload} -> payload end)

      # We pumped 1..5 with cap=3; should keep [3, 4, 5].
      assert payloads == Enum.to_list((cap + 2 - cap + 1)..(cap + 2))
    end
  end

  describe "pending_handler_queue is bounded — rejects updates at the cap" do
    defmodule SlowHandlerWorkflow do
      # First update parks on a never-resolving sleep, blocking the handler
      # queue. Subsequent dispatches stack in pending_handler_queue.
      use Temporalex.Workflow

      def run(_args) do
        result =
          API.receive(:initial,
            update: %{
              "park" => fn _args, state ->
                API.sleep(:timer.hours(1))
                {:reply, :ok, state}
              end
            },
            signal: %{"done" => fn _payload, s -> {:stop, s} end}
          )

        {:ok, result}
      end
    end

    test "updates beyond the queue cap surface as :rejected immediately" do
      cap = 2
      {:ok, exec} = start_executor(SlowHandlerWorkflow, max_pending_handlers: cap)
      send_activation(exec, init_activation(SlowHandlerWorkflow))
      assert_receive {:flushed, _, _}, 500

      # Send cap + 2 updates. The first runs (and parks); cap-1 fit in
      # the queue; the (cap+1)th must be rejected immediately.
      for i <- 1..(cap + 2) do
        send_activation(
          exec,
          activation([
            {:do_update,
             %{
               id: "u#{i}",
               protocol_instance_id: "p#{i}",
               name: "park",
               input: []
             }}
          ])
        )
      end

      # Drain flushes and inspect for at least one explicit rejection of the
      # form "handler queue full".
      rejections = collect_rejected_updates(800)

      assert length(rejections) >= 1,
             "expected at least one rejection due to queue cap; got #{inspect(rejections)}"

      # And: the cap is enforced — pending_handler_count never exceeds cap.
      state = :sys.get_state(exec)
      assert state.pending_handler_count <= cap
    end
  end

  defp collect_rejected_updates(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_rejected_updates([], deadline)
  end

  defp do_collect_rejected_updates(acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:flushed, _, cmds} ->
        rejs =
          Enum.filter(cmds, fn
            {:update_response, %{response: {:rejected, %{message: "handler queue full" <> _}}}} ->
              true

            _ ->
              false
          end)

        do_collect_rejected_updates(acc ++ rejs, deadline)
    after
      remaining -> acc
    end
  end

  # --- Race: receive timer firing while a sync handler is still running ---

  describe "receive timer racing with in-flight sync handler" do
    # Same race as RC16 in receive_api_test.exs but exercised against the
    # production executor. Without the receive_from-nil guard in
    # complete_receive, the executor crashes with FunctionClauseError.
    defmodule TimerRaceProdWorkflow do
      use Temporalex.Workflow

      def run(_args) do
        result =
          API.receive(:initial,
            signal: %{
              "go" => fn _payload, _state ->
                Process.sleep(80)
                {:stop, :handler_won}
              end
            },
            timeout: 30
          )

        {:ok, result}
      end
    end

    test "timer fires while handler is sleeping: executor stays alive, timer wins" do
      Process.flag(:trap_exit, true)
      {:ok, exec} = start_executor(TimerRaceProdWorkflow)
      ref = Process.monitor(exec)

      send_activation(exec, init_activation(TimerRaceProdWorkflow))
      assert_receive {:flushed, _, []}, 500

      send_activation(
        exec,
        activation([
          {:signal_workflow, %{signal_name: "go", input: [], identity: ""}}
        ])
      )

      # Wait long enough for both the 30ms timer to fire AND the 80ms
      # handler sleep to elapse.
      Process.sleep(150)

      # Executor must still be alive — no crash.
      refute_received {:DOWN, ^ref, :process, ^exec, _}

      # The runner saw the timer's reply ({:timeout, :initial}) and
      # exited with that as the workflow result.
      [{:complete_workflow_execution, %{result: payload}}] = drain_until_complete(800)
      assert {:timeout, :initial} = Temporalex.Converter.decode(payload)
    end
  end

  # --- Serial mailbox processing — regression guard ---

  describe "consecutive activations process in mailbox order" do
    # The BEAM guarantees serial processing of messages within a single
    # process. This test pins that guarantee at the executor level — if
    # someone ever introduces a selective `receive` that prioritises
    # certain message types, this test breaks.
    defmodule TickWorkflow2 do
      use Temporalex.Workflow

      def run(_args) do
        result =
          API.receive([],
            signal: %{
              "tick" => fn payload, list -> {:noreply, [payload | list]} end,
              "done" => fn _payload, list -> {:stop, Enum.reverse(list)} end
            }
          )

        {:ok, result}
      end
    end

    test "ticks delivered in separate activations land in send order" do
      {:ok, exec} = start_executor(TickWorkflow2)
      send_activation(exec, init_activation(TickWorkflow2))
      assert_receive {:flushed, _, []}, 500

      # Send three activations back-to-back without waiting between sends.
      # Each is one tick; payload is the tick number. They MUST land in
      # the workflow's accumulator in 1, 2, 3 order.
      for i <- 1..3 do
        send_activation(
          exec,
          activation([
            {:signal_workflow,
             %{signal_name: "tick", input: [Temporalex.Converter.encode(i)], identity: ""}}
          ])
        )
      end

      send_activation(
        exec,
        activation([
          {:signal_workflow, %{signal_name: "done", input: [], identity: ""}}
        ])
      )

      [{:complete_workflow_execution, %{result: payload}}] = drain_until_complete(800)
      assert [1, 2, 3] = Temporalex.Converter.decode(payload)
    end
  end
end
