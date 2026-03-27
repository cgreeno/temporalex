defmodule Coresdk.ActivityHeartbeat do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.ActivityHeartbeat",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :task_token, 1, type: :bytes, json_name: "taskToken"
  field :details, 2, repeated: true, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.ActivityTaskCompletion do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.ActivityTaskCompletion",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :task_token, 1, type: :bytes, json_name: "taskToken"
  field :result, 2, type: Coresdk.ActivityResult.ActivityExecutionResult
end

defmodule Coresdk.WorkflowSlotInfo do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.WorkflowSlotInfo",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :workflow_type, 1, type: :string, json_name: "workflowType"
  field :is_sticky, 2, type: :bool, json_name: "isSticky"
end

defmodule Coresdk.ActivitySlotInfo do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.ActivitySlotInfo",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :activity_type, 1, type: :string, json_name: "activityType"
end

defmodule Coresdk.LocalActivitySlotInfo do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.LocalActivitySlotInfo",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :activity_type, 1, type: :string, json_name: "activityType"
end

defmodule Coresdk.NexusSlotInfo do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.NexusSlotInfo",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service, 1, type: :string
  field :operation, 2, type: :string
end

defmodule Coresdk.NamespaceInfo.Limits do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.NamespaceInfo.Limits",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :blob_size_limit_error, 1, type: :int64, json_name: "blobSizeLimitError"
  field :memo_size_limit_error, 2, type: :int64, json_name: "memoSizeLimitError"
end

defmodule Coresdk.NamespaceInfo do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.NamespaceInfo",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :limits, 1, type: Coresdk.NamespaceInfo.Limits
end
