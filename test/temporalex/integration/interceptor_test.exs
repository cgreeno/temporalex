defmodule Temporalex.InterceptorIntegrationTest do
  @moduledoc """
  Coverage for client interceptors.

  The headline case is the one that motivated them: an interceptor injecting a
  trace header at start, and the workflow reading that header back — proving
  context actually crosses the client/workflow boundary rather than just being
  accepted by the option.

  Client-side only. Workflow-side interception is deliberately absent: workflow
  code is replayed, so a value minted per call would land in a command and differ
  on replay. See `Temporalex.Interceptor`.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  # Publishes its inbound headers so a test can assert what arrived.
  defmodule HeaderEcho do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_), do: {:ok, API.headers()}
  end

  defmodule Plain do
    use Temporalex.Workflow

    def run(n), do: {:ok, n}
  end

  defmodule Activities do
    use Temporalex.Activity

    # Reports the headers the activity task carried, so a test can prove context
    # crossed the workflow -> activity boundary.
    defactivity echo_headers(ctx), start_to_close_timeout: 5_000 do
      {:ok, ctx.headers}
    end
  end

  # Copies its own inbound headers onto the activity it schedules. Copying values
  # that came from history is replay-safe; minting new ones would not be.
  defmodule PropagatesToActivity do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      API.execute_activity("#{inspect(Activities)}.echo_headers", [], headers: API.headers())
    end
  end

  defmodule DoesNotPropagate do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      {:ok, activity_headers} = API.execute_activity("#{inspect(Activities)}.echo_headers", [])
      {:ok, %{"workflow" => API.headers(), "activity" => activity_headers}}
    end
  end

  defmodule ChildHeaderEcho do
    use Temporalex.Workflow

    def run(_), do: {:ok, Temporalex.Workflow.API.headers()}
  end

  defmodule PropagatesToChild do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(child_id) do
      API.execute_child_workflow(inspect(ChildHeaderEcho), [nil],
        workflow_id: child_id,
        headers: API.headers()
      )
    end
  end

  # Injects a trace header on start, the way a real tracing interceptor would.
  defmodule Tracing do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Temporalex.Interceptor.Context{operation: :start_workflow}, opts, next) do
      headers =
        opts
        |> Keyword.get(:headers, %{})
        |> Map.put("traceparent", "00-abcdef-42-01")

      next.(Keyword.put(opts, :headers, headers))
    end

    def intercept(%Temporalex.Interceptor.Context{}, opts, next), do: next.(opts)
  end

  # Records the operations it saw, in order, on a named agent.
  defmodule Recorder do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Temporalex.Interceptor.Context{operation: operation}, opts, next) do
      Agent.update(__MODULE__, &[operation | &1])
      next.(opts)
    end
  end

  defmodule Outer do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Temporalex.Interceptor.Context{}, opts, next) do
      Agent.update(Recorder, &[:outer_before | &1])
      result = next.(opts)
      Agent.update(Recorder, &[:outer_after | &1])
      result
    end
  end

  defmodule Inner do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Temporalex.Interceptor.Context{}, opts, next) do
      Agent.update(Recorder, &[:inner | &1])
      next.(opts)
    end
  end

  defmodule Boom do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Temporalex.Interceptor.Context{}, _opts, _next),
      do: raise("interceptor blew up")
  end

  defmodule NotAnInterceptor do
    def hello, do: :world
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    :ok
  end

  describe "trace context injection — the motivating case" do
    test "a header added by an interceptor reaches the workflow" do
      client = start_stack(interceptors: [Tracing])

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, HeaderEcho, nil,
          workflow_id: "icept-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      assert {:ok, headers} = Temporalex.Client.get_result(handle, timeout: 10_000)
      assert headers["traceparent"] == "00-abcdef-42-01"
    end

    test "an interceptor does not clobber headers the caller already set" do
      client = start_stack(interceptors: [Tracing])

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, HeaderEcho, nil,
          workflow_id: "icept-#{System.unique_integer([:positive])}",
          headers: %{"tenant" => "salon-4291"},
          timeout: 10_000
        )

      assert {:ok, headers} = Temporalex.Client.get_result(handle, timeout: 10_000)
      assert headers["traceparent"] == "00-abcdef-42-01"
      assert headers["tenant"] == "salon-4291"
    end

    # Paired with a positive assertion so this cannot pass just because headers
    # never arrive at all.
    test "without the interceptor the header is absent, but others still arrive" do
      client = start_stack([])

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, HeaderEcho, nil,
          workflow_id: "icept-#{System.unique_integer([:positive])}",
          headers: %{"tenant" => "salon-4291"},
          timeout: 10_000
        )

      assert {:ok, headers} = Temporalex.Client.get_result(handle, timeout: 10_000)
      assert headers["tenant"] == "salon-4291"
      refute Map.has_key?(headers, "traceparent")
    end
  end

  describe "propagation onward from the workflow" do
    test "context reaches an activity" do
      client = start_stack(interceptors: [Tracing])

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, PropagatesToActivity, nil,
          workflow_id: "icept-#{System.unique_integer([:positive])}",
          timeout: 15_000
        )

      assert {:ok, headers} = Temporalex.Client.get_result(handle, timeout: 15_000)
      assert headers["traceparent"] == "00-abcdef-42-01"
    end

    test "context reaches a child workflow" do
      client = start_stack(interceptors: [Tracing])
      child_id = "icept-child-#{System.unique_integer([:positive])}"

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, PropagatesToChild, child_id,
          workflow_id: "icept-#{System.unique_integer([:positive])}",
          timeout: 15_000
        )

      assert {:ok, headers} = Temporalex.Client.get_result(handle, timeout: 15_000)
      assert headers["traceparent"] == "00-abcdef-42-01"
    end

    # Propagation is explicit, not something the SDK does behind the caller's
    # back: the same interceptor is installed, the workflow receives the header,
    # and the activity still sees nothing because the workflow did not pass it.
    test "an activity gets no headers when the workflow does not pass them" do
      client = start_stack(interceptors: [Tracing])

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, DoesNotPropagate, nil,
          workflow_id: "icept-#{System.unique_integer([:positive])}",
          timeout: 15_000
        )

      assert {:ok, seen} = Temporalex.Client.get_result(handle, timeout: 15_000)

      # Differential: the workflow DID receive it, the activity did not.
      assert seen["workflow"]["traceparent"] == "00-abcdef-42-01"
      refute Map.has_key?(seen["activity"], "traceparent")
    end
  end

  describe "the chain" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> [] end, name: Recorder)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
      :ok
    end

    test "sees the operation name" do
      client = start_stack(interceptors: [Recorder])
      run_plain(client)

      operations = Agent.get(Recorder, &Enum.reverse(&1))
      assert :start_workflow in operations
      assert :get_result in operations
    end

    test "runs outside-in, with the operation innermost" do
      client = start_stack(interceptors: [Outer, Inner])
      run_plain(client)

      # Only the start_workflow pass matters for ordering here.
      trace = Agent.get(Recorder, &Enum.reverse(&1))
      assert Enum.take(trace, 3) == [:outer_before, :inner, :outer_after]
    end

    test "an empty list behaves as no interceptors" do
      client = start_stack(interceptors: [])
      assert {:ok, 7} = run_plain(client)
    end

    test "a bare module is accepted as well as a list" do
      client = start_stack(interceptors: Tracing)

      {:ok, handle} =
        Temporalex.Client.start_workflow(client, HeaderEcho, nil,
          workflow_id: "icept-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      # Asserting the header proves the bare module was actually installed and
      # ran; asserting only that the workflow completed would pass regardless.
      assert {:ok, headers} = Temporalex.Client.get_result(handle, timeout: 10_000)
      assert headers["traceparent"] == "00-abcdef-42-01"
    end
  end

  describe "failure and validation" do
    test "a raising interceptor surfaces to the caller rather than being swallowed" do
      client = start_stack(interceptors: [Boom])

      assert_raise RuntimeError, ~r/interceptor blew up/, fn ->
        run_plain(client)
      end
    end

    test "a module without intercept/3 is rejected at client start" do
      assert {:error, %ArgumentError{} = error} =
               start_client_result(interceptors: [NotAnInterceptor])

      assert Exception.message(error) =~ "does not export intercept/3"
    end

    test "a non-module is rejected at client start" do
      assert {:error, %ArgumentError{} = error} = start_client_result(interceptors: ["nope"])
      assert Exception.message(error) =~ "expected an interceptor module"
    end
  end

  defp run_plain(client) do
    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Plain, 7,
        workflow_id: "icept-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    Temporalex.Client.get_result(handle, timeout: 10_000)
  end

  defp start_stack(client_opts) do
    task_queue = "icept-#{System.unique_integer([:positive])}"
    client = start_client!(Keyword.put(client_opts, :task_queue, task_queue))
    worker = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker,
        client: client,
        task_queue: task_queue,
        workflows: [
          Plain,
          HeaderEcho,
          PropagatesToActivity,
          PropagatesToChild,
          ChildHeaderEcho,
          DoesNotPropagate
        ],
        activities: [Activities]
      )

    stop_on_exit(worker_pid, &Supervisor.stop/3)
    client
  end

  # A raise inside init comes back from start_link as {:error, {exception, stack}}
  # rather than an exit, so this matches the return value.
  defp start_client_result(client_opts) do
    Process.flag(:trap_exit, true)

    case Temporalex.Client.start_link(client_opts_for(client_opts)) do
      {:ok, pid} ->
        stop_on_exit(pid, &GenServer.stop/3)
        :ok

      {:error, {%ArgumentError{} = error, _stacktrace}} ->
        {:error, error}

      other ->
        other
    end
  end

  defp start_client!(client_opts) do
    opts = client_opts_for(client_opts)
    {:ok, pid} = Temporalex.Client.start_link(opts)
    stop_on_exit(pid, &GenServer.stop/3)
    Keyword.fetch!(opts, :name)
  end

  defp client_opts_for(client_opts) do
    Keyword.merge(client_opts,
      name: Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}"),
      backend: Temporalex.Backend.TemporalCore,
      target: Server.target(),
      namespace: Temporalex.TestSupport.Namespace.name(),
      task_queue: Keyword.get(client_opts, :task_queue, "default")
    )
  end

  defp stop_on_exit(pid, stop_fun) do
    on_exit(fn ->
      try do
        if Process.alive?(pid), do: stop_fun.(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)
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
