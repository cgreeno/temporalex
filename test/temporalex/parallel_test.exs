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

      # Both branches block on activities. We need to resolve both.
      # The parallel branches spawn immediately, so we should see two activities.
      # But the test executor sees them as individual blocking calls from separate processes.
      # Each branch calls its activity, which blocks on GenServer.call to executor.
      # The executor sees two pending execute_activity calls.

      # First activity from one branch
      assert {:activity, _} = Testing.next(exec)

      # Resolve first, second branch's activity appears
      assert {:activity, _} = Testing.resolve(exec, {:ok, %{id: "u1"}})

      # Resolve second — workflow completes
      assert {:ok, result} = Testing.resolve(exec, {:ok, %{tenant: "t1"}})
      assert result.user.id == "u1"
      assert result.config.tenant == "t1"
    end
  end
end
