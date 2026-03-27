defmodule Coresdk.Nexus.NexusTaskCancelReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.nexus.NexusTaskCancelReason",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :TIMED_OUT, 0
  field :WORKER_SHUTDOWN, 1
end

defmodule Coresdk.Nexus.NexusOperationCancellationType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.nexus.NexusOperationCancellationType",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :WAIT_CANCELLATION_COMPLETED, 0
  field :ABANDON, 1
  field :TRY_CANCEL, 2
  field :WAIT_CANCELLATION_REQUESTED, 3
end

defmodule Coresdk.Nexus.NexusOperationResult do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.nexus.NexusOperationResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :status, 0

  field :completed, 1, type: Temporal.Api.Common.V1.Payload, oneof: 0
  field :failed, 2, type: Temporal.Api.Failure.V1.Failure, oneof: 0
  field :cancelled, 3, type: Temporal.Api.Failure.V1.Failure, oneof: 0
  field :timed_out, 4, type: Temporal.Api.Failure.V1.Failure, json_name: "timedOut", oneof: 0
end

defmodule Coresdk.Nexus.NexusTaskCompletion do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.nexus.NexusTaskCompletion",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :status, 0

  field :task_token, 1, type: :bytes, json_name: "taskToken"
  field :completed, 2, type: Temporal.Api.Nexus.V1.Response, oneof: 0
  field :error, 3, type: Temporal.Api.Nexus.V1.HandlerError, oneof: 0, deprecated: true
  field :ack_cancel, 4, type: :bool, json_name: "ackCancel", oneof: 0
  field :failure, 5, type: Temporal.Api.Failure.V1.Failure, oneof: 0
end

defmodule Coresdk.Nexus.NexusTask do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.nexus.NexusTask",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :variant, 0

  field :task, 1, type: Temporal.Api.Workflowservice.V1.PollNexusTaskQueueResponse, oneof: 0
  field :cancel_task, 2, type: Coresdk.Nexus.CancelNexusTask, json_name: "cancelTask", oneof: 0
  field :request_deadline, 3, type: Google.Protobuf.Timestamp, json_name: "requestDeadline"
end

defmodule Coresdk.Nexus.CancelNexusTask do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.nexus.CancelNexusTask",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :task_token, 1, type: :bytes, json_name: "taskToken"
  field :reason, 2, type: Coresdk.Nexus.NexusTaskCancelReason, enum: true
end
