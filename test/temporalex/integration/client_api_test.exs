defmodule Temporalex.ClientApiIntegrationTest do
  @moduledoc """
  Per-method coverage for `Temporalex.Client` against a live Temporal
  dev server: start, get_result, signal, query, update, cancel,
  terminate, describe.

  Connects to a Temporal dev server at 127.0.0.1:7233. Skipped by
  default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Workflow do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("counter", _args, state), do: {:reply, state}
    def handle_query("anything?", _args, state), do: {:reply, {:got, state}}

    def run(initial) do
      API.publish_state(initial)

      result =
        API.phase(initial,
          signal: %{
            "tick" => fn _args, count ->
              new_count = count + 1
              API.publish_state(new_count)
              {:noreply, new_count}
            end,
            "stop" => fn _args, count -> {:stop, count} end
          },
          update: %{
            "bump" => fn [amount], count ->
              new_count = count + amount
              API.publish_state(new_count)
              {:reply, new_count, new_count}
            end
          }
        )

      {:ok, result}
    end
  end

  defmodule LongRunner do
    use Temporalex.Workflow
    def run(_), do: Temporalex.Workflow.API.sleep(60_000) && {:ok, :woke_up}
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    task_queue = "client-api-#{System.unique_integer([:positive])}"

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: "default",
        task_queue: task_queue,
        workflows: [Workflow, LongRunner],
        activities: []
      )

    on_exit(fn ->
      try do
        if Process.alive?(worker_pid), do: Supervisor.stop(worker_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, worker: worker_name}
  end

  test "start_workflow returns a handle with workflow_id and run_id", %{worker: worker} do
    workflow_id = "client-start-#{System.unique_integer([:positive])}"

    assert {:ok, handle} =
             Temporalex.Client.start_workflow(worker, Workflow, 0,
               workflow_id: workflow_id,
               timeout: 10_000
             )

    assert handle.workflow_id == workflow_id
    assert is_binary(handle.run_id) and handle.run_id != ""
    assert handle.workflow_type == Workflow.__workflow_type__()

    # Cleanup so the workflow doesn't linger forever.
    _ = Temporalex.Client.signal_workflow(handle, "stop", [], timeout: 5_000)
    _ = Temporalex.Client.get_result(handle, timeout: 10_000)
  end

  test "signal_workflow delivers the signal to the workflow", %{worker: worker} do
    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, Workflow, 0,
        workflow_id: "client-signal-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    assert :ok = Temporalex.Client.signal_workflow(handle, "tick", [], timeout: 5_000)
    assert :ok = Temporalex.Client.signal_workflow(handle, "tick", [], timeout: 5_000)
    assert :ok = Temporalex.Client.signal_workflow(handle, "stop", [], timeout: 5_000)

    assert {:ok, 2} = Temporalex.Client.get_result(handle, timeout: 15_000)
  end

  test "query_workflow returns the last published state", %{worker: worker} do
    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, Workflow, 7,
        workflow_id: "client-query-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    # Eventually the workflow publishes 7 as its state.
    assert eventually(fn ->
             Temporalex.Client.query_workflow(handle, "counter", [], timeout: 5_000) ==
               {:ok, 7}
           end)

    _ = Temporalex.Client.signal_workflow(handle, "stop", [], timeout: 5_000)
    _ = Temporalex.Client.get_result(handle, timeout: 10_000)
  end

  test "update_workflow returns the handler's reply", %{worker: worker} do
    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, Workflow, 10,
        workflow_id: "client-update-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    # Send a signal first and wait for the workflow to actually process it
    # (signal_workflow returns when the server accepts the signal, not when
    # the workflow has consumed it). Retry the update itself in case the
    # workflow task is still in flight when the first attempt arrives.
    assert :ok = Temporalex.Client.signal_workflow(handle, "tick", [], timeout: 5_000)

    assert eventually(fn ->
             Temporalex.Client.query_workflow(handle, "counter", [], timeout: 2_000) ==
               {:ok, 11}
           end),
           "workflow never processed the tick signal"

    # Retry on transient "not_accepting_update" — happens if the update
    # arrives in a tiny window between activations where state.phase isn't
    # populated in the cached executor's view.
    assert eventually(fn ->
             match?(
               {:ok, 16},
               Temporalex.Client.update_workflow(handle, "bump", [5], timeout: 5_000)
             )
           end),
           "update never accepted"

    assert {:ok, 18} = Temporalex.Client.update_workflow(handle, "bump", [2], timeout: 10_000)

    _ = Temporalex.Client.signal_workflow(handle, "stop", [], timeout: 5_000)
    assert {:ok, 18} = Temporalex.Client.get_result(handle, timeout: 10_000)
  end

  test "describe_workflow returns workflow execution info", %{worker: worker} do
    workflow_id = "client-describe-#{System.unique_integer([:positive])}"

    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, Workflow, 0,
        workflow_id: workflow_id,
        timeout: 10_000
      )

    assert {:ok, description} =
             Temporalex.Client.describe_workflow(handle, timeout: 5_000)

    assert description.workflow_id == workflow_id
    assert description.workflow_type == Workflow.__workflow_type__()
    assert description.status == :running
    assert is_integer(description.history_length)
    assert description.history_length > 0

    _ = Temporalex.Client.signal_workflow(handle, "stop", [], timeout: 5_000)
    _ = Temporalex.Client.get_result(handle, timeout: 10_000)
  end

  test "cancel_workflow requests workflow cancellation", %{worker: worker} do
    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, LongRunner, nil,
        workflow_id: "client-cancel-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    assert :ok = Temporalex.Client.cancel_workflow(handle, timeout: 5_000)

    # LongRunner doesn't actually check cancellation, so the cancel request
    # is recorded but won't end the workflow until the sleep ends. Just
    # verify cancel_workflow itself succeeded — that's the unit under test.
    # Don't wait for the workflow to finish; the on_exit handles teardown.
  end

  test "terminate_workflow forcibly ends the workflow", %{worker: worker} do
    {:ok, handle} =
      Temporalex.Client.start_workflow(worker, LongRunner, nil,
        workflow_id: "client-terminate-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    assert :ok =
             Temporalex.Client.terminate_workflow(handle,
               reason: "client_api_test",
               details: :test_termination,
               timeout: 5_000
             )

    assert {:error, {:terminated, [:test_termination]}} =
             Temporalex.Client.get_result(handle, timeout: 10_000)
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

  defp eventually(fun, timeout \\ 5_000) do
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
        Process.sleep(100)
        do_eventually(fun, deadline)
      end
    end
  end
end
