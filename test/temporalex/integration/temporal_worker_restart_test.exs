defmodule Temporalex.TemporalWorkerRestartTest do
  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.TemporalDevServer
  alias Temporalex.Workflow.API

  defmodule Activities do
    use Temporalex.Activity

    defactivity restart_after_worker_stop(ctx, %{parent: parent, label: label}),
      start_to_close_timeout: 1_000,
      schedule_to_close_timeout: 20_000,
      retry_policy: [initial_interval: 100, maximum_attempts: 3] do
      send(parent, {:restart_activity_attempt, label, ctx.attempt, self()})

      if ctx.attempt == 1 do
        Process.sleep(10_000)
        {:ok, {:unexpected_first_attempt_completion, ctx.attempt}}
      else
        {:ok, {:activity_attempt, ctx.attempt}}
      end
    end
  end

  defmodule TimerRestartWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(_) do
      API.publish_state(:waiting_for_timer)
      API.sleep!(300)
      API.publish_state(:timer_fired)
      {:ok, :timer_done}
    end
  end

  defmodule ActivityRestartWorkflow do
    use Temporalex.Workflow

    def run(input) do
      {:ok, result} = Activities.restart_after_worker_stop(input)
      {:ok, result}
    end
  end

  defmodule SignalStateWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(_) do
      API.publish_state(0)

      state =
        API.phase!(0,
          signal: %{
            "add" => fn [amount], state ->
              state = state + amount
              API.publish_state(state)
              {:noreply, state}
            end,
            "done" => fn _args, state -> {:stop, state} end
          }
        )

      {:ok, state}
    end
  end

  defmodule ContinueAfterRestartWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(%{count: 0, task_queue: task_queue} = input) do
      API.publish_state({:waiting_to_continue, 0})
      API.wait_for_signal!("continue")
      API.continue_as_new!(%{input | count: 1}, task_queue: task_queue)
    end

    def run(%{count: count}) do
      {:ok, {:continued, count}}
    end
  end

  test "worker restart replays real Temporal history across blocked workflow states" do
    temporal = TemporalDevServer.start!()

    task_queue = "temporalex-restart-#{System.unique_integer([:positive])}"
    client_name = unique_name(:Client)

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client_name,
        backend: Temporalex.Backend.TemporalCore,
        target: temporal.target,
        namespace: "default",
        task_queue: task_queue,
        workflow_result_timeout: 30_000
      )

    worker_pid = start_worker!(client_name, task_queue)

    try do
      worker_pid =
        timer_replay_after_worker_restart(client_name, worker_pid, client_pid, task_queue)

      worker_pid =
        activity_retry_after_worker_restart(
          client_name,
          worker_pid,
          client_pid,
          task_queue,
          self()
        )

      worker_pid =
        signal_history_after_worker_restart(client_name, worker_pid, client_pid, task_queue)

      worker_pid =
        continue_as_new_after_worker_restart(client_name, worker_pid, client_pid, task_queue)

      stop_worker(worker_pid)
    after
      if Process.alive?(client_pid) do
        GenServer.stop(client_pid, :normal, 15_000)
      end

      TemporalDevServer.stop(temporal)
    end
  end

  defp timer_replay_after_worker_restart(client_name, worker_pid, client_pid, task_queue) do
    workflow_id = "temporalex-restart-timer-#{System.unique_integer([:positive])}"

    assert {:ok, handle} =
             Temporalex.Client.start_workflow(client_name, TimerRestartWorkflow, nil,
               workflow_id: workflow_id,
               workflow_task_timeout: 10_000,
               timeout: 10_000
             )

    assert TemporalDevServer.eventually(fn ->
             Temporalex.Client.query_workflow(handle, "state", [], timeout: 10_000) ==
               {:ok, :waiting_for_timer}
           end)

    stop_worker(worker_pid)
    assert Process.alive?(client_pid)

    Process.sleep(800)

    worker_pid = start_worker!(client_name, task_queue)

    assert {:ok, :timer_done} = Temporalex.Client.get_result(handle, timeout: 30_000)

    worker_pid
  end

  defp activity_retry_after_worker_restart(
         client_name,
         worker_pid,
         client_pid,
         task_queue,
         parent
       ) do
    label = "activity-#{System.unique_integer([:positive])}"

    assert {:ok, handle} =
             Temporalex.Client.start_workflow(
               client_name,
               ActivityRestartWorkflow,
               %{parent: parent, label: label},
               workflow_id: "temporalex-restart-activity-#{System.unique_integer([:positive])}",
               workflow_task_timeout: 10_000,
               timeout: 10_000
             )

    assert_receive {:restart_activity_attempt, ^label, 1, _pid}, 10_000

    stop_worker(worker_pid)
    assert Process.alive?(client_pid)

    Process.sleep(1_500)

    worker_pid = start_worker!(client_name, task_queue)

    assert_receive {:restart_activity_attempt, ^label, retry_attempt, _pid}
                   when retry_attempt > 1,
                   20_000

    assert {:ok, {:activity_attempt, ^retry_attempt}} =
             Temporalex.Client.get_result(handle, timeout: 30_000)

    worker_pid
  end

  defp signal_history_after_worker_restart(client_name, worker_pid, client_pid, task_queue) do
    assert {:ok, handle} =
             Temporalex.Client.start_workflow(client_name, SignalStateWorkflow, nil,
               workflow_id: "temporalex-restart-signal-#{System.unique_integer([:positive])}",
               workflow_task_timeout: 10_000,
               timeout: 10_000
             )

    assert TemporalDevServer.eventually(fn ->
             Temporalex.Client.query_workflow(handle, "state", [], timeout: 10_000) == {:ok, 0}
           end)

    stop_worker(worker_pid)
    assert Process.alive?(client_pid)

    assert :ok = Temporalex.Client.signal_workflow(handle, "add", [5], timeout: 10_000)

    worker_pid = start_worker!(client_name, task_queue)

    assert TemporalDevServer.eventually(fn ->
             Temporalex.Client.query_workflow(handle, "state", [], timeout: 10_000) == {:ok, 5}
           end)

    assert :ok = Temporalex.Client.signal_workflow(handle, "done", [], timeout: 10_000)
    assert {:ok, 5} = Temporalex.Client.get_result(handle, timeout: 30_000)

    worker_pid
  end

  defp continue_as_new_after_worker_restart(client_name, worker_pid, client_pid, task_queue) do
    assert {:ok, handle} =
             Temporalex.Client.start_workflow(
               client_name,
               ContinueAfterRestartWorkflow,
               %{count: 0, task_queue: task_queue},
               workflow_id: "temporalex-restart-continue-#{System.unique_integer([:positive])}",
               workflow_task_timeout: 10_000,
               timeout: 10_000
             )

    assert TemporalDevServer.eventually(fn ->
             Temporalex.Client.query_workflow(handle, "state", [], timeout: 10_000) ==
               {:ok, {:waiting_to_continue, 0}}
           end)

    stop_worker(worker_pid)
    assert Process.alive?(client_pid)

    assert :ok = Temporalex.Client.signal_workflow(handle, "continue", [], timeout: 10_000)

    worker_pid = start_worker!(client_name, task_queue)

    assert {:ok, {:continued, 1}} = Temporalex.Client.get_result(handle, timeout: 30_000)

    worker_pid
  end

  defp start_worker!(client_name, task_queue) do
    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: unique_name(:Worker),
        client: client_name,
        task_queue: task_queue,
        workflows: [
          TimerRestartWorkflow,
          ActivityRestartWorkflow,
          SignalStateWorkflow,
          ContinueAfterRestartWorkflow
        ],
        activities: [Activities],
        max_workflow_pollers: 2,
        max_activity_pollers: 2,
        shutdown_timeout: 15_000
      )

    worker_pid
  end

  defp stop_worker(worker_pid) when is_pid(worker_pid) do
    if Process.alive?(worker_pid) do
      Supervisor.stop(worker_pid, :normal, 15_000)
    end

    :ok
  end

  defp unique_name(prefix) do
    Module.concat(__MODULE__, :"#{prefix}#{System.unique_integer([:positive])}")
  end
end
