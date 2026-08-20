defmodule Temporalex.PriorityEffectIntegrationTest do
  @moduledoc """
  The demonstration `:priority` owes: that it changes dispatch order.

  It does not, on any server we can currently run against. Queue a backlog of
  `priority_key: 5` workflows plus one `priority_key: 1` on an empty task
  queue, then start the worker, and the high-priority one runs last — measured
  by the server's own close times, reproduced with the default five pollers
  and with a single poller. Temporal's fairness is newer than
  `temporalio/auto-setup:1.27` and is typically gated behind matching-service
  dynamic config, so this is the server's answer, not ours.

  So this test FAILS today, by design, and is excluded by default.

  It lives in its own module rather than beside the rest of the `:priority`
  coverage for a mechanical reason: ExUnit's `include` beats `exclude`, so a
  test tagged both `:external` and `:priority_effect` runs on
  `mix test --include external` — CI would fail on it. Tagged only
  `:priority_effect`, it stays out until asked for by name:

      mix test --include priority_effect

  What tells us the day this becomes worth running is the canary in
  `test/temporalex/integration/priority_test.exs`, which asserts the server
  still records no priority at all.
  """

  use ExUnit.Case, async: false

  @moduletag :priority_effect
  @moduletag timeout: 180_000

  @low_count 12

  defmodule Workflow do
    use Temporalex.Workflow

    def run(n), do: {:ok, n}
  end

  setup_all do
    case :gen_tcp.connect(~c"127.0.0.1", 7233, [:binary, active: false], 1_000) do
      {:ok, socket} -> :gen_tcp.close(socket)
      _ -> raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    :ok
  end

  test "a high-priority workflow queued last is dispatched first" do
    task_queue = "priority-effect-#{System.unique_integer([:positive])}"
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

    on_exit(fn ->
      try do
        if Process.alive?(client_pid), do: GenServer.stop(client_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    # The backlog goes on while NOTHING is polling, so the whole queue is
    # waiting when the worker arrives and the server is free to choose. The
    # high-priority one is queued LAST, so FIFO and priority disagree: under
    # FIFO it finishes last, under priority it finishes first.
    low =
      for n <- 1..@low_count do
        {:ok, handle} =
          Temporalex.Client.start_workflow(client, Workflow, n,
            workflow_id: "priority-effect-low-#{n}-#{System.unique_integer([:positive])}",
            priority: [priority_key: 5]
          )

        handle
      end

    {:ok, high} =
      Temporalex.Client.start_workflow(client, Workflow, 0,
        workflow_id: "priority-effect-high-#{System.unique_integer([:positive])}",
        priority: [priority_key: 1]
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
      catch
        :exit, _ -> :ok
      end
    end)

    for handle <- [high | low] do
      assert {:ok, _} = Temporalex.Client.get_result(handle, timeout: 60_000)
    end

    # Close time is the server's own record of when each finished, so the
    # ordering claim does not depend on the order we awaited them in.
    high_close = close_time(high)
    low_closes = Enum.map(low, &close_time/1)
    later = Enum.count(low_closes, &(&1 > high_close))

    # Deliberately not "first of all 12": weighted dispatch is not a strict
    # ordering guarantee, and a worker with several slots runs some overlap. A
    # high-priority task queued last landing in the front half is the weakest
    # claim that FIFO cannot satisfy.
    assert later >= div(@low_count, 2) + 1,
           """
           priority did not affect dispatch order: the high-priority workflow \
           finished before only #{later} of #{length(low_closes)} low-priority \
           ones, and it was queued last of all.

           high close: #{high_close}
           low closes: #{inspect(Enum.sort(low_closes))}
           """
  end

  defp close_time(handle) do
    {:ok, description} = Temporalex.Client.describe_workflow(handle)
    Map.fetch!(description, :close_time_ms)
  end
end
