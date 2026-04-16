defmodule Temporalex.TestingHelpersTest do
  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test modules ---

  defmodule Activities.Math do
    use Temporalex.Activity

    defactivity add(a, b) do
      {:ok, a + b}
    end
  end

  defmodule SimpleWorkflow do
    use Temporalex.Workflow

    def handle_query("total", _args, state), do: {:reply, state}

    def run(args) do
      {:ok, sum} = Activities.Math.add(args["a"], args["b"])
      API.publish_state(sum)
      {:ok, sum}
    end
  end

  defmodule SleepWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      API.sleep(5000)
      {:ok, :done}
    end
  end

  # --- Tests ---

  describe "run_workflow/3" do
    test "runs workflow with pre-loaded activity log" do
      assert {:ok, 7} =
               Testing.run_workflow(SimpleWorkflow, %{"a" => 3, "b" => 4},
                 log: [
                   {:activity, :any, {:ok, 7}}
                 ]
               )
    end

    test "runs workflow with matched activity type" do
      type = "Temporalex.TestingHelpersTest.Activities.Math.add"

      assert {:ok, 7} =
               Testing.run_workflow(SimpleWorkflow, %{"a" => 3, "b" => 4},
                 log: [{:activity, type, {:ok, 7}}]
               )
    end

    test "runs workflow with sleep" do
      assert {:ok, :done} =
               Testing.run_workflow(SleepWorkflow, %{}, log: [{:sleep, :ok}])
    end
  end

  describe "run_activity/3" do
    test "calls activity implementation directly" do
      assert {:ok, 7} = Testing.run_activity(Activities.Math, :add, [3, 4])
    end
  end

  describe "query with publish_state" do
    test "query returns published state" do
      {:ok, exec} = Testing.start_workflow(SimpleWorkflow, %{"a" => 3, "b" => 4})

      # Workflow blocks on activity after publishing state
      assert {:activity, _} = Testing.next(exec)

      # Query should return nil (publish_state hasn't been called yet — it's before the activity)
      # Actually publish_state IS called before the activity in this workflow
      assert {:reply, nil} = Testing.query(exec, "total")

      # Hmm, publish_state is after the activity. Let me re-check the workflow.
      # The workflow calls add first, then publish_state. So state is nil before resolve.

      # Resolve the activity
      assert {:ok, 7} = Testing.resolve(exec, {:ok, 7})

      # Now published_state should be 7
      assert {:reply, 7} = Testing.query(exec, "total")
    end
  end
end
