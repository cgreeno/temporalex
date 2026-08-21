defmodule Temporalex.MemoIntegrationTest do
  @moduledoc """
  Coverage for the memo paths that are reachable today.

  Memo is unindexed operator annotation — Temporal returns it when you describe
  or list a workflow, and it is the counterpart to indexed search attributes.

  Three of Temporal's four memo paths are covered here: `upsert_memo/1` from
  workflow code, `:memo` on a child workflow, and reading it back via
  `describe_workflow`. The fourth — memo on client `start_workflow` — is not,
  because sdk-rust v0.4.0's `WorkflowStartOptions` has no memo field, so it
  cannot be set through the client at all.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  defmodule Child do
    use Temporalex.Workflow

    def run(n), do: {:ok, n * 2}
  end

  defmodule Upserter do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(memo) do
      API.upsert_memo(memo)
      {:ok, "upserted"}
    end
  end

  defmodule UpsertsTwice do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      API.upsert_memo(%{"stage" => "started", "salon_id" => "salon-1"})
      API.upsert_memo(%{"stage" => "finished"})
      {:ok, "done"}
    end
  end

  defmodule ParentWithChildMemo do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    # The child id comes in as input so each run addresses a distinct child and
    # the test can describe it afterwards.
    def run(child_id) do
      API.execute_child_workflow(inspect(Child), [21],
        workflow_id: child_id,
        memo: %{"origin" => "parent"}
      )
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    task_queue = "memo-#{System.unique_integer([:positive])}"
    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    worker = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client,
        backend: Temporalex.Backend.TemporalCore,
        target: Server.target(),
        namespace: Temporalex.TestSupport.Namespace.name(),
        task_queue: task_queue,
        payload_codec: :json
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker,
        client: client,
        task_queue: task_queue,
        workflows: [Child, Upserter, UpsertsTwice, ParentWithChildMemo],
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

  describe "upsert_memo/1" do
    test "sets memo that describe_workflow reads back", %{client: client} do
      {:ok, handle} = start(client, Upserter, %{"salon_id" => "salon-4291", "channel" => "web"})
      assert {:ok, "upserted"} = Temporalex.Client.get_result(handle, timeout: 10_000)

      assert {:ok, description} = Temporalex.Client.describe_workflow(handle, timeout: 10_000)
      assert description.memo["salon_id"] == "salon-4291"
      assert description.memo["channel"] == "web"
    end

    test "a later upsert merges over an earlier one", %{client: client} do
      {:ok, handle} = start(client, UpsertsTwice, nil)
      assert {:ok, "done"} = Temporalex.Client.get_result(handle, timeout: 10_000)

      assert {:ok, description} = Temporalex.Client.describe_workflow(handle, timeout: 10_000)
      # Second upsert overwrote :stage; the untouched key survives.
      assert description.memo["stage"] == "finished"
      assert description.memo["salon_id"] == "salon-1"
    end

    # The server rejects an empty ModifyWorkflowProperties with
    # "UpsertedMemo.Fields is not set", which fails the workflow *task* rather
    # than the workflow — so it retries forever and wedges the execution. An
    # empty upsert must therefore emit no command at all.
    test "an empty upsert is a no-op and does not wedge the workflow", %{client: client} do
      {:ok, handle} = start(client, Upserter, %{})
      assert {:ok, "upserted"} = Temporalex.Client.get_result(handle, timeout: 10_000)

      assert {:ok, description} = Temporalex.Client.describe_workflow(handle, timeout: 10_000)
      assert description.memo == %{}
    end
  end

  describe "describe_workflow memo" do
    test "is an empty map when no memo was ever set", %{client: client} do
      {:ok, handle} = start(client, Child, 1)
      assert {:ok, 2} = Temporalex.Client.get_result(handle, timeout: 10_000)

      assert {:ok, description} = Temporalex.Client.describe_workflow(handle, timeout: 10_000)
      assert description.memo == %{}
    end
  end

  describe "child workflow :memo" do
    test "a child started with :memo completes and carries it", %{client: client} do
      child_id = "memo-child-#{System.unique_integer([:positive])}"

      {:ok, handle} = start(client, ParentWithChildMemo, child_id)
      assert {:ok, 42} = Temporalex.Client.get_result(handle, timeout: 15_000)

      assert {:ok, child} =
               Temporalex.Client.describe_workflow(client, child_id, timeout: 10_000)

      assert child.memo["origin"] == "parent"
    end
  end

  defp start(client, workflow, input) do
    Temporalex.Client.start_workflow(client, workflow, input,
      workflow_id: "memo-#{System.unique_integer([:positive])}",
      timeout: 10_000
    )
  end

  defp temporal_available? do
    case :gen_tcp.connect(
           String.to_charlist(Server.host()),
           Server.port(),
           [:binary, active: false],
           1_000
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
