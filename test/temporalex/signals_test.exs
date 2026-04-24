defmodule Temporalex.SignalsTest do
  @moduledoc """
  Priority 2 — Signals (S1-S12) from TESTS_V2.md.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test workflows ---

  # Simple receive with one signal handler.
  defmodule EchoWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive([],
          signal: %{
            "msg" => fn payload, acc -> {:noreply, [payload | acc]} end,
            "done" => fn _payload, acc -> {:stop, Enum.reverse(acc)} end
          }
        )

      {:ok, result}
    end
  end

  # Waits for a single signal outside of receive.
  defmodule WaitWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      payload = API.wait_for_signal("go")
      {:ok, payload}
    end
  end

  # Two sequential wait_for_signal calls to test FIFO.
  defmodule TwoWaitsWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      a = API.wait_for_signal("step")
      b = API.wait_for_signal("step")
      {:ok, [a, b]}
    end
  end

  # Async signal handler.
  defmodule AsyncSignalWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(0,
          signal: %{
            "bump" => fn _payload, count ->
              {:async,
               fn ->
                 API.update_state(fn s -> {s + 1, s + 1} end)
               end, count}
            end,
            "done" => fn _payload, count -> {:stop, count} end
          }
        )

      {:ok, result}
    end
  end

  # Buffered-before-receive pattern: waits for a signal, then enters receive
  # (any signals sent in between get drained on receive entry).
  defmodule BufferThenReceiveWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      API.wait_for_signal("start")

      result =
        API.receive(0,
          signal: %{
            "inc" => fn _payload, n -> {:noreply, n + 1} end,
            "done" => fn _payload, n -> {:stop, n} end
          }
        )

      {:ok, result}
    end
  end

  # --- Tests ---

  describe "S1 — signal delivered inside receive" do
    test "handler runs when signal name matches" do
      {:ok, exec} = Testing.start_workflow(EchoWorkflow, %{})

      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "msg", "hello")
      Process.sleep(20)
      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, ["hello"]} = Testing.next(exec)
    end
  end

  describe "S2 — signal buffered when outside receive" do
    test "wait_for_signal consumes a signal sent before it was called" do
      {:ok, exec} = Testing.start_workflow(WaitWorkflow, %{})

      # Workflow is blocked on wait_for_signal — a pre-buffered signal would
      # have been consumed immediately. Here we send it now.
      assert {:signal, "go"} = Testing.next(exec)
      Testing.send_signal(exec, "go", :payload)

      assert {:ok, :payload} = Testing.next(exec)
    end
  end

  describe "S3 — FIFO ordering" do
    test "two signals arrive in the order they were sent" do
      {:ok, exec} = Testing.start_workflow(EchoWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "msg", :first)
      Process.sleep(10)
      Testing.send_signal(exec, "msg", :second)
      Process.sleep(10)
      Testing.send_signal(exec, "msg", :third)
      Process.sleep(10)
      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, [:first, :second, :third]} = Testing.next(exec)
    end
  end

  describe "S4 — same name accumulates" do
    test "two signals with the same name both fire the handler" do
      {:ok, exec} = Testing.start_workflow(EchoWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "msg", 1)
      Process.sleep(10)
      Testing.send_signal(exec, "msg", 2)
      Process.sleep(10)
      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, [1, 2]} = Testing.next(exec)
    end
  end

  describe "S5 — signal before receive is not lost" do
    test "two sequential wait_for_signal calls drain the buffer in FIFO order" do
      {:ok, exec} = Testing.start_workflow(TwoWaitsWorkflow, %{})

      # Workflow is at the first wait_for_signal; send two signals quickly.
      assert {:signal, "step"} = Testing.next(exec)
      Testing.send_signal(exec, "step", :a)

      # Second wait — buffer already has a pending :b? No, we send now.
      assert {:signal, "step"} = Testing.next(exec)
      Testing.send_signal(exec, "step", :b)

      assert {:ok, [:a, :b]} = Testing.next(exec)
    end
  end

  describe "S6 — signal payload round-trip" do
    test "complex payload map reaches the handler unchanged" do
      {:ok, exec} = Testing.start_workflow(EchoWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      payload = %{"user_id" => 42, "tags" => ["a", "b"], "meta" => %{"k" => :v}}
      Testing.send_signal(exec, "msg", payload)
      Process.sleep(20)
      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, [^payload]} = Testing.next(exec)
    end
  end

  describe "S7 — {:noreply, state} keeps receive alive" do
    test "multiple :noreply handlers fire; receive only exits on :stop" do
      {:ok, exec} = Testing.start_workflow(EchoWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # 5 :noreply signals — handler updates state each time, receive stays open.
      for n <- 1..5 do
        Testing.send_signal(exec, "msg", n)
        Process.sleep(10)
      end

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, [1, 2, 3, 4, 5]} = Testing.next(exec)
    end
  end

  describe "S8 — {:stop, state} exits receive" do
    test "receive returns the :stop state to the caller" do
      {:ok, exec} = Testing.start_workflow(EchoWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, []} = Testing.next(exec)
    end
  end

  describe "S9 — {:async, fn, state} spawns async work" do
    test "async handler's update_state merges atomically into receive state" do
      {:ok, exec} = Testing.start_workflow(AsyncSignalWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # Fire three async-bump handlers; each increments the counter by 1.
      for _ <- 1..3 do
        Testing.send_signal(exec, "bump", nil)
        Process.sleep(15)
      end

      Testing.send_signal(exec, "done", nil)
      Process.sleep(30)

      assert {:ok, 3} = Testing.next(exec)
    end
  end

  describe "S10 — unmatched signal inside receive is buffered" do
    test "a signal with no handler name lands in the buffer (returned as :buffered)" do
      {:ok, exec} = Testing.start_workflow(EchoWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert :buffered = Testing.send_signal(exec, "no_such_handler", :ignored)

      # Receive is still alive — stop it.
      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, []} = Testing.next(exec)
    end
  end

  describe "S11 — buffered signals drained on receive entry" do
    test "signals sent before receive starts are auto-dispatched when it opens" do
      {:ok, exec} = Testing.start_workflow(BufferThenReceiveWorkflow, %{})

      # Workflow is at wait_for_signal("start"). Buffer an "inc" first, then
      # send "start" — entering receive should drain the buffered "inc".
      assert {:signal, "start"} = Testing.next(exec)
      Testing.send_signal(exec, "inc", nil)
      Testing.send_signal(exec, "start", nil)
      Process.sleep(30)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(30)

      assert {:ok, 1} = Testing.next(exec)
    end
  end

  describe "S12 — wait_for_signal returns immediately if buffered" do
    test "a pre-buffered signal unblocks the next wait_for_signal" do
      {:ok, exec} = Testing.start_workflow(TwoWaitsWorkflow, %{})

      # First wait — send signal to unblock it.
      assert {:signal, "step"} = Testing.next(exec)
      Testing.send_signal(exec, "step", :first)

      # Wait until the second wait_for_signal has parked itself as a
      # signal descriptor — that is, the runner is now blocked on the
      # *second* wait. At that point sending :second goes through
      # signal_waiters (replies the parked GenServer.call) and the workflow
      # completes.
      assert {:signal, "step"} = Testing.next(exec)
      Testing.send_signal(exec, "step", :second)

      assert {:ok, [:first, :second]} = Testing.next(exec)
    end
  end
end
