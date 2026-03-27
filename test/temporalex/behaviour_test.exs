defmodule Temporalex.BehaviourTest do
  @moduledoc """
  Tests that workflow and activity behaviours compile and work correctly.
  Updated for Phase 2.5: run/1, no ctx threading, process-dictionary API.
  """
  use ExUnit.Case, async: true

  # --- Test workflow module ---

  defmodule TestGreeterWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(args) do
      name = (is_map(args) && args["name"]) || "world"
      {:ok, "Hello, #{name}!"}
    end
  end

  defmodule TestSignalWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(_args) do
      set_state(%{items: []})
      {:ok, get_state()}
    end

    @impl true
    def handle_signal("add_item", item, state) do
      {:noreply, %{state | items: [item | state.items]}}
    end

    @impl true
    def handle_query("get_items", _args, state) do
      {:reply, state.items}
    end
  end

  # --- Test activity module ---

  defmodule TestGreetActivity do
    use Temporalex.Activity

    @impl true
    def perform(_ctx, %{"name" => name}) do
      {:ok, "Hello, #{name}!"}
    end

    def perform(_ctx, _input) do
      {:ok, "Hello, world!"}
    end
  end

  # --- Tests ---

  describe "Workflow behaviour" do
    test "workflow module defines __workflow_type__" do
      assert TestGreeterWorkflow.__workflow_type__() ==
               "Temporalex.BehaviourTest.TestGreeterWorkflow"
    end

    test "workflow run/1 returns {:ok, result}" do
      assert {:ok, "Hello, Chris!"} = TestGreeterWorkflow.run(%{"name" => "Chris"})
    end

    test "default handle_signal returns {:noreply, state}" do
      assert {:noreply, :some_state} =
               TestGreeterWorkflow.handle_signal("unknown", nil, :some_state)
    end

    test "custom handle_signal updates state" do
      assert {:noreply, %{items: ["item1"]}} =
               TestSignalWorkflow.handle_signal("add_item", "item1", %{items: []})
    end

    test "custom handle_query returns state data" do
      assert {:reply, ["a", "b"]} =
               TestSignalWorkflow.handle_query("get_items", nil, %{items: ["a", "b"]})
    end
  end

  describe "Activity behaviour" do
    test "activity module defines __activity_type__" do
      assert TestGreetActivity.__activity_type__() ==
               "Temporalex.BehaviourTest.TestGreetActivity"
    end

    test "activity perform/2 returns {:ok, result}" do
      ctx = %Temporalex.Activity.Context{
        activity_id: "0",
        activity_type: "greet",
        task_token: <<>>,
        task_queue: "test-queue"
      }

      assert {:ok, "Hello, Chris!"} = TestGreetActivity.perform(ctx, %{"name" => "Chris"})
    end

    test "activity perform/2 handles missing input" do
      ctx = %Temporalex.Activity.Context{
        activity_id: "0",
        activity_type: "greet",
        task_token: <<>>,
        task_queue: "test-queue"
      }

      assert {:ok, "Hello, world!"} = TestGreetActivity.perform(ctx, %{})
    end
  end
end
