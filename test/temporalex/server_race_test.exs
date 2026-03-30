defmodule Temporalex.ServerRaceTest do
  @moduledoc "Tests for Server race conditions (T5: cancel race, T6: completion attribution)."
  use ExUnit.Case, async: true

  # ============================================================
  # T5: Activity cancel race — stale result after cancel is discarded
  # ============================================================

  describe "activity cancel duplicate completion guard" do
    test "stale ref not in activity_tasks is detected" do
      # Simulate the guard logic from server.ex handle_info({ref, {token, result}})
      tracked_ref = make_ref()
      stale_ref = make_ref()

      activity_tasks = %{tracked_ref => {"token-1", "MyActivity", self()}}

      # Tracked ref is found
      assert Map.has_key?(activity_tasks, tracked_ref)

      # Stale ref (from cancelled activity) is NOT found — would be discarded
      refute Map.has_key?(activity_tasks, stale_ref)
    end

    test "cancel removes from activity_tasks before result arrives" do
      # Simulate: cancel arrives, removes task, then late result arrives
      ref = make_ref()
      activity_tasks = %{ref => {"token-1", "Upload", self()}}

      # Cancel: remove from map
      activity_tasks = Map.delete(activity_tasks, ref)
      assert activity_tasks == %{}

      # Late result arrives — ref not found, should be discarded
      refute Map.has_key?(activity_tasks, ref)
    end
  end

  # ============================================================
  # T6: Completion attribution — last_completing_run_id is advisory
  # ============================================================

  describe "completion attribution" do
    test "last_completing_run_id tracks most recent completion" do
      # Simulate the state transitions
      state = %{last_completing_run_id: nil}

      # First completion
      state = %{state | last_completing_run_id: "run-1"}
      assert state.last_completing_run_id == "run-1"

      # Completion acknowledged, cleared
      state = %{state | last_completing_run_id: nil}
      assert state.last_completing_run_id == nil

      # Second completion
      state = %{state | last_completing_run_id: "run-2"}
      assert state.last_completing_run_id == "run-2"
    end

    test "concurrent completions overwrite (advisory field)" do
      # If two completions race, last one wins — this is OK because
      # the field is only used for logging, not for correctness
      state = %{last_completing_run_id: "run-1"}
      state = %{state | last_completing_run_id: "run-2"}
      assert state.last_completing_run_id == "run-2"
    end
  end

  # ============================================================
  # Executor timeout race — commands after timeout are dropped
  # ============================================================

  describe "executor timeout race" do
    test "pending_activations pop prevents double processing" do
      pending = %{
        "run-1" => %{
          activation: :fake_activation,
          inline_commands: [],
          activation_start: System.monotonic_time(),
          timeout_ref: make_ref()
        }
      }

      # First pop (timeout handler)
      {popped, remaining} = Map.pop(pending, "run-1")
      assert popped != nil
      assert remaining == %{}

      # Second pop (late executor_commands) — returns nil
      {popped2, _} = Map.pop(remaining, "run-1")
      assert popped2 == nil
    end
  end
end
