defmodule Temporalex.ChildWorkflowTest do
  @moduledoc """
  Priority 4 — Child Workflows (CW1-CW10) from TESTS_V2.md.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test child workflows ---

  defmodule DoublerChild do
    use Temporalex.Workflow

    def run(args), do: {:ok, args["value"] * 2}
  end

  defmodule FailingChild do
    use Temporalex.Workflow

    def run(_args), do: {:error, :child_failed}
  end

  # --- Parent workflows ---

  defmodule SimpleParent do
    use Temporalex.Workflow

    def run(args) do
      {:ok, doubled} = API.start_child_workflow(DoublerChild, %{"value" => args["x"]})
      {:ok, doubled}
    end
  end

  defmodule FailingParent do
    use Temporalex.Workflow

    def run(_args) do
      result = API.start_child_workflow(FailingChild, %{})
      {:ok, result}
    end
  end

  defmodule WorkflowIdParent do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, _} =
        API.start_child_workflow(DoublerChild, %{"value" => 1}, workflow_id: "explicit-id-001")

      {:ok, :done}
    end
  end

  defmodule TaskQueueParent do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, _} =
        API.start_child_workflow(DoublerChild, %{"value" => 1}, task_queue: "child-queue")

      {:ok, :done}
    end
  end

  defmodule CloseTerminateParent do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, _} =
        API.start_child_workflow(DoublerChild, %{"value" => 1}, parent_close_policy: :terminate)

      {:ok, :done}
    end
  end

  defmodule CloseAbandonParent do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, _} =
        API.start_child_workflow(DoublerChild, %{"value" => 1}, parent_close_policy: :abandon)

      {:ok, :done}
    end
  end

  defmodule CancellationTypeParent do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, _} =
        API.start_child_workflow(DoublerChild, %{"value" => 1},
          cancellation_type: :wait_cancellation_completed
        )

      {:ok, :done}
    end
  end

  defmodule TimeoutParent do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.start_child_workflow(DoublerChild, %{"value" => 1}, timeout: 5_000)

      {:ok, result}
    end
  end

  # --- Tests ---

  describe "CW1 — start child workflow and get result" do
    test "parent blocks on child, gets result back" do
      {:ok, exec} = Testing.start_workflow(SimpleParent, %{"x" => 5})

      assert {:child_workflow, call} = Testing.next(exec)
      assert call.workflow_type == "Temporalex.ChildWorkflowTest.DoublerChild"
      assert call.args == %{"value" => 5}

      assert {:ok, 10} = Testing.resolve(exec, {:ok, 10})
    end
  end

  describe "CW2 — child failure propagates to parent" do
    test "child {:error, _} surfaces to parent's start_child_workflow caller" do
      {:ok, exec} = Testing.start_workflow(FailingParent, %{})

      assert {:child_workflow, _call} = Testing.next(exec)
      assert {:ok, {:error, :child_failed}} = Testing.resolve(exec, {:error, :child_failed})
    end
  end

  describe "CW3 — explicit workflow_id" do
    test "workflow_id option flows through to the call descriptor" do
      {:ok, exec} = Testing.start_workflow(WorkflowIdParent, %{})

      assert {:child_workflow, call} = Testing.next(exec)
      assert Keyword.get(call.opts, :workflow_id) == "explicit-id-001"

      assert {:ok, :done} = Testing.resolve(exec, {:ok, 2})
    end
  end

  describe "CW4 — child on different task queue" do
    test "task_queue option flows through to the call descriptor" do
      {:ok, exec} = Testing.start_workflow(TaskQueueParent, %{})

      assert {:child_workflow, call} = Testing.next(exec)
      assert Keyword.get(call.opts, :task_queue) == "child-queue"

      assert {:ok, :done} = Testing.resolve(exec, {:ok, 2})
    end
  end

  describe "CW5 — child workflow replays correctly" do
    # The Worker.Executor's replay log treats child workflow resolutions
    # exactly like activities: a `{:resolve_child_workflow_execution, ...}`
    # job becomes a `{:child_workflow, seq, result}` entry, and the next
    # `start_child_workflow` call consumes it via Replay.consume/3 — no
    # new command is emitted. Verified via the Replay module:
    test "a child_workflow entry in the replay log is consumed without re-scheduling" do
      log = [{:child_workflow, 1, 42}]

      assert {:replay, 42, []} =
               Temporalex.Worker.Replay.consume(log, :child_workflow, 1)
    end
  end

  describe "CW6 — child workflow cancel" do
    # Cancellation cascade is a server-driven flow: the parent's executor
    # sends a `cancel_child_workflow_execution` command and the server
    # delivers a resolution back. We verify the option passthrough here;
    # full cancel cascading is covered at E2E (E2E13).
    test "cancellation_type option flows through to the call descriptor" do
      {:ok, exec} = Testing.start_workflow(CancellationTypeParent, %{})

      assert {:child_workflow, call} = Testing.next(exec)

      assert Keyword.get(call.opts, :cancellation_type) ==
               :wait_cancellation_completed

      assert {:ok, :done} = Testing.resolve(exec, {:ok, 2})
    end
  end

  describe "CW7 — parent close policy: terminate" do
    test "parent_close_policy :terminate flows through to the call descriptor" do
      {:ok, exec} = Testing.start_workflow(CloseTerminateParent, %{})

      assert {:child_workflow, call} = Testing.next(exec)
      assert Keyword.get(call.opts, :parent_close_policy) == :terminate

      assert {:ok, :done} = Testing.resolve(exec, {:ok, 2})
    end
  end

  describe "CW8 — parent close policy: abandon" do
    test "parent_close_policy :abandon flows through to the call descriptor" do
      {:ok, exec} = Testing.start_workflow(CloseAbandonParent, %{})

      assert {:child_workflow, call} = Testing.next(exec)
      assert Keyword.get(call.opts, :parent_close_policy) == :abandon

      assert {:ok, :done} = Testing.resolve(exec, {:ok, 2})
    end
  end

  describe "CW9 — duplicate workflow ID" do
    # The server enforces workflow_id uniqueness; the SDK surfaces the
    # rejection as a failure resolution. We model that here as a
    # caller-driven `{:error, _}` resolve, which the parent receives like
    # any other child failure.
    test "an :already_started failure resolution is propagated to the parent" do
      {:ok, exec} = Testing.start_workflow(WorkflowIdParent, %{})

      assert {:child_workflow, _call} = Testing.next(exec)

      # The runner pattern-matches on {:ok, _} from start_child_workflow,
      # so a failure resolution here causes the runner to crash with
      # MatchError — surfaces as {:error, {:crashed, _}}.
      assert {:error, {:crashed, _}} =
               Testing.resolve(exec, {:error, :workflow_already_started})
    end
  end

  describe "CW10 — child workflow timeout" do
    test "timeout option flows through to the call descriptor" do
      {:ok, exec} = Testing.start_workflow(TimeoutParent, %{})

      assert {:child_workflow, call} = Testing.next(exec)
      assert Keyword.get(call.opts, :timeout) == 5_000

      # When the server enforces the timeout, it sends a failure resolution.
      assert {:ok, {:error, :timeout}} = Testing.resolve(exec, {:error, :timeout})
    end
  end
end
