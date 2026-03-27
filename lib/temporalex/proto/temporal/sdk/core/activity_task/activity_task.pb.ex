defmodule Coresdk.ActivityTask.ActivityCancelReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.activity_task.ActivityCancelReason",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :NOT_FOUND, 0
  field :CANCELLED, 1
  field :TIMED_OUT, 2
  field :WORKER_SHUTDOWN, 3
  field :PAUSED, 4
  field :RESET, 5
end

defmodule Coresdk.ActivityTask.ActivityTask do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_task.ActivityTask",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :variant, 0

  field :task_token, 1, type: :bytes, json_name: "taskToken"
  field :start, 3, type: Coresdk.ActivityTask.Start, oneof: 0
  field :cancel, 4, type: Coresdk.ActivityTask.Cancel, oneof: 0
end

defmodule Coresdk.ActivityTask.Start.HeaderFieldsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_task.Start.HeaderFieldsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.ActivityTask.Start do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_task.Start",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :workflow_namespace, 1, type: :string, json_name: "workflowNamespace"
  field :workflow_type, 2, type: :string, json_name: "workflowType"

  field :workflow_execution, 3,
    type: Temporal.Api.Common.V1.WorkflowExecution,
    json_name: "workflowExecution"

  field :activity_id, 4, type: :string, json_name: "activityId"
  field :activity_type, 5, type: :string, json_name: "activityType"

  field :header_fields, 6,
    repeated: true,
    type: Coresdk.ActivityTask.Start.HeaderFieldsEntry,
    json_name: "headerFields",
    map: true

  field :input, 7, repeated: true, type: Temporal.Api.Common.V1.Payload

  field :heartbeat_details, 8,
    repeated: true,
    type: Temporal.Api.Common.V1.Payload,
    json_name: "heartbeatDetails"

  field :scheduled_time, 9, type: Google.Protobuf.Timestamp, json_name: "scheduledTime"

  field :current_attempt_scheduled_time, 10,
    type: Google.Protobuf.Timestamp,
    json_name: "currentAttemptScheduledTime"

  field :started_time, 11, type: Google.Protobuf.Timestamp, json_name: "startedTime"
  field :attempt, 12, type: :uint32

  field :schedule_to_close_timeout, 13,
    type: Google.Protobuf.Duration,
    json_name: "scheduleToCloseTimeout"

  field :start_to_close_timeout, 14,
    type: Google.Protobuf.Duration,
    json_name: "startToCloseTimeout"

  field :heartbeat_timeout, 15, type: Google.Protobuf.Duration, json_name: "heartbeatTimeout"
  field :retry_policy, 16, type: Temporal.Api.Common.V1.RetryPolicy, json_name: "retryPolicy"
  field :priority, 18, type: Temporal.Api.Common.V1.Priority
  field :is_local, 17, type: :bool, json_name: "isLocal"
end

defmodule Coresdk.ActivityTask.Cancel do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_task.Cancel",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :reason, 1, type: Coresdk.ActivityTask.ActivityCancelReason, enum: true
  field :details, 2, type: Coresdk.ActivityTask.ActivityCancellationDetails
end

defmodule Coresdk.ActivityTask.ActivityCancellationDetails do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_task.ActivityCancellationDetails",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :is_not_found, 1, type: :bool, json_name: "isNotFound"
  field :is_cancelled, 2, type: :bool, json_name: "isCancelled"
  field :is_paused, 3, type: :bool, json_name: "isPaused"
  field :is_timed_out, 4, type: :bool, json_name: "isTimedOut"
  field :is_worker_shutdown, 5, type: :bool, json_name: "isWorkerShutdown"
  field :is_reset, 6, type: :bool, json_name: "isReset"
end
