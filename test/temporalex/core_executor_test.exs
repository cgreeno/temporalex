defmodule Temporalex.CoreExecutorTest do
  use ExUnit.Case, async: false

  alias Temporalex.Core.Command
  alias Temporalex.Core.Job
  alias Temporalex.Core.Nondeterminism
  alias Temporalex.Core.TestHarness
  alias Temporalex.Workflow.API

  defmodule Activities do
    use Temporalex.Activity

    defactivity echo(value), timeout: 1_000 do
      {:ok, value}
    end
  end

  defmodule CompleteWorkflow do
    use Temporalex.Workflow

    def run(input), do: {:ok, {:done, input}}
  end

  defmodule ErrorWorkflow do
    use Temporalex.Workflow

    def run(reason), do: {:error, reason}
  end

  defmodule ContinueWorkflow do
    use Temporalex.Workflow

    def run(args), do: {:continue_as_new, args}
  end

  defmodule CancelledWorkflow do
    use Temporalex.Workflow

    def run(_), do: {:cancelled, :requested}
  end

  defmodule UnsupportedReturnWorkflow do
    use Temporalex.Workflow

    def run(_), do: :bad_return
  end

  defmodule RaisingWorkflow do
    use Temporalex.Workflow

    def run(_), do: raise("boom")
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

  defmodule SleepWorkflow do
    use Temporalex.Workflow

    def run(duration_ms) do
      :ok = API.sleep(duration_ms)
      {:ok, :slept}
    end
  end

  defmodule ActivityThenTimerWorkflow do
    use Temporalex.Workflow

    def run(value) do
      {:ok, _} = Activities.echo(value)
      :ok = API.sleep(10)
      {:ok, :done}
    end
  end

  defmodule InfoWorkflow do
    use Temporalex.Workflow

    def run(_) do
      {:ok, %{info: API.workflow_info(), cancelled?: API.cancelled?(), now: API.now()}}
    end
  end

  defmodule RandomWorkflow do
    use Temporalex.Workflow

    def run(_) do
      {:ok, %{random: [API.random(), API.random()], uuid: API.uuid4()}}
    end
  end

  defmodule PatchWorkflow do
    use Temporalex.Workflow

    def run(_) do
      enabled? = API.patched?("new-path")
      API.deprecate_patch("old-path")
      {:ok, enabled?}
    end
  end

  defmodule SearchAttributesWorkflow do
    use Temporalex.Workflow

    def run(_) do
      :ok = API.upsert_search_attributes(%{"CustomKeywordField" => "alpha"})
      {:ok, :done}
    end
  end

  defmodule ContextKeysWorkflow do
    use Temporalex.Workflow

    def run(_) do
      {:ok, Process.get_keys()}
    end
  end

  defmodule ParallelWorkflow do
    use Temporalex.Workflow

    def run(_) do
      results =
        API.parallel([
          fn ->
            {:ok, :a1} = Activities.echo(:a1)
            {:ok, :a2} = Activities.echo(:a2)
            :a_done
          end,
          fn ->
            {:ok, :b1} = Activities.echo(:b1)
            {:ok, :b2} = Activities.echo(:b2)
            :b_done
          end
        ])

      {:ok, results}
    end
  end

  defmodule NestedParallelWorkflow do
    use Temporalex.Workflow

    def run(_) do
      result =
        API.parallel([
          fn ->
            API.parallel([
              fn -> Activities.echo(:a_nested) end,
              fn -> Activities.echo(:b_nested) end
            ])
          end
        ])

      {:ok, result}
    end
  end

  defmodule PhaseSignalWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase(0,
          signal: %{
            "inc" => fn [amount], state -> {:noreply, state + amount} end,
            "done" => fn _args, state -> {:stop, state} end
          }
        )

      {:ok, state}
    end
  end

  defmodule WaitSignalWorkflow do
    use Temporalex.Workflow

    def run(_) do
      first = API.wait_for_signal("go")
      second = API.wait_for_signal("go")
      {:ok, [first, second]}
    end
  end

  defmodule BufferedSignalWorkflow do
    use Temporalex.Workflow

    def run(_) do
      {:ok, :gate} = Activities.echo(:gate)

      state =
        API.phase(0,
          signal: %{
            "inc" => fn [amount], state -> {:noreply, state + amount} end,
            "done" => fn _args, state -> {:stop, state} end
          }
        )

      {:ok, state}
    end
  end

  defmodule SyncSignalWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase([],
          signal: %{
            "work" => fn [name], state ->
              {:ok, result} = Activities.echo(name)
              {:noreply, state ++ [result]}
            end,
            "done" => fn _args, state -> {:stop, state} end
          }
        )

      {:ok, state}
    end
  end

  defmodule AsyncSignalWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase(0,
          signal: %{
            "slow" => fn _args, state ->
              {:async,
               fn ->
                 :ok = API.sleep(10)
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

  defmodule UpdateWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase(0,
          update: %{
            "add" =>
              {fn [amount], state ->
                 {:reply, state + amount, state + amount}
               end,
               validator: fn
                 [amount], _state when amount > 0 -> :ok
                 _args, _state -> {:error, :invalid_amount}
               end},
            "activity" => fn _args, state ->
              {:ok, :activity_done} = Activities.echo(:update_activity)
              {:reply, :activity_done, state}
            end,
            "skip_validator" =>
              {fn _args, state -> {:reply, :validator_skipped, state} end,
               validator: fn _args, _state -> raise("validator should be skipped") end},
            "stop" => fn _args, state -> {:stop, :stopped, state} end
          },
          signal: %{"done" => fn _args, state -> {:stop, state} end}
        )

      {:ok, state}
    end
  end

  defmodule AsyncUpdateWorkflow do
    use Temporalex.Workflow

    def run(_) do
      state =
        API.phase(0,
          update: %{
            "slow" => fn [amount], state ->
              {:async,
               fn ->
                 :ok = API.sleep(10)
                 API.update_state(fn current -> {current + amount, current + amount} end)
               end, state}
            end,
            "bad_state" => fn _args, state ->
              {:async,
               fn ->
                 API.update_state(fn current ->
                   API.sleep(1)
                   {:ok, current}
                 end)
               end, state}
            end,
            "stop" => fn _args, state -> {:stop, :stopped, state} end
          }
        )

      {:ok, state}
    end
  end

  defmodule TimeoutPhaseWorkflow do
    use Temporalex.Workflow

    def run(_) do
      result =
        API.phase(:open,
          timeout: 50,
          signal: %{"done" => fn _args, state -> {:stop, state} end}
        )

      {:ok, result}
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

  defmodule BadQueryWorkflow do
    use Temporalex.Workflow

    def handle_query("bad", _args, _state) do
      API.sleep(1)
      {:reply, :impossible}
    end

    def run(_) do
      API.publish_state(:ready)
      {:ok, :done}
    end
  end

  describe "Slice 1 sequential core" do
    test "terminal workflow return shapes become terminal commands" do
      assert {:ok, exec} = TestHarness.start_workflow(CompleteWorkflow, :input)
      assert {:complete, {:ok, {:done, :input}}} = TestHarness.next(exec)

      assert {:ok, exec} = TestHarness.start_workflow(ErrorWorkflow, :bad)
      assert {:complete, {:error, :bad}} = TestHarness.next(exec)

      assert {:ok, exec} = TestHarness.start_workflow(ContinueWorkflow, [:next])
      assert {:continue_as_new, [:next]} = TestHarness.next(exec)

      assert {:ok, exec} = TestHarness.start_workflow(CancelledWorkflow, nil)
      assert {:yield, [%Command.CancelWorkflow{}]} = TestHarness.next(exec)

      assert {:ok, exec} = TestHarness.start_workflow(UnsupportedReturnWorkflow, :ignored)

      assert {:complete, {:error, {:unsupported_workflow_return, :bad_return}}} =
               TestHarness.next(exec)

      assert {:ok, exec} = TestHarness.start_workflow(RaisingWorkflow, :ignored)

      assert {:complete, {:error, {:exception, {:exception, %RuntimeError{}, _stack}}}} =
               TestHarness.next(exec)
    end

    test "activity commands block and resume by sequence number" do
      assert {:ok, exec} = TestHarness.start_workflow(ActivityWorkflow, :value)

      assert {:yield, [%Command.ScheduleActivity{} = command]} = TestHarness.next(exec)
      assert command.seq == 0
      assert command.thread_id == []
      assert command.activity_id == "activity-0"
      assert command.type == "#{inspect(Activities)}.echo"
      assert command.input == [:value]

      assert {:complete, {:ok, :result}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: command.seq,
                 result: {:ok, :result}
               })
    end

    test "blocked runner remains alive while waiting for activity resolution" do
      assert {:ok, exec} = TestHarness.start_workflow(ActivityWorkflow, :value)
      assert {:yield, [%Command.ScheduleActivity{}]} = TestHarness.next(exec)

      state = Temporalex.Core.Executor.inspect_state(exec.pid)
      runner = state.threads[[]]

      assert runner.status == :blocked
      assert Process.alive?(runner.pid)
    end

    test "executor shutdown tears down linked blocked runner" do
      previous_flag = Process.flag(:trap_exit, true)

      try do
        assert {:ok, exec} = TestHarness.start_workflow(ActivityWorkflow, :value)
        assert {:yield, [%Command.ScheduleActivity{}]} = TestHarness.next(exec)

        runner_pid = Temporalex.Core.Executor.inspect_state(exec.pid).threads[[]].pid
        assert Process.alive?(runner_pid)

        Process.exit(exec.pid, :shutdown)
        assert_receive {:EXIT, pid, :shutdown} when pid == exec.pid

        refute Process.alive?(runner_pid)
      after
        Process.flag(:trap_exit, previous_flag)
      end
    end

    test "activity failures are workflow-visible values" do
      assert {:ok, exec} = TestHarness.start_workflow(ActivityWorkflow, :value)
      assert {:yield, [%Command.ScheduleActivity{} = command]} = TestHarness.next(exec)

      assert {:complete, {:ok, {:error, :activity_failed}}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: command.seq,
                 result: {:error, :activity_failed}
               })
    end

    test "timer commands block and resume by sequence number" do
      assert {:ok, exec} = TestHarness.start_workflow(SleepWorkflow, 25)

      assert {:yield, [%Command.StartTimer{} = command]} = TestHarness.next(exec)
      assert command.seq == 0
      assert command.thread_id == []
      assert command.duration_ms == 25

      assert {:complete, {:ok, :slept}} =
               TestHarness.resolve(exec, %Job.TimerFired{seq: command.seq})
    end

    test "search attribute upsert is a non-pausing workflow command" do
      assert {:ok, exec} = TestHarness.start_workflow(SearchAttributesWorkflow, nil)

      completion =
        TestHarness.activate_raw(exec, [
          %Job.InitializeWorkflow{
            workflow_type: inspect(SearchAttributesWorkflow),
            workflow_id: "wf-search-attrs",
            arguments: [nil],
            workflow_info: %{},
            randomness_seed: 0
          }
        ])

      assert {:ok,
              [
                %Command.UpsertSearchAttributes{attrs: %{"CustomKeywordField" => "alpha"}},
                %Command.CompleteWorkflow{result: :done}
              ]} = completion.status
    end

    test "activity followed by timer keeps monotonic command sequence" do
      assert {:ok, exec} = TestHarness.start_workflow(ActivityThenTimerWorkflow, :value)
      assert {:yield, [%Command.ScheduleActivity{seq: 0} = activity]} = TestHarness.next(exec)

      assert {:yield, [%Command.StartTimer{seq: 1} = timer]} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: activity.seq,
                 result: {:ok, :value}
               })

      assert {:complete, {:ok, :done}} =
               TestHarness.resolve(exec, %Job.TimerFired{seq: timer.seq})
    end

    test "workflow info, cancellation, and activation time are executor-owned" do
      assert {:ok, exec} =
               TestHarness.start_workflow(InfoWorkflow, nil, timestamp: ~U[2026-05-07 12:00:00Z])

      assert {:complete, {:ok, result}} =
               TestHarness.activate(exec, [
                 %Job.InitializeWorkflow{
                   workflow_type: inspect(InfoWorkflow),
                   workflow_id: "wf-info",
                   arguments: [nil],
                   workflow_info: %{task_queue: "test"},
                   randomness_seed: 0
                 },
                 %Job.CancelWorkflow{reason: :requested}
               ])

      assert result.cancelled? == true
      assert result.now == ~U[2026-05-07 12:00:00Z]
      assert result.info.workflow_id == "wf-info"
      assert result.info.task_queue == "test"
    end

    test "deterministic random and UUID derive from replayed seed" do
      assert {:ok, first} = TestHarness.start_workflow(RandomWorkflow, nil)
      assert {:ok, second} = TestHarness.start_workflow(RandomWorkflow, nil)

      assert {:complete, {:ok, first_result}} =
               TestHarness.next(first, randomness_seed: 123_456_789)

      assert {:complete, {:ok, second_result}} =
               TestHarness.next(second, randomness_seed: 123_456_789)

      assert first_result == second_result
      assert [a, b] = first_result.random
      assert is_float(a)
      assert is_float(b)
      assert a >= 0.0 and a < 1.0
      assert b >= 0.0 and b < 1.0

      assert first_result.uuid =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "patch APIs emit markers on new executions and respect replay notifications" do
      assert {:ok, exec} = TestHarness.start_workflow(PatchWorkflow, nil)

      assert {:ok,
              [
                %Command.SetPatchMarker{id: "new-path", deprecated: false},
                %Command.SetPatchMarker{id: "old-path", deprecated: true},
                %Command.CompleteWorkflow{result: true}
              ]} =
               TestHarness.activate_raw(exec, [
                 %Job.InitializeWorkflow{
                   workflow_type: inspect(PatchWorkflow),
                   workflow_id: "wf-patch",
                   arguments: [nil],
                   workflow_info: %{},
                   randomness_seed: 0
                 }
               ]).status

      assert {:ok, exec} = TestHarness.start_workflow(PatchWorkflow, nil)

      assert {:ok,
              [
                %Command.SetPatchMarker{id: "new-path", deprecated: false},
                %Command.CompleteWorkflow{result: true}
              ]} =
               TestHarness.activate_raw(
                 exec,
                 [
                   %Job.NotifyPatch{id: "new-path"},
                   %Job.InitializeWorkflow{
                     workflow_type: inspect(PatchWorkflow),
                     workflow_id: "wf-patch-replay",
                     arguments: [nil],
                     workflow_info: %{},
                     randomness_seed: 0
                   }
                 ], replay: true).status

      assert {:ok, exec} = TestHarness.start_workflow(PatchWorkflow, nil)

      assert {:ok, [%Command.CompleteWorkflow{result: false}]} =
               TestHarness.activate_raw(
                 exec,
                 [
                   %Job.InitializeWorkflow{
                     workflow_type: inspect(PatchWorkflow),
                     workflow_id: "wf-patch-old-replay",
                     arguments: [nil],
                     workflow_info: %{},
                     randomness_seed: 0
                   }
                 ], replay: true).status
    end

    test "workflow processes carry only the Temporalex context key" do
      assert {:ok, exec} = TestHarness.start_workflow(ContextKeysWorkflow, nil)
      assert {:complete, {:ok, keys}} = TestHarness.next(exec)
      assert keys == [:__temporal_context__]
    end

    test "eviction activations run no workflow code" do
      assert {:ok, exec} = TestHarness.start_workflow(RaisingWorkflow, nil)

      assert {:yield, []} =
               TestHarness.resolve(exec, %Job.RemoveFromCache{reason: :evict, message: "test"})
    end

    test "replay accepts matching command decisions and fails mismatches" do
      expected = [
        %Command.ScheduleActivity{
          seq: 0,
          thread_id: [],
          activity_id: "activity-0",
          type: "#{inspect(Activities)}.echo",
          input: [:value],
          opts: [timeout: 1_000]
        }
      ]

      assert {:ok, exec} = TestHarness.start_workflow(ActivityWorkflow, :value)

      assert {:yield, expected} ==
               TestHarness.next(exec, replay: true, expected_commands: expected)

      wrong = [%Command.StartTimer{seq: 0, thread_id: [], duration_ms: 10}]
      assert {:ok, exec} = TestHarness.start_workflow(ActivityWorkflow, :value)

      assert {:failed, %Nondeterminism{}} =
               TestHarness.next(exec, replay: true, expected_commands: wrong)

      assert {:ok, exec} = TestHarness.start_workflow(ActivityWorkflow, :value)

      assert {:failed, %Nondeterminism{}} =
               TestHarness.next(exec, replay: true, expected_commands: [])

      assert {:ok, exec} = TestHarness.start_workflow(ActivityWorkflow, :value)

      assert {:failed, %Nondeterminism{}} =
               TestHarness.next(exec,
                 replay: true,
                 expected_commands:
                   expected ++ [%Command.StartTimer{seq: 1, thread_id: [], duration_ms: 1}]
               )
    end

    test "test harness can record and replay a command transcript" do
      assert {:ok, transcript, :done} =
               TestHarness.record(ActivityThenTimerWorkflow, :value, fn
                 %Command.ScheduleActivity{} -> {:ok, :value}
               end)

      assert {:ok, {:ok, :done}} =
               TestHarness.replay(ActivityThenTimerWorkflow, :value, transcript)
    end
  end

  describe "Slice 2 deterministic scheduler and parallel" do
    test "parallel branches emit first commands in input order" do
      assert {:ok, exec} = TestHarness.start_workflow(ParallelWorkflow, nil)

      assert {:yield,
              [
                %Command.ScheduleActivity{thread_id: [{:p, 0}], input: [:a1]},
                %Command.ScheduleActivity{thread_id: [{:p, 1}], input: [:b1]}
              ]} = TestHarness.next(exec)
    end

    test "one resolved branch can continue without waiting for unresolved siblings" do
      assert {:ok, exec} = TestHarness.start_workflow(ParallelWorkflow, nil)

      assert {:yield,
              [
                %Command.ScheduleActivity{seq: a_seq, input: [:a1]},
                %Command.ScheduleActivity{seq: b_seq, input: [:b1]}
              ]} = TestHarness.next(exec)

      assert {:yield, [%Command.ScheduleActivity{seq: c_seq, thread_id: [{:p, 0}], input: [:a2]}]} =
               TestHarness.resolve(exec, %Job.ActivityResolved{seq: a_seq, result: {:ok, :a1}})

      assert b_seq == 1
      assert c_seq == 2
    end

    test "branches resolved in one activation continue in stable branch order" do
      assert {:ok, exec} = TestHarness.start_workflow(ParallelWorkflow, nil)

      assert {:yield,
              [
                %Command.ScheduleActivity{seq: a_seq},
                %Command.ScheduleActivity{seq: b_seq}
              ]} = TestHarness.next(exec)

      assert {:yield,
              [
                %Command.ScheduleActivity{thread_id: [{:p, 0}], input: [:a2]},
                %Command.ScheduleActivity{thread_id: [{:p, 1}], input: [:b2]}
              ]} =
               TestHarness.resolve(exec, [
                 %Job.ActivityResolved{seq: b_seq, result: {:ok, :b1}},
                 %Job.ActivityResolved{seq: a_seq, result: {:ok, :a1}}
               ])
    end

    test "parallel returns results in input order after every branch finishes" do
      assert {:ok, exec} = TestHarness.start_workflow(ParallelWorkflow, nil)

      assert {:yield, [%Command.ScheduleActivity{seq: a1}, %Command.ScheduleActivity{seq: b1}]} =
               TestHarness.next(exec)

      assert {:yield, [%Command.ScheduleActivity{seq: a2}, %Command.ScheduleActivity{seq: b2}]} =
               TestHarness.resolve(exec, [
                 %Job.ActivityResolved{seq: a1, result: {:ok, :a1}},
                 %Job.ActivityResolved{seq: b1, result: {:ok, :b1}}
               ])

      assert {:complete, {:ok, [:a_done, :b_done]}} =
               TestHarness.resolve(exec, [
                 %Job.ActivityResolved{seq: b2, result: {:ok, :b2}},
                 %Job.ActivityResolved{seq: a2, result: {:ok, :a2}}
               ])
    end

    test "nested parallel uses hierarchical thread ids" do
      assert {:ok, exec} = TestHarness.start_workflow(NestedParallelWorkflow, nil)

      assert {:yield,
              [
                %Command.ScheduleActivity{thread_id: [{:p, 0}, {:p, 0}], input: [:a_nested]},
                %Command.ScheduleActivity{thread_id: [{:p, 0}, {:p, 1}], input: [:b_nested]}
              ]} = TestHarness.next(exec)
    end

    test "parallel command order is stable across repeated runs" do
      orders =
        for _ <- 1..25 do
          {:ok, exec} = TestHarness.start_workflow(ParallelWorkflow, nil)
          {:yield, commands} = TestHarness.next(exec)
          Enum.map(commands, & &1.thread_id)
        end

      assert Enum.uniq(orders) == [[[{:p, 0}], [{:p, 1}]]]
    end
  end

  describe "Slice 2 phase, signals, updates, and queries" do
    test "signal before phase is buffered and consumed by the matching phase handler" do
      assert {:ok, exec} = TestHarness.start_workflow(BufferedSignalWorkflow, nil)
      assert {:yield, [%Command.ScheduleActivity{seq: gate_seq}]} = TestHarness.next(exec)
      assert {:yield, []} = TestHarness.send_signal(exec, "inc", [2])

      assert {:waiting, %{state: 2}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: gate_seq,
                 result: {:ok, :gate}
               })

      assert {:complete, {:ok, 2}} = TestHarness.send_signal(exec, "done", [])
    end

    test "non-matching signal inside phase remains buffered" do
      assert {:ok, exec} = TestHarness.start_workflow(PhaseSignalWorkflow, nil)
      assert {:waiting, _info} = TestHarness.next(exec)

      assert {:waiting, _info} = TestHarness.send_signal(exec, "other", [:value])

      state = Temporalex.Core.Executor.inspect_state(exec.pid)
      assert [%Job.SignalReceived{name: "other", args: [:value]}] = state.signal_buffer
    end

    test "wait_for_signal consumes buffered signals in arrival order" do
      assert {:ok, exec} = TestHarness.start_workflow(WaitSignalWorkflow, nil)

      completion =
        TestHarness.activate_raw(exec, [
          %Job.SignalReceived{name: "go", args: [:first]},
          %Job.SignalReceived{name: "go", args: [:second]},
          %Job.InitializeWorkflow{
            workflow_type: inspect(WaitSignalWorkflow),
            workflow_id: "wf-wait",
            arguments: [nil],
            workflow_info: %{},
            randomness_seed: 0
          }
        ])

      assert {:ok, [%Command.CompleteWorkflow{result: [[:first], [:second]]}]} = completion.status
    end

    test "sync signal handlers serialize message processing" do
      assert {:ok, exec} = TestHarness.start_workflow(SyncSignalWorkflow, nil)
      assert {:waiting, _info} = TestHarness.next(exec)

      assert {:yield, [%Command.ScheduleActivity{seq: first_seq, input: [:first]}]} =
               TestHarness.resolve(exec, [
                 %Job.SignalReceived{name: "work", args: [:first]},
                 %Job.SignalReceived{name: "work", args: [:second]}
               ])

      assert {:yield, [%Command.ScheduleActivity{seq: second_seq, input: [:second]}]} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: first_seq,
                 result: {:ok, :first}
               })

      assert {:waiting, %{state: [:first, :second]}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: second_seq,
                 result: {:ok, :second}
               })
    end

    test "async signal handler can block while phase dispatches later messages" do
      assert {:ok, exec} = TestHarness.start_workflow(AsyncSignalWorkflow, nil)
      assert {:waiting, _info} = TestHarness.next(exec)

      assert {:yield, [%Command.StartTimer{seq: timer_seq, thread_id: [{:h, 0}, {:a, 0}]}]} =
               TestHarness.resolve(exec, [
                 %Job.SignalReceived{name: "slow", args: []},
                 %Job.SignalReceived{name: "done", args: []}
               ])

      assert {:complete, {:ok, 1}} = TestHarness.resolve(exec, %Job.TimerFired{seq: timer_seq})
    end

    test "updates emit accepted before handler commands and complete after handler result" do
      assert {:ok, exec} = TestHarness.start_workflow(UpdateWorkflow, nil)
      assert {:waiting, _info} = TestHarness.next(exec)

      assert {:yield,
              [
                %Command.RespondToUpdate{protocol_instance_id: "p1", response: :accepted},
                %Command.ScheduleActivity{seq: activity_seq, input: [:update_activity]}
              ]} =
               TestHarness.send_update(exec, "activity", [], protocol_instance_id: "p1")

      assert {:yield,
              [
                %Command.RespondToUpdate{
                  protocol_instance_id: "p1",
                  response: {:completed, :activity_done}
                }
              ]} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: activity_seq,
                 result: {:ok, :activity_done}
               })
    end

    test "async update handler accepts before work and completes after its durable wait" do
      assert {:ok, exec} = TestHarness.start_workflow(AsyncUpdateWorkflow, nil)
      assert {:waiting, _info} = TestHarness.next(exec)

      assert {:yield,
              [
                %Command.RespondToUpdate{protocol_instance_id: "async", response: :accepted},
                %Command.StartTimer{seq: timer_seq, thread_id: [{:h, 0}, {:a, 0}]}
              ]} =
               TestHarness.send_update(exec, "slow", [3], protocol_instance_id: "async")

      assert {:yield,
              [%Command.RespondToUpdate{protocol_instance_id: "async", response: {:completed, 3}}]} =
               TestHarness.resolve(exec, %Job.TimerFired{seq: timer_seq})

      assert {:complete, {:ok, 3}} =
               TestHarness.send_update(exec, "stop", [], protocol_instance_id: "stop")
    end

    test "update_state closures that call workflow APIs fail the async update" do
      assert {:ok, exec} = TestHarness.start_workflow(AsyncUpdateWorkflow, nil)
      assert {:waiting, _info} = TestHarness.next(exec)

      assert {:yield,
              [
                %Command.RespondToUpdate{protocol_instance_id: "bad-state", response: :accepted},
                %Command.RespondToUpdate{
                  protocol_instance_id: "bad-state",
                  response: {:rejected, {:exception, %RuntimeError{}, _stack}}
                }
              ]} =
               TestHarness.send_update(exec, "bad_state", [], protocol_instance_id: "bad-state")
    end

    test "update validators reject invalid updates and run_validator false skips validation" do
      assert {:ok, exec} = TestHarness.start_workflow(UpdateWorkflow, nil)
      assert {:waiting, _info} = TestHarness.next(exec)

      assert {:yield,
              [
                %Command.RespondToUpdate{
                  protocol_instance_id: "bad",
                  response: {:rejected, :invalid_amount}
                }
              ]} =
               TestHarness.send_update(exec, "add", [-1], protocol_instance_id: "bad")

      assert {:yield,
              [
                %Command.RespondToUpdate{protocol_instance_id: "skip", response: :accepted},
                %Command.RespondToUpdate{
                  protocol_instance_id: "skip",
                  response: {:completed, :validator_skipped}
                }
              ]} =
               TestHarness.send_update(exec, "skip_validator", [],
                 protocol_instance_id: "skip",
                 run_validator: false
               )
    end

    test "updates outside matching phase are rejected" do
      assert {:ok, exec} = TestHarness.start_workflow(CompleteWorkflow, nil)

      completion =
        TestHarness.activate_raw(exec, [
          %Job.InitializeWorkflow{
            workflow_type: inspect(CompleteWorkflow),
            workflow_id: "wf",
            arguments: [nil],
            workflow_info: %{},
            randomness_seed: 0
          },
          %Job.UpdateReceived{
            name: "add",
            args: [1],
            protocol_instance_id: "outside",
            run_validator: true
          }
        ])

      assert {:ok,
              [
                %Command.RespondToUpdate{
                  protocol_instance_id: "outside",
                  response: {:rejected, {:not_accepting_update, "add"}}
                },
                %Command.CompleteWorkflow{}
              ]} = completion.status
    end

    test "phase timeout uses durable timer and returns timeout tuple" do
      assert {:ok, exec} = TestHarness.start_workflow(TimeoutPhaseWorkflow, nil)

      assert {:yield, [%Command.StartTimer{seq: timeout_seq, duration_ms: 50}]} =
               TestHarness.next(exec)

      assert {:complete, {:ok, {:timeout, :open}}} =
               TestHarness.resolve(exec, %Job.TimerFired{seq: timeout_seq})
    end

    test "phase stop before timeout emits CancelTimer" do
      assert {:ok, exec} = TestHarness.start_workflow(TimeoutPhaseWorkflow, nil)
      assert {:yield, [%Command.StartTimer{seq: timeout_seq}]} = TestHarness.next(exec)

      completion = TestHarness.activate_raw(exec, [%Job.SignalReceived{name: "done", args: []}])

      assert {:ok,
              [
                %Command.CancelTimer{seq: ^timeout_seq},
                %Command.CompleteWorkflow{result: :open}
              ]} = completion.status

      state = Temporalex.Core.Executor.inspect_state(exec.pid)
      assert state.pending == %{}
      assert Enum.any?(state.threads, fn {_id, thread} -> thread.status == :done end)
    end

    test "query handlers read published state and query-only activation does not advance workflow units" do
      assert {:ok, exec} = TestHarness.start_workflow(QueryWorkflow, nil)
      assert {:yield, [%Command.ScheduleActivity{seq: activity_seq}]} = TestHarness.next(exec)

      assert {:yield,
              [%Command.RespondToQuery{query_id: "q1", result: {:ok, %{step: :before_activity}}}]} =
               TestHarness.query(exec, "state", [], query_id: "q1")

      assert %{[] => :blocked} = TestHarness.thread_states(exec)

      assert {:complete, {:ok, :done}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: activity_seq,
                 result: {:ok, :activity}
               })
    end

    test "query failures become query responses instead of workflow failures" do
      assert {:ok, exec} = TestHarness.start_workflow(BadQueryWorkflow, nil)
      assert {:complete, {:ok, :done}} = TestHarness.next(exec)

      assert {:yield,
              [%Command.RespondToQuery{query_id: "bad", result: {:error, %RuntimeError{}}}]} =
               TestHarness.query(exec, "bad", [], query_id: "bad")
    end
  end

  describe "Slice 2 replay coverage" do
    test "branch command mismatch fails activation nondeterministically" do
      wrong = [
        %Command.ScheduleActivity{
          seq: 0,
          thread_id: [{:p, 1}],
          activity_id: "activity-0",
          type: "#{inspect(Activities)}.echo",
          input: [:b1],
          opts: [timeout: 1_000]
        }
      ]

      assert {:ok, exec} = TestHarness.start_workflow(ParallelWorkflow, nil)

      assert {:failed, %Nondeterminism{}} =
               TestHarness.next(exec, replay: true, expected_commands: wrong)
    end

    test "handler command mismatch fails activation nondeterministically" do
      assert {:ok, exec} = TestHarness.start_workflow(UpdateWorkflow, nil)
      assert {:waiting, _info} = TestHarness.next(exec)

      wrong = [
        %Command.RespondToUpdate{protocol_instance_id: "p1", response: :accepted},
        %Command.StartTimer{seq: 0, thread_id: [{:h, 0}], duration_ms: 1}
      ]

      assert {:failed, %Nondeterminism{}} =
               TestHarness.send_update(exec, "activity", [],
                 protocol_instance_id: "p1",
                 replay: true,
                 expected_commands: wrong
               )
    end
  end
end
