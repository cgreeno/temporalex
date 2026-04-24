defmodule Temporalex.ParallelTest do
  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test activities ---

  defmodule Activities.Processor do
    use Temporalex.Activity

    defactivity run(item) do
      _ = item
      {:ok, :processed}
    end
  end

  defmodule Activities.Users do
    use Temporalex.Activity

    defactivity fetch(user_id) do
      _ = user_id
      {:ok, %{id: user_id}}
    end
  end

  defmodule Activities.Config do
    use Temporalex.Activity

    defactivity load(tenant) do
      _ = tenant
      {:ok, %{tenant: tenant}}
    end
  end

  # --- Test workflows ---

  defmodule FanOutWorkflow do
    use Temporalex.Workflow

    def run(%{"items" => items}) do
      results =
        API.parallel(
          Enum.map(items, fn item ->
            fn -> Activities.Processor.run(item) end
          end)
        )

      failures = Enum.filter(results, &match?({:error, _}, &1))

      if failures == [] do
        {:ok, %{processed: length(results)}}
      else
        {:error, %{failures: length(failures)}}
      end
    end
  end

  defmodule TwoBranchWorkflow do
    use Temporalex.Workflow

    def run(args) do
      [{:ok, user}, {:ok, config}] =
        API.parallel([
          fn -> Activities.Users.fetch(args["user_id"]) end,
          fn -> Activities.Config.load(args["tenant"]) end
        ])

      {:ok, %{user: user, config: config}}
    end
  end

  # --- Tests ---

  describe "parallel" do
    test "two branches run concurrently" do
      {:ok, exec} =
        Testing.start_workflow(TwoBranchWorkflow, %{
          "user_id" => "u1",
          "tenant" => "t1"
        })

      # Mailbox arrival order from concurrent branches is nondeterministic.
      # Resolve each activity using its own input so each branch receives
      # what it asked for, regardless of order.
      assert {:activity, c1} = Testing.next(exec)
      assert {:activity, c2} = Testing.resolve(exec, response_for(hd(c1.input)))

      assert {:ok, result} = Testing.resolve(exec, response_for(hd(c2.input)))
      assert result.user.id == "u1"
      assert result.config.tenant == "t1"
    end

    defp response_for("u1"), do: {:ok, %{id: "u1"}}
    defp response_for("t1"), do: {:ok, %{tenant: "t1"}}
  end
end
