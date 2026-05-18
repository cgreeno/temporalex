defmodule Temporalex.BackendExtrasTest do
  @moduledoc """
  Conformance coverage for the new commands (ScheduleLocalActivity,
  StartChildWorkflowExecution) and structured-error encoding through
  the Temporal Core codec. No live Temporal needed.
  """

  use ExUnit.Case, async: false

  alias Temporalex.Backend.TemporalCore.Codec
  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.Command
  alias Temporalex.Core.Completion

  describe "ScheduleLocalActivity codec" do
    test "encodes a local activity schedule with valid options" do
      assert {:ok, bytes} =
               Codec.workflow_completion_to_bytes(
                 %Completion{
                   run_id: "run-la-valid",
                   status:
                     {:ok,
                      [
                        %Command.ScheduleLocalActivity{
                          seq: 0,
                          thread_id: [],
                          activity_id: "local-1",
                          type: "MyApp.Activities.quick",
                          input: ["hello"],
                          opts: [start_to_close_timeout: 5_000]
                        }
                      ]}
                 },
                 task_queue: "test-queue"
               )

      assert is_binary(bytes) and byte_size(bytes) > 0
    end

    test "rejects local activity with negative timeout" do
      assert {:error, reason} =
               Codec.workflow_completion_to_bytes(
                 %Completion{
                   run_id: "run-la-bad-timeout",
                   status:
                     {:ok,
                      [
                        %Command.ScheduleLocalActivity{
                          seq: 0,
                          thread_id: [],
                          activity_id: "local-1",
                          type: "MyApp.Activities.quick",
                          input: [],
                          opts: [start_to_close_timeout: -1]
                        }
                      ]}
                 },
                 task_queue: "test-queue"
               )

      assert reason =~ "must be non-negative"
    end

    test "accepts local activity with a retry policy" do
      assert {:ok, bytes} =
               Codec.workflow_completion_to_bytes(
                 %Completion{
                   run_id: "run-la-retry",
                   status:
                     {:ok,
                      [
                        %Command.ScheduleLocalActivity{
                          seq: 0,
                          thread_id: [],
                          activity_id: "local-1",
                          type: "MyApp.Activities.quick",
                          input: [],
                          opts: [
                            start_to_close_timeout: 5_000,
                            retry_policy: [
                              initial_interval: 100,
                              maximum_attempts: 3
                            ]
                          ]
                        }
                      ]}
                 },
                 task_queue: "test-queue"
               )

      assert is_binary(bytes)
    end
  end

  describe "StartChildWorkflowExecution codec" do
    test "encodes a child workflow start with defaults" do
      assert {:ok, bytes} =
               Codec.workflow_completion_to_bytes(
                 %Completion{
                   run_id: "run-cw-default",
                   status:
                     {:ok,
                      [
                        %Command.StartChildWorkflowExecution{
                          seq: 0,
                          thread_id: [],
                          workflow_type: "MyApp.ChildWorkflow",
                          workflow_id: "child-1",
                          input: ["init"],
                          opts: []
                        }
                      ]}
                 },
                 task_queue: "parent-queue"
               )

      assert is_binary(bytes) and byte_size(bytes) > 0
    end

    test "encodes child workflow with parent_close_policy and id_reuse_policy" do
      assert {:ok, _bytes} =
               Codec.workflow_completion_to_bytes(
                 %Completion{
                   run_id: "run-cw-policies",
                   status:
                     {:ok,
                      [
                        %Command.StartChildWorkflowExecution{
                          seq: 0,
                          thread_id: [],
                          workflow_type: "MyApp.ChildWorkflow",
                          workflow_id: "child-1",
                          input: [],
                          opts: [
                            parent_close_policy: :abandon,
                            workflow_id_reuse_policy: :reject_duplicate
                          ]
                        }
                      ]}
                 },
                 task_queue: "parent-queue"
               )
    end

    test "rejects unknown parent_close_policy atom" do
      assert {:error, reason} =
               Codec.workflow_completion_to_bytes(
                 %Completion{
                   run_id: "run-cw-bad-policy",
                   status:
                     {:ok,
                      [
                        %Command.StartChildWorkflowExecution{
                          seq: 0,
                          thread_id: [],
                          workflow_type: "MyApp.ChildWorkflow",
                          workflow_id: "child-1",
                          input: [],
                          opts: [parent_close_policy: :not_a_policy]
                        }
                      ]}
                 },
                 task_queue: "parent-queue"
               )

      assert reason =~ "parent close policy"
    end
  end

  describe "structured error encoding through activity completion codec" do
    test "ApplicationError struct encodes without error" do
      assert {:ok, bytes} =
               Codec.activity_completion_to_bytes(%ActivityCompletion{
                 task_token: <<1, 2, 3>>,
                 result:
                   {:error,
                    %Temporalex.ApplicationError{
                      message: "bad input",
                      type: "InvalidInput",
                      non_retryable: true,
                      details: %{field: "amount"}
                    }}
               })

      assert is_binary(bytes) and byte_size(bytes) > 0
    end

    test "CancelledError struct encodes without error" do
      assert {:ok, bytes} =
               Codec.activity_completion_to_bytes(%ActivityCompletion{
                 task_token: <<4, 5, 6>>,
                 result: {:cancelled, %Temporalex.CancelledError{message: "user cancelled"}}
               })

      assert is_binary(bytes) and byte_size(bytes) > 0
    end

    test "TimeoutError with start_to_close type encodes without error" do
      assert {:ok, bytes} =
               Codec.activity_completion_to_bytes(%ActivityCompletion{
                 task_token: <<7, 8, 9>>,
                 result:
                   {:error,
                    %Temporalex.TimeoutError{
                      message: "took too long",
                      timeout_type: :start_to_close
                    }}
               })

      assert is_binary(bytes) and byte_size(bytes) > 0
    end

    test "TimeoutError with each timeout_type variant encodes" do
      for tt <- [:start_to_close, :schedule_to_close, :schedule_to_start, :heartbeat] do
        assert {:ok, _bytes} =
                 Codec.activity_completion_to_bytes(%ActivityCompletion{
                   task_token: <<0>>,
                   result: {:error, %Temporalex.TimeoutError{message: "to", timeout_type: tt}}
                 }),
               "failed for timeout_type=#{tt}"
      end
    end

    test "Bare {:error, atom} still falls through to generic encoding" do
      # Backwards-compat path: anything that isn't a recognized struct should
      # still encode successfully via the generic ApplicationError fallback.
      assert {:ok, bytes} =
               Codec.activity_completion_to_bytes(%ActivityCompletion{
                 task_token: <<10>>,
                 result: {:error, :some_atom}
               })

      assert is_binary(bytes) and byte_size(bytes) > 0
    end
  end
end
