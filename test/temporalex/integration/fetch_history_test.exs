defmodule Temporalex.FetchHistoryIntegrationTest do
  @moduledoc """
  Coverage for `Temporalex.Client.fetch_workflow_history/2,3`: parsed
  `%Temporalex.History{}` by default (#27), `raw: true` for the encoded
  protobuf replay-fixture form, and `stuck_reason/1` reading a stuck
  workflow's failed-task reason out of live history (#29).

  Connects to a Temporal dev server at 127.0.0.1:7233. Skipped by default; run
  with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Activities do
    use Temporalex.Activity

    defactivity double(n), start_to_close_timeout: 5_000 do
      {:ok, n * 2}
    end
  end

  defmodule Workflow do
    use Temporalex.Workflow

    def run(n) do
      {:ok, doubled} = Activities.double(n)
      {:ok, doubled}
    end
  end

  defmodule TimerSignalWorkflow do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(n) do
      :ok = API.sleep(50)
      {:ok, args} = API.wait_for_signal("proceed")
      {:ok, {n, args}}
    end
  end

  # Same shape, more activities — so more history events. Exists only so the
  # completeness smoke test has two histories of different lengths to compare.
  defmodule LongerWorkflow do
    use Temporalex.Workflow

    def run(n) do
      {:ok, a} = Activities.double(n)
      {:ok, b} = Activities.double(a)
      {:ok, c} = Activities.double(b)
      {:ok, c}
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    task_queue = "fetch-history-#{System.unique_integer([:positive])}"
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
        workflows: [Workflow, LongerWorkflow, Stuck, TimerSignalWorkflow],
        activities: [Activities]
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

  test "returns parsed events for a completed workflow", %{client: client} do
    handle = run_workflow(client)

    assert {:ok, %Temporalex.History{} = history} =
             Temporalex.Client.fetch_workflow_history(handle, timeout: 15_000)

    assert history.workflow_id == handle.workflow_id

    types = Enum.map(history.events, & &1.type)
    assert List.first(types) == :workflow_execution_started
    assert List.last(types) == :workflow_execution_completed
    assert :activity_task_scheduled in types
    assert :activity_task_completed in types

    # Ordered, timestamped, attributed.
    ids = Enum.map(history.events, & &1.id)
    assert ids == Enum.sort(ids)
    assert %DateTime{} = List.first(history.events).time

    started = Temporalex.History.last(history, :workflow_execution_started)
    assert started.attributes.workflow_type =~ "Workflow"

    assert Temporalex.History.stuck_reason(history) == nil
  end

  test "raw: true returns the encoded protobuf replay-fixture form", %{client: client} do
    handle = run_workflow(client)

    assert {:ok, bytes} =
             Temporalex.Client.fetch_workflow_history(handle, raw: true, timeout: 15_000)

    assert is_binary(bytes)
    # Protobuf keeps strings uncompressed, so a real History carries the
    # workflow type and activity type verbatim.
    assert bytes =~ "Workflow"
    assert bytes =~ "double"
    assert byte_size(bytes) > 200
  end

  test "works by workflow id without a handle", %{client: client} do
    handle = run_workflow(client)

    assert {:ok, %Temporalex.History{events: events}} =
             Temporalex.Client.fetch_workflow_history(client, handle.workflow_id, timeout: 15_000)

    assert length(events) > 5
  end

  # Smoke test for completeness: more activities must yield more events, so a
  # fetch that returned only the tail (or a fixed prefix) fails here. It does
  # NOT exercise pagination — that needs >1000 events.
  test "a history with more activities has more events", %{client: client} do
    {:ok, one_activity} =
      Temporalex.Client.fetch_workflow_history(run_workflow(client), timeout: 15_000)

    {:ok, longer_handle} =
      Temporalex.Client.start_workflow(client, LongerWorkflow, 2,
        workflow_id: "fetch-history-longer-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    assert {:ok, 16} = Temporalex.Client.get_result(longer_handle, timeout: 10_000)

    {:ok, three_activities} =
      Temporalex.Client.fetch_workflow_history(longer_handle, timeout: 15_000)

    assert length(Temporalex.History.events(three_activities, :activity_task_completed)) == 3
    assert length(Temporalex.History.events(one_activity, :activity_task_completed)) == 1
    assert length(three_activities.events) > length(one_activity.events)
  end

  defmodule Stuck do
    use Temporalex.Workflow

    # Blocks the executor thread past its did-not-yield bound (5s), which
    # fails the ACTIVATION — a workflow-task failure the server retries —
    # rather than failing the workflow. The workflow sits Running, stuck,
    # which is exactly the state stuck_reason/1 exists to explain.
    def run(_input) do
      Process.sleep(30_000)
      {:ok, :never}
    end
  end

  @tag timeout: 90_000
  test "stuck_reason reads a stuck workflow's failed-task reason from live history",
       %{client: client} do
    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Stuck, nil,
        workflow_id: "fetch-history-stuck-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    # Wait out the first activation abort (5s) plus server round trips, then
    # poll history until the WorkflowTaskFailed event lands.
    reason =
      Enum.reduce_while(1..30, nil, fn _, _ ->
        Process.sleep(1_000)

        with {:ok, history} <- Temporalex.Client.fetch_workflow_history(handle, timeout: 15_000),
             %{} = reason <- Temporalex.History.stuck_reason(history) do
          {:halt, reason}
        else
          _ -> {:cont, nil}
        end
      end)

    assert %{message: message, event_id: event_id} = reason,
           "no workflow_task_failed event appeared — the stuck repro never failed a task"

    assert is_integer(event_id)

    # Two executor writers race to set the failure reason (the did-not-yield
    # watchdog vs the killed thread's exit during teardown) — either way the
    # recorded failure must carry a usable message and the right cause.
    assert is_binary(message) and message != ""
    assert reason.cause == :WORKFLOW_TASK_FAILED_CAUSE_WORKFLOW_WORKER_UNHANDLED_FAILURE

    # Stop the retry loop; the workflow is unrecoverable by design.
    Temporalex.Client.terminate_workflow(handle, reason: "stuck repro done")
  end

  test "a fetched history replays clean against the same code — the round trip",
       %{client: client} do
    handle = run_workflow(client)

    {:ok, history} = Temporalex.Client.fetch_workflow_history(handle, timeout: 15_000)
    assert :ok = Temporalex.Replay.replay(history, workflows: [Workflow])

    # And the fixture path: raw bytes -> decode -> replay.
    {:ok, bytes} = Temporalex.Client.fetch_workflow_history(handle, raw: true, timeout: 15_000)
    {:ok, decoded} = Temporalex.Replay.decode(bytes)
    assert :ok = Temporalex.Replay.replay(decoded, workflows: [Workflow])
  end

  test "a timer+signal history replays clean — real durations and signal payloads",
       %{client: client} do
    {:ok, handle} =
      Temporalex.Client.start_workflow(client, TimerSignalWorkflow, 7,
        workflow_id: "fetch-history-ts-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    Process.sleep(300)
    :ok = Temporalex.Client.signal_workflow(handle, "proceed", [:go], timeout: 10_000)
    assert {:ok, {7, [:go]}} = Temporalex.Client.get_result(handle, timeout: 15_000)

    {:ok, history} = Temporalex.Client.fetch_workflow_history(handle, timeout: 15_000)
    assert :ok = Temporalex.Replay.replay(history, workflows: [TimerSignalWorkflow])
  end

  test "unknown workflow id errors rather than returning empty bytes", %{client: client} do
    assert {:error, _} =
             Temporalex.Client.fetch_workflow_history(
               client,
               "does-not-exist-#{System.os_time()}",
               timeout: 10_000
             )
  end

  defp run_workflow(client) do
    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Workflow, 21,
        workflow_id: "fetch-history-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    assert {:ok, 42} = Temporalex.Client.get_result(handle, timeout: 10_000)
    handle
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
