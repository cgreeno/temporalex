defmodule Temporalex.PriorityIntegrationTest do
  @moduledoc """
  Coverage for the `:priority` start option — task priority and fairness.

  ## What is asserted

  That the option is accepted end to end, that omitting it is unchanged, and
  that the three documented limits are enforced with clear errors.

  And that the server records what we send, exactly.

  ## Server version matters, and it bit us

  A previous version of this file asserted the opposite: that the server
  records *no* priority. That was true of the server it was written against
  and false in CI, which caught it within minutes of merging.

    * Server **1.27.4** (`temporalio/auto-setup:1.27`, the local docker
      compose) accepts priority and silently drops it. The
      WorkflowExecutionStarted event carries none, and `temporal workflow
      describe` reports `priority: null` even for workflows the CLI started
      itself with `--priority-key`.

    * Server **1.31.2** (what `temporal server start-dev` bundles today, and
      what CI runs) records all three fields exactly.

  Recording is not the same as honouring. Whether priority changes dispatch
  order is a separate question, and one we could not answer with a test — see
  "What we assert about a server, and what we do not" in `docs/testing.md`.

  So this suite needs a server that supports priority, and the round-trip
  below is what says so out loud rather than leaving it to be rediscovered.
  If it fails, check your server version first: `temporal operator cluster
  describe -o json | grep serverVersion`.

  The decoder is pinned separately, in
  `test/temporalex/backend/temporal_core/priority_decode_test.exs`, so a
  failure here points at the server rather than at our parsing.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  defmodule Workflow do
    use Temporalex.Workflow

    def run(n), do: {:ok, n}
  end

  setup_all do
    unless Server.reachable?() do
      raise "Temporal dev server not reachable at #{Server.address()}"
    end

    task_queue = "priority-#{System.unique_integer([:positive])}"
    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    worker = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client,
        backend: Temporalex.Backend.TemporalCore,
        target: Server.target(),
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

  describe "the server records what we send" do
    test "all three fields round-trip through the started event", %{client: client} do
      priority = [priority_key: 1, fairness_key: "salon-4291", fairness_weight: 2.5]

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, Workflow, 7,
          workflow_id: "priority-roundtrip-#{System.unique_integer([:positive])}",
          priority: priority
        )

      assert {:ok, 7} = Temporalex.Client.get_result(handle, timeout: 15_000)
      assert {:ok, history} = Temporalex.Client.fetch_workflow_history(handle)

      started = Temporalex.History.last(history, :workflow_execution_started)
      assert started, "no WorkflowExecutionStarted event — the history shape changed"

      assert Map.get(started.attributes, :priority) ==
               %{priority_key: 1, fairness_key: "salon-4291", fairness_weight: 2.5},
             """
             the server did not record the priority we sent (#{inspect(priority)}); \
             it came back as #{inspect(Map.get(started.attributes, :priority))}.

             CHECK THE SERVER VERSION FIRST:

                 temporal operator cluster describe -o json | grep serverVersion

             1.27.4 accepts priority and drops it; 1.31.2 records it. If you are on
             an old `temporalio/auto-setup` image, that is the cause — CI runs
             `temporal server start-dev`, which bundles a current server. Our send
             path is not in question here: the decoder is pinned separately in
             test/temporalex/backend/temporal_core/priority_decode_test.exs.
             """
    end

    test "an unset field is recorded as its default, not as ours", %{client: client} do
      # Sending only the key must not invent a fairness key. The server fills
      # the rest with its own defaults, which is what "inherits or falls back"
      # in the start_workflow docs means concretely.
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, Workflow, 7,
          workflow_id: "priority-partial-#{System.unique_integer([:positive])}",
          priority: [priority_key: 2]
        )

      assert {:ok, 7} = Temporalex.Client.get_result(handle, timeout: 15_000)
      assert {:ok, history} = Temporalex.Client.fetch_workflow_history(handle)

      started = Temporalex.History.last(history, :workflow_execution_started)
      recorded = Map.get(started.attributes, :priority)

      assert Map.get(recorded, :priority_key) == 2
      assert Map.get(recorded, :fairness_key) in [nil, ""]
      assert Map.get(recorded, :fairness_weight) in [nil, 0.0]
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
end
