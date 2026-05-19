defmodule Temporalex.Backend.TemporalCore.CodecTest do
  use ExUnit.Case, async: true

  alias Temporalex.Backend.TemporalCore.Codec
  alias Temporalex.Backend.TemporalCore.PayloadConverter
  alias Temporalex.Backend.TemporalCore.Proto.Schema
  alias Temporalex.Core.ActivityTask
  alias Temporalex.Core.Activation
  alias Temporalex.Core.Job
  alias Temporalex.Failure

  @workflow_activation :"coresdk.workflow_activation.WorkflowActivation"
  @activity_task :"coresdk.activity_task.ActivityTask"

  test "decodes workflow activation protobuf bytes into core jobs" do
    payload = PayloadConverter.term_to_payload(:input)
    header = PayloadConverter.term_to_payload("trace-1")

    bytes =
      encode!(@workflow_activation, %{
        run_id: "run-1",
        timestamp: ~U[2023-11-14 22:13:20.123000Z],
        is_replaying: true,
        history_length: 7,
        history_size_bytes: 4096,
        continue_as_new_suggested: true,
        available_internal_flags: [1, 2],
        jobs: [
          %{
            variant:
              {:initialize_workflow,
               %{
                 workflow_type: "ExampleWorkflow",
                 workflow_id: "workflow-1",
                 arguments: [payload],
                 headers: %{"trace" => header},
                 identity: "client",
                 first_execution_run_id: "first-run",
                 attempt: 2,
                 randomness_seed: 42
               }}
          },
          %{variant: {:signal_workflow, %{signal_name: "approve", input: [payload]}}},
          %{
            variant:
              {:query_workflow, %{query_id: "query-1", query_type: "state", arguments: [payload]}}
          },
          %{
            variant:
              {:do_update,
               %{
                 id: "update-1",
                 protocol_instance_id: "protocol-1",
                 name: "change",
                 input: [payload],
                 run_validator: true
               }}
          },
          %{
            variant:
              {:resolve_activity,
               %{
                 seq: 4,
                 result: %{
                   status:
                     {:failed,
                      %{
                        failure:
                          application_failure("declined",
                            type: "PaymentDeclined",
                            non_retryable: true,
                            details: [%{payment_id: "payment-1"}]
                          )
                      }}
                 }
               }}
          },
          %{
            variant: {:remove_from_cache, %{reason: :NONDETERMINISM, message: "history mismatch"}}
          }
        ]
      })

    assert {:ok,
            %Activation{
              run_id: "run-1",
              timestamp: ~U[2023-11-14 22:13:20.123000Z],
              is_replaying: true,
              history_length: 7,
              history_size_bytes: 4096,
              continue_as_new_suggested: true,
              available_internal_flags: [1, 2],
              jobs: [
                %Job.InitializeWorkflow{
                  workflow_type: "ExampleWorkflow",
                  workflow_id: "workflow-1",
                  arguments: [:input],
                  headers: %{"trace" => "trace-1"},
                  workflow_info: %{
                    workflow_id: "workflow-1",
                    workflow_type: "ExampleWorkflow",
                    attempt: 2,
                    identity: "client",
                    run_id: "first-run"
                  },
                  randomness_seed: 42
                },
                %Job.SignalReceived{name: "approve", args: [:input]},
                %Job.QueryReceived{query_id: "query-1", query_type: "state", args: [:input]},
                %Job.UpdateReceived{
                  id: "update-1",
                  protocol_instance_id: "protocol-1",
                  name: "change",
                  args: [:input],
                  run_validator: true
                },
                %Job.ActivityResolved{
                  seq: 4,
                  result:
                    {:error,
                     %Failure.ApplicationError{
                       message: "declined",
                       type: "PaymentDeclined",
                       retryable?: false,
                       details: [%{payment_id: "payment-1"}]
                     }}
                },
                %Job.RemoveFromCache{reason: :nondeterminism, message: "history mismatch"}
              ]
            }} = Codec.workflow_activation_from_bytes(bytes)
  end

  test "decodes activity task protobuf bytes into core tasks" do
    bytes =
      encode!(@activity_task, %{
        task_token: <<1, 2, 3>>,
        variant:
          {:start,
           %{
             workflow_namespace: "default",
             workflow_type: "ExampleWorkflow",
             workflow_execution: %{workflow_id: "workflow-1", run_id: "run-1"},
             activity_id: "activity-1",
             activity_type: "ExampleActivity",
             header_fields: %{"trace" => PayloadConverter.term_to_payload("trace-1")},
             input: [PayloadConverter.term_to_payload(%{amount: 1000})],
             attempt: 3,
             heartbeat_timeout: 2500,
             is_local: false
           }}
      })

    assert {:ok,
            %ActivityTask{
              task_token: <<1, 2, 3>>,
              activity_id: "activity-1",
              activity_type: "ExampleActivity",
              workflow_id: "workflow-1",
              run_id: "run-1",
              workflow_type: "ExampleWorkflow",
              namespace: "default",
              input: [%{amount: 1000}],
              attempt: 3,
              heartbeat_timeout: 2500,
              is_local: false,
              headers: %{"trace" => "trace-1"},
              variant: :start
            }} = Codec.activity_task_from_bytes(bytes)

    cancel_bytes =
      encode!(@activity_task, %{
        task_token: <<4, 5, 6>>,
        variant: {:cancel, %{reason: :CANCELLED}}
      })

    assert {:ok,
            %ActivityTask{
              task_token: <<4, 5, 6>>,
              variant: :cancel,
              cancel_reason: :cancelled
            }} = Codec.activity_task_from_bytes(cancel_bytes)
  end

  test "decodes empty failure payload maps as empty detail lists" do
    bytes =
      encode!(@workflow_activation, %{
        run_id: "run-1",
        jobs: [
          %{
            variant:
              {:resolve_activity,
               %{
                 seq: 1,
                 result: %{
                   status:
                     {:cancelled,
                      %{
                        failure: %{
                          message: "cancelled",
                          source: "test",
                          failure_info: {:canceled_failure_info, %{details: %{}}}
                        }
                      }}
                 }
               }}
          }
        ]
      })

    assert {:ok,
            %Activation{
              jobs: [
                %Job.ActivityResolved{
                  seq: 1,
                  result: {:cancelled, %Failure.CancelledError{message: "cancelled", details: []}}
                }
              ]
            }} = Codec.workflow_activation_from_bytes(bytes)
  end

  test "does not silently drop invalid failure detail payloads" do
    invalid_payload = %{
      metadata: %{"encoding" => "binary/erlang-eterm"},
      data: "not-etf",
      external_payloads: []
    }

    bytes =
      encode!(@workflow_activation, %{
        run_id: "run-1",
        jobs: [
          %{
            variant:
              {:resolve_activity,
               %{
                 seq: 1,
                 result: %{
                   status:
                     {:failed,
                      %{
                        failure: application_failure("bad details", details: [invalid_payload])
                      }}
                 }
               }}
          }
        ]
      })

    assert {:error, "payload is not ETF encoded"} = Codec.workflow_activation_from_bytes(bytes)
  end

  defp application_failure(message, opts) do
    details =
      opts
      |> Keyword.get(:details, [])
      |> Enum.map(fn
        %{metadata: _metadata, data: _data} = payload -> payload
        term -> PayloadConverter.term_to_payload(term)
      end)

    %{
      message: message,
      source: "test",
      failure_info:
        {:application_failure_info,
         %{
           type: Keyword.get(opts, :type, "ApplicationFailure"),
           non_retryable: Keyword.get(opts, :non_retryable, false),
           details: %{payloads: details}
         }}
    }
  end

  defp encode!(message, proto) do
    {:ok, iodata} = Schema.encode(message, proto)
    IO.iodata_to_binary(iodata)
  end
end
