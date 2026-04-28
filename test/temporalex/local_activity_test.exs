defmodule Temporalex.LocalActivityTest do
  @moduledoc """
  Local activity primitive — the safe replacement for `side_effect/1`.

  Unit-level coverage of the dispatch path. Live execution requires the
  Core SDK runtime; see e2e_test.exs for an integration test.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  defmodule Acts do
    use Temporalex.Activity

    defactivity make_id(prefix), local: true do
      {:ok, "#{prefix}-#{System.unique_integer([:positive])}"}
    end

    defactivity normal_op(x) do
      {:ok, x * 2}
    end
  end

  defmodule MixedWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, id} = Acts.make_id("order")
      {:ok, doubled} = Acts.normal_op(7)
      {:ok, %{id: id, doubled: doubled}}
    end
  end

  describe "dispatch path" do
    test "defactivity ..., local: true emits a :local_activity descriptor" do
      {:ok, exec} = Testing.start_workflow(MixedWorkflow, %{})

      assert {:local_activity, call} = Testing.next(exec)
      assert call.type == "Temporalex.LocalActivityTest.Acts.make_id"
      assert call.input == ["order"]

      # Resolve local activity → next descriptor is the regular activity
      assert {:activity, call} = Testing.resolve(exec, {:ok, "order-42"})
      assert call.type == "Temporalex.LocalActivityTest.Acts.normal_op"
      assert call.input == [7]

      assert {:ok, %{id: "order-42", doubled: 14}} =
               Testing.resolve(exec, {:ok, 14})
    end

    test "regular and local activities each carry their own opts through the descriptor" do
      {:ok, exec} = Testing.start_workflow(MixedWorkflow, %{})

      assert {:local_activity, call} = Testing.next(exec)
      # `local: true` is reflected in the opts the workflow API receives.
      assert Keyword.get(call.opts, :local) == true

      # Resolving returns the NEXT descriptor — capture it.
      assert {:activity, call} = Testing.resolve(exec, {:ok, "x"})
      refute Keyword.has_key?(call.opts, :local)

      Testing.resolve(exec, {:ok, 14})
    end
  end

  describe "explicit API" do
    defmodule ExplicitWorkflow do
      use Temporalex.Workflow

      def run(_args) do
        result =
          API.execute_local_activity(
            "MyApp.Activities.GenerateId",
            ["order"],
            start_to_close_timeout_ms: 5_000
          )

        {:ok, result}
      end
    end

    test "API.execute_local_activity routes through {:local_activity, _}" do
      {:ok, exec} = Testing.start_workflow(ExplicitWorkflow, %{})

      assert {:local_activity, call} = Testing.next(exec)
      assert call.type == "MyApp.Activities.GenerateId"
      assert Keyword.get(call.opts, :start_to_close_timeout_ms) == 5_000

      assert {:ok, "the-id"} = Testing.resolve(exec, "the-id")
    end
  end
end
