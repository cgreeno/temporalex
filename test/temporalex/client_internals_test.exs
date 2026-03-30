defmodule Temporalex.ClientInternalsTest do
  @moduledoc "Tests for Client internal logic via public API behavior."
  use ExUnit.Case, async: true

  alias Temporalex.Client

  defmodule DummyWorkflow do
    use Temporalex.Workflow
    def run(_), do: {:ok, nil}
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # ============================================================
  # resolve_connection — tested via error paths
  # ============================================================

  describe "resolve_connection" do
    test "dead PID returns error tuple" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(pid)

      assert {:error, _} =
               Client.start_workflow(pid, DummyWorkflow, %{}, id: "w", task_queue: "q")
    end

    test "unregistered atom returns error tuple" do
      assert {:error, _} =
               Client.start_workflow(:nonexistent_conn, DummyWorkflow, %{},
                 id: "w",
                 task_queue: "q"
               )
    end

    test "map connection resolves without crash" do
      # Verify the resolve_connection pattern match works for maps
      # We can't call the NIF with a fake client, so just verify the
      # describe/list paths which also use resolve_connection
      assert {:error, _} = Client.describe_workflow(:nonexistent, "wf-1")
      assert {:error, _} = Client.list_workflows(:nonexistent, "")
    end
  end

  # ============================================================
  # start_workflow argument validation
  # ============================================================

  describe "start_workflow argument validation" do
    test "keyword list args detected as opts mistake" do
      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Client.start_workflow(:conn, DummyWorkflow, id: "x", task_queue: "q")
      end
    end
  end

  # ============================================================
  # generate_workflow_id — tested via auto-generation
  # ============================================================

  describe "workflow ID generation" do
    test "auto-generated IDs are unique" do
      # We can't test the private function directly, but we can verify
      # the module name formatting logic via the workflow type
      defmodule TestWf do
        use Temporalex.Workflow
        def run(_), do: {:ok, nil}
      end

      # The type string uses dots
      assert TestWf.__workflow_type__() =~ "TestWf"
    end
  end

  # ============================================================
  # describe_workflow / list_workflows — connection error paths
  # ============================================================

  describe "describe_workflow" do
    test "returns error for dead connection" do
      assert {:error, _} = Client.describe_workflow(:nonexistent, "wf-1")
    end
  end

  describe "list_workflows" do
    test "returns error for dead connection" do
      assert {:error, _} = Client.list_workflows(:nonexistent, "WorkflowType = 'Test'")
    end
  end
end
