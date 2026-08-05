defmodule Temporalex.ActivityNameResolutionTest do
  @moduledoc """
  A `name:`-renamed activity must resolve server-side by its wire type — and
  ONLY by it. The failure mode this pins is the worst one in RFC 0003:
  a rename stranding in-flight workflows.
  """
  use ExUnit.Case, async: false

  alias Temporalex.Backend.Test, as: TestBackend

  defmodule Acts do
    use Temporalex.Activity

    defactivity charge(amount), name: "bookings.charge" do
      {:ok, {:charged, amount}}
    end
  end

  defmodule WF do
    use Temporalex.Workflow
    def run(v), do: {:ok, v}
  end

  setup do
    name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    start_supervised!({Temporalex.Client, name: client, backend: TestBackend})

    start_supervised!(
      {Temporalex.Worker,
       name: name,
       client: client,
       backend: TestBackend,
       test_owner: self(),
       namespace: "default",
       task_queue: "probe9",
       workflows: [WF],
       activities: [Acts]}
    )

    %{worker: name}
  end

  test "the renamed wire type resolves server-side", %{worker: worker} do
    assert :ok =
             TestBackend.send_activity_task(worker, %Temporalex.Core.ActivityTask{
               task_token: "tok-renamed",
               activity_id: "a1",
               activity_type: "bookings.charge",
               input: [42],
               variant: :start
             })

    assert %Temporalex.Core.ActivityCompletion{result: {:ok, {:charged, 42}}} =
             TestBackend.fetch_activity_completion(worker, "tok-renamed")
  end

  test "the module-derived type is NOT registered when name: is set", %{worker: worker} do
    assert :ok =
             TestBackend.send_activity_task(worker, %Temporalex.Core.ActivityTask{
               task_token: "tok-old",
               activity_id: "a2",
               activity_type: "#{inspect(Acts)}.charge",
               input: [42],
               variant: :start
             })

    assert %Temporalex.Core.ActivityCompletion{result: {:error, err}} =
             TestBackend.fetch_activity_completion(worker, "tok-old")

    assert err.type == "UnknownActivityType"
  end
end
