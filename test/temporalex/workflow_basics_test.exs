defmodule Temporalex.WorkflowBasicsTest do
  @moduledoc """
  Priority 1 — Workflow Basics (W1-W12) from TESTS_V2.md.

  Unit tests against `Temporalex.Testing.Executor`. Server-level behavior
  (registry lookup, string dispatch) is exercised via the workflow-type
  mechanism each module generates.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test activities ---

  defmodule Activities.Noop do
    use Temporalex.Activity

    defactivity run(x) do
      {:ok, x}
    end

    defactivity slow(x), timeout: 60_000 do
      {:ok, x}
    end
  end

  # --- Test workflows ---

  defmodule HappyWorkflow do
    use Temporalex.Workflow

    def run(args) do
      {:ok, result} = Activities.Noop.run(args["x"])
      {:ok, result}
    end
  end

  defmodule ErrorWorkflow do
    use Temporalex.Workflow

    def run(_args), do: {:error, :boom}
  end

  defmodule ContinueWorkflow do
    use Temporalex.Workflow

    def run(args) do
      gen = Map.get(args, "gen", 0)

      if gen >= 2 do
        {:ok, gen}
      else
        {:continue_as_new, %{"gen" => gen + 1}}
      end
    end
  end

  defmodule NoArgsWorkflow do
    use Temporalex.Workflow

    def run(args), do: {:ok, Map.get(args, "missing", :default)}
  end

  defmodule CrashWorkflow do
    use Temporalex.Workflow

    def run(_args), do: raise("deliberate crash")
  end

  defmodule MultiArgWorkflow do
    use Temporalex.Workflow

    def run(%{"a" => a, "b" => b, "c" => c}) do
      {:ok, %{sum: a + b + c, values: [a, b, c]}}
    end
  end

  defmodule PureWorkflow do
    use Temporalex.Workflow

    def run(_args), do: {:ok, :pure}
  end

  defmodule TimeoutOptsWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, x} = Activities.Noop.slow(99)
      {:ok, x}
    end
  end

  # --- Tests ---

  describe "W1 — happy path" do
    test "workflow starts, runs activity, returns {:ok, result}" do
      {:ok, exec} = Testing.start_workflow(HappyWorkflow, %{"x" => 42})

      assert {:activity, call} = Testing.next(exec)
      assert call.input == [42]

      assert {:ok, 42} = Testing.resolve(exec, {:ok, 42})
    end
  end

  describe "W2 — error return" do
    test "workflow returning {:error, reason} surfaces as final state" do
      {:ok, exec} = Testing.start_workflow(ErrorWorkflow, %{})
      assert {:error, :boom} = Testing.next(exec)
    end
  end

  describe "W3 — continue-as-new" do
    test "returns {:continue_as_new, args} on an incomplete generation" do
      {:ok, exec} = Testing.start_workflow(ContinueWorkflow, %{"gen" => 0})
      assert {:continue_as_new, %{"gen" => 1}} = Testing.next(exec)
    end

    test "final generation returns {:ok, value}" do
      {:ok, exec} = Testing.start_workflow(ContinueWorkflow, %{"gen" => 2})
      assert {:ok, 2} = Testing.next(exec)
    end
  end

  describe "W4 — empty arguments" do
    test "workflow called with empty map completes cleanly" do
      {:ok, exec} = Testing.start_workflow(NoArgsWorkflow, %{})
      assert {:ok, :default} = Testing.next(exec)
    end
  end

  describe "W5 — crash" do
    test "raise in run/1 surfaces as {:error, {:crashed, reason}}" do
      {:ok, exec} = Testing.start_workflow(CrashWorkflow, %{})

      assert {:error, {:crashed, reason}} = Testing.next(exec)
      assert inspect(reason) =~ "deliberate crash"
    end
  end

  describe "W6 — multiple input arguments" do
    test "workflow destructures all keys from the args map" do
      args = %{"a" => 10, "b" => 20, "c" => 30}
      {:ok, exec} = Testing.start_workflow(MultiArgWorkflow, args)

      assert {:ok, %{sum: 60, values: [10, 20, 30]}} = Testing.next(exec)
    end
  end

  describe "W7 — pure workflow" do
    test "workflow with no blocking calls completes immediately" do
      {:ok, exec} = Testing.start_workflow(PureWorkflow, %{})
      assert {:ok, :pure} = Testing.next(exec)
    end
  end

  describe "W8 — compile-time validation" do
    test "workflow module missing run/1 raises CompileError" do
      code = """
      defmodule Temporalex.WorkflowBasicsTest.MissingRun do
        use Temporalex.Workflow
      end
      """

      assert_raise CompileError, ~r/must define run\/1/, fn ->
        Code.compile_string(code)
      end
    end
  end

  describe "W9 — workflow type string" do
    test "__temporal_workflow_type__/0 strips the Elixir. prefix" do
      assert HappyWorkflow.__temporal_workflow_type__() ==
               "Temporalex.WorkflowBasicsTest.HappyWorkflow"

      refute String.starts_with?(HappyWorkflow.__temporal_workflow_type__(), "Elixir.")
    end
  end

  describe "W10 — unknown workflow type" do
    test "registry lookup by type string returns nil for unregistered workflows" do
      # Mirror the exact registry shape the Server builds at startup:
      # see Temporalex.Worker.Server.build_workflow_registry/1.
      registry =
        for module <- [HappyWorkflow, ErrorWorkflow], into: %{} do
          {module.__temporal_workflow_type__(), module}
        end

      assert Map.get(registry, HappyWorkflow.__temporal_workflow_type__()) == HappyWorkflow
      assert Map.get(registry, "Temporalex.Nothing") == nil
    end
  end

  describe "W11 — activity options passthrough" do
    test "timeout from defactivity opts reaches the activity call descriptor" do
      {:ok, exec} = Testing.start_workflow(TimeoutOptsWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      assert Keyword.get(call.opts, :timeout) == 60_000

      assert {:ok, 99} = Testing.resolve(exec, {:ok, 99})
    end
  end

  describe "W12 — dynamic workflow dispatch" do
    test "registry resolves workflow type string to module for dispatch" do
      registry =
        for module <- [HappyWorkflow, PureWorkflow, ContinueWorkflow], into: %{} do
          {module.__temporal_workflow_type__(), module}
        end

      # Simulate the Server lookup path — a workflow type arriving as a string
      # on an initialize_workflow job, resolved to a module, then invoked.
      type_string = "Temporalex.WorkflowBasicsTest.PureWorkflow"
      module = Map.fetch!(registry, type_string)

      assert module == PureWorkflow
      assert module.run(%{}) == {:ok, :pure}
    end
  end
end
