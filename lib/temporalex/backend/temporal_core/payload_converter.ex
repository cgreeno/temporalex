defmodule Temporalex.Backend.TemporalCore.PayloadConverter do
  @moduledoc false

  alias Temporalex.SearchAttribute

  @etf_encoding "binary/erlang-eterm"
  @json_encoding "json/plain"
  @codec_key :temporalex_payload_codec

  @doc """
  Run `fun` with the payload codec (`:etf` | `:json`) bound for the current
  process. Encoding and decoding are synchronous within one process, so a
  process-scoped codec threads the option through a whole activation or
  completion without touching every call site. Restores the previous binding
  afterwards so codecs cannot leak between calls.

  Returns what `fun` returns, or `{:error, {:payload_conversion, message}}`
  when `fun` tried to encode a term the codec cannot represent.
  """
  def with_codec(codec, fun) when codec in [:etf, :json] and is_function(fun, 0) do
    previous = Process.get(@codec_key)
    Process.put(@codec_key, codec)

    try do
      fun.()
    catch
      {__MODULE__, :unencodable, message} -> {:error, {:payload_conversion, message}}
    after
      if previous == nil, do: Process.delete(@codec_key), else: Process.put(@codec_key, previous)
    end
  end

  def current_codec, do: Process.get(@codec_key, :json)

  def term_to_payload(term) do
    case encode(term, current_codec()) do
      {:ok, payload} -> payload
      {:error, message} -> throw({__MODULE__, :unencodable, message})
    end
  end

  @doc """
  Encodes a value the SDK itself puts in a failure's details, such as a raised
  exception or an exit reason. Under `:json` a value JSON cannot hold is
  recorded as its `inspect/2` string, so reporting a failure never fails.
  """
  def failure_detail_payload(term) do
    case encode(term, current_codec()) do
      {:ok, payload} -> payload
      {:error, _message} -> json_payload!(inspect(term, limit: 50, printable_limit: 1_000))
    end
  end

  def payload_to_term(%{data: data}) when data in [nil, ""], do: {:ok, nil}

  def payload_to_term(%{data: data} = payload) when is_binary(data),
    do: decode(encoding(payload), data, current_codec())

  def payload_to_term(_payload), do: {:error, "payload is missing data"}

  def term_to_payloads_list(term) do
    term
    |> List.wrap()
    |> Enum.map(&term_to_payload/1)
  end

  def payloads_to_terms(payloads) when is_list(payloads) do
    Enum.reduce_while(payloads, {:ok, []}, fn payload, {:ok, acc} ->
      case payload_to_term(payload) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, reason} -> {:error, reason}
    end
  end

  def term_to_payload_map(nil), do: {:ok, %{}}

  def term_to_payload_map(map) when is_map(map) do
    {:ok, Map.new(map, fn {key, value} -> {to_string(key), term_to_payload(value)} end)}
  end

  def term_to_payload_map(_other), do: {:error, "headers option must be a map"}

  def payload_map_to_term(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, payload}, {:ok, acc} ->
      case payload_to_term(payload) do
        {:ok, term} -> {:cont, {:ok, Map.put(acc, key, term)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def search_attributes_to_payload_map(nil), do: {:ok, %{}}

  def search_attributes_to_payload_map(attrs) when is_map(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, json_value} <- search_attribute_json(value),
           {:ok, payload} <- json_payload(json_value) do
        {:cont, {:ok, Map.put(acc, to_string(key), payload)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def search_attributes_to_payload_map(_attrs),
    do: {:error, "search_attributes option must be a map"}

  defp encode(term, :etf), do: {:ok, payload(@etf_encoding, :erlang.term_to_binary(term))}

  defp encode(term, :json) do
    case Jason.encode(term) do
      {:ok, data} -> {:ok, payload(@json_encoding, data)}
      {:error, error} -> {:error, unencodable(error)}
    end
  rescue
    error in Protocol.UndefinedError -> {:error, unencodable(error)}
  end

  defp unencodable(%Protocol.UndefinedError{value: value}),
    do: "payload_codec :json cannot encode #{inspect(value, limit: 5, printable_limit: 100)}"

  defp unencodable(error), do: "payload_codec :json cannot encode it: #{Exception.message(error)}"

  defp encoding(%{metadata: %{"encoding" => encoding}}), do: encoding
  defp encoding(_payload), do: @etf_encoding

  defp decode(@json_encoding, data, _codec) do
    case Jason.decode(data) do
      {:ok, term} -> {:ok, term}
      {:error, error} -> {:error, "payload is not valid JSON: #{Exception.message(error)}"}
    end
  end

  defp decode(@etf_encoding, data, :etf) do
    {:ok, :erlang.binary_to_term(data, [:safe])}
  rescue
    ArgumentError ->
      {:error, "payload is not ETF encoded, or names an atom this node does not know"}
  end

  defp decode(@etf_encoding, _data, :json),
    do: {:error, "refusing an ETF payload: payload_codec is :json, which never decodes ETF"}

  defp decode(encoding, _data, _codec),
    do: {:error, "unsupported payload encoding #{inspect(encoding)}"}

  defp payload(encoding, data),
    do: %{metadata: %{"encoding" => encoding}, data: data, external_payloads: []}

  defp json_payload!(value), do: payload(@json_encoding, Jason.encode!(value))

  defp json_payload(value) do
    case Jason.encode(value) do
      {:ok, data} -> {:ok, payload(@json_encoding, data)}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp search_attribute_json(%SearchAttribute{type: type, value: value}) do
    typed_search_attribute_json(type, value)
  end

  defp search_attribute_json(value) when is_boolean(value), do: {:ok, value}
  defp search_attribute_json(value) when is_integer(value), do: {:ok, value}

  defp search_attribute_json(value) when is_float(value) do
    if finite_float?(value) do
      {:ok, value}
    else
      {:error, "search attribute double values must be finite"}
    end
  end

  defp search_attribute_json(value) when is_binary(value), do: {:ok, value}

  defp search_attribute_json(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error,
       "search attribute values must be typed values or JSON-compatible bool, integer, float, string, or string list"}
    end
  end

  defp search_attribute_json(_value) do
    {:error,
     "search attribute values must be typed values or JSON-compatible bool, integer, float, string, or string list"}
  end

  defp typed_search_attribute_json(:bool, value) when is_boolean(value), do: {:ok, value}
  defp typed_search_attribute_json(:datetime, value) when is_binary(value), do: {:ok, value}

  defp typed_search_attribute_json(:double, value) when is_float(value) do
    if finite_float?(value) do
      {:ok, value}
    else
      {:error, "search attribute double values must be finite"}
    end
  end

  defp typed_search_attribute_json(:double, value) when is_integer(value), do: {:ok, value * 1.0}
  defp typed_search_attribute_json(:int, value) when is_integer(value), do: {:ok, value}
  defp typed_search_attribute_json(:keyword, value) when is_binary(value), do: {:ok, value}
  defp typed_search_attribute_json(:text, value) when is_binary(value), do: {:ok, value}

  defp typed_search_attribute_json(:keyword_list, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, "keyword_list Search Attribute values must be strings"}
    end
  end

  defp typed_search_attribute_json(_type, _value),
    do: {:error, "unsupported Search Attribute type"}

  # Largest finite IEEE-754 double; excludes ±infinity and NaN (NaN fails both
  # comparisons) so only JSON-representable finite doubles pass.
  @max_finite_float 1.797_693_134_862_315_7e308
  defp finite_float?(value), do: value >= -@max_finite_float and value <= @max_finite_float
end
