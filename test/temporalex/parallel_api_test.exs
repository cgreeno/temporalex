defmodule Temporalex.ParallelApiTest do
  @moduledoc """
  Priority 3 — API.parallel (P1-P8) from TESTS_V2.md.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test activities ---

  defmodule Acts do
    use Temporalex.Activity

    defactivity(work(x), do: {:ok, x})
    defactivity(fail(x), do: {:error, {:bad, x}})
  end

  # --- Test workflows ---

  defmodule TwoBranchWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      results =
        API.parallel([
          fn -> Acts.work(:a) end,
          fn -> Acts.work(:b) end
        ])

      {:ok, results}
    end
  end

  defmodule OrderedWorkflow do
    use Temporalex.Workflow

    def run(%{"ids" => ids}) do
      results =
        API.parallel(
          Enum.map(ids, fn id ->
            fn -> Acts.work(id) end
          end)
        )

      {:ok, results}
    end
  end

  defmodule FailingBranchWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      results =
        API.parallel([
          fn -> Acts.work(:ok1) end,
          fn -> Acts.fail(:oops) end,
          fn -> Acts.work(:ok2) end
        ])

      {:ok, results}
    end
  end

  defmodule RaisingBranchWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      results =
        API.parallel([
          fn -> Acts.work(:safe) end,
          fn -> raise "branch boom" end
        ])

      {:ok, results}
    end
  end

  defmodule NestedParallelWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      [outer_a, outer_b] =
        API.parallel([
          fn ->
            API.parallel([
              fn -> Acts.work(:a1) end,
              fn -> Acts.work(:a2) end
            ])
          end,
          fn ->
            API.parallel([
              fn -> Acts.work(:b1) end,
              fn -> Acts.work(:b2) end
            ])
          end
        ])

      {:ok, %{a: outer_a, b: outer_b}}
    end
  end

  defmodule ParallelInAsyncHandlerWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(nil,
          update: %{
            "fan" => fn _args, state ->
              {:async,
               fn ->
                 results =
                   API.parallel([
                     fn -> Acts.work(:x) end,
                     fn -> Acts.work(:y) end
                   ])

                 API.update_state(fn _ -> {results, results} end)
               end, state}
            end
          },
          signal: %{
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule EmptyParallelWorkflow do
    use Temporalex.Workflow

    def run(_args), do: {:ok, API.parallel([])}
  end

  defmodule SingleBranchWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      [result] = API.parallel([fn -> Acts.work(:only) end])
      {:ok, result}
    end
  end

  # --- Tests ---

  describe "P1 — concurrent execution" do
    test "two branches both reach activity scheduling before any resolves" do
      {:ok, exec} = Testing.start_workflow(TwoBranchWorkflow, %{})

      # Each branch spawns concurrently — mailbox arrival order is
      # nondeterministic. Resolve each activity with its own input so
      # results map back correctly regardless of resolve order.
      assert {:activity, c1} = Testing.next(exec)
      assert {:activity, c2} = Testing.resolve(exec, {:ok, hd(c1.input)})

      assert {:ok, [{:ok, :a}, {:ok, :b}]} =
               Testing.resolve(exec, {:ok, hd(c2.input)})
    end
  end

  describe "P2 — result order matches input order" do
    test "results come back in input position regardless of resolution order" do
      {:ok, exec} = Testing.start_workflow(OrderedWorkflow, %{"ids" => [1, 2, 3, 4]})

      # Resolve each activity using its own input — branches see correct
      # results regardless of mailbox arrival order.
      assert {:activity, c1} = Testing.next(exec)
      assert {:activity, c2} = Testing.resolve(exec, {:ok, hd(c1.input)})
      assert {:activity, c3} = Testing.resolve(exec, {:ok, hd(c2.input)})
      assert {:activity, c4} = Testing.resolve(exec, {:ok, hd(c3.input)})

      # Final parallel results are always ordered by input index.
      assert {:ok, [{:ok, 1}, {:ok, 2}, {:ok, 3}, {:ok, 4}]} =
               Testing.resolve(exec, {:ok, hd(c4.input)})
    end
  end

  describe "P3 — branch failure captured" do
    test "one failing branch does not kill peer branches; all results returned" do
      {:ok, exec} = Testing.start_workflow(FailingBranchWorkflow, %{})

      # Three branches: work(:ok1), fail(:oops), work(:ok2). Failing branch
      # is recognisable by its input :oops.
      resolutions =
        for _ <- 1..3, reduce: {nil, []} do
          {_, acc} ->
            descriptor =
              case acc do
                [] -> Testing.next(exec)
                [last_result | _] -> Testing.resolve(exec, last_result)
              end

            {:activity, call} = descriptor
            input = hd(call.input)

            result =
              case input do
                :oops -> {:error, {:bad, :oops}}
                other -> {:ok, other}
              end

            {descriptor, [result | acc]}
        end

      [last_result | _] = elem(resolutions, 1)

      assert {:ok, results} = Testing.resolve(exec, last_result)
      assert results == [{:ok, :ok1}, {:error, {:bad, :oops}}, {:ok, :ok2}]
    end

    test "raised exception inside a branch surfaces as {:error, _}" do
      {:ok, exec} = Testing.start_workflow(RaisingBranchWorkflow, %{})

      # One branch raises immediately before reaching the activity, so we
      # only see one activity from the safe branch.
      assert {:activity, call} = Testing.next(exec)
      assert call.input == [:safe]

      assert {:ok, results} = Testing.resolve(exec, {:ok, :safe})
      assert [{:ok, :safe}, {:error, _}] = results
    end
  end

  describe "P4 — each branch can call activities" do
    test "independent activity calls per branch, each resolvable in any order" do
      {:ok, exec} = Testing.start_workflow(OrderedWorkflow, %{"ids" => [:alpha, :beta]})

      assert {:activity, c1} = Testing.next(exec)
      assert hd(c1.input) in [:alpha, :beta]

      assert {:activity, c2} = Testing.resolve(exec, {:ok, :"#{hd(c1.input)}_done"})
      assert hd(c2.input) in [:alpha, :beta]
      refute hd(c2.input) == hd(c1.input)

      # Final result order is always by input index — alpha first, beta second.
      assert {:ok, [{:ok, :alpha_done}, {:ok, :beta_done}]} =
               Testing.resolve(exec, {:ok, :"#{hd(c2.input)}_done"})
    end
  end

  describe "P5 — nested parallel" do
    test "parallel inside parallel — 2x2 activities resolve to ordered results" do
      {:ok, exec} = Testing.start_workflow(NestedParallelWorkflow, %{})

      # 4 activity calls total across the nested parallels. Resolve each
      # with its own input so results are correct regardless of arrival order.
      assert {:activity, c1} = Testing.next(exec)
      assert {:activity, c2} = Testing.resolve(exec, {:ok, hd(c1.input)})
      assert {:activity, c3} = Testing.resolve(exec, {:ok, hd(c2.input)})
      assert {:activity, c4} = Testing.resolve(exec, {:ok, hd(c3.input)})

      assert {:ok, result} = Testing.resolve(exec, {:ok, hd(c4.input)})
      assert result.a == [{:ok, :a1}, {:ok, :a2}]
      assert result.b == [{:ok, :b1}, {:ok, :b2}]
    end
  end

  describe "P6 — parallel inside async handler" do
    test "async update handler can use API.parallel" do
      {:ok, exec} = Testing.start_workflow(ParallelInAsyncHandlerWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      update_task = Task.async(fn -> Testing.send_update(exec, "fan", []) end)
      Process.sleep(20)

      assert {:activity, c1} = Testing.next(exec)
      assert {:activity, c2} = Testing.resolve(exec, {:ok, hd(c1.input)})
      assert {:receive, _} = Testing.resolve(exec, {:ok, hd(c2.input)})

      results = Task.await(update_task, 1_000)
      assert results == [{:ok, :x}, {:ok, :y}]

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, [{:ok, :x}, {:ok, :y}]} = Testing.next(exec)
    end
  end

  describe "P7 — empty list" do
    test "API.parallel([]) returns [] without blocking" do
      {:ok, exec} = Testing.start_workflow(EmptyParallelWorkflow, %{})
      assert {:ok, []} = Testing.next(exec)
    end
  end

  describe "P8 — single branch" do
    test "API.parallel([fn]) works like a single sequential call" do
      {:ok, exec} = Testing.start_workflow(SingleBranchWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      assert call.input == [:only]

      assert {:ok, {:ok, :only}} = Testing.resolve(exec, {:ok, :only})
    end
  end
end
