defmodule Coresdk.Common.VersioningIntent do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.common.VersioningIntent",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :UNSPECIFIED, 0
  field :COMPATIBLE, 1
  field :DEFAULT, 2
end

defmodule Coresdk.Common.NamespacedWorkflowExecution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.common.NamespacedWorkflowExecution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :namespace, 1, type: :string
  field :workflow_id, 2, type: :string, json_name: "workflowId"
  field :run_id, 3, type: :string, json_name: "runId"
end

defmodule Coresdk.Common.WorkerDeploymentVersion do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.common.WorkerDeploymentVersion",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :deployment_name, 1, type: :string, json_name: "deploymentName"
  field :build_id, 2, type: :string, json_name: "buildId"
end
