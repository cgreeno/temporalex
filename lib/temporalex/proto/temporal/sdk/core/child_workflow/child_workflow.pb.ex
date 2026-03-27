defmodule Coresdk.ChildWorkflow.ParentClosePolicy do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.child_workflow.ParentClosePolicy",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :PARENT_CLOSE_POLICY_UNSPECIFIED, 0
  field :PARENT_CLOSE_POLICY_TERMINATE, 1
  field :PARENT_CLOSE_POLICY_ABANDON, 2
  field :PARENT_CLOSE_POLICY_REQUEST_CANCEL, 3
end

defmodule Coresdk.ChildWorkflow.StartChildWorkflowExecutionFailedCause do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.child_workflow.StartChildWorkflowExecutionFailedCause",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :START_CHILD_WORKFLOW_EXECUTION_FAILED_CAUSE_UNSPECIFIED, 0
  field :START_CHILD_WORKFLOW_EXECUTION_FAILED_CAUSE_WORKFLOW_ALREADY_EXISTS, 1
end

defmodule Coresdk.ChildWorkflow.ChildWorkflowCancellationType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "coresdk.child_workflow.ChildWorkflowCancellationType",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :ABANDON, 0
  field :TRY_CANCEL, 1
  field :WAIT_CANCELLATION_COMPLETED, 2
  field :WAIT_CANCELLATION_REQUESTED, 3
end

defmodule Coresdk.ChildWorkflow.ChildWorkflowResult do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.child_workflow.ChildWorkflowResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :status, 0

  field :completed, 1, type: Coresdk.ChildWorkflow.Success, oneof: 0
  field :failed, 2, type: Coresdk.ChildWorkflow.Failure, oneof: 0
  field :cancelled, 3, type: Coresdk.ChildWorkflow.Cancellation, oneof: 0
end

defmodule Coresdk.ChildWorkflow.Success do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.child_workflow.Success",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :result, 1, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.ChildWorkflow.Failure do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.child_workflow.Failure",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :failure, 1, type: Temporal.Api.Failure.V1.Failure
end

defmodule Coresdk.ChildWorkflow.Cancellation do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.child_workflow.Cancellation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :failure, 1, type: Temporal.Api.Failure.V1.Failure
end
