defmodule Temporalex.ActivityExecutionTest do
  @moduledoc """
  Priority 1 — Activity Execution (A1-A14) from TESTS_V2.md.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Activity.Context
  alias Temporalex.Testing

  # --- Test activities ---

  defmodule Acts do
    use Temporalex.Activity

    defactivity identity(x) do
      {:ok, x}
    end

    defactivity add(a, b) do
      {:ok, a + b}
    end

    defactivity sum3(a, b, c) do
      {:ok, a + b + c}
    end

    defactivity failing(reason) do
      {:error, reason}
    end

    defactivity with_retry(x),
      retry_policy: %{
        initial_interval_ms: 100,
        max_interval_ms: 30_000,
        backoff_coefficient: 2.0,
        max_attempts: 5,
        non_retryable_error_types: ["FatalError"]
      } do
      {:ok, x}
    end

    defactivity read_context(tag) do
      ctx = Context.current()

      {:ok,
       %{
         tag: tag,
         activity_type: ctx.activity_type,
         attempt: ctx.attempt,
         workflow_id: ctx.workflow_id
       }}
    end
  end

  # --- Test workflows ---

  defmodule SingleWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      Acts.identity(:hello)
    end
  end

  defmodule TwoArgWorkflow do
    use Temporalex.Workflow

    def run(_args), do: Acts.add(2, 3)
  end

  defmodule ThreeArgWorkflow do
    use Temporalex.Workflow

    def run(_args), do: Acts.sum3(1, 2, 3)
  end

  defmodule FailingWorkflow do
    use Temporalex.Workflow

    def run(_args), do: Acts.failing(:oops)
  end

  defmodule RetryConfiguredWorkflow do
    use Temporalex.Workflow

    def run(_args), do: Acts.with_retry(:ok)
  end

  defmodule FanOutWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      results =
        API.parallel([
          fn -> Acts.identity(1) end,
          fn -> Acts.identity(2) end,
          fn -> Acts.identity(3) end
        ])

      {:ok, results}
    end
  end

  # --- Tests ---

  describe "A1 — single activity" do
    test "workflow calls activity, gets result back" do
      {:ok, exec} = Testing.start_workflow(SingleWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      assert call.type == "Temporalex.ActivityExecutionTest.Acts.identity"
      assert call.input == [:hello]

      assert {:ok, :hello} = Testing.resolve(exec, {:ok, :hello})
    end
  end

  describe "A2 — multiple arguments" do
    test "two-argument activity receives both inputs in order" do
      {:ok, exec} = Testing.start_workflow(TwoArgWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      assert call.input == [2, 3]
      assert {:ok, 5} = Testing.resolve(exec, {:ok, 5})
    end

    test "three-argument activity receives all inputs in order" do
      {:ok, exec} = Testing.start_workflow(ThreeArgWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      assert call.input == [1, 2, 3]
      assert {:ok, 6} = Testing.resolve(exec, {:ok, 6})
    end
  end

  describe "A3 — failure propagates to workflow" do
    test "activity {:error, reason} resolution reaches workflow" do
      {:ok, exec} = Testing.start_workflow(FailingWorkflow, %{})

      assert {:activity, _call} = Testing.next(exec)
      assert {:error, :oops} = Testing.resolve(exec, {:error, :oops})
    end
  end

  describe "A4 — activity crash propagates" do
    test "crash-shaped failure reaches workflow as error tuple" do
      {:ok, exec} = Testing.start_workflow(FailingWorkflow, %{})

      assert {:activity, _call} = Testing.next(exec)

      failure = {:error, %{message: "boom", stack_trace: ""}}
      assert ^failure = Testing.resolve(exec, failure)
    end
  end

  describe "A5 — activity not registered" do
    test "activity registry lookup returns nil for unknown type" do
      registry =
        for module <- [Acts],
            {name, _opts} <- module.__temporal_activities__(),
            into: %{} do
          module_str = module |> to_string() |> String.trim_leading("Elixir.")
          type = "#{module_str}.#{name}"
          impl = :"__#{name}__"
          {type, {module, impl}}
        end

      assert Map.fetch!(registry, "Temporalex.ActivityExecutionTest.Acts.identity") ==
               {Acts, :__identity__}

      assert Map.get(registry, "Temporalex.Nothing.nope") == nil
    end
  end

  describe "A6 — activity retry policy (opts passthrough)" do
    test "retry_policy on defactivity flows into the activity call opts" do
      {:ok, exec} = Testing.start_workflow(RetryConfiguredWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      policy = Keyword.fetch!(call.opts, :retry_policy)

      assert policy.initial_interval_ms == 100
      assert policy.backoff_coefficient == 2.0

      Testing.resolve(exec, {:ok, :ok})
    end
  end

  describe "A7 — default retry on error (opts shape)" do
    test "activity without explicit policy sends no retry_policy opt" do
      {:ok, exec} = Testing.start_workflow(SingleWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      refute Keyword.has_key?(call.opts, :retry_policy)

      Testing.resolve(exec, {:ok, :ok})
    end
  end

  describe "A8 — max_attempts passthrough" do
    test "max_attempts is part of the retry policy map" do
      {:ok, exec} = Testing.start_workflow(RetryConfiguredWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      policy = Keyword.fetch!(call.opts, :retry_policy)
      assert policy.max_attempts == 5

      Testing.resolve(exec, {:ok, :ok})
    end
  end

  describe "A9 — non-retryable error types" do
    test "non_retryable_error_types is part of the retry policy map" do
      {:ok, exec} = Testing.start_workflow(RetryConfiguredWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      policy = Keyword.fetch!(call.opts, :retry_policy)
      assert policy.non_retryable_error_types == ["FatalError"]

      Testing.resolve(exec, {:ok, :ok})
    end
  end

  describe "A10 — parallel activities" do
    test "three activities fan out and collect ordered results" do
      {:ok, exec} = Testing.start_workflow(FanOutWorkflow, %{})

      # Mailbox arrival across concurrent branches is nondeterministic.
      # Resolve each activity using its own input so results are correct
      # regardless of ordering; parallel return is always ordered by input.
      assert {:activity, c1} = Testing.next(exec)
      assert {:activity, c2} = Testing.resolve(exec, {:ok, hd(c1.input)})
      assert {:activity, c3} = Testing.resolve(exec, {:ok, hd(c2.input)})

      assert {:ok, [{:ok, 1}, {:ok, 2}, {:ok, 3}]} =
               Testing.resolve(exec, {:ok, hd(c3.input)})
    end
  end

  describe "A11 — Context.current/0 inside activity" do
    test "activity body can read the current context from the process dict" do
      ctx = %Context{
        task_token: <<0>>,
        activity_type: "Temporalex.ActivityExecutionTest.Acts.read_context",
        activity_id: "act-1",
        workflow_id: "wf-1",
        attempt: 2,
        cancel_ref: nil
      }

      Process.put(:__temporal_activity_context__, ctx)

      try do
        assert {:ok, info} = Testing.run_activity(Acts, :read_context, [:tagged])
        assert info.tag == :tagged
        assert info.activity_type == ctx.activity_type
        assert info.attempt == 2
        assert info.workflow_id == "wf-1"
      after
        Process.delete(:__temporal_activity_context__)
      end
    end
  end

  describe "A12 — heartbeat short-circuits when cancelled" do
    test "heartbeat returns {:cancelled, _} once the cancel flag is set" do
      ref = Context.new_cancel_ref()

      ctx = %Context{
        task_token: <<0>>,
        activity_type: "fake",
        activity_id: "a",
        worker: nil,
        cancel_ref: ref
      }

      Process.put(:__temporal_activity_context__, ctx)

      try do
        Context.set_cancelled(ref)
        assert {:cancelled, :activity_cancelled} = Context.heartbeat(:anything)
      after
        Process.delete(:__temporal_activity_context__)
      end
    end
  end

  describe "A13 — cancelled? reflects the atomic flag" do
    test "cancelled?/0 starts false, flips to true after set_cancelled" do
      ref = Context.new_cancel_ref()

      ctx = %Context{
        task_token: <<0>>,
        activity_type: "fake",
        activity_id: "a",
        cancel_ref: ref
      }

      Process.put(:__temporal_activity_context__, ctx)

      try do
        refute Context.cancelled?()
        Context.set_cancelled(ref)
        assert Context.cancelled?()
      after
        Process.delete(:__temporal_activity_context__)
      end
    end
  end

  describe "A14 — cancel atomic primitive" do
    test "set_cancelled writes 1 into slot 1 of the atomics ref" do
      ref = Context.new_cancel_ref()
      assert :atomics.get(ref, 1) == 0

      Context.set_cancelled(ref)
      assert :atomics.get(ref, 1) == 1
    end
  end
end
