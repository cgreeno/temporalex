defmodule Coresdk.WorkflowCompletion.WorkflowActivationCompletion do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_completion.WorkflowActivationCompletion",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :status, 0

  field :run_id, 1, type: :string, json_name: "runId"
  field :successful, 2, type: Coresdk.WorkflowCompletion.Success, oneof: 0
  field :failed, 3, type: Coresdk.WorkflowCompletion.Failure, oneof: 0
end

defmodule Coresdk.WorkflowCompletion.Success do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_completion.Success",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :commands, 1, repeated: true, type: Coresdk.WorkflowCommands.WorkflowCommand
  field :used_internal_flags, 6, repeated: true, type: :uint32, json_name: "usedInternalFlags"

  field :versioning_behavior, 7,
    type: Temporal.Api.Enums.V1.VersioningBehavior,
    json_name: "versioningBehavior",
    enum: true
end

defmodule Coresdk.WorkflowCompletion.Failure do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.workflow_completion.Failure",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :failure, 1, type: Temporal.Api.Failure.V1.Failure

  field :force_cause, 2,
    type: Temporal.Api.Enums.V1.WorkflowTaskFailedCause,
    json_name: "forceCause",
    enum: true
end
