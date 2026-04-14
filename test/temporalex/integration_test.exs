defmodule Temporalex.IntegrationTest do
  @moduledoc """
  Integration tests that require a running Temporal server at localhost:7233.
  Run with: mix test --include integration
  """

  use ExUnit.Case

  @moduletag :integration

  # --- Test activity module ---

  defmodule Activities.Math do
    use Temporalex.Activity

    defactivity add(a, b) do
      {:ok, a + b}
    end

    defactivity multiply(a, b) do
      {:ok, a * b}
    end
  end

  # --- Test workflow modules ---

  defmodule SimpleWorkflow do
    use Temporalex.Workflow

    def run(args) do
      {:ok, sum} = Activities.Math.add(args["a"], args["b"])
      {:ok, sum}
    end
  end

  defmodule TwoStepWorkflow do
    use Temporalex.Workflow

    def handle_query("result", _args, state), do: {:reply, state}

    def run(args) do
      {:ok, sum} = Activities.Math.add(args["a"], args["b"])
      API.publish_state(%{step: :added, sum: sum})
      {:ok, product} = Activities.Math.multiply(sum, args["c"])
      API.publish_state(%{step: :done, product: product})
      {:ok, %{sum: sum, product: product}}
    end
  end

  # --- Tests ---

  setup_all do
    # Start a worker for the integration test task queue
    task_queue = "temporalex-integration-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Temporalex.Worker.start_link(
        url: "http://localhost:7233",
        namespace: "default",
        task_queue: task_queue,
        workflows: [SimpleWorkflow, TwoStepWorkflow],
        activities: [Activities.Math],
        name: :"test_worker_#{task_queue}"
      )

    # Give the worker time to connect and start poll loops
    Process.sleep(2000)

    {:ok, runtime} = Temporalex.Runtime.get()

    %{task_queue: task_queue, runtime: runtime}
  end

  @tag timeout: 30_000
  test "simple workflow: one activity", %{task_queue: task_queue} do
    workflow_id = "simple-#{System.unique_integer([:positive])}"

    # Start workflow via temporal CLI
    {output, 0} =
      System.cmd("temporal", [
        "workflow",
        "start",
        "--type",
        "Temporalex.IntegrationTest.SimpleWorkflow",
        "--task-queue",
        task_queue,
        "--workflow-id",
        workflow_id,
        "--input",
        ~s({"a": 3, "b": 4}),
        "--output",
        "json"
      ])

    assert output =~ workflow_id

    # Wait for result
    {result_output, 0} =
      System.cmd(
        "temporal",
        [
          "workflow",
          "show",
          "--workflow-id",
          workflow_id,
          "--output",
          "json",
          "--follow"
        ],
        stderr_to_stdout: true
      )

    IO.puts("Workflow result: #{result_output}")

    # The workflow should have completed
    assert result_output =~ "Completed"
  end
end
