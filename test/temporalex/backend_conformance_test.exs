defmodule Temporalex.BackendConformanceTest do
  use ExUnit.Case, async: false

  alias Temporalex.Backend.TemporalCore.Codec
  alias Temporalex.Backend.Test, as: TestBackend
  alias Temporalex.Core.Activation
  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.ActivityTask
  alias Temporalex.Core.Command
  alias Temporalex.Core.Completion
  alias Temporalex.SearchAttribute

  defmodule Workflow do
    use Temporalex.Workflow

    def run(input), do: {:ok, input}
  end

  setup do
    name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    start_supervised!(
      {Temporalex.Worker,
       name: name, backend: TestBackend, test_owner: self(), workflows: [Workflow], activities: []}
    )

    %{worker: name}
  end

  test "test backend delivers workflow activations and captures workflow completions", %{
    worker: worker
  } do
    activation = %Activation{
      run_id: "run-backend-conformance",
      jobs: [
        %Temporalex.Core.Job.InitializeWorkflow{
          workflow_type: Workflow.__workflow_type__(),
          workflow_id: "wf",
          arguments: [:ok],
          workflow_info: %{},
          randomness_seed: 0
        }
      ]
    }

    assert :ok = TestBackend.send_activation(worker, activation)

    assert %Completion{
             run_id: "run-backend-conformance",
             status: {:ok, [%Command.CompleteWorkflow{result: :ok}]}
           } = TestBackend.fetch_workflow_completion(worker, "run-backend-conformance")

    assert_receive {:temporalex_test_backend, :workflow_completion, %Completion{}}
  end

  test "test backend delivers activity tasks and captures activity completions", %{worker: worker} do
    completion = %ActivityCompletion{
      task_token: "token",
      result:
        {:error,
         %Temporalex.ApplicationError{
           message: "unknown activity type: missing",
           type: "UnknownActivityType",
           non_retryable: true,
           details: "missing"
         }}
    }

    assert :ok =
             TestBackend.send_activity_task(worker, %ActivityTask{
               task_token: "token",
               activity_id: "activity",
               activity_type: "missing",
               input: [],
               variant: :start
             })

    assert ^completion = TestBackend.fetch_activity_completion(worker, "token")
    assert_receive {:temporalex_test_backend, :activity_completion, ^completion}
  end

  test "TemporalCore codec encodes core completions without leaking native resources" do
    assert {:ok, workflow_bytes} =
             Codec.workflow_completion_to_bytes(
               %Completion{
                 run_id: "run-codec",
                 status:
                   {:ok,
                    [
                      %Command.StartTimer{seq: 0, duration_ms: 10},
                      %Command.UpsertSearchAttributes{
                        attrs: %{
                          "CustomKeywordField" => SearchAttribute.keyword("alpha"),
                          "CustomIntField" => SearchAttribute.int(7)
                        }
                      }
                    ]}
               },
               task_queue: "temporalex-test"
             )

    assert is_binary(workflow_bytes)
    assert byte_size(workflow_bytes) > 0

    assert {:ok, activity_bytes} =
             Codec.activity_completion_to_bytes(%ActivityCompletion{
               task_token: <<1, 2, 3>>,
               result: {:ok, :done}
             })

    assert is_binary(activity_bytes)
    assert byte_size(activity_bytes) > 0
  end

  test "TemporalCore codec rejects invalid duration and retry options" do
    assert {:error, timer_reason} =
             Codec.workflow_completion_to_bytes(
               %Completion{
                 run_id: "run-invalid-timer",
                 status: {:ok, [%Command.StartTimer{seq: 0, duration_ms: -1}]}
               },
               task_queue: "temporalex-test"
             )

    assert timer_reason =~ "timer duration must be non-negative"

    assert {:error, activity_reason} =
             Codec.workflow_completion_to_bytes(
               %Completion{
                 run_id: "run-invalid-activity",
                 status:
                   {:ok,
                    [
                      %Command.ScheduleActivity{
                        seq: 0,
                        thread_id: [],
                        activity_id: "activity",
                        type: "Example.activity",
                        input: [],
                        opts: [
                          start_to_close_timeout: 10,
                          retry_policy: [initial_interval: -1]
                        ]
                      }
                    ]}
               },
               task_queue: "temporalex-test"
             )

    assert activity_reason =~ "retry_policy.initial_interval must be non-negative"

    assert {:error, backoff_reason} =
             Temporalex.Backend.TemporalCore.Codec.workflow_completion_to_bytes(
               %Completion{
                 run_id: "run-invalid-backoff",
                 status:
                   {:ok,
                    [
                      %Command.ScheduleActivity{
                        seq: 0,
                        thread_id: [],
                        activity_id: "activity",
                        type: "Example.activity",
                        input: [],
                        opts: [
                          start_to_close_timeout: 10,
                          retry_policy: [backoff_coefficient: 0.5]
                        ]
                      }
                    ]}
               },
               task_queue: "temporalex-test"
             )

    assert backoff_reason =~ "retry_policy.backoff_coefficient must be 1.0 or larger"

    assert {:error, zero_backoff_reason} =
             Temporalex.Backend.TemporalCore.Codec.workflow_completion_to_bytes(
               %Completion{
                 run_id: "run-invalid-zero-backoff",
                 status:
                   {:ok,
                    [
                      %Command.ScheduleActivity{
                        seq: 0,
                        thread_id: [],
                        activity_id: "activity",
                        type: "Example.activity",
                        input: [],
                        opts: [
                          start_to_close_timeout: 10,
                          retry_policy: [backoff_coefficient: 0.0]
                        ]
                      }
                    ]}
               },
               task_queue: "temporalex-test"
             )

    assert zero_backoff_reason =~ "retry_policy.backoff_coefficient must be 1.0 or larger"
  end

  test "TemporalCore codec rejects invalid search attribute values" do
    assert {:error, reason} =
             Temporalex.Backend.TemporalCore.Codec.workflow_completion_to_bytes(
               %Completion{
                 run_id: "run-invalid-search-attrs",
                 status:
                   {:ok,
                    [
                      %Command.UpsertSearchAttributes{
                        attrs: %{"CustomKeywordField" => %{unsupported: :map}}
                      }
                    ]}
               },
               task_queue: "temporalex-test"
             )

    assert reason =~ "search attribute values must be typed values"
  end
end
