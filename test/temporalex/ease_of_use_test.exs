defmodule Temporalex.EaseOfUseTest do
  @moduledoc "Tests for ease-of-use improvements: sleep guards, signal sim, child workflow stubs, converter errors."
  use ExUnit.Case, async: true
  use Temporalex.Testing

  alias Temporalex.Workflow.API

  # ============================================================
  # Test modules
  # ============================================================

  defmodule ChildProcessor do
    use Temporalex.Workflow
    def run(%{id: id}), do: {:ok, "processed-#{id}"}
  end

  defmodule ParentWorkflow do
    use Temporalex.Workflow

    def run(%{id: id}) do
      {:ok, child_result} = execute_child_workflow(ChildProcessor, %{id: id}, id: "child-#{id}")
      {:ok, "parent-#{child_result}"}
    end
  end

  defmodule SignalWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, payload} = wait_for_signal("approval")
      {:ok, "approved: #{payload}"}
    end
  end

  # ============================================================
  # sleep/1 validation
  # ============================================================

  describe "sleep/1 validation" do
    test "rejects zero duration" do
      assert_raise ArgumentError, ~r/must be positive/, fn ->
        API.sleep(0)
      end
    end

    test "rejects negative duration" do
      assert_raise ArgumentError, ~r/must be positive/, fn ->
        API.sleep(-1000)
      end
    end

    test "rejects non-integer" do
      assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
        API.sleep(1.5)
      end
    end

    test "rejects string" do
      assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
        API.sleep("5000")
      end
    end
  end

  # ============================================================
  # Signal simulation
  # ============================================================

  describe "send_signal/2" do
    test "pre-buffered signal is consumed by wait_for_signal" do
      workflow_context()
      send_signal("approval", "yes")

      # Signal is now in the buffer — wait_for_signal should return immediately
      buffer = Process.get(:__temporal_signal_buffer__, [])
      assert [{"approval", "yes"}] = buffer
    end

    test "workflow with pre-buffered signal completes" do
      assert {:ok, "approved: approved-by-admin"} =
               run_workflow(SignalWorkflow, %{}, signals: [{"approval", "approved-by-admin"}])
    end

    test "multiple signals buffered in order" do
      workflow_context()
      send_signal("first", "a")
      send_signal("second", "b")
      send_signal("first", "c")

      buffer = Process.get(:__temporal_signal_buffer__, [])
      assert [{"first", "a"}, {"second", "b"}, {"first", "c"}] = buffer
    end
  end

  # ============================================================
  # Child workflow stubs
  # ============================================================

  describe "child workflow stubs" do
    test "stub replaces executor call" do
      child_stubs = %{ChildProcessor => fn %{id: id} -> {:ok, "stubbed-#{id}"} end}

      assert {:ok, "parent-stubbed-42"} =
               run_workflow(ParentWorkflow, %{id: 42}, child_workflows: child_stubs)
    end

    test "child workflow calls are recorded" do
      child_stubs = %{ChildProcessor => fn %{id: id} -> {:ok, "s-#{id}"} end}
      run_workflow(ParentWorkflow, %{id: 99}, child_workflows: child_stubs)

      calls = get_child_workflow_calls()
      assert [{ChildProcessor, %{id: 99}}] = calls
    end

    test "assert_child_workflow_called succeeds" do
      child_stubs = %{ChildProcessor => fn _ -> {:ok, "ok"} end}
      run_workflow(ParentWorkflow, %{id: 1}, child_workflows: child_stubs)
      assert_child_workflow_called(ChildProcessor)
    end

    test "stub_child_workflow works after workflow_context" do
      workflow_context()
      stub_child_workflow(ChildProcessor, fn %{id: id} -> {:ok, "manual-#{id}"} end)

      # Now execute the parent workflow (context already set, won't be reset)
      assert {:ok, "parent-manual-5"} = ParentWorkflow.run(%{id: 5})
    end
  end

  # ============================================================
  # from_payload! error messages
  # ============================================================

  describe "from_payload! error messages" do
    test "includes encoding and data size on failure" do
      payload = %Temporal.Api.Common.V1.Payload{
        data: "not-valid-json",
        metadata: %{"encoding" => "json/plain"}
      }

      error = assert_raise RuntimeError, fn -> Temporalex.Converter.from_payload!(payload) end
      assert error.message =~ "encoding="
      assert error.message =~ "data_bytes="
      assert error.message =~ "json/plain"
    end
  end
end
