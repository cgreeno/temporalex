defmodule Temporalex.InterceptorUnitTest do
  @moduledoc """
  Interceptor tests that need no Temporal server.

  The chain, its ordering, its ability to change options, and startup validation
  are all observable through `Temporalex.Backend.Test`: the chain has already run
  by the time the backend refuses the operation. Header replay-safety is covered
  through the in-process harness.

  The server-backed behaviour — a header actually reaching a workflow and an
  activity — lives in `test/temporalex/integration/interceptor_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Temporalex.Interceptor.Context

  defmodule Recorder do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Context{} = context, opts, next) do
      send(Application.get_env(:temporalex, :test_sink), {:intercepted, context, opts})
      next.(opts)
    end
  end

  defmodule Outer do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Context{}, opts, next) do
      sink = Application.get_env(:temporalex, :test_sink)
      send(sink, :outer_before)
      result = next.(opts)
      send(sink, :outer_after)
      result
    end
  end

  defmodule Inner do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Context{}, opts, next) do
      send(Application.get_env(:temporalex, :test_sink), :inner)
      next.(opts)
    end
  end

  defmodule AddsHeader do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Context{}, opts, next) do
      next.(Keyword.put(opts, :headers, %{"injected" => "yes"}))
    end
  end

  defmodule ShortCircuits do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept(%Context{}, _opts, _next), do: {:ok, :short_circuited}
  end

  defmodule NotAnInterceptor do
    def hello, do: :world
  end

  setup do
    Application.put_env(:temporalex, :test_sink, self())
    on_exit(fn -> Application.delete_env(:temporalex, :test_sink) end)
    :ok
  end

  describe "validation at client start (no server needed)" do
    test "a module without intercept/3 is rejected" do
      assert {:error, {%ArgumentError{} = error, _}} =
               start_client(interceptors: [NotAnInterceptor])

      assert Exception.message(error) =~ "does not export intercept/3"
    end

    test "a non-module is rejected" do
      assert {:error, {%ArgumentError{} = error, _}} = start_client(interceptors: ["nope"])
      assert Exception.message(error) =~ "expected an interceptor module"
    end

    test "a module that does not exist is rejected" do
      assert {:error, {error, _}} = start_client(interceptors: [:no_such_module_anywhere])
      assert is_exception(error)
    end

    test "a valid interceptor starts" do
      assert {:ok, _pid} = start_client(interceptors: [Recorder])
    end
  end

  describe "the chain" do
    test "receives a Context carrying the operation and client" do
      client = start_client!(interceptors: [Recorder])
      _ = Temporalex.Client.start_workflow(client, "SomeType", nil, workflow_id: "u-1")

      assert_receive {:intercepted, %Context{operation: :start_workflow, client: ^client}, opts}
      assert Keyword.get(opts, :workflow_id) == "u-1"
    end

    test "does not leak the internal :client_monitor key to interceptors" do
      client = start_client!(interceptors: [Recorder])
      _ = Temporalex.Client.start_workflow(client, "SomeType", nil, workflow_id: "u-2")

      assert_receive {:intercepted, %Context{}, opts}

      # Dropping or corrupting this key disables client-down detection or raises
      # from a private backend function, so interceptors must never see it.
      refute Keyword.has_key?(opts, :client_monitor)
    end

    test "runs outside-in with the operation innermost" do
      client = start_client!(interceptors: [Outer, Inner])
      _ = Temporalex.Client.start_workflow(client, "SomeType", nil, workflow_id: "u-3")

      assert_receive :outer_before
      assert_receive :inner
      assert_receive :outer_after
    end

    test "an interceptor can change the options the operation sees" do
      client = start_client!(interceptors: [AddsHeader, Recorder])
      _ = Temporalex.Client.start_workflow(client, "SomeType", nil, workflow_id: "u-4")

      # Recorder sits after AddsHeader, so it observes the mutated opts.
      assert_receive {:intercepted, %Context{}, opts}
      assert Keyword.get(opts, :headers) == %{"injected" => "yes"}
    end

    test "not calling next short-circuits the operation" do
      client = start_client!(interceptors: [ShortCircuits])

      assert {:ok, :short_circuited} =
               Temporalex.Client.start_workflow(client, "SomeType", nil, workflow_id: "u-5")
    end

    test "no interceptors is a straight passthrough" do
      client = start_client!([])
      # Backend.Test refuses the operation, which proves it was reached.
      assert {:error, _} =
               Temporalex.Client.start_workflow(client, "SomeType", nil, workflow_id: "u-6")
    end

    test "interceptors run for operations other than start_workflow" do
      client = start_client!(interceptors: [Recorder])
      _ = Temporalex.Client.describe_workflow(client, "u-7", [])

      assert_receive {:intercepted, %Context{operation: :describe_workflow}, _opts}
    end
  end

  defp start_client!(client_opts) do
    {:ok, pid} = start_client(client_opts)

    on_exit(fn ->
      # Racy by nature: the client may already be gone by the time this runs.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  defp start_client(client_opts) do
    Process.flag(:trap_exit, true)

    Temporalex.Client.start_link(
      Keyword.merge(client_opts, backend: Temporalex.Backend.Test, namespace: "default")
    )
  end
end
