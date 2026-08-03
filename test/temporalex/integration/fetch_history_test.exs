defmodule Temporalex.FetchHistoryIntegrationTest do
  @moduledoc """
  Coverage for `Temporalex.Client.fetch_workflow_history/2,3`.

  History is returned as encoded protobuf rather than JSON: `.temporal.api.history`
  is not in temporalio-common's pbjson list, so `History`'s derived serde impl is
  not proto-JSON compatible. Bytes are what a replay worker consumes and what to
  check in as a replay fixture.

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
        namespace: "default",
        task_queue: task_queue
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker,
        client: client,
        task_queue: task_queue,
        workflows: [Workflow, LongerWorkflow],
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

  test "returns protobuf bytes for a completed workflow", %{client: client} do
    handle = run_workflow(client)

    assert {:ok, bytes} = Temporalex.Client.fetch_workflow_history(handle, timeout: 15_000)
    assert is_binary(bytes)

    # Protobuf keeps strings uncompressed, so a real History carries the
    # workflow type and activity type verbatim.
    assert bytes =~ "Workflow"
    assert bytes =~ "double"
    assert byte_size(bytes) > 200
  end

  test "works by workflow id without a handle", %{client: client} do
    handle = run_workflow(client)

    assert {:ok, bytes} =
             Temporalex.Client.fetch_workflow_history(client, handle.workflow_id, timeout: 15_000)

    assert is_binary(bytes) and byte_size(bytes) > 200
  end

  # Smoke test for completeness: more events must yield more bytes, so a fetch
  # that returned only the tail (or a fixed prefix) fails here. It does NOT
  # exercise pagination — that needs >1000 events. The real assertion for this
  # NIF is the fetch -> replay round trip, once the replay worker exists.
  test "returns more bytes for a history with more events", %{client: client} do
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

    assert byte_size(three_activities) > byte_size(one_activity)
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
