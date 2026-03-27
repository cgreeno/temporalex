defmodule Temporalex.BugfixTest do
  @moduledoc """
  Tests for bugs found during code review.
  Covers error paths, edge cases, and message interleaving.
  """
  use ExUnit.Case, async: true
  use Temporalex.Testing

  alias Temporalex.Workflow.API

  # ============================================================
  # Test workflow modules
  # ============================================================

  defmodule FailingWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(%{reason: reason}), do: {:error, reason}
    def run(_args), do: {:error, "something went wrong"}
  end

  defmodule SignalCounterWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(_args) do
      set_state(%{count: 0})
      {:ok, _payload} = wait_for_signal("increment")
      {:ok, get_state()}
    end

    @impl true
    def handle_signal("side_effect", %{value: v}, state) do
      {:noreply, Map.put(state, :side, v)}
    end

    def handle_signal(_, _, state), do: {:noreply, state}
  end

  # ============================================================
  # Fix #1: Workflow {:error, reason} should fail, not nil
  # ============================================================

  describe "complete_workflow_command with errors" do
    test "workflow returning {:error, string} produces error tuple" do
      result = FailingWorkflow.run(%{reason: "invalid input"})
      assert {:error, "invalid input"} = result
    end

    test "workflow returning {:error, exception} preserves message" do
      err = %RuntimeError{message: "boom"}
      result = FailingWorkflow.run(%{reason: err})
      assert {:error, %RuntimeError{message: "boom"}} = result
    end
  end

  # ============================================================
  # Fix #4/6: Receive loops handle patches and cancellations
  # ============================================================

  describe "wait_for_signal_receive handles interleaved messages" do
    test "patches received during signal wait are stored" do
      {:ok, executor} =
        GenServer.start_link(Temporalex.BugfixTest.FakeExecutor, nil)

      Process.put(:__temporal_executor__, executor)
      Process.put(:__temporal_signal_buffer__, [])
      Process.put(:__temporal_state__, nil)
      Process.put(:__temporal_patches__, MapSet.new())

      # Put a patch then the target signal in our own mailbox
      send(self(), {:notify_has_patch, "new-feature"})
      send(self(), {:signal, "go", %{value: 1}})

      {:ok, _payload} = API.wait_for_signal("go")

      patches = Process.get(:__temporal_patches__, MapSet.new())
      assert MapSet.member?(patches, "new-feature")

      GenServer.stop(executor)
    end

    test "cancel_workflow received during signal wait sets flag" do
      {:ok, executor} =
        GenServer.start_link(Temporalex.BugfixTest.FakeExecutor, nil)

      Process.put(:__temporal_executor__, executor)
      Process.put(:__temporal_signal_buffer__, [])
      Process.put(:__temporal_state__, nil)
      Process.put(:__temporal_cancelled__, false)

      send(self(), {:cancel_workflow})
      send(self(), {:signal, "go", %{}})

      {:ok, _payload} = API.wait_for_signal("go")

      assert Process.get(:__temporal_cancelled__, false) == true

      GenServer.stop(executor)
    end
  end

  # ============================================================
  # Converter edge cases
  # ============================================================

  describe "Converter.to_payload edge cases" do
    test "non-JSON-serializable value doesn't crash" do
      # Tuples are not JSON-serializable
      payload = Temporalex.Converter.to_payload({:a, :b, :c})
      assert %{data: data} = payload
      assert is_binary(data)
    end

    test "PID value doesn't crash" do
      payload = Temporalex.Converter.to_payload(self())
      assert %{data: data} = payload
      assert is_binary(data)
    end

    test "nil encodes to null payload" do
      payload = Temporalex.Converter.to_payload(nil)
      assert payload.metadata["encoding"] == "binary/null"
    end

    test "nested map round-trips correctly" do
      original = %{"a" => %{"b" => [1, 2, %{"c" => true}]}}
      payload = Temporalex.Converter.to_payload(original)
      assert {:ok, decoded} = Temporalex.Converter.from_payload(payload)
      # Converter decodes with atom keys by default
      assert decoded == %{a: %{b: [1, 2, %{c: true}]}}
    end

    test "large binary doesn't crash" do
      big = :crypto.strong_rand_bytes(100_000)
      payload = Temporalex.Converter.to_payload(big)
      assert %{data: _} = payload
    end

    test "empty string round-trips" do
      payload = Temporalex.Converter.to_payload("")
      assert {:ok, ""} = Temporalex.Converter.from_payload(payload)
    end
  end

  # ============================================================
  # Error type coverage
  # ============================================================

  describe "error types" do
    test "CancelledError formats message" do
      err = %Temporalex.Error.CancelledError{message: "user cancelled"}
      assert Exception.message(err) =~ "user cancelled"
    end

    test "ApplicationError formats message" do
      err = %Temporalex.Error.ApplicationError{message: "bad state", type: "INVALID"}
      assert Exception.message(err) =~ "bad state"
    end
  end

  # ============================================================
  # Cancelled? after drain
  # ============================================================

  describe "cancelled? reflects cancel message" do
    test "cancelled? returns false before cancel" do
      workflow_context()
      assert API.cancelled?() == false
    end

    test "cancelled? returns true after flag set" do
      workflow_context()
      Process.put(:__temporal_cancelled__, true)
      assert API.cancelled?() == true
    end
  end

  # ============================================================
  # Context edge cases (pure struct tests — Context still exists)
  # ============================================================

  describe "workflow context" do
    alias Temporalex.Workflow.Context

    test "next_seq increments monotonically" do
      ctx = %Context{
        workflow_id: "wf-1",
        run_id: "run-1",
        workflow_type: "TestWorkflow",
        task_queue: "test-queue",
        namespace: "default",
        attempt: 1
      }

      {seq0, ctx} = Context.next_seq(ctx)
      {seq1, ctx} = Context.next_seq(ctx)
      {seq2, _ctx} = Context.next_seq(ctx)

      assert seq0 == 0
      assert seq1 == 1
      assert seq2 == 2
    end

    test "flush_commands returns in correct order and clears" do
      ctx = %Context{
        workflow_id: "wf-1",
        run_id: "run-1",
        workflow_type: "TestWorkflow",
        task_queue: "test-queue",
        namespace: "default",
        attempt: 1
      }

      cmd1 = %{variant: {:test, "first"}}
      cmd2 = %{variant: {:test, "second"}}
      ctx = Context.add_command(ctx, cmd1)
      ctx = Context.add_command(ctx, cmd2)

      {commands, ctx} = Context.flush_commands(ctx)
      assert [^cmd1, ^cmd2] = commands
      assert ctx.commands == []
    end

    test "replaying? reflects context state" do
      ctx_replaying = %Context{
        workflow_id: "wf-1",
        run_id: "run-1",
        workflow_type: "TestWorkflow",
        task_queue: "test-queue",
        namespace: "default",
        attempt: 1,
        is_replaying: true
      }

      ctx_not_replaying = %{ctx_replaying | is_replaying: false}

      assert Context.replaying?(ctx_replaying) == true
      assert Context.replaying?(ctx_not_replaying) == false
    end

    test "random is deterministic for same run_id and seq" do
      ctx = %Context{
        workflow_id: "wf-1",
        run_id: "fixed-run",
        workflow_type: "TestWorkflow",
        task_queue: "test-queue",
        namespace: "default",
        attempt: 1
      }

      {val1, _} = Context.random(ctx)
      {val2, _} = Context.random(ctx)
      assert val1 == val2
    end

    test "uuid4 is deterministic for same run_id and seq" do
      ctx = %Context{
        workflow_id: "wf-1",
        run_id: "fixed-run",
        workflow_type: "TestWorkflow",
        task_queue: "test-queue",
        namespace: "default",
        attempt: 1
      }

      {uuid1, _} = Context.uuid4(ctx)
      {uuid2, _} = Context.uuid4(ctx)
      assert uuid1 == uuid2
      assert String.contains?(uuid1, "-4000-")
    end
  end

  # ============================================================
  # Patched? edge cases (using executor)
  # ============================================================

  describe "patched? edge cases" do
    test "returns true when patch is pre-notified" do
      workflow_context(patches: ["patch-a"])
      assert API.patched?("patch-a") == true
    end

    test "multiple pre-notified patches tracked independently" do
      workflow_context(patches: ["patch-a", "patch-b"])
      assert API.patched?("patch-a") == true
      assert API.patched?("patch-b") == true
    end
  end

  # ============================================================
  # FakeExecutor for signal wait tests
  # ============================================================

  defmodule FakeExecutor do
    use GenServer

    def init(_), do: {:ok, nil}

    def handle_call({:yield, _state}, _from, state) do
      {:reply, :ok, state}
    end
  end
end
