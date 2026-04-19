defmodule Temporalex.ExecutorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Temporalex.WorkflowTaskExecutor

  # ============================================================
  # Test modules
  # ============================================================

  defmodule Payments do
    use Temporalex.DSL

    defactivity charge(amount), timeout: 30_000 do
      {:ok, "real-charge-#{amount}"}
    end

    defactivity send_receipt(email), timeout: 5_000 do
      {:ok, "real-receipt-#{email}"}
    end

    def process_order(%{amount: amount, email: email}) do
      with {:ok, charge_id} <- charge(amount),
           {:ok, _receipt} <- send_receipt(email) do
        {:ok, charge_id}
      end
    end
  end

  defmodule SimpleWorkflow do
    use Temporalex.DSL

    def greet(%{name: name}), do: {:ok, "Hello, #{name}!"}
  end

  defmodule FailWorkflow do
    use Temporalex.DSL

    def run(%{reason: reason}), do: {:error, reason}
  end

  # ============================================================
  # Pure workflow (no activities)
  # ============================================================

  describe "pure workflow (no activities)" do
    test "completes immediately with result" do
      {:ok, executor} =
        WorkflowTaskExecutor.start_link(
          server_pid: self(),
          run_id: "run-1",
          task_queue: "test",
          run_fn: &SimpleWorkflow.greet/1
        )

      send(executor, {:start, %{name: "Alice"}, []})

      assert_receive {:executor_commands, "run-1", [command], nil, :done}, 1_000
      assert {:complete_workflow_execution, completion} = command.variant
      assert completion.result != nil
    end

    test "error workflow sends fail command" do
      {:ok, executor} =
        WorkflowTaskExecutor.start_link(
          server_pid: self(),
          run_id: "run-2",
          task_queue: "test",
          run_fn: &FailWorkflow.run/1
        )

      send(executor, {:start, %{reason: "broken"}, []})

      assert_receive {:executor_commands, "run-2", [command], nil, :done}, 1_000
      assert {:fail_workflow_execution, failure} = command.variant
      assert failure.failure.message == "broken"
    end
  end

  # ============================================================
  # Workflow with activities (first execution)
  # ============================================================

  describe "workflow with activities (first execution)" do
    test "runner blocks on activity, executor sends schedule command" do
      {:ok, executor} =
        WorkflowTaskExecutor.start_link(
          server_pid: self(),
          run_id: "run-3",
          task_queue: "orders",
          run_fn: &Payments.process_order/1
        )

      # Start the workflow
      send(executor, {:start, %{amount: 100, email: "a@b.com"}, []})

      # Runner hits charge(100) → blocks, executor sends schedule command
      assert_receive {:executor_commands, "run-3", [cmd], nil, :yielded}, 1_000
      assert {:schedule_activity, schedule} = cmd.variant
      assert schedule.activity_type =~ "Payments.charge"
      assert schedule.seq == 0

      # Simulate: Temporal resolves the activity
      send(executor, {:resolve_activity, 0, {:ok, "charged-100"}})

      # Runner resumes, hits send_receipt → blocks again
      assert_receive {:executor_commands, "run-3", [cmd2], nil, :yielded}, 1_000
      assert {:schedule_activity, schedule2} = cmd2.variant
      assert schedule2.activity_type =~ "Payments.send_receipt"
      assert schedule2.seq == 1

      # Resolve second activity
      send(executor, {:resolve_activity, 1, {:ok, "receipt-sent"}})

      # Workflow completes
      assert_receive {:executor_commands, "run-3", [cmd3], nil, :done}, 1_000
      assert {:complete_workflow_execution, _} = cmd3.variant
    end
  end

  # ============================================================
  # Replay (results pre-loaded from history)
  # ============================================================

  describe "replay (pre-loaded results)" do
    test "runner gets replay results immediately, no commands scheduled" do
      {:ok, executor} =
        WorkflowTaskExecutor.start_link(
          server_pid: self(),
          run_id: "run-4",
          task_queue: "orders",
          run_fn: &Payments.process_order/1,
          replay_results: %{
            0 => {:activity, {:ok, "replayed-charge"}},
            1 => {:activity, {:ok, "replayed-receipt"}}
          }
        )

      send(executor, {:start, %{amount: 50, email: "x@y.com"}, []})

      # Both activities are replay — no schedule commands, goes straight to complete
      assert_receive {:executor_commands, "run-4", [cmd], nil, :done}, 1_000
      assert {:complete_workflow_execution, _} = cmd.variant
    end

    test "partial replay: first activity replayed, second scheduled" do
      {:ok, executor} =
        WorkflowTaskExecutor.start_link(
          server_pid: self(),
          run_id: "run-5",
          task_queue: "orders",
          run_fn: &Payments.process_order/1,
          replay_results: %{0 => {:activity, {:ok, "replayed-charge"}}}
        )

      send(executor, {:start, %{amount: 50, email: "x@y.com"}, []})

      # First activity replayed, second needs scheduling
      assert_receive {:executor_commands, "run-5", [cmd], nil, :yielded}, 1_000
      assert {:schedule_activity, schedule} = cmd.variant
      assert schedule.seq == 1

      # Resolve second activity
      send(executor, {:resolve_activity, 1, {:ok, "receipt-done"}})

      assert_receive {:executor_commands, "run-5", [cmd2], nil, :done}, 1_000
      assert {:complete_workflow_execution, _} = cmd2.variant
    end
  end

  # ============================================================
  # Nondeterminism detection
  # ============================================================

  describe "nondeterminism detection" do
    test "activity where timer expected fails with nondeterminism" do
      # Replay history says seq 0 was a timer, but workflow code calls an activity
      activity_fn = fn _args ->
        GenServer.call(
          Process.get(:__temporal_executor__),
          {:execute_activity, "SomeActivity", "input", []},
          :infinity
        )
      end

      log =
        capture_log(fn ->
          {:ok, executor} =
            WorkflowTaskExecutor.start_link(
              server_pid: self(),
              run_id: "run-nd-1",
              task_queue: "test",
              run_fn: activity_fn,
              replay_results: %{0 => {:timer, :ok}}
            )

          send(executor, {:start, %{}, []})

          assert_receive {:executor_commands, "run-nd-1", [cmd], nil, :done}, 1_000
          assert {:fail_workflow_execution, fail} = cmd.variant
          assert fail.failure.message =~ "Nondeterminism"
          assert fail.failure.message =~ "activity"
          assert fail.failure.message =~ "timer"
        end)

      assert log =~ "Nondeterminism detected"
      assert log =~ "workflow called activity(SomeActivity)"
      assert log =~ "replay history has timer"
    end

    test "timer where activity expected fails with nondeterminism" do
      # Replay history says seq 0 was an activity, but workflow code calls sleep
      sleep_fn = fn _args ->
        GenServer.call(Process.get(:__temporal_executor__), {:sleep, 1000}, :infinity)
      end

      log =
        capture_log(fn ->
          {:ok, executor} =
            WorkflowTaskExecutor.start_link(
              server_pid: self(),
              run_id: "run-nd-2",
              task_queue: "test",
              run_fn: sleep_fn,
              replay_results: %{0 => {:activity, {:ok, "some-result"}}}
            )

          send(executor, {:start, %{}, []})

          assert_receive {:executor_commands, "run-nd-2", [cmd], nil, :done}, 1_000
          assert {:fail_workflow_execution, fail} = cmd.variant
          assert fail.failure.message =~ "Nondeterminism"
          assert fail.failure.message =~ "timer"
          assert fail.failure.message =~ "activity"
        end)

      assert log =~ "Nondeterminism detected"
      assert log =~ "workflow called timer"
      assert log =~ "replay history has activity"
    end
  end

  # ============================================================
  # Runner crash handling
  # ============================================================

  describe "runner crash" do
    test "crashed runner sends fail command" do
      crash_fn = fn _args -> raise "boom" end

      log =
        capture_log(fn ->
          {:ok, executor} =
            WorkflowTaskExecutor.start_link(
              server_pid: self(),
              run_id: "run-crash",
              task_queue: "test",
              run_fn: crash_fn
            )

          send(executor, {:start, %{}, []})

          assert_receive {:executor_commands, "run-crash", [cmd], nil, :done}, 1_000
          assert {:fail_workflow_execution, failure} = cmd.variant
          assert failure.failure.message =~ "boom"
        end)

      assert log =~ "Workflow runner crashed"
    end
  end

  # ============================================================
  # Signals forwarded to runner
  # ============================================================

  describe "signal forwarding" do
    test "signals are forwarded to runner process" do
      # Workflow that waits a bit so we can send a signal
      me = self()

      wait_fn = fn _args ->
        send(me, {:runner_started, self()})

        receive do
          {:signal, "go", _payload} -> {:ok, "got signal"}
        after
          5_000 -> {:error, "timeout"}
        end
      end

      {:ok, executor} =
        WorkflowTaskExecutor.start_link(
          server_pid: self(),
          run_id: "run-sig",
          task_queue: "test",
          run_fn: wait_fn
        )

      send(executor, {:start, %{}, []})

      # Wait for runner to start
      assert_receive {:runner_started, _pid}, 1_000

      # Send signal through executor
      send(executor, {:signal, "go", "payload"})

      # Workflow should complete
      assert_receive {:executor_commands, "run-sig", [cmd], nil, :done}, 2_000
      assert {:complete_workflow_execution, _} = cmd.variant
    end
  end

  # ============================================================
  # Server child_spec
  # ============================================================

  describe "Server.child_spec" do
    test "uses task_queue as ID for multiple servers" do
      spec1 = Temporalex.Server.child_spec(task_queue: "orders", workflows: [], activities: [])
      spec2 = Temporalex.Server.child_spec(task_queue: "emails", workflows: [], activities: [])

      assert spec1.id == {Temporalex.Server, "orders"}
      assert spec2.id == {Temporalex.Server, "emails"}
      assert spec1.id != spec2.id
    end

    test "sets shutdown timeout for NIF drain" do
      spec = Temporalex.Server.child_spec(task_queue: "test", workflows: [], activities: [])
      assert spec.shutdown == 35_000
    end

    test "requires task_queue" do
      assert_raise ArgumentError, ~r/task_queue/, fn ->
        Temporalex.Server.child_spec(workflows: [], activities: [])
      end
    end
  end
end
