defmodule Temporalex.ReplayTest do
  @moduledoc """
  Priority 1 — Replay / Determinism (R1-R15) from TESTS_V2.md.

  Exercises `Temporalex.Worker.Replay` directly for log construction and
  consumption. Side-effect and patched? behavior is tested through the
  Testing.Executor (which stands in for the production Executor).
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing
  alias Temporalex.Worker.Replay

  # Converter.decode expects a payload map. For test fixtures we pre-encode
  # values so the Replay module's decode step produces the original term.
  defp payload(term), do: Temporalex.Converter.encode(term)

  # --- Test workflows ---

  defmodule SideEffectWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      id = API.side_effect(fn -> "generated-#{System.unique_integer([:positive])}" end)
      {:ok, id}
    end
  end

  defmodule PatchedWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      if API.patched?("v2") do
        {:ok, :new_branch}
      else
        {:ok, :old_branch}
      end
    end
  end

  defmodule ThreeActivityWorkflow do
    use Temporalex.Workflow

    defmodule Acts do
      use Temporalex.Activity
      defactivity(one(x), do: {:ok, x})
      defactivity(two(x), do: {:ok, x})
      defactivity(three(x), do: {:ok, x})
    end

    def run(_args) do
      {:ok, a} = Acts.one(1)
      {:ok, b} = Acts.two(2)
      {:ok, c} = Acts.three(3)
      {:ok, {a, b, c}}
    end
  end

  # --- Replay module tests ---

  describe "R1 — full replay" do
    test "all activity resolutions become log entries sorted by seq" do
      jobs = [
        {:resolve_activity, %{seq: 2, result: {:completed, payload(:b)}}},
        {:resolve_activity, %{seq: 1, result: {:completed, payload(:a)}}},
        {:resolve_activity, %{seq: 3, result: {:completed, payload(:c)}}}
      ]

      assert [
               {:activity, 1, :a},
               {:activity, 2, :b},
               {:activity, 3, :c}
             ] = Replay.build_log(jobs)
    end
  end

  describe "R2 — partial replay" do
    test "consuming one entry leaves the rest; next consume on empty log is :new" do
      log = [
        {:activity, 1, :first},
        {:activity, 2, :second}
      ]

      assert {:replay, :first, rest1} = Replay.consume(log, :activity, 1)
      assert {:replay, :second, rest2} = Replay.consume(rest1, :activity, 2)
      assert {:new, []} = Replay.consume(rest2, :activity, 3)
    end
  end

  describe "R3 — activity where timer expected" do
    test "consume raises when the head is an activity but caller asks for timer" do
      log = [{:activity, 1, :ok}]

      assert_raise RuntimeError, ~r/Nondeterminism/, fn ->
        Replay.consume(log, :timer, 1)
      end
    end
  end

  describe "R4 — timer where activity expected" do
    test "consume raises when the head is a timer but caller asks for activity" do
      log = [{:timer, 1, :ok}]

      assert_raise RuntimeError, ~r/Nondeterminism/, fn ->
        Replay.consume(log, :activity, 1)
      end
    end
  end

  describe "R5 — extra call after replay" do
    test "consume on an empty log returns {:new, []}, letting caller schedule" do
      assert {:new, []} = Replay.consume([], :activity, 1)
    end
  end

  describe "R6 — fewer calls than history" do
    test "log retains unconsumed entries (later activations surface them)" do
      log = [
        {:activity, 1, :a},
        {:activity, 2, :b},
        {:activity, 3, :c}
      ]

      assert {:replay, :a, rest} = Replay.consume(log, :activity, 1)
      assert rest == [{:activity, 2, :b}, {:activity, 3, :c}]
    end
  end

  describe "R7 — seq monotonically increasing" do
    test "build_log sorts entries by seq so consume sees them in order" do
      jobs = [
        {:fire_timer, %{seq: 5}},
        {:resolve_activity, %{seq: 1, result: {:completed, payload(:a)}}},
        {:fire_timer, %{seq: 3}},
        {:resolve_activity, %{seq: 2, result: {:completed, payload(:b)}}}
      ]

      log = Replay.build_log(jobs)
      seqs = Enum.map(log, fn {_, seq, _} -> seq end)

      assert seqs == [1, 2, 3, 5]
      assert seqs == Enum.sort(seqs)
    end
  end

  describe "R8 — seqs unique across parallel branches" do
    test "log built from interleaved parallel resolutions has unique seqs" do
      jobs = [
        {:resolve_activity, %{seq: 1, result: {:completed, payload(:branch_a1)}}},
        {:resolve_activity, %{seq: 2, result: {:completed, payload(:branch_b1)}}},
        {:resolve_activity, %{seq: 3, result: {:completed, payload(:branch_a2)}}},
        {:resolve_activity, %{seq: 4, result: {:completed, payload(:branch_b2)}}}
      ]

      log = Replay.build_log(jobs)
      seqs = Enum.map(log, fn {_, seq, _} -> seq end)

      assert seqs == Enum.uniq(seqs)
      assert length(seqs) == 4
    end
  end

  describe "R9 — commands accumulated and flushed in order" do
    test "sequential activity calls surface in workflow order" do
      {:ok, exec} = Testing.start_workflow(ThreeActivityWorkflow, %{})

      assert {:activity, %{input: [1]}} = Testing.next(exec)
      assert {:activity, %{input: [2]}} = Testing.resolve(exec, {:ok, 1})
      assert {:activity, %{input: [3]}} = Testing.resolve(exec, {:ok, 2})
      assert {:ok, {1, 2, 3}} = Testing.resolve(exec, {:ok, 3})
    end
  end

  describe "R10 — side_effect recorded/replay behavior" do
    # The current production Executor does not yet emit SideEffect markers
    # (see lib/temporalex/worker/executor.ex handle_call {:side_effect, _}).
    # A recorded-marker entry, when present in the replay log, would flow
    # through the same `consume/3` mechanism — we verify that contract here
    # using a hypothetical :side_effect entry type.
    test "a recorded side-effect entry in the log would replay unchanged" do
      log = [{:side_effect, 1, "recorded-value"}]
      assert {:replay, "recorded-value", []} = Replay.consume(log, :side_effect, 1)
    end
  end

  describe "R11 — side_effect executes on first run" do
    test "side_effect runs the function inline and returns its value" do
      {:ok, exec} = Testing.start_workflow(SideEffectWorkflow, %{})

      assert {:ok, id} = Testing.next(exec)
      assert String.starts_with?(id, "generated-")
    end
  end

  describe "R12 — patched? on new execution" do
    test "patched? returns true on a fresh execution, taking the new branch" do
      {:ok, exec} = Testing.start_workflow(PatchedWorkflow, %{})
      assert {:ok, :new_branch} = Testing.next(exec)
    end
  end

  describe "R13 — patched? on replay with marker in history" do
    test "patched? returns true when the patch id is pre-marked as seen" do
      {:ok, exec} =
        Testing.start_workflow(PatchedWorkflow, %{},
          is_replaying: true,
          seen_patches: ["v2"]
        )

      assert {:ok, :new_branch} = Testing.next(exec)
    end
  end

  describe "R14 — patched? on replay without marker" do
    test "patched? returns false when replaying and the patch isn't in history" do
      {:ok, exec} = Testing.start_workflow(PatchedWorkflow, %{}, is_replaying: true)

      assert {:ok, :old_branch} = Testing.next(exec)
    end
  end

  describe "R15 — continue-as-new replays correctly" do
    # Continue-as-new produces a brand new execution with a fresh replay log.
    # The log-construction contract is that a CAN activation starts with
    # `initialize_workflow` and no resolve entries — an empty replay log.
    test "fresh activation (only initialize_workflow job) builds an empty log" do
      jobs = [{:initialize_workflow, %{workflow_type: "X", arguments: []}}]
      assert Replay.build_log(jobs) == []
    end
  end
end
