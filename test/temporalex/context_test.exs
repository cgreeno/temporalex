defmodule Temporalex.ContextTest do
  @moduledoc """
  Tests for Workflow.Context -- sequence allocation, command tracking,
  deterministic utilities. Updated for Phase 2.5 fields.
  """
  use ExUnit.Case, async: true

  alias Temporalex.Workflow.Context

  defp new_ctx(overrides \\ %{}) do
    Map.merge(
      %Context{
        workflow_id: "wf-1",
        run_id: "run-1",
        workflow_type: "TestWorkflow",
        task_queue: "test-queue",
        namespace: "default",
        attempt: 1
      },
      overrides
    )
  end

  describe "next_seq/1" do
    test "allocates incrementing sequence numbers" do
      ctx = new_ctx()
      {seq0, ctx} = Context.next_seq(ctx)
      {seq1, ctx} = Context.next_seq(ctx)
      {seq2, _ctx} = Context.next_seq(ctx)

      assert seq0 == 0
      assert seq1 == 1
      assert seq2 == 2
    end
  end

  describe "add_command/2 and flush_commands/1" do
    test "prepend + flush returns commands in order" do
      ctx = new_ctx()
      ctx = Context.add_command(ctx, :cmd1)
      ctx = Context.add_command(ctx, :cmd2)
      ctx = Context.add_command(ctx, :cmd3)

      {cmds, ctx} = Context.flush_commands(ctx)
      assert cmds == [:cmd1, :cmd2, :cmd3]
      assert ctx.commands == []
    end
  end

  describe "now/1" do
    test "returns nil when no timestamp set" do
      assert Context.now(new_ctx()) == nil
    end

    test "returns the workflow time when set" do
      dt = ~U[2026-03-16 12:00:00Z]
      assert Context.now(new_ctx(%{current_time: dt})) == dt
    end
  end

  describe "replaying?/1" do
    test "returns false by default" do
      refute Context.replaying?(new_ctx())
    end

    test "returns true when replaying" do
      assert Context.replaying?(new_ctx(%{is_replaying: true}))
    end
  end

  describe "random/1" do
    test "returns a float between 0 and 1" do
      {value, _ctx} = Context.random(new_ctx())
      assert is_float(value)
      assert value >= 0.0 and value < 1.0
    end

    test "is deterministic for same run_id and seq" do
      ctx = new_ctx()
      {val1, _} = Context.random(ctx)
      {val2, _} = Context.random(ctx)
      assert val1 == val2
    end
  end

  describe "uuid4/1" do
    test "returns a string that looks like a UUID" do
      {uuid, _ctx} = Context.uuid4(new_ctx())
      assert is_binary(uuid)
      assert String.contains?(uuid, "-")
    end
  end

  describe "new fields" do
    test "replay_results defaults to empty map" do
      assert new_ctx().replay_results == %{}
    end

    test "worker_pid and workflow_module default to nil" do
      ctx = new_ctx()
      assert ctx.worker_pid == nil
      assert ctx.workflow_module == nil
    end

    test "randomness_seed defaults to nil" do
      assert new_ctx().randomness_seed == nil
    end
  end
end
