defmodule Temporalex.SearchAttribute do
  @moduledoc """
  Typed Temporal Search Attribute value.

  Search Attributes are visibility fields, not normal workflow payloads. Values
  must be encoded so the Temporal Server can index and query them.
  """

  @enforce_keys [:type, :value]
  defstruct [:type, :value]

  @type type :: :bool | :datetime | :double | :int | :keyword | :keyword_list | :text
  @type t :: %__MODULE__{type: type(), value: term()}

  @doc "Build a Bool Search Attribute value."
  def bool(value) when is_boolean(value), do: %__MODULE__{type: :bool, value: value}

  @doc "Build a Datetime Search Attribute value from a DateTime, NaiveDateTime, Date, or ISO-8601 string."
  def datetime(%DateTime{} = value),
    do: %__MODULE__{type: :datetime, value: DateTime.to_iso8601(value)}

  def datetime(%NaiveDateTime{} = value),
    do: %__MODULE__{type: :datetime, value: NaiveDateTime.to_iso8601(value) <> "Z"}

  def datetime(%Date{} = value),
    do: %__MODULE__{type: :datetime, value: Date.to_iso8601(value) <> "T00:00:00Z"}

  def datetime(value) when is_binary(value) do
    validate_datetime_string!(value)
    %__MODULE__{type: :datetime, value: value}
  end

  @doc "Build a Double Search Attribute value."
  def double(value) when is_float(value), do: %__MODULE__{type: :double, value: value}
  def double(value) when is_integer(value), do: %__MODULE__{type: :double, value: value * 1.0}

  @doc "Build an Int Search Attribute value."
  def int(value) when is_integer(value), do: %__MODULE__{type: :int, value: value}

  @doc "Build a Keyword Search Attribute value."
  def keyword(value) when is_binary(value), do: %__MODULE__{type: :keyword, value: value}

  @doc "Build a KeywordList Search Attribute value."
  def keyword_list(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      %__MODULE__{type: :keyword_list, value: values}
    else
      raise ArgumentError, "keyword_list Search Attribute values must be strings"
    end
  end

  @doc "Build a Text Search Attribute value."
  def text(value) when is_binary(value), do: %__MODULE__{type: :text, value: value}

  @doc false
  def validate!(%__MODULE__{type: type, value: value} = attr) do
    case type do
      :bool when is_boolean(value) -> attr
      :datetime when is_binary(value) -> datetime(value)
      :double when is_float(value) -> attr
      :double when is_integer(value) -> double(value)
      :int when is_integer(value) -> attr
      :keyword when is_binary(value) -> attr
      :keyword_list when is_list(value) -> keyword_list(value)
      :text when is_binary(value) -> attr
      _ -> raise ArgumentError, "invalid Search Attribute #{inspect(attr)}"
    end
  end

  def validate!(value)
      when is_boolean(value) or is_integer(value) or is_float(value) or is_binary(value),
      do: value

  def validate!(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      values
    else
      raise ArgumentError, "bare Search Attribute lists must contain only strings"
    end
  end

  def validate!(%DateTime{} = value), do: datetime(value)
  def validate!(%NaiveDateTime{} = value), do: datetime(value)
  def validate!(%Date{} = value), do: datetime(value)

  def validate!(other),
    do: raise(ArgumentError, "invalid Search Attribute value #{inspect(other)}")

  @doc false
  def validate_map!(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), validate!(value)} end)
  end

  defp validate_datetime_string!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} ->
        :ok

      {:error, _} ->
        raise ArgumentError, "datetime Search Attribute must be ISO-8601 with an offset"
    end
  end
end
