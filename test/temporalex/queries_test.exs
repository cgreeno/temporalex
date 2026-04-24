defmodule Temporalex.QueriesTest do
  @moduledoc """
  Priority 2 — Queries (Q1-Q8) from TESTS_V2.md.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test activity ---

  defmodule Acts do
    use Temporalex.Activity

    defactivity(work(x), do: {:ok, x})
  end

  # --- Test workflows ---

  defmodule PublishingWorkflow do
    use Temporalex.Workflow

    def handle_query("status", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(%{step: :init})
      {:ok, _} = Acts.work(:a)
      API.publish_state(%{step: :done, value: 42})
      {:ok, :finished}
    end
  end

  defmodule NoPublishWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, _} = Acts.work(:a)
      {:ok, :finished}
    end
  end

  defmodule QueryArgsWorkflow do
    use Temporalex.Workflow

    def handle_query("pick", [key], state), do: {:reply, Map.get(state, key)}

    def run(_args) do
      API.publish_state(%{"a" => 1, "b" => 2, "c" => 3})
      {:ok, _} = Acts.work(:a)
      {:ok, :done}
    end
  end

  defmodule ReceivingWorkflow do
    use Temporalex.Workflow

    def handle_query("phase", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(:awaiting_signal)

      result =
        API.receive(:in_loop,
          signal: %{
            "done" => fn _payload, state -> {:stop, state} end
          }
        )

      {:ok, result}
    end
  end

  defmodule CrashQueryWorkflow do
    use Temporalex.Workflow

    def handle_query("ok", _args, state), do: {:reply, state}
    def handle_query("boom", _args, _state), do: raise("query exploded")

    def run(_args) do
      API.publish_state(:alive)
      {:ok, _} = Acts.work(:a)
      {:ok, :finished}
    end
  end

  defmodule MultiQueryWorkflow do
    use Temporalex.Workflow

    def handle_query("count", _args, state), do: {:reply, map_size(state)}
    def handle_query("keys", _args, state), do: {:reply, Map.keys(state) |> Enum.sort()}
    def handle_query("dump", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(%{"x" => 1, "y" => 2, "z" => 3})
      {:ok, _} = Acts.work(:a)
      {:ok, :done}
    end
  end

  # --- Tests ---

  describe "Q1 — query returns published state" do
    test "query reflects the latest publish_state" do
      {:ok, exec} = Testing.start_workflow(PublishingWorkflow, %{})

      assert {:activity, _} = Testing.next(exec)
      assert {:reply, %{step: :init}} = Testing.query(exec, "status")

      assert {:ok, :finished} = Testing.resolve(exec, {:ok, :a})
      assert {:reply, %{step: :done, value: 42}} = Testing.query(exec, "status")
    end
  end

  describe "Q2 — unpublished state returns nil" do
    test "default handle_query replies with nil when no state has been published" do
      {:ok, exec} = Testing.start_workflow(NoPublishWorkflow, %{})

      assert {:activity, _} = Testing.next(exec)
      assert {:reply, nil} = Testing.query(exec, "anything")
    end
  end

  describe "Q3 — query with arguments" do
    test "handler receives args and can filter published state" do
      {:ok, exec} = Testing.start_workflow(QueryArgsWorkflow, %{})
      assert {:activity, _} = Testing.next(exec)

      assert {:reply, 1} = Testing.query(exec, "pick", ["a"])
      assert {:reply, 3} = Testing.query(exec, "pick", ["c"])
      assert {:reply, nil} = Testing.query(exec, "pick", ["missing"])
    end
  end

  describe "Q4 — query during receive" do
    test "query responds while the workflow is waiting in a receive loop" do
      {:ok, exec} = Testing.start_workflow(ReceivingWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:reply, :awaiting_signal} = Testing.query(exec, "phase")

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, :in_loop} = Testing.next(exec)
    end
  end

  describe "Q5 — query while blocked on activity" do
    test "query responds while the workflow is waiting on an activity result" do
      {:ok, exec} = Testing.start_workflow(PublishingWorkflow, %{})

      assert {:activity, _} = Testing.next(exec)
      # Workflow is blocked; query must still work.
      assert {:reply, %{step: :init}} = Testing.query(exec, "status")
    end
  end

  describe "Q6 — handler exception does not crash workflow" do
    test "raising handler returns {:error, _}; workflow continues" do
      {:ok, exec} = Testing.start_workflow(CrashQueryWorkflow, %{})
      assert {:activity, _} = Testing.next(exec)

      assert {:reply, {:error, message}} = Testing.query(exec, "boom")
      assert message =~ "query exploded"

      # Other queries still work.
      assert {:reply, :alive} = Testing.query(exec, "ok")

      # Workflow still runs to completion.
      assert {:ok, :finished} = Testing.resolve(exec, {:ok, :a})
    end
  end

  describe "Q7 — multiple query types on same workflow" do
    test "each registered handler_query clause is routable by name" do
      {:ok, exec} = Testing.start_workflow(MultiQueryWorkflow, %{})
      assert {:activity, _} = Testing.next(exec)

      assert {:reply, 3} = Testing.query(exec, "count")
      assert {:reply, ["x", "y", "z"]} = Testing.query(exec, "keys")
      assert {:reply, %{"x" => 1, "y" => 2, "z" => 3}} = Testing.query(exec, "dump")
    end
  end

  describe "Q8 — query on completed workflow" do
    test "query returns the last published state after workflow completes" do
      {:ok, exec} = Testing.start_workflow(PublishingWorkflow, %{})

      assert {:activity, _} = Testing.next(exec)
      assert {:ok, :finished} = Testing.resolve(exec, {:ok, :a})

      # Workflow is done; last published state is still queryable.
      assert {:reply, %{step: :done, value: 42}} = Testing.query(exec, "status")
    end
  end
end
