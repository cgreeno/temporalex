defmodule Temporalex.TemporalCliSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :external

  test "Temporal CLI starts a local development server" do
    temporal =
      System.find_executable("temporal") || flunk("temporal CLI executable was not found")

    port = free_port()
    http_port = free_port()
    metrics_port = free_port()

    temporal_port =
      Port.open(
        {:spawn_executable, temporal},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 4096},
          args: [
            "server",
            "start-dev",
            "--headless",
            "--ip",
            "127.0.0.1",
            "--port",
            Integer.to_string(port),
            "--http-port",
            Integer.to_string(http_port),
            "--metrics-port",
            Integer.to_string(metrics_port),
            "--log-level",
            "error"
          ]
        ]
      )

    try do
      assert wait_for_health(temporal, port)
    after
      Port.close(temporal_port)
      drain_port_messages()
    end
  end

  defp wait_for_health(temporal, port) do
    deadline = System.monotonic_time(:millisecond) + 20_000
    do_wait_for_health(temporal, port, deadline)
  end

  defp do_wait_for_health(temporal, port, deadline) do
    address = "127.0.0.1:#{port}"

    case System.cmd(
           temporal,
           [
             "operator",
             "cluster",
             "health",
             "--address",
             address,
             "--client-connect-timeout",
             "1s",
             "--command-timeout",
             "2s"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        true

      {_output, _status} ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(250)
          do_wait_for_health(temporal, port, deadline)
        end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp drain_port_messages do
    receive do
      {_port, {:data, _data}} -> drain_port_messages()
      {_port, {:exit_status, _status}} -> drain_port_messages()
    after
      100 -> :ok
    end
  end
end
