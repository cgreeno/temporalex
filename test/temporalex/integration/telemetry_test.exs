defmodule Temporalex.TelemetryIntegrationTest do
  @moduledoc """
  Coverage for the runtime telemetry options and the configurable worker
  build id.

  Connects to a Temporal dev server at 127.0.0.1:7233. Skipped by default; run
  with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  @target "http://127.0.0.1:7233"

  defmodule Workflow do
    use Temporalex.Workflow

    def run(value), do: {:ok, value}
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    :ok
  end

  describe "prometheus exporter" do
    test "serves core metrics on the configured address" do
      port = free_port()

      {client, _worker} =
        start_stack(
          telemetry: [
            prometheus: [bind_address: "127.0.0.1:#{port}"],
            global_tags: %{"service" => "telemetry-test"}
          ]
        )

      # Core only records metrics once the worker has actually done something.
      run_workflow(client)

      body = scrape("127.0.0.1", port)

      assert body =~ "temporal_num_pollers"
      assert body =~ "temporal_workflow_task_schedule_to_start_latency"
      assert body =~ ~s(service="telemetry-test")
    end

    test "rejects a bind address that is not host:port" do
      assert {:error, reason} =
               start_client(telemetry: [prometheus: [bind_address: "not-an-address"]])

      assert inspect(reason) =~ "invalid prometheus :bind_address"
    end

    test "requires a bind address" do
      assert {:error, reason} =
               start_client(telemetry: [prometheus: [counters_total_suffix: true]])

      assert inspect(reason) =~ ":bind_address"
    end
  end

  describe "otlp exporter" do
    test "rejects a url that is not parseable" do
      assert {:error, reason} = start_client(telemetry: [otlp: [url: "nonsense"]])
      assert inspect(reason) =~ "invalid otlp :url"
    end

    test "rejects an unknown metric temporality" do
      assert {:error, reason} =
               start_client(
                 telemetry: [otlp: [url: "http://127.0.0.1:4317", metric_temporality: :sideways]]
               )

      assert inspect(reason) =~ ":metric_temporality must be :cumulative or :delta"
    end
  end

  test "prometheus and otlp are mutually exclusive" do
    assert {:error, reason} =
             start_client(
               telemetry: [
                 prometheus: [bind_address: "127.0.0.1:#{free_port()}"],
                 otlp: [url: "http://127.0.0.1:4317"]
               ]
             )

    assert inspect(reason) =~ "cannot enable both :prometheus and :otlp"
  end

  test "telemetry is off by default" do
    {client, _worker} = start_stack([])
    assert "quiet" == run_workflow(client, "quiet")
  end

  test "a custom build id starts a worker and runs a workflow" do
    {client, _worker} = start_stack([], build_id: "release-abc123")
    assert "built" == run_workflow(client, "built")
  end

  defp run_workflow(client, value \\ "hi") do
    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Workflow, value,
        workflow_id: "telemetry-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    {:ok, result} = Temporalex.Client.get_result(handle, timeout: 10_000)
    result
  end

  # Starts a client plus a worker bound to it, and returns both names.
  defp start_stack(client_opts, worker_opts \\ []) do
    task_queue = "telemetry-#{System.unique_integer([:positive])}"

    {:ok, client} = start_client(Keyword.put(client_opts, :task_queue, task_queue))

    worker = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Temporalex.Worker.start_link(
        worker_opts
        |> Keyword.put_new(:workflows, [Workflow])
        |> Keyword.put_new(:activities, [])
        |> Keyword.merge(name: worker, client: client, task_queue: task_queue)
      )

    stop_on_exit(pid, &Supervisor.stop/3)

    {client, worker}
  end

  # Returns {:ok, name} or {:error, reason}. Traps exits because `start_link`
  # links the doomed client to the test process when telemetry config is bad.
  defp start_client(opts) do
    Process.flag(:trap_exit, true)
    name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")

    opts =
      opts
      |> Keyword.put_new(:task_queue, "telemetry-#{System.unique_integer([:positive])}")
      |> Keyword.merge(
        name: name,
        backend: Temporalex.Backend.TemporalCore,
        target: @target,
        namespace: "default"
      )

    case Temporalex.Client.start_link(opts) do
      {:ok, pid} ->
        stop_on_exit(pid, &GenServer.stop/3)
        {:ok, name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_on_exit(pid, stop_fun) do
    on_exit(fn ->
      try do
        if Process.alive?(pid), do: stop_fun.(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # A raw HTTP/1.1 GET rather than :httpc — the latter drags in :ssl and
  # :public_key even for a plaintext localhost request.
  defp scrape(host, port) do
    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET /metrics HTTP/1.1\r\nHost: #{host}:#{port}\r\nConnection: close\r\n\r\n"
      )

    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  # Bind port 0, read what the OS handed out, release it. Racy in principle,
  # fine in practice, and better than hard-coding a port the CI box may hold.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
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
