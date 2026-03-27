defmodule Temporalex.Test.GreetingWorkflow do
  @moduledoc """
  Test workflow that schedules a greet activity and returns its result.
  """
  use Temporalex.Workflow

  require Logger

  @impl true
  def run(args) do
    Logger.info("GreetingWorkflow.run/1", args: inspect(args))

    {:ok, result} =
      execute_activity(Temporalex.Test.GreetActivity, args, start_to_close_timeout: 30_000)

    {:ok, result}
  end
end

defmodule Temporalex.Test.GreetActivity do
  @moduledoc """
  Test activity that greets a name.
  """
  use Temporalex.Activity,
    start_to_close_timeout: :timer.seconds(30)

  require Logger

  # Using perform/1 — no ctx needed
  @impl true
  def perform(input) do
    name =
      cond do
        is_map(input) -> Map.get(input, :name, nil) || Map.get(input, "name", "world")
        is_binary(input) -> String.trim(input, "\"")
        is_nil(input) -> "world"
        true -> to_string(input)
      end

    Logger.info("GreetActivity.perform/1", name: name)
    {:ok, "Hello, #{name}!"}
  end
end
