defmodule Temporalex.PriorityIntegrationTest do
  @moduledoc """
  Coverage for the `:priority` start option — task priority and fairness.

  ## What is asserted

  That the option is accepted end to end, that omitting it is unchanged, and
  that the three documented limits are enforced with clear errors.

  And that the server still ignores it — see the canary below.

  ## What the server does with it, and why that is asserted here

  Nothing, on the dev server this suite runs against
  (`temporalio/auto-setup:1.27`). Two separate observations:

    * It does not *record* it. The WorkflowExecutionStarted event carries no
      priority at all, and `temporal workflow describe` reports
      `priority: null` — including for workflows started by the `temporal`
      CLI itself with `--priority-key`. So this is the server, not our send
      path (which puts it on `StartWorkflowExecutionRequest.priority` the way
      sdk-rust does).

    * It does not *enforce* it either. Queue a backlog of `priority_key: 5`
      workflows plus one `priority_key: 1` on an empty task queue, then start
      the worker: the high-priority one runs LAST. Reproduced with the default
      five pollers and with a single poller, so it is not a poller artefact.

  An earlier version of this file argued that asserting the first observation
  would be "a test that can only fail for reasons unrelated to this code".
  That was the wrong conclusion from a right premise. We do not want to assert
  that priority *round-trips* — that would indeed fail on our own server. We
  want to be told the day it starts working, because that is the day this
  option stops being decorative. So the canary asserts the current answer and
  fails loudly, with instructions, when it changes.

  The observer is pinned separately, in
  `test/temporalex/backend/temporal_core/priority_decode_test.exs`: a started
  event that *does* carry priority decodes with it intact. Without that, the
  canary would pass just as well if we were simply blind to the field.

  The enforcement experiment lives in
  `test/temporalex/integration/priority_effect_test.exs`, excluded by default
  because it fails on every server we can currently run against. It is the
  demonstration we owe the feature, kept executable so it is one flag away
  rather than a paragraph someone has to rebuild from scratch.

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

  describe "server support canary" do
    test "the server still records no priority", %{client: client} do
      priority = [priority_key: 1, fairness_key: "salon-4291", fairness_weight: 2.5]
      workflow_id = "priority-canary-#{System.unique_integer([:positive])}"

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, Workflow, 7,
          workflow_id: workflow_id,
          priority: priority
        )

      assert {:ok, 7} = Temporalex.Client.get_result(handle, timeout: 15_000)
      assert {:ok, history} = Temporalex.Client.fetch_workflow_history(handle)

      started = Temporalex.History.last(history, :workflow_execution_started)
      assert started, "no WorkflowExecutionStarted event — the history shape changed"

      assert Map.get(started.attributes, :priority) == nil, """
      GOOD NEWS, ACTION NEEDED: the server now records priority. We sent
      #{inspect(priority)} and it came back as
      #{inspect(Map.get(started.attributes, :priority))}.

      This assertion exists to catch exactly this moment. Now:

        1. Run the enforcement experiment — `mix test --include external \
      --include priority_effect` — and see whether dispatch order actually
           honours the key. Recording and enforcing are separate questions.
        2. Surface priority on describe. WorkflowExecutionInfo carries it
           (field 24) but describe_to_term in native/temporalex_nif/src/lib.rs
           does not map it, so today users can set a field they cannot read.
        3. Drop the "Server support" admonition in Temporalex.Client.start_workflow
           and this module's moduledoc, and replace this canary with a
           round-trip assertion.
      """
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
