defmodule Temporalex.FailFlagshipIntegrationTest do
  @moduledoc """
  The README's flagship error round trip, live: `Temporalex.fail!/2` in the
  activity, the `%{cause: %{type: ...}}` match through the ActivityError
  wrapper in the workflow, both branches, plus retry semantics driven by
  `retry:` through the real server.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Payments do
    use Temporalex.Activity, start_to_close_timeout: 5_000

    # maximum_attempts: 3 allows retries, so retry: false is what prevents
    # them. The attempt > 1 branch fails with a type the workflow does not
    # match: if retry: false stopped suppressing retries, attempt 2 would run
    # and the workflow would fail with a CaseClauseError instead of returning
    # :limit_exceeded.
    defactivity charge(ctx, amount), retry_policy: [maximum_attempts: 3, initial_interval: 100] do
      cond do
        ctx.attempt > 1 ->
          Temporalex.fail!("retried despite retry: false", type: "Retried")

        amount > 10_000 ->
          Temporalex.fail!("amount exceeds limit", type: "AmountTooLarge", retry: false)

        true ->
          {:ok, {:charged, amount}}
      end
    end

    # Fails attempt 1 with retry: true (the default). Temporal must retry it.
    defactivity flaky(ctx, amount), retry_policy: [maximum_attempts: 3, initial_interval: 100] do
      if ctx.attempt == 1 do
        Temporalex.fail!("transient wobble", type: "Transient")
      else
        {:ok, {:charged_on_attempt, ctx.attempt, amount}}
      end
    end
  end

  defmodule Checkout do
    use Temporalex.Workflow, queue: "fail-flagship"

    @impl true
    def id(key), do: "fail-flagship-#{key}"

    @impl true
    def run({:charge, amount}) do
      case Payments.charge(amount) do
        {:ok, charge} -> {:ok, charge}
        {:error, %{cause: %{type: "AmountTooLarge"}}} -> {:ok, :limit_exceeded}
      end
    end

    def run({:flaky, amount}), do: {:ok, Payments.flaky!(amount)}
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
      Temporalex.Worker.start_link(client: client, workflows: [Checkout], activities: [Payments])

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

  test "the happy branch", %{client: client} do
    key = System.unique_integer([:positive])
    assert {:charged, 500} = Checkout.execute!({:charge, 500}, id: "ff-ok-#{key}", client: client)
  end

  test "retry: false is final: one attempt, matched through the wrapper", %{client: client} do
    key = System.unique_integer([:positive])

    assert :limit_exceeded =
             Checkout.execute!({:charge, 20_000}, id: "ff-limit-#{key}", client: client)
  end

  test "retry: true (the default) actually retries: attempt 2 succeeds", %{client: client} do
    key = System.unique_integer([:positive])

    assert {:charged_on_attempt, attempt, 100} =
             Checkout.execute!({:flaky, 100},
               id: "ff-flaky-#{key}",
               client: client,
               timeout: 20_000
             )

    assert attempt > 1
  end
end
