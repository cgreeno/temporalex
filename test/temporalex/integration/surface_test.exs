defmodule Temporalex.SurfaceIntegrationTest do
  @moduledoc """
  RFC 0002 surface, end to end against a live dev server.

  Covers what the unit tests cannot: that a derived-queue worker actually
  serves the module, that duplicate starts attach under the pinned
  `:use_existing` default (and fail loudly when asked to), that the chain's
  timeout rides the handle, and that address-resolved signal/query land.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  defmodule Greet do
    use Temporalex.Workflow, queue: "surface-greet"

    @impl true
    def id(name), do: "surface-greet-#{name}"

    @impl true
    def run(name), do: {:ok, "Hello, #{name}!"}
  end

  defmodule ZeroConf do
    use Temporalex.Workflow, queue: "surface-zeroconf"

    @impl true
    def id(name), do: "surface-zeroconf-#{name}"

    @impl true
    def run(name), do: {:ok, "Hello, #{name}!"}
  end

  defmodule Anon do
    use Temporalex.Workflow, queue: "surface-greet"

    @impl true
    def id(_), do: :generate

    @impl true
    def run(n), do: {:ok, n}
  end

  defmodule Sleeper do
    use Temporalex.Workflow, queue: "surface-greet"

    alias Temporalex.Workflow.API

    @impl true
    def id(key), do: "surface-sleeper-#{key}"

    @impl true
    def run(_key) do
      :ok = API.sleep(2_000)
      {:ok, :woke}
    end
  end

  defmodule Counter do
    use Temporalex.Workflow, queue: "surface-greet"

    alias Temporalex.Workflow.API

    @impl true
    def id(key), do: "surface-counter-#{key}"

    @impl true
    def handle_query("count", _args, count), do: {:reply, count}

    @impl true
    def run(_key) do
      API.publish_state(0)

      count =
        API.phase(0,
          signal: %{
            "bump" => fn _args, count ->
              API.publish_state(count + 1)
              {:noreply, count + 1}
            end,
            "stop" => fn _args, count -> {:stop, count} end
          }
        )

      {:ok, count}
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client,
        backend: Temporalex.Backend.TemporalCore,
        target: Server.target(),
        namespace: Temporalex.TestSupport.Namespace.name()
      )

    # The worker spec the RFC promises: no name, no task_queue — both derived
    # from the workflow modules.
    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        client: client,
        workflows: [Greet, Sleeper, Counter, Anon],
        activities: []
      )

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

  describe "the one-liner" do
    test "execute! runs on a worker whose queue was derived from the module", %{client: client} do
      name = "fresha-#{System.unique_integer([:positive])}"
      assert Greet.execute!(name, client: client) == "Hello, #{name}!"
    end

    test "the tuple twin", %{client: client} do
      name = "tuple-#{System.unique_integer([:positive])}"
      assert {:ok, "Hello, " <> _} = Greet.execute(name, client: client)
    end
  end

  describe "zero configuration" do
    # The RFC's headline: an unnamed client registers the default name, the
    # worker defaults to it, and the call site names nothing but data.
    test "unnamed client + defaulted worker + bare call" do
      {:ok, client_pid} =
        Temporalex.Client.start_link(
          backend: Temporalex.Backend.TemporalCore,
          target: Server.target(),
          namespace: Temporalex.TestSupport.Namespace.name()
        )

      assert Process.whereis(Temporalex.Client) == client_pid

      {:ok, worker_pid} = Temporalex.Worker.start_link(workflows: [ZeroConf], activities: [])

      try do
        name = "zeroconf-#{System.unique_integer([:positive])}"
        assert ZeroConf.execute!(name) == "Hello, #{name}!"
      after
        Supervisor.stop(worker_pid, :normal, 5_000)
        GenServer.stop(client_pid, :normal, 5_000)
      end
    end
  end

  describe ":generate at the terminal verb" do
    test "a reused :generate start draws a fresh id each time", %{client: client} do
      start = Anon.new(:x, client: client)

      first = Temporalex.start!(start)
      second = Temporalex.start!(start)

      assert first.workflow_id != second.workflow_id
    end
  end

  describe "start! then await" do
    test "start returns a handle; await collects", %{client: client} do
      name = "later-#{System.unique_integer([:positive])}"

      handle = Greet.start!(name, client: client)
      assert handle.workflow_id == "surface-greet-#{name}"
      assert Temporalex.await!(handle) == "Hello, #{name}!"
    end

    test "a chain timeout rides the handle and bounds a later await", %{client: client} do
      key = System.unique_integer([:positive])

      handle =
        key
        |> Sleeper.new(client: client)
        |> Temporalex.timeout(300)
        |> Temporalex.start!()

      assert handle.await_timeout == 300

      # The carried timeout is the caller giving up — the workflow is untouched…
      assert {:error, %Temporalex.TransportError{category: :timeout}} = Temporalex.await(handle)

      # …so a patient await on the same handle still collects the result.
      assert Temporalex.await!(handle, timeout: 10_000) == :woke
    end
  end

  describe "duplicate starts — the pinned :use_existing default" do
    test "a second start attaches to the running execution", %{client: client} do
      key = System.unique_integer([:positive])

      first = Sleeper.start!(key, client: client)
      second = Sleeper.start!(key, client: client)

      assert first.workflow_id == second.workflow_id
      assert first.run_id == second.run_id

      assert Temporalex.await!(second, timeout: 10_000) == :woke
    end

    test "id_conflict_policy: :fail makes duplicates loud", %{client: client} do
      key = System.unique_integer([:positive])
      _running = Sleeper.start!(key, client: client)

      assert {:error, %Temporalex.WorkflowAlreadyStartedError{}} =
               Sleeper.start(key, client: client, id_conflict_policy: :fail)

      assert_raise Temporalex.WorkflowAlreadyStartedError, fn ->
        Sleeper.start!(key, client: client, id_conflict_policy: :fail)
      end
    end
  end

  describe "addressing by business key" do
    test "signal! and query! resolve the target through id/1", %{client: client} do
      key = System.unique_integer([:positive])
      handle = Counter.start!(key, client: client)

      assert :ok = Counter.signal!(key, "bump", nil, client: client)
      assert :ok = Counter.signal!(key, "bump", nil, client: client)

      assert Counter.query!(key, "count", [], client: client) == 2

      assert :ok = Counter.signal!(key, "stop", nil, client: client)
      assert Temporalex.await!(handle, timeout: 10_000) == 2
    end

    test "signalling a workflow that does not exist errors", %{client: client} do
      assert {:error, error} =
               Counter.signal(-System.unique_integer([:positive]), "bump", nil, client: client)

      assert is_exception(error)
    end
  end

  describe "chain policy end to end" do
    test "retry, priority, and fairness are accepted and the workflow completes",
         %{client: client} do
      name = "policy-#{System.unique_integer([:positive])}"

      result =
        name
        |> Greet.new(client: client)
        |> Temporalex.retry(max_attempts: 2)
        |> Temporalex.priority(2)
        |> Temporalex.fairness("salon-#{name}")
        |> Temporalex.execute!()

      assert result == "Hello, #{name}!"
    end
  end

  defp temporal_available? do
    case :gen_tcp.connect(
           String.to_charlist(Server.host()),
           Server.port(),
           [:binary, active: false],
           1_000
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
