defmodule Temporalex.ValidationTest do
  use ExUnit.Case, async: true

  # Tests for startup validation error messages.
  # Server.init raises inside start_link, so we trap exits and
  # match on the ArgumentError in the exit reason.

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp start_and_expect_error(opts, pattern) do
    result = Temporalex.Server.start_link(opts)
    assert {:error, {%ArgumentError{message: msg}, _}} = result
    assert msg =~ pattern
  end

  describe "workflow registration errors" do
    test "rejects non-existent module" do
      start_and_expect_error(
        [
          task_queue: "test-val",
          workflows: [DoesNotExist.Module],
          address: "http://localhost:7233"
        ],
        "could not be loaded"
      )
    end

    test "rejects module without run/1" do
      start_and_expect_error(
        [task_queue: "test-val", workflows: [Enum], address: "http://localhost:7233"],
        "does not export run/1"
      )
    end

    test "rejects invalid workflow spec" do
      start_and_expect_error(
        [task_queue: "test-val", workflows: [123], address: "http://localhost:7233"],
        "Invalid workflow spec"
      )
    end
  end

  describe "activity registration errors" do
    test "rejects non-existent module" do
      start_and_expect_error(
        [
          task_queue: "test-val",
          activities: [DoesNotExist.Activity],
          address: "http://localhost:7233"
        ],
        "could not be loaded"
      )
    end

    test "rejects module without activity markers" do
      start_and_expect_error(
        [task_queue: "test-val", activities: [Enum], address: "http://localhost:7233"],
        "not a valid activity"
      )
    end
  end

  describe "missing required options" do
    test "task_queue is required" do
      start_and_expect_error(
        [workflows: []],
        "requires :task_queue"
      )
    end
  end

  describe "config validation" do
    test "rejects max_concurrent_workflow_tasks = 0" do
      start_and_expect_error(
        [task_queue: "test-val", max_concurrent_workflow_tasks: 0],
        "max_concurrent_workflow_tasks must be a positive integer"
      )
    end

    test "rejects max_concurrent_workflow_tasks = -1" do
      start_and_expect_error(
        [task_queue: "test-val", max_concurrent_workflow_tasks: -1],
        "max_concurrent_workflow_tasks must be a positive integer"
      )
    end

    test "rejects max_concurrent_activity_tasks = 0" do
      start_and_expect_error(
        [task_queue: "test-val", max_concurrent_activity_tasks: 0],
        "max_concurrent_activity_tasks must be a positive integer"
      )
    end

    test "rejects non-integer max_concurrent_workflow_tasks" do
      start_and_expect_error(
        [task_queue: "test-val", max_concurrent_workflow_tasks: "five"],
        "max_concurrent_workflow_tasks must be a positive integer"
      )
    end
  end
end
