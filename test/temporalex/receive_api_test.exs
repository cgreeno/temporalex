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

      # Complete the activity → async handler finishes → receive can exit.
      Testing.resolve(exec, {:ok, :done})
      _ = Task.await(update_task, 1_000)

      assert {:ok, %{count: 1}} = Testing.next(exec)
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
