defmodule Temporalex.TemporalCoreIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Activities do
    use Temporalex.Activity

    defactivity echo(value), start_to_close_timeout: 10_000 do
      {:ok, {:echo, value}}
    end

    defactivity heartbeat(ctx, value),
      start_to_close_timeout: 10_000,
      heartbeat_timeout: 10_000 do
      :ok = Temporalex.Activity.Context.heartbeat(ctx, {:heartbeat, value})
      {:ok, {:heartbeat, value}}
    end
  end

  defmodule Workflow do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(input) do
      API.sleep(10)
      {:ok, echoed} = Activities.echo(input)
      {:ok, heartbeat} = Activities.heartbeat(input)
      {:ok, {:done, echoed, heartbeat}}
    end
  end

  defmodule InteractiveWorkflow do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("state", _args, state), do: {:reply, state}

    def run(initial) do
      API.publish_state(initial)

      state =
        API.phase(initial,
          signal: %{
            "add" => fn [amount], state ->
              state = state + amount
              API.publish_state(state)
              {:noreply, state}
            end
          },
          update: %{
            "add" => fn [amount], state ->
              state = state + amount
              API.publish_state(state)
              {:reply, state, state}
            end,
            "finish" => fn _args, state ->
              API.publish_state(state)
              {:stop, :finished, state}
            end
          }
        )

      {:ok, state}
    end
  end

  defmodule WaitingWorkflow do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("state", _args, state), do: {:reply, state}

    def run(label) do
      API.publish_state({:waiting, label})
      API.sleep(60_000)
      {:ok, {:completed, label}}
    end
  end

  test "TemporalCore worker runs workflow tasks, activities, and client operations against dev server" do
    temporal =
      System.find_executable("temporal") || flunk("temporal CLI executable was not found")

    port = free_port()
    http_port = free_port()
    metrics_port = free_port()

    temporal_port = start_temporal(temporal, port, http_port, metrics_port)

    try do
      assert wait_for_health(temporal, port)

      worker_name =
        Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

      task_queue = "temporalex-native-#{System.unique_integer([:positive])}"

      {:ok, worker_pid} =
        Temporalex.Worker.start_link(
          name: worker_name,
          backend: Temporalex.Backend.TemporalCore,
          target: "http://127.0.0.1:#{port}",
          namespace: "default",
          task_queue: task_queue,
          workflows: [Workflow, InteractiveWorkflow, WaitingWorkflow],
          activities: [Activities],
          max_workflow_pollers: 2,
          max_activity_pollers: 2,
          workflow_result_timeout: 30_000
        )

      try do
        assert {:error, invalid_start_reason} =
                 Temporalex.Client.start_workflow(worker_name, Workflow, :invalid_options,
                   workflow_id: "temporalex-invalid-#{System.unique_integer([:positive])}",
                   workflow_task_timeout: -1,
                   timeout: 10_000
                 )

        assert invalid_start_reason =~ "duration option must be non-negative"

        input = {:native, System.unique_integer([:positive])}
        workflow_id = "temporalex-native-#{System.unique_integer([:positive])}"

        assert {:ok, handle} =
                 Temporalex.Client.start_workflow(worker_name, Workflow, input,
                   workflow_id: workflow_id,
                   timeout: 10_000
                 )

        assert handle.workflow_id == workflow_id
        assert is_binary(handle.run_id)
        assert handle.run_id != ""

        assert {:ok, {:done, {:echo, ^input}, {:heartbeat, ^input}}} =
                 Temporalex.Client.get_result(handle, timeout: 30_000)

        interactive_id = "temporalex-interactive-#{System.unique_integer([:positive])}"

        assert {:ok, interactive} =
                 Temporalex.Client.start_workflow(worker_name, InteractiveWorkflow, 0,
                   workflow_id: interactive_id,
                   workflow_task_timeout: 10_000,
                   id_reuse_policy: :reject_duplicate,
                   id_conflict_policy: :fail,
                   static_summary: "Temporalex integration test",
                   timeout: 10_000
                 )

        assert eventually(fn ->
                 Temporalex.Client.query_workflow(interactive, "state", [], timeout: 10_000) ==
                   {:ok, 0}
               end)

        assert :ok =
                 Temporalex.Client.signal_workflow(interactive, "add", [2], timeout: 10_000)

        assert eventually(fn ->
                 Temporalex.Client.query_workflow(interactive, "state", [], timeout: 10_000) ==
                   {:ok, 2}
               end)

        assert {:ok, 5} =
                 Temporalex.Client.update_workflow(interactive, "add", [3], timeout: 15_000)

        assert {:ok, description} =
                 Temporalex.Client.describe_workflow(interactive, timeout: 10_000)

        assert description.workflow_id == interactive_id
        assert description.run_id == interactive.run_id
        assert description.workflow_type == InteractiveWorkflow.__workflow_type__()
        assert description.status == :running
        assert is_integer(description.history_length)

        assert {:ok, :finished} =
                 Temporalex.Client.update_workflow(interactive, "finish", [], timeout: 15_000)

        assert {:ok, 5} = Temporalex.Client.get_result(interactive, timeout: 30_000)

        terminated_id = "temporalex-terminated-#{System.unique_integer([:positive])}"

        assert {:ok, terminated} =
                 Temporalex.Client.start_workflow(worker_name, WaitingWorkflow, :terminate,
                   workflow_id: terminated_id,
                   timeout: 10_000
                 )

        assert eventually(fn ->
                 Temporalex.Client.query_workflow(terminated, "state", [], timeout: 10_000) ==
                   {:ok, {:waiting, :terminate}}
               end)

        assert :ok =
                 Temporalex.Client.terminate_workflow(terminated,
                   reason: "integration test",
                   details: :terminated_by_test,
                   timeout: 10_000
                 )

        assert {:error, {:terminated, [:terminated_by_test]}} =
                 Temporalex.Client.get_result(terminated, timeout: 30_000)
      after
        if Process.alive?(worker_pid) do
          Supervisor.stop(worker_pid, :normal, 15_000)
        end
      end
    after
      Port.close(temporal_port)
      drain_port_messages()
    end
  end

  defp start_temporal(temporal, port, http_port, metrics_port) do
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

  defp eventually(fun, timeout \\ 10_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
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
