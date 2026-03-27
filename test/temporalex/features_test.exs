defmodule Temporalex.FeaturesTest do
  use ExUnit.Case, async: true
  use Temporalex.Testing

  alias Temporalex.Workflow.API

  # ============================================================
  # Test workflow modules
  # ============================================================

  defmodule CounterWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(%{page: page}) do
      if page >= 3 do
        {:ok, "done at page #{page}"}
      else
        continue_as_new(%{page: page + 1})
      end
    end
  end

  defmodule ParentWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(_args) do
      {:ok, result} =
        execute_child_workflow(ChildWorkflow, %{msg: "hello"},
          id: "child-1",
          task_queue: "test-queue"
        )

      {:ok, "parent got: #{result}"}
    end
  end

  defmodule ChildWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(%{msg: msg}) do
      {:ok, "child says: #{msg}"}
    end
  end

  defmodule UpdatableWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(_args) do
      set_state(%{counter: 0})
      {:ok, "done"}
    end
  end

  defmodule QuickLookup do
    use Temporalex.Activity,
      start_to_close_timeout: 5_000

    @impl true
    def perform(%{id: id}), do: {:ok, "found-#{id}"}
  end

  defmodule SearchAttrWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(_args) do
      upsert_search_attributes(%{"CustomField" => "test_value", "Priority" => 5})
      {:ok, "done"}
    end
  end

  # ============================================================
  # Continue-as-new tests
  # ============================================================

  describe "continue_as_new" do
    test "raises ContinueAsNew exception" do
      workflow_context()

      assert_raise Temporalex.Error.ContinueAsNew, fn ->
        API.continue_as_new(%{page: 2})
      end
    end

    test "ContinueAsNew carries workflow type and task queue from context" do
      workflow_context(workflow_type: "MyWorkflow", task_queue: "my-queue")

      err = catch_error(API.continue_as_new(%{page: 2}))

      assert err.workflow_type == "MyWorkflow"
      assert err.task_queue == "my-queue"
      assert err.args == [%{page: 2}]
    end

    test "ContinueAsNew allows overriding workflow type and task queue" do
      workflow_context(workflow_type: "OriginalWorkflow", task_queue: "original-queue")

      err =
        catch_error(
          API.continue_as_new(%{page: 2},
            workflow_type: "NewWorkflow",
            task_queue: "new-queue"
          )
        )

      assert err.workflow_type == "NewWorkflow"
      assert err.task_queue == "new-queue"
    end

    test "ContinueAsNew with no args" do
      workflow_context()

      err = catch_error(API.continue_as_new())
      assert err.args == []
    end
  end

  # ============================================================
  # Child workflow tests (via executor)
  # ============================================================

  describe "execute_child_workflow" do
    test "builds start_child_workflow_execution command and resolves" do
      test_pid = self()

      # Start executor with ourselves as server_pid so we receive commands
      {:ok, executor} =
        Temporalex.WorkflowTaskExecutor.start(
          server_pid: test_pid,
          run_id: "run-child-1",
          task_queue: "test-queue",
          run_fn: fn _ -> {:ok, "done"} end,
          replay_results: %{},
          workflow_info: %{}
        )

      task =
        Task.async(fn ->
          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_workflow_info__, %{})
          Process.put(:__temporal_state__, nil)

          API.execute_child_workflow(ChildWorkflow, %{msg: "hi"}, id: "child-1")
        end)

      # Executor sends commands to us
      assert_receive {:executor_commands, "run-child-1", commands, _state, :yielded}, 1000
      assert length(commands) == 1
      [cmd] = commands
      assert {:start_child_workflow_execution, start} = cmd.variant
      assert start.workflow_id == "child-1"
      assert start.workflow_type == "Temporalex.FeaturesTest.ChildWorkflow"

      # Resolve the pending child workflow (seq 0)
      send(executor, {:resolve_activity, 0, {:ok, "child result"}})

      assert {:ok, "child result"} = Task.await(task)
      GenServer.stop(executor)
    end

    test "child workflow replays from history without blocking" do
      test_pid = self()

      task =
        Task.async(fn ->
          {:ok, executor} =
            Temporalex.WorkflowTaskExecutor.start(
              server_pid: test_pid,
              run_id: "run-child-replay",
              task_queue: "test-queue",
              run_fn: fn _ -> {:ok, "done"} end,
              replay_results: %{0 => {:activity, {:ok, "child result"}}},
              workflow_info: %{}
            )

          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_workflow_info__, %{})
          Process.put(:__temporal_state__, nil)

          result =
            API.execute_child_workflow(ChildWorkflow, %{msg: "hi"}, id: "child-1")

          GenServer.stop(executor)
          result
        end)

      assert {:ok, "child result"} = Task.await(task)
    end
  end

  # ============================================================
  # Search attributes tests (via executor)
  # ============================================================

  describe "upsert_search_attributes" do
    test "adds upsert command via executor" do
      test_pid = self()

      task =
        Task.async(fn ->
          {:ok, executor} =
            Temporalex.WorkflowTaskExecutor.start(
              server_pid: test_pid,
              run_id: "run-search",
              task_queue: "test-queue",
              run_fn: fn _ -> {:ok, "done"} end,
              replay_results: %{},
              workflow_info: %{}
            )

          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_workflow_info__, %{})
          Process.put(:__temporal_state__, nil)

          API.upsert_search_attributes(%{"Status" => "active", "Priority" => 1})

          GenServer.stop(executor)
          :ok
        end)

      assert :ok = Task.await(task)
    end
  end

  # ============================================================
  # Error type tests
  # ============================================================

  describe "error types" do
    test "ContinueAsNew is a proper exception" do
      err = %Temporalex.Error.ContinueAsNew{
        workflow_type: "MyWorkflow",
        task_queue: "q",
        args: [1, 2],
        opts: []
      }

      assert Exception.message(err) == "continue_as_new"
    end

    test "ChildWorkflowFailure formats message" do
      err = %Temporalex.Error.ChildWorkflowFailure{
        message: "timed out",
        workflow_type: "OrderWorkflow",
        workflow_id: "order-123"
      }

      assert Exception.message(err) =~ "Child workflow failed"
      assert Exception.message(err) =~ "OrderWorkflow"
    end
  end

  # ============================================================
  # Patching / versioning tests
  # ============================================================

  describe "patched?" do
    test "returns true when patch is pre-notified" do
      workflow_context(patches: ["use-new-algo"])
      assert API.patched?("use-new-algo") == true
    end

    test "returns true on first execution via executor and emits set_patch_marker" do
      test_pid = self()

      task =
        Task.async(fn ->
          {:ok, executor} =
            Temporalex.WorkflowTaskExecutor.start(
              server_pid: test_pid,
              run_id: "run-patch-1",
              task_queue: "test-queue",
              run_fn: fn _ -> {:ok, "done"} end,
              replay_results: %{},
              workflow_info: %{}
            )

          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_workflow_info__, %{})
          Process.put(:__temporal_state__, nil)
          Process.put(:__temporal_patches__, MapSet.new())

          result = API.patched?("use-new-algo")
          GenServer.stop(executor)
          result
        end)

      assert true = Task.await(task)
    end

    test "deprecate_patch emits deprecated marker via executor" do
      test_pid = self()

      task =
        Task.async(fn ->
          {:ok, executor} =
            Temporalex.WorkflowTaskExecutor.start(
              server_pid: test_pid,
              run_id: "run-patch-2",
              task_queue: "test-queue",
              run_fn: fn _ -> {:ok, "done"} end,
              replay_results: %{},
              workflow_info: %{}
            )

          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_workflow_info__, %{})
          Process.put(:__temporal_state__, nil)
          Process.put(:__temporal_patches__, MapSet.new())

          API.deprecate_patch("old-patch")
          GenServer.stop(executor)
          :ok
        end)

      assert :ok = Task.await(task)
    end
  end

  # ============================================================
  # Cancellation tests
  # ============================================================

  describe "cancelled?" do
    test "returns false by default" do
      workflow_context()
      assert API.cancelled?() == false
    end

    test "returns true after cancel flag set" do
      workflow_context()
      Process.put(:__temporal_cancelled__, true)
      assert API.cancelled?() == true
    end
  end

  # ============================================================
  # Local activity tests (via executor)
  # ============================================================

  describe "execute_local_activity" do
    test "replays from history without blocking" do
      test_pid = self()

      task =
        Task.async(fn ->
          {:ok, executor} =
            Temporalex.WorkflowTaskExecutor.start(
              server_pid: test_pid,
              run_id: "run-local-1",
              task_queue: "test-queue",
              run_fn: fn _ -> {:ok, "done"} end,
              replay_results: %{0 => {:activity, {:ok, "local result"}}},
              workflow_info: %{}
            )

          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_workflow_info__, %{})
          Process.put(:__temporal_state__, nil)

          result = API.execute_local_activity(QuickLookup, %{id: 1})
          GenServer.stop(executor)
          result
        end)

      assert {:ok, "local result"} = Task.await(task)
    end

    test "stubs work for local activities too" do
      workflow_context()
      stub_activity(QuickLookup, fn %{id: id} -> {:ok, "stub-#{id}"} end)

      assert {:ok, "stub-42"} = API.execute_local_activity(QuickLookup, %{id: 42})
      assert_activity_called(QuickLookup, %{id: 42})
    end
  end
end
