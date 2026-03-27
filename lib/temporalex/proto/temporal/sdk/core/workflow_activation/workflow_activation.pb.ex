defmodule Coresdk.WorkflowActivation.RemoveFromCache.EvictionReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.workflow_activation.RemoveFromCache.EvictionReason",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :UNSPECIFIED, 0
  field :CACHE_FULL, 1
  field :CACHE_MISS, 2
  field :NONDETERMINISM, 3
  field :LANG_FAIL, 4
  field :LANG_REQUESTED, 5
  field :TASK_NOT_FOUND, 6
  field :UNHANDLED_COMMAND, 7
  field :FATAL, 8
  field :PAGINATION_OR_HISTORY_FETCH, 9
  field :WORKFLOW_EXECUTION_ENDING, 10
end

defmodule Coresdk.WorkflowActivation.WorkflowActivation do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.WorkflowActivation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :run_id, 1, type: :string, json_name: "runId"
  field :timestamp, 2, type: Google.Protobuf.Timestamp
  field :is_replaying, 3, type: :bool, json_name: "isReplaying"
  field :history_length, 4, type: :uint32, json_name: "historyLength"
  field :jobs, 5, repeated: true, type: Coresdk.WorkflowActivation.WorkflowActivationJob

  field :available_internal_flags, 6,
    repeated: true,
    type: :uint32,
    json_name: "availableInternalFlags"

  field :history_size_bytes, 7, type: :uint64, json_name: "historySizeBytes"
  field :continue_as_new_suggested, 8, type: :bool, json_name: "continueAsNewSuggested"

  field :deployment_version_for_current_task, 9,
    type: Coresdk.Common.WorkerDeploymentVersion,
    json_name: "deploymentVersionForCurrentTask"

  field :last_sdk_version, 10, type: :string, json_name: "lastSdkVersion"

  field :suggest_continue_as_new_reasons, 11,
    repeated: true,
    type: Temporal.Api.Enums.V1.SuggestContinueAsNewReason,
    json_name: "suggestContinueAsNewReasons",
    enum: true

  field :target_worker_deployment_version_changed, 12,
    type: :bool,
    json_name: "targetWorkerDeploymentVersionChanged"
end

defmodule Coresdk.WorkflowActivation.WorkflowActivationJob do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.WorkflowActivationJob",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :variant, 0

  field :initialize_workflow, 1,
    type: Coresdk.WorkflowActivation.InitializeWorkflow,
    json_name: "initializeWorkflow",
    oneof: 0

  field :fire_timer, 2,
    type: Coresdk.WorkflowActivation.FireTimer,
    json_name: "fireTimer",
    oneof: 0

  field :update_random_seed, 4,
    type: Coresdk.WorkflowActivation.UpdateRandomSeed,
    json_name: "updateRandomSeed",
    oneof: 0

  field :query_workflow, 5,
    type: Coresdk.WorkflowActivation.QueryWorkflow,
    json_name: "queryWorkflow",
    oneof: 0

  field :cancel_workflow, 6,
    type: Coresdk.WorkflowActivation.CancelWorkflow,
    json_name: "cancelWorkflow",
    oneof: 0

  field :signal_workflow, 7,
    type: Coresdk.WorkflowActivation.SignalWorkflow,
    json_name: "signalWorkflow",
    oneof: 0

  field :resolve_activity, 8,
    type: Coresdk.WorkflowActivation.ResolveActivity,
    json_name: "resolveActivity",
    oneof: 0

  field :notify_has_patch, 9,
    type: Coresdk.WorkflowActivation.NotifyHasPatch,
    json_name: "notifyHasPatch",
    oneof: 0

  field :resolve_child_workflow_execution_start, 10,
    type: Coresdk.WorkflowActivation.ResolveChildWorkflowExecutionStart,
    json_name: "resolveChildWorkflowExecutionStart",
    oneof: 0

  field :resolve_child_workflow_execution, 11,
    type: Coresdk.WorkflowActivation.ResolveChildWorkflowExecution,
    json_name: "resolveChildWorkflowExecution",
    oneof: 0

  field :resolve_signal_external_workflow, 12,
    type: Coresdk.WorkflowActivation.ResolveSignalExternalWorkflow,
    json_name: "resolveSignalExternalWorkflow",
    oneof: 0

  field :resolve_request_cancel_external_workflow, 13,
    type: Coresdk.WorkflowActivation.ResolveRequestCancelExternalWorkflow,
    json_name: "resolveRequestCancelExternalWorkflow",
    oneof: 0

  field :do_update, 14, type: Coresdk.WorkflowActivation.DoUpdate, json_name: "doUpdate", oneof: 0

  field :resolve_nexus_operation_start, 15,
    type: Coresdk.WorkflowActivation.ResolveNexusOperationStart,
    json_name: "resolveNexusOperationStart",
    oneof: 0

  field :resolve_nexus_operation, 16,
    type: Coresdk.WorkflowActivation.ResolveNexusOperation,
    json_name: "resolveNexusOperation",
    oneof: 0

  field :remove_from_cache, 50,
    type: Coresdk.WorkflowActivation.RemoveFromCache,
    json_name: "removeFromCache",
    oneof: 0
end

defmodule Coresdk.WorkflowActivation.InitializeWorkflow.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.InitializeWorkflow.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowActivation.InitializeWorkflow do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.InitializeWorkflow",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :workflow_type, 1, type: :string, json_name: "workflowType"
  field :workflow_id, 2, type: :string, json_name: "workflowId"
  field :arguments, 3, repeated: true, type: Temporal.Api.Common.V1.Payload
  field :randomness_seed, 4, type: :uint64, json_name: "randomnessSeed"

  field :headers, 5,
    repeated: true,
    type: Coresdk.WorkflowActivation.InitializeWorkflow.HeadersEntry,
    map: true

  field :identity, 6, type: :string

  field :parent_workflow_info, 7,
    type: Coresdk.Common.NamespacedWorkflowExecution,
    json_name: "parentWorkflowInfo"

  field :workflow_execution_timeout, 8,
    type: Google.Protobuf.Duration,
    json_name: "workflowExecutionTimeout"

  field :workflow_run_timeout, 9, type: Google.Protobuf.Duration, json_name: "workflowRunTimeout"

  field :workflow_task_timeout, 10,
    type: Google.Protobuf.Duration,
    json_name: "workflowTaskTimeout"

  field :continued_from_execution_run_id, 11,
    type: :string,
    json_name: "continuedFromExecutionRunId"

  field :continued_initiator, 12,
    type: Temporal.Api.Enums.V1.ContinueAsNewInitiator,
    json_name: "continuedInitiator",
    enum: true

  field :continued_failure, 13,
    type: Temporal.Api.Failure.V1.Failure,
    json_name: "continuedFailure"

  field :last_completion_result, 14,
    type: Temporal.Api.Common.V1.Payloads,
    json_name: "lastCompletionResult"

  field :first_execution_run_id, 15, type: :string, json_name: "firstExecutionRunId"
  field :retry_policy, 16, type: Temporal.Api.Common.V1.RetryPolicy, json_name: "retryPolicy"
  field :attempt, 17, type: :int32
  field :cron_schedule, 18, type: :string, json_name: "cronSchedule"

  field :workflow_execution_expiration_time, 19,
    type: Google.Protobuf.Timestamp,
    json_name: "workflowExecutionExpirationTime"

  field :cron_schedule_to_schedule_interval, 20,
    type: Google.Protobuf.Duration,
    json_name: "cronScheduleToScheduleInterval"

  field :memo, 21, type: Temporal.Api.Common.V1.Memo

  field :search_attributes, 22,
    type: Temporal.Api.Common.V1.SearchAttributes,
    json_name: "searchAttributes"

  field :start_time, 23, type: Google.Protobuf.Timestamp, json_name: "startTime"

  field :root_workflow, 24,
    type: Temporal.Api.Common.V1.WorkflowExecution,
    json_name: "rootWorkflow"

  field :priority, 25, type: Temporal.Api.Common.V1.Priority
end

defmodule Coresdk.WorkflowActivation.FireTimer do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.FireTimer",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
end

defmodule Coresdk.WorkflowActivation.ResolveActivity do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveActivity",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :result, 2, type: Coresdk.ActivityResult.ActivityResolution
  field :is_local, 3, type: :bool, json_name: "isLocal"
end

defmodule Coresdk.WorkflowActivation.ResolveChildWorkflowExecutionStart do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveChildWorkflowExecutionStart",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :status, 0

  field :seq, 1, type: :uint32

  field :succeeded, 2,
    type: Coresdk.WorkflowActivation.ResolveChildWorkflowExecutionStartSuccess,
    oneof: 0

  field :failed, 3,
    type: Coresdk.WorkflowActivation.ResolveChildWorkflowExecutionStartFailure,
    oneof: 0

  field :cancelled, 4,
    type: Coresdk.WorkflowActivation.ResolveChildWorkflowExecutionStartCancelled,
    oneof: 0
end

defmodule Coresdk.WorkflowActivation.ResolveChildWorkflowExecutionStartSuccess do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveChildWorkflowExecutionStartSuccess",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :run_id, 1, type: :string, json_name: "runId"
end

defmodule Coresdk.WorkflowActivation.ResolveChildWorkflowExecutionStartFailure do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveChildWorkflowExecutionStartFailure",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :workflow_id, 1, type: :string, json_name: "workflowId"
  field :workflow_type, 2, type: :string, json_name: "workflowType"
  field :cause, 3, type: Coresdk.ChildWorkflow.StartChildWorkflowExecutionFailedCause, enum: true
end

defmodule Coresdk.WorkflowActivation.ResolveChildWorkflowExecutionStartCancelled do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveChildWorkflowExecutionStartCancelled",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :failure, 1, type: Temporal.Api.Failure.V1.Failure
end

defmodule Coresdk.WorkflowActivation.ResolveChildWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveChildWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :result, 2, type: Coresdk.ChildWorkflow.ChildWorkflowResult
end

defmodule Coresdk.WorkflowActivation.UpdateRandomSeed do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.UpdateRandomSeed",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :randomness_seed, 1, type: :uint64, json_name: "randomnessSeed"
end

defmodule Coresdk.WorkflowActivation.QueryWorkflow.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.QueryWorkflow.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowActivation.QueryWorkflow do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.QueryWorkflow",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :query_id, 1, type: :string, json_name: "queryId"
  field :query_type, 2, type: :string, json_name: "queryType"
  field :arguments, 3, repeated: true, type: Temporal.Api.Common.V1.Payload

  field :headers, 5,
    repeated: true,
    type: Coresdk.WorkflowActivation.QueryWorkflow.HeadersEntry,
    map: true
end

defmodule Coresdk.WorkflowActivation.CancelWorkflow do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.CancelWorkflow",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :reason, 1, type: :string
end

defmodule Coresdk.WorkflowActivation.SignalWorkflow.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.SignalWorkflow.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowActivation.SignalWorkflow do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.SignalWorkflow",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :signal_name, 1, type: :string, json_name: "signalName"
  field :input, 2, repeated: true, type: Temporal.Api.Common.V1.Payload
  field :identity, 3, type: :string

  field :headers, 5,
    repeated: true,
    type: Coresdk.WorkflowActivation.SignalWorkflow.HeadersEntry,
    map: true
end

defmodule Coresdk.WorkflowActivation.NotifyHasPatch do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.NotifyHasPatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :patch_id, 1, type: :string, json_name: "patchId"
end

defmodule Coresdk.WorkflowActivation.ResolveSignalExternalWorkflow do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveSignalExternalWorkflow",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :failure, 2, type: Temporal.Api.Failure.V1.Failure
end

defmodule Coresdk.WorkflowActivation.ResolveRequestCancelExternalWorkflow do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveRequestCancelExternalWorkflow",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :failure, 2, type: Temporal.Api.Failure.V1.Failure
end

defmodule Coresdk.WorkflowActivation.DoUpdate.HeadersEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.DoUpdate.HeadersEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.WorkflowActivation.DoUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.DoUpdate",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :protocol_instance_id, 2, type: :string, json_name: "protocolInstanceId"
  field :name, 3, type: :string
  field :input, 4, repeated: true, type: Temporal.Api.Common.V1.Payload

  field :headers, 5,
    repeated: true,
    type: Coresdk.WorkflowActivation.DoUpdate.HeadersEntry,
    map: true

  field :meta, 6, type: Temporal.Api.Update.V1.Meta
  field :run_validator, 7, type: :bool, json_name: "runValidator"
end

defmodule Coresdk.WorkflowActivation.ResolveNexusOperationStart do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveNexusOperationStart",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :status, 0

  field :seq, 1, type: :uint32
  field :operation_token, 2, type: :string, json_name: "operationToken", oneof: 0
  field :started_sync, 3, type: :bool, json_name: "startedSync", oneof: 0
  field :failed, 4, type: Temporal.Api.Failure.V1.Failure, oneof: 0
end

defmodule Coresdk.WorkflowActivation.ResolveNexusOperation do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.ResolveNexusOperation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :result, 2, type: Coresdk.Nexus.NexusOperationResult
end

defmodule Coresdk.WorkflowActivation.RemoveFromCache do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_activation.RemoveFromCache",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :message, 1, type: :string
  field :reason, 2, type: Coresdk.WorkflowActivation.RemoveFromCache.EvictionReason, enum: true
end
