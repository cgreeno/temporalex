defmodule Coresdk.WorkflowCommands.ActivityCancellationType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.workflow_commands.ActivityCancellationType",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :TRY_CANCEL, 0
  field :WAIT_CANCELLATION_COMPLETED, 1
  field :ABANDON, 2
end

defmodule Coresdk.WorkflowCommands.WorkflowCommand do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.WorkflowCommand",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :variant, 0

  field :user_metadata, 100, type: Temporal.Api.Sdk.V1.UserMetadata, json_name: "userMetadata"

  field :start_timer, 1,
    type: Coresdk.WorkflowCommands.StartTimer,
    json_name: "startTimer",
    oneof: 0

  field :schedule_activity, 2,
    type: Coresdk.WorkflowCommands.ScheduleActivity,
    json_name: "scheduleActivity",
    oneof: 0

  field :respond_to_query, 3,
    type: Coresdk.WorkflowCommands.QueryResult,
    json_name: "respondToQuery",
    oneof: 0

  field :request_cancel_activity, 4,
    type: Coresdk.WorkflowCommands.RequestCancelActivity,
    json_name: "requestCancelActivity",
    oneof: 0

  field :cancel_timer, 5,
    type: Coresdk.WorkflowCommands.CancelTimer,
    json_name: "cancelTimer",
    oneof: 0

  field :complete_workflow_execution, 6,
    type: Coresdk.WorkflowCommands.CompleteWorkflowExecution,
    json_name: "completeWorkflowExecution",
    oneof: 0

  field :fail_workflow_execution, 7,
    type: Coresdk.WorkflowCommands.FailWorkflowExecution,
    json_name: "failWorkflowExecution",
    oneof: 0

  field :continue_as_new_workflow_execution, 8,
    type: Coresdk.WorkflowCommands.ContinueAsNewWorkflowExecution,
    json_name: "continueAsNewWorkflowExecution",
    oneof: 0

  field :cancel_workflow_execution, 9,
    type: Coresdk.WorkflowCommands.CancelWorkflowExecution,
    json_name: "cancelWorkflowExecution",
    oneof: 0

  field :set_patch_marker, 10,
    type: Coresdk.WorkflowCommands.SetPatchMarker,
    json_name: "setPatchMarker",
    oneof: 0

  field :start_child_workflow_execution, 11,
    type: Coresdk.WorkflowCommands.StartChildWorkflowExecution,
    json_name: "startChildWorkflowExecution",
    oneof: 0

  field :cancel_child_workflow_execution, 12,
    type: Coresdk.WorkflowCommands.CancelChildWorkflowExecution,
    json_name: "cancelChildWorkflowExecution",
    oneof: 0

  field :request_cancel_external_workflow_execution, 13,
    type: Coresdk.WorkflowCommands.RequestCancelExternalWorkflowExecution,
    json_name: "requestCancelExternalWorkflowExecution",
    oneof: 0

  field :signal_external_workflow_execution, 14,
    type: Coresdk.WorkflowCommands.SignalExternalWorkflowExecution,
    json_name: "signalExternalWorkflowExecution",
    oneof: 0

  field :cancel_signal_workflow, 15,
    type: Coresdk.WorkflowCommands.CancelSignalWorkflow,
    json_name: "cancelSignalWorkflow",
    oneof: 0

  field :schedule_local_activity, 16,
    type: Coresdk.WorkflowCommands.ScheduleLocalActivity,
    json_name: "scheduleLocalActivity",
    oneof: 0

  field :request_cancel_local_activity, 17,
    type: Coresdk.WorkflowCommands.RequestCancelLocalActivity,
    json_name: "requestCancelLocalActivity",
    oneof: 0

  field :upsert_workflow_search_attributes, 18,
    type: Coresdk.WorkflowCommands.UpsertWorkflowSearchAttributes,
    json_name: "upsertWorkflowSearchAttributes",
    oneof: 0

  field :modify_workflow_properties, 19,
    type: Coresdk.WorkflowCommands.ModifyWorkflowProperties,
    json_name: "modifyWorkflowProperties",
    oneof: 0

  field :update_response, 20,
    type: Coresdk.WorkflowCommands.UpdateResponse,
    json_name: "updateResponse",
    oneof: 0

  field :schedule_nexus_operation, 21,
    type: Coresdk.WorkflowCommands.ScheduleNexusOperation,
    json_name: "scheduleNexusOperation",
    oneof: 0

  field :request_cancel_nexus_operation, 22,
    type: Coresdk.WorkflowCommands.RequestCancelNexusOperation,
    json_name: "requestCancelNexusOperation",
    oneof: 0
end

defmodule Coresdk.WorkflowCommands.StartTimer do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.StartTimer",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :start_to_fire_timeout, 2, type: Google.Protobuf.Duration, json_name: "startToFireTimeout"
end

defmodule Coresdk.WorkflowCommands.CancelTimer do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.CancelTimer",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
end

defmodule Coresdk.WorkflowCommands.ScheduleActivity.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ScheduleActivity.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.ScheduleActivity do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ScheduleActivity",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :activity_id, 2, type: :string, json_name: "activityId"
  field :activity_type, 3, type: :string, json_name: "activityType"
  field :task_queue, 5, type: :string, json_name: "taskQueue"

  field :headers, 6,
    repeated: true,
    type: Coresdk.WorkflowCommands.ScheduleActivity.HeadersEntry,
    map: true

  field :arguments, 7, repeated: true, type: Temporal.Api.Common.V1.Payload

  field :schedule_to_close_timeout, 8,
    type: Google.Protobuf.Duration,
    json_name: "scheduleToCloseTimeout"

  field :schedule_to_start_timeout, 9,
    type: Google.Protobuf.Duration,
    json_name: "scheduleToStartTimeout"

  field :start_to_close_timeout, 10,
    type: Google.Protobuf.Duration,
    json_name: "startToCloseTimeout"

  field :heartbeat_timeout, 11, type: Google.Protobuf.Duration, json_name: "heartbeatTimeout"
  field :retry_policy, 12, type: Temporal.Api.Common.V1.RetryPolicy, json_name: "retryPolicy"

  field :cancellation_type, 13,
    type: Coresdk.WorkflowCommands.ActivityCancellationType,
    json_name: "cancellationType",
    enum: true

  field :do_not_eagerly_execute, 14, type: :bool, json_name: "doNotEagerlyExecute"

  field :versioning_intent, 15,
    type: Coresdk.Common.VersioningIntent,
    json_name: "versioningIntent",
    enum: true

  field :priority, 16, type: Temporal.Api.Common.V1.Priority
end

defmodule Coresdk.WorkflowCommands.ScheduleLocalActivity.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ScheduleLocalActivity.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.ScheduleLocalActivity do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ScheduleLocalActivity",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :activity_id, 2, type: :string, json_name: "activityId"
  field :activity_type, 3, type: :string, json_name: "activityType"
  field :attempt, 4, type: :uint32

  field :original_schedule_time, 5,
    type: Google.Protobuf.Timestamp,
    json_name: "originalScheduleTime"

  field :headers, 6,
    repeated: true,
    type: Coresdk.WorkflowCommands.ScheduleLocalActivity.HeadersEntry,
    map: true

  field :arguments, 7, repeated: true, type: Temporal.Api.Common.V1.Payload

  field :schedule_to_close_timeout, 8,
    type: Google.Protobuf.Duration,
    json_name: "scheduleToCloseTimeout"

  field :schedule_to_start_timeout, 9,
    type: Google.Protobuf.Duration,
    json_name: "scheduleToStartTimeout"

  field :start_to_close_timeout, 10,
    type: Google.Protobuf.Duration,
    json_name: "startToCloseTimeout"

  field :retry_policy, 11, type: Temporal.Api.Common.V1.RetryPolicy, json_name: "retryPolicy"

  field :local_retry_threshold, 12,
    type: Google.Protobuf.Duration,
    json_name: "localRetryThreshold"

  field :cancellation_type, 13,
    type: Coresdk.WorkflowCommands.ActivityCancellationType,
    json_name: "cancellationType",
    enum: true
end

defmodule Coresdk.WorkflowCommands.RequestCancelActivity do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.RequestCancelActivity",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
end

defmodule Coresdk.WorkflowCommands.RequestCancelLocalActivity do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.RequestCancelLocalActivity",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
end

defmodule Coresdk.WorkflowCommands.QueryResult do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.QueryResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :variant, 0

  field :query_id, 1, type: :string, json_name: "queryId"
  field :succeeded, 2, type: Coresdk.WorkflowCommands.QuerySuccess, oneof: 0
  field :failed, 3, type: Temporal.Api.Failure.V1.Failure, oneof: 0
end

defmodule Coresdk.WorkflowCommands.QuerySuccess do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.QuerySuccess",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :response, 1, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.CompleteWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.CompleteWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :result, 1, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.FailWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.FailWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :failure, 1, type: Temporal.Api.Failure.V1.Failure
end

defmodule Coresdk.WorkflowCommands.ContinueAsNewWorkflowExecution.MemoEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ContinueAsNewWorkflowExecution.MemoEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.ContinueAsNewWorkflowExecution.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ContinueAsNewWorkflowExecution.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.ContinueAsNewWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ContinueAsNewWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :workflow_type, 1, type: :string, json_name: "workflowType"
  field :task_queue, 2, type: :string, json_name: "taskQueue"
  field :arguments, 3, repeated: true, type: Temporal.Api.Common.V1.Payload
  field :workflow_run_timeout, 4, type: Google.Protobuf.Duration, json_name: "workflowRunTimeout"

  field :workflow_task_timeout, 5,
    type: Google.Protobuf.Duration,
    json_name: "workflowTaskTimeout"

  field :memo, 6,
    repeated: true,
    type: Coresdk.WorkflowCommands.ContinueAsNewWorkflowExecution.MemoEntry,
    map: true

  field :headers, 7,
    repeated: true,
    type: Coresdk.WorkflowCommands.ContinueAsNewWorkflowExecution.HeadersEntry,
    map: true

  field :search_attributes, 8,
    type: Temporal.Api.Common.V1.SearchAttributes,
    json_name: "searchAttributes"

  field :retry_policy, 9, type: Temporal.Api.Common.V1.RetryPolicy, json_name: "retryPolicy"

  field :versioning_intent, 10,
    type: Coresdk.Common.VersioningIntent,
    json_name: "versioningIntent",
    enum: true

  field :initial_versioning_behavior, 11,
    type: Temporal.Api.Enums.V1.ContinueAsNewVersioningBehavior,
    json_name: "initialVersioningBehavior",
    enum: true
end

defmodule Coresdk.WorkflowCommands.CancelWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.CancelWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Coresdk.WorkflowCommands.SetPatchMarker do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.SetPatchMarker",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :patch_id, 1, type: :string, json_name: "patchId"
  field :deprecated, 2, type: :bool
end

defmodule Coresdk.WorkflowCommands.StartChildWorkflowExecution.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.StartChildWorkflowExecution.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.StartChildWorkflowExecution.MemoEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.StartChildWorkflowExecution.MemoEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.StartChildWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.StartChildWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :namespace, 2, type: :string
  field :workflow_id, 3, type: :string, json_name: "workflowId"
  field :workflow_type, 4, type: :string, json_name: "workflowType"
  field :task_queue, 5, type: :string, json_name: "taskQueue"
  field :input, 6, repeated: true, type: Temporal.Api.Common.V1.Payload

  field :workflow_execution_timeout, 7,
    type: Google.Protobuf.Duration,
    json_name: "workflowExecutionTimeout"

  field :workflow_run_timeout, 8, type: Google.Protobuf.Duration, json_name: "workflowRunTimeout"

  field :workflow_task_timeout, 9,
    type: Google.Protobuf.Duration,
    json_name: "workflowTaskTimeout"

  field :parent_close_policy, 10,
    type: Coresdk.ChildWorkflow.ParentClosePolicy,
    json_name: "parentClosePolicy",
    enum: true

  field :workflow_id_reuse_policy, 12,
    type: Temporal.Api.Enums.V1.WorkflowIdReusePolicy,
    json_name: "workflowIdReusePolicy",
    enum: true

  field :retry_policy, 13, type: Temporal.Api.Common.V1.RetryPolicy, json_name: "retryPolicy"
  field :cron_schedule, 14, type: :string, json_name: "cronSchedule"

  field :headers, 15,
    repeated: true,
    type: Coresdk.WorkflowCommands.StartChildWorkflowExecution.HeadersEntry,
    map: true

  field :memo, 16,
    repeated: true,
    type: Coresdk.WorkflowCommands.StartChildWorkflowExecution.MemoEntry,
    map: true

  field :search_attributes, 17,
    type: Temporal.Api.Common.V1.SearchAttributes,
    json_name: "searchAttributes"

  field :cancellation_type, 18,
    type: Coresdk.ChildWorkflow.ChildWorkflowCancellationType,
    json_name: "cancellationType",
    enum: true

  field :versioning_intent, 19,
    type: Coresdk.Common.VersioningIntent,
    json_name: "versioningIntent",
    enum: true

  field :priority, 20, type: Temporal.Api.Common.V1.Priority
end

defmodule Coresdk.WorkflowCommands.CancelChildWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.CancelChildWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :child_workflow_seq, 1, type: :uint32, json_name: "childWorkflowSeq"
  field :reason, 2, type: :string
end

defmodule Coresdk.WorkflowCommands.RequestCancelExternalWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.RequestCancelExternalWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32

  field :workflow_execution, 2,
    type: Coresdk.Common.NamespacedWorkflowExecution,
    json_name: "workflowExecution"

  field :reason, 3, type: :string
end

defmodule Coresdk.WorkflowCommands.SignalExternalWorkflowExecution.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.SignalExternalWorkflowExecution.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowCommands.SignalExternalWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.SignalExternalWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :target, 0

  field :seq, 1, type: :uint32

  field :workflow_execution, 2,
    type: Coresdk.Common.NamespacedWorkflowExecution,
    json_name: "workflowExecution",
    oneof: 0

  field :child_workflow_id, 3, type: :string, json_name: "childWorkflowId", oneof: 0
  field :signal_name, 4, type: :string, json_name: "signalName"
  field :args, 5, repeated: true, type: Temporal.Api.Common.V1.Payload

  field :headers, 6,
    repeated: true,
    type: Coresdk.WorkflowCommands.SignalExternalWorkflowExecution.HeadersEntry,
    map: true
end

defmodule Coresdk.WorkflowCommands.CancelSignalWorkflow do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.CancelSignalWorkflow",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
end

defmodule Coresdk.WorkflowCommands.UpsertWorkflowSearchAttributes do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.UpsertWorkflowSearchAttributes",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :search_attributes, 1,
    type: Temporal.Api.Common.V1.SearchAttributes,
    json_name: "searchAttributes"
end

defmodule Coresdk.WorkflowCommands.ModifyWorkflowProperties do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ModifyWorkflowProperties",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :upserted_memo, 1, type: Temporal.Api.Common.V1.Memo, json_name: "upsertedMemo"
end

defmodule Coresdk.WorkflowCommands.UpdateResponse do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.UpdateResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :response, 0

  field :protocol_instance_id, 1, type: :string, json_name: "protocolInstanceId"
  field :accepted, 2, type: Google.Protobuf.Empty, oneof: 0
  field :rejected, 3, type: Temporal.Api.Failure.V1.Failure, oneof: 0
  field :completed, 4, type: Temporal.Api.Common.V1.Payload, oneof: 0
end

defmodule Coresdk.WorkflowCommands.ScheduleNexusOperation.NexusHeaderEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ScheduleNexusOperation.NexusHeaderEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Coresdk.WorkflowCommands.ScheduleNexusOperation do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.ScheduleNexusOperation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :endpoint, 2, type: :string
  field :service, 3, type: :string
  field :operation, 4, type: :string
  field :input, 5, type: Temporal.Api.Common.V1.Payload

  field :schedule_to_close_timeout, 6,
    type: Google.Protobuf.Duration,
    json_name: "scheduleToCloseTimeout"

  field :nexus_header, 7,
    repeated: true,
    type: Coresdk.WorkflowCommands.ScheduleNexusOperation.NexusHeaderEntry,
    json_name: "nexusHeader",
    map: true

  field :cancellation_type, 8,
    type: Coresdk.Nexus.NexusOperationCancellationType,
    json_name: "cancellationType",
    enum: true

  field :schedule_to_start_timeout, 9,
    type: Google.Protobuf.Duration,
    json_name: "scheduleToStartTimeout"

  field :start_to_close_timeout, 10,
    type: Google.Protobuf.Duration,
    json_name: "startToCloseTimeout"
end

defmodule Coresdk.WorkflowCommands.RequestCancelNexusOperation do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_commands.RequestCancelNexusOperation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
end
