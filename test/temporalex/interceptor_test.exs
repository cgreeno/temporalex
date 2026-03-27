defmodule Temporalex.InterceptorTest do
  use ExUnit.Case, async: true

  alias Temporalex.Interceptor

  # Test interceptor that records calls
  defmodule RecordingInterceptor do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept_client(operation, input, next) do
      send(input[:test_pid], {:client_intercepted, operation, input})
      next.(input)
    end

    @impl true
    def intercept_activity(activity_type, input, ctx, next) do
      send(ctx.worker_pid, {:activity_intercepted, activity_type})
      next.(input, ctx)
    end

    @impl true
    def intercept_workflow(workflow_type, args, next) do
      send(self(), {:workflow_intercepted, workflow_type})
      next.(args)
    end
  end

  # Test interceptor that modifies input
  defmodule EnrichingInterceptor do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept_client(_op, input, next) do
      next.(Map.put(input, :enriched, true))
    end

    @impl true
    def intercept_workflow(_type, args, next) do
      next.(Map.put(args, :enriched, true))
    end
  end

  # Test interceptor that short-circuits
  defmodule BlockingInterceptor do
    @behaviour Temporalex.Interceptor

    @impl true
    def intercept_client(_op, _input, _next) do
      {:error, :blocked}
    end
  end

  # Test interceptor with no optional callbacks
  defmodule NoopInterceptor do
    @behaviour Temporalex.Interceptor
  end

  describe "chain_client/3" do
    test "empty chain calls final directly" do
      chain = Interceptor.chain_client(:start_workflow, [], fn input -> {:ok, input} end)
      assert {:ok, %{id: "123"}} = chain.(%{id: "123"})
    end

    test "single interceptor wraps call" do
      chain =
        Interceptor.chain_client(:start_workflow, [RecordingInterceptor], fn input ->
          {:ok, input}
        end)

      result = chain.(%{test_pid: self(), workflow_id: "wf-1"})
      assert {:ok, _} = result
      assert_receive {:client_intercepted, :start_workflow, %{workflow_id: "wf-1"}}
    end

    test "interceptor chain applies in order" do
      chain =
        Interceptor.chain_client(
          :start_workflow,
          [EnrichingInterceptor, RecordingInterceptor],
          fn input -> {:ok, input} end
        )

      result = chain.(%{test_pid: self(), id: "1"})
      assert {:ok, %{enriched: true}} = result
      assert_receive {:client_intercepted, :start_workflow, %{enriched: true}}
    end

    test "interceptor can short-circuit" do
      chain =
        Interceptor.chain_client(
          :start_workflow,
          [BlockingInterceptor, RecordingInterceptor],
          fn _input -> {:ok, "should not reach"} end
        )

      assert {:error, :blocked} = chain.(%{test_pid: self()})
      refute_receive {:client_intercepted, _, _}
    end

    test "noop interceptor passes through" do
      chain =
        Interceptor.chain_client(:start_workflow, [NoopInterceptor], fn input ->
          {:ok, input}
        end)

      assert {:ok, %{x: 1}} = chain.(%{x: 1})
    end
  end

  describe "chain_activity/3" do
    test "interceptor wraps activity execution" do
      ctx = %Temporalex.Activity.Context{
        activity_id: "act-1",
        activity_type: "Test",
        task_token: "token",
        worker_pid: self()
      }

      chain =
        Interceptor.chain_activity("Test", [RecordingInterceptor], fn input, _ctx ->
          {:ok, input}
        end)

      assert {:ok, %{value: 42}} = chain.(%{value: 42}, ctx)
      assert_receive {:activity_intercepted, "Test"}
    end
  end

  describe "chain_workflow/3" do
    test "interceptor wraps workflow execution" do
      chain =
        Interceptor.chain_workflow("MyWorkflow", [RecordingInterceptor], fn args ->
          {:ok, args}
        end)

      assert {:ok, %{name: "test"}} = chain.(%{name: "test"})
      assert_receive {:workflow_intercepted, "MyWorkflow"}
    end

    test "enriching interceptor modifies args" do
      chain =
        Interceptor.chain_workflow("MyWorkflow", [EnrichingInterceptor], fn args ->
          {:ok, args}
        end)

      assert {:ok, %{enriched: true}} = chain.(%{})
    end
  end
end
