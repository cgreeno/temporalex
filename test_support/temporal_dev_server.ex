defmodule Temporalex.TestSupport.TemporalDevServer do
  @moduledoc false

  defstruct [:temporal, :port, :http_port, :metrics_port, :port_handle, :target]

  def start(opts \\ []) do
    with {:ok, temporal} <- temporal_executable(opts) do
      port = Keyword.get_lazy(opts, :port, &free_port/0)
      http_port = Keyword.get_lazy(opts, :http_port, &free_port/0)
      metrics_port = Keyword.get_lazy(opts, :metrics_port, &free_port/0)

      port_handle = start_port(temporal, port, http_port, metrics_port, opts)

      server = %__MODULE__{
        temporal: temporal,
        port: port,
        http_port: http_port,
        metrics_port: metrics_port,
        port_handle: port_handle,
        target: "http://127.0.0.1:#{port}"
      }

      if wait_for_health(server) do
        {:ok, server}
      else
        stop(server)
        {:error, {:health_timeout, port}}
      end
    end
  end

  def start!(opts \\ []) do
    case start(opts) do
      {:ok, server} -> server
      {:error, reason} -> raise "failed to start Temporal dev server: #{inspect(reason)}"
    end
  end

  def stop(%__MODULE__{} = server) do
    if Port.info(server.port_handle) do
      Port.close(server.port_handle)
    end

    drain_port_messages(server.port_handle)
  end

  def address(%__MODULE__{} = server), do: "127.0.0.1:#{server.port}"

  def workflow_visible?(%__MODULE__{} = server, query, workflow_id) do
    case System.cmd(
           server.temporal,
           [
             "workflow",
             "list",
             "--address",
             address(server),
             "--namespace",
             "default",
             "--query",
             query,
             "--limit",
             "10"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output =~ workflow_id
      {_output, _status} -> false
    end
  end

  def eventually(fun, timeout \\ 10_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp temporal_executable(opts) do
    case Keyword.get(opts, :temporal) || System.find_executable("temporal") do
      nil -> {:error, :temporal_cli_not_found}
      temporal -> {:ok, temporal}
    end
  end

  defp start_port(temporal, port, http_port, metrics_port, opts) do
    Port.open(
      {:spawn_executable, temporal},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        args:
          [
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
            Keyword.get(opts, :log_level, "error")
          ] ++ search_attribute_args(Keyword.get(opts, :search_attributes, []))
      ]
    )
  end

  defp search_attribute_args(search_attributes) do
    Enum.flat_map(search_attributes, fn
      {name, type} -> ["--search-attribute", "#{name}=#{type}"]
      value when is_binary(value) -> ["--search-attribute", value]
    end)
  end

  defp wait_for_health(%__MODULE__{} = server) do
    deadline = System.monotonic_time(:millisecond) + 20_000
    do_wait_for_health(server, deadline)
  end

  defp do_wait_for_health(%__MODULE__{} = server, deadline) do
    case System.cmd(
           server.temporal,
           [
             "operator",
             "cluster",
             "health",
             "--address",
             address(server),
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
          do_wait_for_health(server, deadline)
        end
    end
  end

  defp drain_port_messages(port_handle) do
    receive do
      {^port_handle, {:data, _data}} -> drain_port_messages(port_handle)
      {^port_handle, {:exit_status, _status}} -> drain_port_messages(port_handle)
    after
      100 -> :ok
    end
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(250)
        do_eventually(fun, deadline)
      end
    end
  end
end
