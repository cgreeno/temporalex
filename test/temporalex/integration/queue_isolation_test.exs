defmodule Temporalex.QueueIsolationIntegrationTest do
  @moduledoc """
  The race conditions that queue naming can cause, tested rather than assumed.

  Two properties:

  1. **Namespace isolation.** Two workers polling the *same task-queue name*
     for the *same workflow type* in *different namespaces* never see each
     other's work. This is the regression guard for the flake that motivated
     per-run namespaces: several tests declare fixed queues, and before
     isolation two concurrent runs stole each other's workflow tasks.

  2. **One worker per namespace + queue, per process.** sdk-core refuses to
     register a second worker with overlapping task types on the same
     namespace, task queue and build id, so two in-process workers cannot
     share a queue — the answer for throughput is one worker with higher
     `max_concurrent_*` settings, or a separate OS process. Pinned here
     because someone will reasonably try the other thing.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  alias Temporalex.TestSupport.Namespace

  @moduletag :external
  @moduletag timeout: 120_000

  alias Temporalex.TestSupport.Server

  # Same wire type on purpose — `name:` pins it, so both namespaces answer to
  # the identical workflow type. Only the namespace can keep them apart.
  defmodule AlphaWorkflow do
    use Temporalex.Workflow, queue: "queue-isolation-probe", name: "queue.isolation.probe"

    @impl true
    def id(key), do: "queue-isolation-#{key}"

    @impl true
    def run(_input), do: {:ok, :alpha}
  end

  defmodule BetaWorkflow do
    use Temporalex.Workflow, queue: "queue-isolation-probe", name: "queue.isolation.probe"

    @impl true
    def id(key), do: "queue-isolation-#{key}"

    @impl true
    def run(_input), do: {:ok, :beta}
  end

  defmodule Counted do
    use Temporalex.Workflow, queue: "queue-competing-consumers"

    @impl true
    def id(key), do: "queue-competing-#{key}"

    @impl true
    def run(n), do: {:ok, n * 2}
  end

  setup_all do
    unless match?(
             {:ok, _},
             :gen_tcp.connect(String.to_charlist(Server.host()), Server.port(), [:binary], 1_000)
           ) do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    # A second namespace of this test's own, so the isolation claim is tested
    # against a real namespace boundary rather than a mocked one.
    other = Namespace.create!("#{Namespace.name()}-other")

    {:ok, alpha_client} = start_client(Namespace.name())
    {:ok, beta_client} = start_client(other)

    {:ok, alpha_worker} =
      Temporalex.Worker.start_link(
        name: :queue_isolation_alpha,
        client: alpha_client,
        workflows: [AlphaWorkflow],
        activities: []
      )

    {:ok, beta_worker} =
      Temporalex.Worker.start_link(
        name: :queue_isolation_beta,
        client: beta_client,
        workflows: [BetaWorkflow],
        activities: []
      )

    on_exit(fn ->
      for pid <- [alpha_worker, beta_worker] do
        try do
          if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, alpha_client: alpha_client, beta_client: beta_client, other_namespace: other}
  end

  defp start_client(namespace) do
    name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")

    Temporalex.Client.start_link(
      name: name,
      backend: Temporalex.Backend.TemporalCore,
      target: Server.target(),
      namespace: namespace
    )
  end

  describe "namespace isolation" do
    test "identical queue names in different namespaces cannot steal each other's tasks",
         %{alpha_client: alpha, beta_client: beta} do
      key = System.unique_integer([:positive])

      # Both workers poll "queue-isolation-probe" for workflow type
      # "queue.isolation.probe". If namespaces did not isolate, either
      # implementation could answer either start.
      assert AlphaWorkflow.execute!(key, client: alpha, timeout: 20_000) == :alpha
      assert BetaWorkflow.execute!(key, client: beta, timeout: 20_000) == :beta
    end

    test "the same workflow id can run concurrently in two namespaces",
         %{alpha_client: alpha, beta_client: beta} do
      # Identical workflow id in both namespaces: ids are namespace-scoped, so
      # neither start collides with the other (before isolation this was the
      # WorkflowAlreadyStarted collision between concurrent runs).
      key = System.unique_integer([:positive])

      alpha_handle = AlphaWorkflow.start!(key, client: alpha)
      beta_handle = BetaWorkflow.start!(key, client: beta)

      assert alpha_handle.workflow_id == beta_handle.workflow_id
      assert Temporalex.await!(alpha_handle, timeout: 20_000) == :alpha
      assert Temporalex.await!(beta_handle, timeout: 20_000) == :beta
    end
  end

  describe "two workers, one queue, one namespace" do
    # Not a competing-consumers test, because sdk-core refuses to register a
    # second worker with overlapping task types on the same namespace + task
    # queue + build id inside one process. That constraint is worth pinning:
    # someone will try to run two workers on one queue for throughput, and the
    # answer is a single worker with higher max_concurrent_* settings (or a
    # second OS process / build id).
    test "a second in-process worker on the same namespace and queue is refused",
         %{alpha_client: client} do
      Process.flag(:trap_exit, true)

      {:ok, first} =
        Temporalex.Worker.start_link(
          name: :queue_same_first,
          client: client,
          workflows: [Counted],
          activities: []
        )

      result =
        try do
          Temporalex.Worker.start_link(
            name: :queue_same_second,
            client: client,
            workflows: [Counted],
            activities: []
          )
        catch
          :exit, reason -> {:exit, reason}
        end

      assert inspect(result) =~ "overlapping worker task types",
             "expected sdk-core to refuse the duplicate registration, got: #{inspect(result)}"

      # The first worker is unharmed and still serves its queue.
      # The first argument IS the input (and id/1 derives the workflow id
      # from it) — there is no :input option, by design.
      assert Counted.execute!(21, client: client, timeout: 20_000) == 42

      try do
        if Process.alive?(first), do: Supervisor.stop(first, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
