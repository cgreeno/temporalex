defmodule Temporalex.PriorityIntegrationTest do
  @moduledoc """
  Coverage for the `:priority` start option — task priority and fairness.

  ## What is asserted

  That the option is accepted end to end, that omitting it is unchanged, and
  that the three documented limits are enforced with clear errors.

  ## What is NOT asserted, and why

  That the server *records* the priority. It does not, on the dev server this
  suite runs against (`temporalio/auto-setup:1.27`) — `describe` and the
  WorkflowExecutionStarted event both report `priority: null`.

  That is not a bug here. Starting a workflow with `temporal workflow start
  --priority-key 2 --fairness-key ... --fairness-weight 2.5` — Temporal's own
  client — produces `null` on the same server. The field is sent the way
  sdk-rust sends it (`StartWorkflowExecutionRequest.priority`); recording it
  needs a newer server. Asserting round-trip here would mean writing a test
  that can only fail for reasons unrelated to this code.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Workflow do
    use Temporalex.Workflow

    def run(n), do: {:ok, n}
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    task_queue = "priority-#{System.unique_integer([:positive])}"
    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    worker = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: Temporalex.TestSupport.Namespace.name(),
        task_queue: task_queue
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker,
        client: client,
        task_queue: task_queue,
        workflows: [Workflow],
        activities: []
      )

    on_exit(fn ->
      try do
        if Process.alive?(worker_pid), do: Supervisor.stop(worker_pid, :normal, 5_000)
        if Process.alive?(client_pid), do: GenServer.stop(client_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, client: client}
  end

  describe "accepted forms" do
    test "all three fields together", %{client: client} do
      assert {:ok, 7} =
               run(client,
                 priority: [priority_key: 2, fairness_key: "salon-4291", fairness_weight: 2.5]
               )
    end

    test "priority_key alone", %{client: client} do
      assert {:ok, 7} = run(client, priority: [priority_key: 1])
    end

    test "fairness_key alone — the multi-tenant case", %{client: client} do
      assert {:ok, 7} = run(client, priority: [fairness_key: "salon-4291"])
    end

    test "an empty priority list is the same as omitting it", %{client: client} do
      assert {:ok, 7} = run(client, priority: [])
    end

    test "priority: nil is treated as absent", %{client: client} do
      assert {:ok, 7} = run(client, priority: nil)
    end

    test "omitting :priority entirely still works", %{client: client} do
      assert {:ok, 7} = run(client, [])
    end
  end

  describe "documented limits are enforced" do
    test "priority_key must be 1 or larger", %{client: client} do
      assert {:error, error} = run(client, priority: [priority_key: 0])
      assert Exception.message(error) =~ "priority_key must be 1 or larger"
    end

    test "priority_key rejects negatives", %{client: client} do
      assert {:error, error} = run(client, priority: [priority_key: -3])
      assert Exception.message(error) =~ "priority_key must be 1 or larger"
    end

    test "fairness_key is capped at 64 bytes", %{client: client} do
      assert {:error, error} = run(client, priority: [fairness_key: String.duplicate("x", 65)])
      assert Exception.message(error) =~ "fairness_key is limited to 64 bytes"
    end

    test "a 64 byte fairness_key is allowed", %{client: client} do
      assert {:ok, 7} = run(client, priority: [fairness_key: String.duplicate("x", 64)])
    end

    test "fairness_weight must be positive", %{client: client} do
      assert {:error, error} = run(client, priority: [fairness_weight: 0.0])
      assert Exception.message(error) =~ "fairness_weight must be greater than 0"
    end
  end

  defp run(client, opts) do
    opts =
      Keyword.merge(opts,
        workflow_id: "priority-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    case Temporalex.Client.start_workflow(client, Workflow, 7, opts) do
      {:ok, handle} -> Temporalex.Client.get_result(handle, timeout: 10_000)
      {:error, error} -> {:error, error}
    end
  end

  defp temporal_available? do
    case :gen_tcp.connect(~c"127.0.0.1", 7233, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
