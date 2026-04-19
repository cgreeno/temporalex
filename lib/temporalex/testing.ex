defmodule Temporalex.Testing do
  @moduledoc """
  Test helpers for Temporalex workflows and activities.

  ## Usage

      use Temporalex.Testing

  This imports helpers for running workflow logic in tests without
  a Temporal server, and for asserting on workflow/activity behavior.

  ## Example

      defmodule MyApp.GreetWorkflowTest do
        use ExUnit.Case
        use Temporalex.Testing

        test "workflow returns greeting" do
          assert {:ok, "Hello, Alice!"} = run_workflow(MyApp.GreetWorkflow, %{name: "Alice"})
        end

        test "workflow executes expected activity" do
          stub_activity(MyApp.GreetActivity, fn %{name: n} -> {:ok, "Hello, \#{n}!"} end)
          assert {:ok, _} = run_workflow(MyApp.GreetWorkflow, %{name: "Alice"})
          assert_activity_called(MyApp.GreetActivity)
        end
      end
  """

  alias Temporalex.Workflow.API

  defmacro __using__(_opts) do
    quote do
      import Temporalex.Testing
    end
  end

  @doc """
  Build a workflow context for testing. Stores it in the process dictionary.

  Sets up the process dictionary keys that workflow API functions expect.
  Since tests use activity stubs, no real executor is needed.

  ## Options

    * `:workflow_id` - workflow ID (default: "test-wf-<unique>")
    * `:run_id` - run ID (default: "test-run-<unique>")
    * `:workflow_type` - workflow type string (default: derived from module)
    * `:task_queue` - task queue name (default: "test-queue")
    * `:workflow_module` - the workflow module (default: nil)
    * `:patches` - list of patch IDs to pre-notify (default: [])

  """
  def workflow_context(opts \\ []) do
    unique = System.unique_integer([:positive])

    module = Keyword.get(opts, :workflow_module)

    workflow_type =
      Keyword.get_lazy(opts, :workflow_type, fn ->
        if module && function_exported?(module, :__workflow_type__, 0),
          do: module.__workflow_type__(),
          else: "TestWorkflow"
      end)

    workflow_info = %{
      workflow_id: Keyword.get(opts, :workflow_id, "test-wf-#{unique}"),
      run_id: Keyword.get(opts, :run_id, "test-run-#{unique}"),
      workflow_type: workflow_type,
      task_queue: Keyword.get(opts, :task_queue, "test-queue"),
      namespace: Keyword.get(opts, :namespace, "default"),
      attempt: Keyword.get(opts, :attempt, 1)
    }

    patches =
      opts
      |> Keyword.get(:patches, [])
      |> MapSet.new()

    Process.put(:__temporal_workflow_info__, workflow_info)
    Process.put(:__temporal_state__, nil)
    Process.put(:__temporal_patches__, patches)
    Process.put(:__temporal_cancelled__, false)

    signals =
      opts
      |> Keyword.get(:signals, [])
      |> Enum.map(fn {name, payload} -> {name, payload} end)

    Process.put(:__temporal_signal_buffer__, signals)
    Process.put(:__temporal_activity_stubs__, Keyword.get(opts, :activities, %{}))
    Process.put(:__temporal_activity_calls__, [])
    Process.put(:__temporal_child_workflow_stubs__, Keyword.get(opts, :child_workflows, %{}))
    Process.put(:__temporal_child_workflow_calls__, [])

    workflow_info
  end

  @doc """
  Run a workflow's `run/1` callback directly (no Temporal server).

  For workflows that don't call `execute_activity` or other blocking APIs,
  this returns the result immediately. For workflows that yield, you'll
  need to provide activity stubs.

  ## Options

    * `:args` - arguments to pass (default: %{})
    * `:ctx` - pre-built context (default: auto-generated)
    * `:patches` - list of active patch IDs (default: [])

  ## Example

      assert {:ok, "done"} = run_workflow(MyWorkflow, %{input: "value"})

  """
  def run_workflow(module_or_fun, args \\ %{}, opts \\ [])

  def run_workflow(fun, args, opts) when is_function(fun, 1) do
    unless Process.get(:__temporal_workflow_info__) do
      workflow_context(
        patches: Keyword.get(opts, :patches, []),
        activities: Keyword.get(opts, :activities, %{}),
        signals: Keyword.get(opts, :signals, []),
        child_workflows: Keyword.get(opts, :child_workflows, %{})
      )
    end

    apply_runtime_opts(opts)
    fun.(args)
  end

  def run_workflow(module, args, opts) when is_atom(module) do
    unless Process.get(:__temporal_workflow_info__) do
      workflow_context(
        workflow_module: module,
        patches: Keyword.get(opts, :patches, []),
        activities: Keyword.get(opts, :activities, %{}),
        signals: Keyword.get(opts, :signals, []),
        child_workflows: Keyword.get(opts, :child_workflows, %{})
      )
    end

    apply_runtime_opts(opts)
    module.run(args)
  end

  @doc """
  Run an activity's `perform` callback directly.

  Builds an activity context and calls either `perform/1` or `perform/2`
  depending on which the module implements.

  ## Example

      assert {:ok, "Hello, Alice!"} = run_activity(MyApp.GreetActivity, %{name: "Alice"})

  """
  def run_activity(module, input \\ %{}) do
    if function_exported?(module, :perform, 1) do
      module.perform(input)
    else
      ctx = %Temporalex.Activity.Context{
        task_token: "test-token",
        activity_id: "test-activity-#{System.unique_integer([:positive])}",
        activity_type: module.__activity_type__(),
        attempt: 1,
        worker_pid: self(),
        task_queue: "test-queue",
        heartbeat_timeout: nil
      }

      module.perform(ctx, input)
    end
  end

  @doc """
  Get the current workflow state set via `set_state/1`.
  """
  def get_workflow_state do
    Process.get(:__temporal_state__)
  end

  @doc """
  Register an activity stub for the current test process.

  When the workflow calls `execute_activity(module, input)`, the stub
  function is called instead of yielding to the executor.

  ## Example

      stub_activity(ChargePayment, fn %{amount: a} -> {:ok, "charged-\#{a}"} end)
      run_workflow(OrderWorkflow, %{amount: 100})

  """
  def stub_activity(module, fun) when is_atom(module) and is_function(fun, 1) do
    stubs = Process.get(:__temporal_activity_stubs__, %{})
    Process.put(:__temporal_activity_stubs__, Map.put(stubs, module, fun))
    :ok
  end

  def stub_activity({module, name}, fun)
      when is_atom(module) and is_atom(name) and is_function(fun, 1) do
    stubs = Process.get(:__temporal_activity_stubs__, %{})
    Process.put(:__temporal_activity_stubs__, Map.put(stubs, {module, name}, fun))
    :ok
  end

  @doc """
  Get the list of activity calls recorded during the workflow run.

  Returns `[{module, input}, ...]` in call order.
  """
  def get_activity_calls do
    Process.get(:__temporal_activity_calls__, []) |> Enum.reverse()
  end

  @doc """
  Assert that a specific activity was called during the workflow run.

  ## Examples

      assert_activity_called(ChargePayment)
      assert_activity_called(ChargePayment, %{amount: 100})

  """
  defmacro assert_activity_called(module) do
    quote do
      calls = Temporalex.Testing.get_activity_calls()

      assert Enum.any?(calls, fn {mod, _input} -> mod == unquote(module) end),
             "Expected #{inspect(unquote(module))} to be called but got: #{inspect(Enum.map(calls, &elem(&1, 0)))}"
    end
  end

  defmacro assert_activity_called(module, expected_input) do
    quote do
      calls = Temporalex.Testing.get_activity_calls()

      assert Enum.any?(calls, fn {mod, input} ->
               mod == unquote(module) && input == unquote(expected_input)
             end),
             "Expected #{inspect(unquote(module))} called with #{inspect(unquote(expected_input))} but got: #{inspect(calls)}"
    end
  end

  # Apply runtime overrides from opts (for when context was already set up)
  defp apply_runtime_opts(opts) do
    case Keyword.get(opts, :activities) do
      nil -> :ok
      stubs when is_map(stubs) -> Process.put(:__temporal_activity_stubs__, stubs)
    end

    case Keyword.get(opts, :child_workflows) do
      nil -> :ok
      stubs when is_map(stubs) -> Process.put(:__temporal_child_workflow_stubs__, stubs)
    end

    :ok
  end

  # ============================================================
  # Signal simulation
  # ============================================================

  @doc """
  Send a signal to the workflow under test.

  Buffers the signal in the process dictionary so the next
  `wait_for_signal/1` call returns it immediately.

  ## Example

      send_signal("approve", %{approved_by: "admin"})
      assert {:ok, _} = run_workflow(ApprovalWorkflow, %{})

  """
  def send_signal(signal_name, payload \\ nil) do
    API.buffer_signal(signal_name, payload)
    :ok
  end

  # ============================================================
  # Child workflow stubs
  # ============================================================

  @doc """
  Register a child workflow stub for the current test process.

  When the workflow calls `execute_child_workflow(module, input)`,
  the stub function is called instead of yielding to the executor.

  ## Example

      stub_child_workflow(OrderProcessor, fn %{id: id} -> {:ok, "processed-\#{id}"} end)
      assert {:ok, _} = run_workflow(ParentWorkflow, %{id: "123"})

  """
  def stub_child_workflow(module, fun) when is_atom(module) and is_function(fun, 1) do
    stubs = Process.get(:__temporal_child_workflow_stubs__, %{})
    Process.put(:__temporal_child_workflow_stubs__, Map.put(stubs, module, fun))
    :ok
  end

  @doc """
  Get the list of child workflow calls recorded during the workflow run.

  Returns `[{module, input}, ...]` in call order.
  """
  def get_child_workflow_calls do
    Process.get(:__temporal_child_workflow_calls__, []) |> Enum.reverse()
  end

  @doc """
  Assert that a child workflow was called during the workflow run.
  """
  defmacro assert_child_workflow_called(module) do
    quote do
      calls = Temporalex.Testing.get_child_workflow_calls()

      assert Enum.any?(calls, fn {mod, _input} -> mod == unquote(module) end),
             "Expected child workflow #{inspect(unquote(module))} to be called but got: #{inspect(Enum.map(calls, &elem(&1, 0)))}"
    end
  end
end
