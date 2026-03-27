defmodule Coresdk.ExternalData.LocalActivityMarkerData do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.external_data.LocalActivityMarkerData",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :seq, 1, type: :uint32
  field :attempt, 2, type: :uint32
  field :activity_id, 3, type: :string, json_name: "activityId"
  field :activity_type, 4, type: :string, json_name: "activityType"
  field :complete_time, 5, type: Google.Protobuf.Timestamp, json_name: "completeTime"
  field :backoff, 6, type: Google.Protobuf.Duration

  field :original_schedule_time, 7,
    type: Google.Protobuf.Timestamp,
    json_name: "originalScheduleTime"
end

defmodule Coresdk.ExternalData.PatchedMarkerData do
  @moduledoc false

  use Protobuf,
    full_name: "coresdk.external_data.PatchedMarkerData",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :deprecated, 2, type: :bool
end
