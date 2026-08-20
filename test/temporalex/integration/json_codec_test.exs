defmodule Temporalex.JsonCodecIntegrationTest do
  @moduledoc """
  Verifies the full bidirectional JSON codec: a worker configured with
  `payload_codec: :json` decodes incoming JSON payloads AND emits
  workflow/activity completion payloads encoded as `json/plain`.

  This unlocks the official `temporal` CLI rendering paths that the
  default ETF encoding can't satisfy.

  Connects to 127.0.0.1:7233. Skipped by default.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule SimpleWorkflow do
    @moduledoc """
    Returns a JSON-friendly Elixir term so the json/plain encoding is
    lossless for this test.
    """
    use Temporalex.Workflow

    def run(input) do
      {:ok, %{"echoed" => input, "ok" => true}}
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

  defp cli_available?, do: System.find_executable("temporal") != nil

  setup_all do
    unless temporal_available?(), do: raise("Temporal dev server not reachable")
    unless cli_available?(), do: raise("`temporal` CLI not on PATH")

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    client_name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    task_queue = "json-codec-#{System.unique_integer([:positive])}"

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client_name,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: Temporalex.TestSupport.Namespace.name(),
        task_queue: task_queue,
        payload_codec: :json
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        client: client_name,
        task_queue: task_queue,
        workflows: [SimpleWorkflow],
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

    {:ok, client: client_name, worker: worker_name, task_queue: task_queue}
  end

  test "JSON-encoded workflow result round-trips via our Client", %{client: client} do
    workflow_id = "json-result-client-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(client, SimpleWorkflow, "hello",
        workflow_id: workflow_id,
        timeout: 10_000
      )

    # Our client gets the result back through the decode path that
    # auto-detects json/plain metadata. The value should be the same
    # Elixir term we returned (modulo atoms collapsing to strings).
    assert {:ok, %{"echoed" => "hello", "ok" => true}} =
             Temporalex.Client.get_result(handle, timeout: 15_000)
  end

  test "JSON-encoded workflow result is renderable by the `temporal` CLI", %{
    client: client,
    task_queue: tq
  } do
    workflow_id = "json-result-cli-#{System.unique_integer([:positive])}"

    {:ok, _handle} =
      Temporalex.Client.start_workflow(client, SimpleWorkflow, "from-cli-test",
        workflow_id: workflow_id,
        timeout: 10_000
      )

    # Wait for completion.
    :ok = wait_for_completion(workflow_id)

    # Use the CLI to fetch the result. With JSON encoding, the CLI can
    # render the payload (the entire reason for this codec mode).
    {output, exit_code} =
      System.cmd("temporal", [
        "workflow",
        "result",
        "--workflow-id",
        workflow_id,
        "--address",
        "127.0.0.1:7233",
        "--namespace",
        Temporalex.TestSupport.Namespace.name()
      ])

    assert exit_code == 0,
           "CLI failed to render workflow result: #{output}\n(task_queue: #{tq})"

    # The CLI output should contain the JSON representation of the value.
    assert output =~ "echoed"
    assert output =~ "from-cli-test"
  end

  defp wait_for_completion(workflow_id) do
    deadline = System.monotonic_time(:millisecond) + 20_000
    do_wait_for_completion(workflow_id, deadline)
  end

  defp do_wait_for_completion(workflow_id, deadline) do
    case System.cmd(
           "temporal",
           [
             "workflow",
             "describe",
             "--workflow-id",
             workflow_id,
             "--address",
             "127.0.0.1:7233",
             "--namespace",
             Temporalex.TestSupport.Namespace.name(),
             "--output",
             "json"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        cond do
          output =~ "WORKFLOW_EXECUTION_STATUS_COMPLETED" ->
            :ok

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :timeout}

          true ->
            Process.sleep(200)
            do_wait_for_completion(workflow_id, deadline)
        end

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(200)
          do_wait_for_completion(workflow_id, deadline)
        end
    end
  end
end
