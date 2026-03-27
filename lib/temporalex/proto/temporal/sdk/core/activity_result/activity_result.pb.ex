defmodule Coresdk.ActivityResult.ActivityExecutionResult do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_result.ActivityExecutionResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :status, 0

  field :completed, 1, type: Coresdk.ActivityResult.Success, oneof: 0
  field :failed, 2, type: Coresdk.ActivityResult.Failure, oneof: 0
  field :cancelled, 3, type: Coresdk.ActivityResult.Cancellation, oneof: 0

  field :will_complete_async, 4,
    type: Coresdk.ActivityResult.WillCompleteAsync,
    json_name: "willCompleteAsync",
    oneof: 0
end

defmodule Coresdk.ActivityResult.ActivityResolution do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_result.ActivityResolution",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :status, 0

  field :completed, 1, type: Coresdk.ActivityResult.Success, oneof: 0
  field :failed, 2, type: Coresdk.ActivityResult.Failure, oneof: 0
  field :cancelled, 3, type: Coresdk.ActivityResult.Cancellation, oneof: 0
  field :backoff, 4, type: Coresdk.ActivityResult.DoBackoff, oneof: 0
end

defmodule Coresdk.ActivityResult.Success do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_result.Success",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :result, 1, type: Temporal.Api.Common.V1.Payload
end

defmodule Coresdk.ActivityResult.Failure do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_result.Failure",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :failure, 1, type: Temporal.Api.Failure.V1.Failure
end

defmodule Coresdk.ActivityResult.Cancellation do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_result.Cancellation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :failure, 1, type: Temporal.Api.Failure.V1.Failure
end

defmodule Coresdk.ActivityResult.WillCompleteAsync do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_result.WillCompleteAsync",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Coresdk.ActivityResult.DoBackoff do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.activity_result.DoBackoff",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :attempt, 1, type: :uint32
  field :backoff_duration, 2, type: Google.Protobuf.Duration, json_name: "backoffDuration"

  field :original_schedule_time, 3,
    type: Google.Protobuf.Timestamp,
    json_name: "originalScheduleTime"
end
