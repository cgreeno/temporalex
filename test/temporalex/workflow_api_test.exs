defmodule Temporalex.WorkflowAPITest do
  @moduledoc """
  Unit tests for the process-per-workflow model.
  Tests the Workflow.API functions via process dictionary.
  """
  use ExUnit.Case, async: true
  use Temporalex.Testing

  alias Temporalex.Workflow.API

  # --- Test modules ---

  defmodule SimpleWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(_args), do: {:ok, "done"}
  end

  defmodule StatefulWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(args) do
      set_state(%{input: args, step: 1})
      assert_state = get_state()
      {:ok, assert_state}
    end
  end

  defmodule InfoWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(_args) do
      info = workflow_info()
      {:ok, info}
    end
  end

  defmodule DummyActivity do
    use Temporalex.Activity

    @impl true
    def perform(_ctx, _input), do: {:ok, "dummy"}
  end

  defmodule FakeExecutor do
    use GenServer

    def init(_), do: {:ok, nil}

    def handle_call({:yield, _state}, _from, state) do
      {:reply, :ok, state}
    end
  end

  # --- Tests ---

  describe "workflow with no activities" do
    test "completes synchronously" do
      assert {:ok, "done"} = SimpleWorkflow.run(nil)
    end
  end

  describe "set_state/get_state" do
    test "stores and retrieves state in process dictionary" do
      task =
        Task.async(fn ->
          API.set_state(%{counter: 42})
          API.get_state()
        end)

      assert %{counter: 42} = Task.await(task)
    end
  end

  describe "workflow_info/0" do
    test "returns workflow metadata from workflow_info dict" do
      task =
        Task.async(fn ->
          Process.put(:__temporal_workflow_info__, %{
            workflow_id: "wf-info-1",
            run_id: "run-info-1",
            workflow_type: "InfoWorkflow",
            task_queue: "info-queue",
            namespace: "test-ns",
            attempt: 3
          })

          API.workflow_info()
        end)

      info = Task.await(task)
      assert info.workflow_id == "wf-info-1"
      assert info.run_id == "run-info-1"
      assert info.task_queue == "info-queue"
      assert info.attempt == 3
    end
  end

  describe "side_effect/1 in executor mode" do
    test "executes function on first run" do
      task =
        Task.async(fn ->
          {:ok, executor} =
            Temporalex.WorkflowTaskExecutor.start(
              server_pid: self(),
              run_id: "run-se-1",
              task_queue: "q",
              run_fn: fn _ -> {:ok, "done"} end,
              replay_results: %{},
              workflow_info: %{}
            )

          Process.put(:__temporal_executor__, executor)
          result = API.side_effect(fn -> 42 end)
          GenServer.stop(executor)
          result
        end)

      assert 42 = Task.await(task)
    end

    test "returns error tuple on replay when seq has recorded result" do
      task =
        Task.async(fn ->
          {:ok, executor} =
            Temporalex.WorkflowTaskExecutor.start(
              server_pid: self(),
              run_id: "run-se-2",
              task_queue: "q",
              run_fn: fn _ -> {:ok, "done"} end,
              replay_results: %{0 => {:activity, {:ok, "old"}}},
              workflow_info: %{}
            )

          Process.put(:__temporal_executor__, executor)
          API.side_effect(fn -> :rand.uniform() end)
        end)

      assert {:error, msg} = Task.await(task)
      assert msg =~ "side_effect replay not yet supported"
    end
  end

  describe "executor-mode signal buffering" do
    test "non-target signals are buffered, not dropped" do
      runner =
        Task.async(fn ->
          {:ok, executor} =
            GenServer.start_link(Temporalex.WorkflowAPITest.FakeExecutor, nil)

          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_signal_buffer__, [])
          Process.put(:__temporal_state__, nil)

          # Pre-send signals: non-target first, then the target
          send(self(), {:signal, "other_signal", %{"data" => "buffered"}})
          send(self(), {:signal, "target_signal", %{"data" => "found"}})

          result = API.wait_for_signal("target_signal")
          buffer = Process.get(:__temporal_signal_buffer__, [])

          GenServer.stop(executor)
          {result, buffer}
        end)

      {result, buffer} = Task.await(runner)
      assert {:ok, %{"data" => "found"}} = result
      assert [{"other_signal", %{"data" => "buffered"}}] = buffer
    end

    test "buffered signal is returned immediately on next wait_for_signal" do
      runner =
        Task.async(fn ->
          {:ok, executor} =
            GenServer.start_link(Temporalex.WorkflowAPITest.FakeExecutor, nil)

          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_state__, nil)

          # Pre-buffer a signal (as if a previous wait_for_signal stored it)
          API.buffer_signal("pre_buffered", %{"early" => true})

          # This should return immediately from the buffer without blocking
          result = API.wait_for_signal("pre_buffered")

          GenServer.stop(executor)
          result
        end)

      assert {:ok, %{"early" => true}} = Task.await(runner)
    end
  end

  describe "replay: pre-loaded results consumed without re-issuing commands" do
    test "execute_activity returns replay result without yielding" do
      test_pid = self()

      task =
        Task.async(fn ->
          {:ok, executor} =
            Temporalex.WorkflowTaskExecutor.start(
              server_pid: test_pid,
              run_id: "run-replay-1",
              task_queue: "q",
              run_fn: fn _ -> {:ok, "done"} end,
              replay_results: %{0 => {:activity, {:ok, "replayed_value"}}},
              workflow_info: %{}
            )

          Process.put(:__temporal_executor__, executor)
          Process.put(:__temporal_workflow_info__, %{})
          Process.put(:__temporal_state__, nil)

          # This should NOT block because seq 0 is in replay_results
          result =
            API.execute_activity(Temporalex.WorkflowAPITest.DummyActivity, %{},
              start_to_close_timeout: 30_000
            )

          GenServer.stop(executor)
          result
        end)

      assert {:ok, "replayed_value"} = Task.await(task)
    end
  end
end
