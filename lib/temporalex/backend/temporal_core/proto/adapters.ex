defmodule Temporalex.Backend.TemporalCore.Proto.Adapters do
  @moduledoc false

  @nanos_per_second 1_000_000_000
  @nanos_per_millisecond 1_000_000

  def adapters do
    [
      %{
        fqn: :"google.protobuf.Timestamp",
        to_proto: {__MODULE__, :datetime_to_proto},
        from_proto: {__MODULE__, :datetime_from_proto},
        type: quote(do: DateTime.t())
      },
      %{
        fqn: :"google.protobuf.Duration",
        to_proto: {__MODULE__, :duration_ms_to_proto},
        from_proto: {__MODULE__, :duration_ms_from_proto},
        type: quote(do: non_neg_integer())
      },
      %{
        fqn: :"temporal.api.common.v1.ActivityType",
        to_proto: {__MODULE__, :type_name_to_proto},
        from_proto: {__MODULE__, :type_name_from_proto},
        type: quote(do: String.t())
      },
      %{
        fqn: :"temporal.api.common.v1.WorkflowType",
        to_proto: {__MODULE__, :type_name_to_proto},
        from_proto: {__MODULE__, :type_name_from_proto},
        type: quote(do: String.t())
      }
    ]
  end

  def datetime_to_proto(%DateTime{} = datetime) do
    {microseconds, _precision} = datetime.microsecond

    {:ok,
     %{
       seconds: DateTime.to_unix(datetime, :second),
       nanos: microseconds * 1_000
     }}
  end

  def datetime_to_proto(value), do: {:error, {:invalid_datetime, value}}

  def datetime_from_proto(message) when is_map(message) do
    seconds = Map.get(message, :seconds, 0)
    nanos = Map.get(message, :nanos, 0)

    cond do
      not is_integer(seconds) or not is_integer(nanos) ->
        {:error, :invalid_timestamp}

      nanos < 0 or nanos >= @nanos_per_second ->
        {:error, :invalid_timestamp}

      true ->
        with {:ok, datetime} <- DateTime.from_unix(seconds, :second) do
          {:ok, Map.put(datetime, :microsecond, {div(nanos, 1_000), 6})}
        end
    end
  end

  def datetime_from_proto(value), do: {:error, {:invalid_timestamp_message, value}}

  def duration_ms_to_proto(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    {:ok,
     %{
       seconds: div(milliseconds, 1_000),
       nanos: rem(milliseconds, 1_000) * @nanos_per_millisecond
     }}
  end

  def duration_ms_to_proto(value), do: {:error, {:invalid_duration_ms, value}}

  def duration_ms_from_proto(message) when is_map(message) do
    seconds = Map.get(message, :seconds, 0)
    nanos = Map.get(message, :nanos, 0)

    cond do
      not is_integer(seconds) or not is_integer(nanos) ->
        {:error, :invalid_duration}

      seconds < 0 or nanos < 0 or nanos >= @nanos_per_second ->
        {:error, :invalid_duration}

      true ->
        {:ok, seconds * 1_000 + div(nanos, @nanos_per_millisecond)}
    end
  end

  def duration_ms_from_proto(value), do: {:error, {:invalid_duration_message, value}}

  def type_name_to_proto(name) when is_binary(name), do: {:ok, %{name: name}}
  def type_name_to_proto(value), do: {:error, {:invalid_type_name, value}}

  def type_name_from_proto(message) when is_map(message), do: {:ok, Map.get(message, :name, "")}
  def type_name_from_proto(value), do: {:error, {:invalid_type_name_message, value}}
end
