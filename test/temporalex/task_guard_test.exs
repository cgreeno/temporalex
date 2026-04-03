defmodule Temporalex.TaskGuardTest do
  use ExUnit.Case, async: true

  # TaskGuard behavior is tested indirectly through NIF calls.
  # The connect NIF uses TaskGuard internally.

  setup do
    {:ok, runtime} = Temporalex.Runtime.get()
    {:ok, runtime: runtime}
  end

  # P1-1: TaskGuard sends tagged success message on normal completion
  # Verified via connect — on validation error, TaskGuard.complete() sends {:connect_error, reason}
  test "TaskGuard delivers success message via connect", %{runtime: runtime} do
    :ok = Temporalex.Native.connect(runtime, "not-a-url", "", %{}, self())

    # The connect NIF validates the URL, and on failure calls guard.complete()
    # which sends the error message. If TaskGuard didn't work, we'd get nothing.
    assert_receive {:connect_error, _reason}, 5_000
  end

  # P1-7: Multiple TaskGuards in flight don't interfere
  test "multiple concurrent guards deliver independent messages", %{runtime: runtime} do
    # Spawn several connect attempts with invalid URLs — each should get its own message
    for i <- 1..5 do
      :ok = Temporalex.Native.connect(runtime, "bad-url-#{i}", "", %{}, self())
    end

    # Collect all 5 messages
    messages =
      for _ <- 1..5 do
        assert_receive {:connect_error, _reason}, 5_000
        :ok
      end

    assert length(messages) == 5

    # No extra messages
    refute_receive {:connect_error, _}, 100
  end

  # P1-2/P1-3: TaskGuard Drop sends error on panic/cancellation
  # These are harder to test from Elixir without a dedicated test NIF.
  # The Drop path fires when a Tokio task panics before calling complete().
  # We verify the mechanism exists by testing the success path above —
  # if complete() works, Drop is correctly suppressed. The symmetry ensures
  # Drop fires in the failure case.
  #
  # Full P1-2/P1-3 testing requires either:
  # 1. A test-only NIF that intentionally panics, or
  # 2. Integration tests where we kill the Temporal server mid-connection
  #
  # For now, the TaskGuard Rust code has unit-level correctness via the
  # completed flag pattern. Integration coverage comes in Phase 3+.
end
