defmodule Temporalex.TimeoutRetryIntegrationTest do
  @moduledoc """
  The live proof for #22: an activity attempt that exceeds
  `start_to_close_timeout` must retry under its retry policy.

  Under the old implicit `schedule_to_close = start_to_close` default, attempt
  one's timeout consumed the whole cross-attempt cap and the server reported
  `:non_retryable_failure` — the workflow failed instead of retrying. This is
  the issue's exact repro: attempt 1 hangs past the timeout, attempt 2
  succeeds.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external
  @moduletag timeout: 60_000

  defmodule Acts do
    use Temporalex.Activity

    defactivity flaky_provider(ctx, order_id),
      start_to_close_timeout: 1_000,
      retry_policy: [maximum_attempts: 3, initial_interval: 100] do
      if ctx.attempt == 1 do
        # Hang past start_to_close: this attempt WILL be timed out by the
        # server. The whole point of #22: the next attempt must still run.
        Process.sleep(3_000)
        {:ok, :never_reached}
      else
        {:ok, {:recovered_on_attempt, ctx.attempt, order_id}}
      end
    end
  end

  defmodule Checkout do
    use Temporalex.Workflow, queue: "s2c-retry"

    @impl true
    def id(order_id), do: "s2c-retry-#{order_id}"

    @impl true
    def run(order_id), do: {:ok, Acts.flaky_provider!(order_id)}
  end

  setup_all do
    unless match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", 7233, [:binary], 1_000)) do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: "default"
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(client: client, workflows: [Checkout], activities: [Acts])

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

  test "a timed-out attempt retries and the next attempt completes the workflow",
       %{client: client} do
    order_id = System.unique_integer([:positive])

    assert {:recovered_on_attempt, attempt, ^order_id} =
             Checkout.execute!(order_id, client: client, timeout: 30_000)

    assert attempt > 1, "the activity succeeded on attempt 1 — the repro never timed out"
  end
end
