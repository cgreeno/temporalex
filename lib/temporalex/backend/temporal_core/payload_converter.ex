defmodule Temporalex.Backend.TemporalCore.PayloadConverter do
  @moduledoc false

  alias Temporalex.SearchAttribute

  @etf_encoding "binary/erlang-eterm"
  @json_encoding "json/plain"

  def term_to_bytes(term), do: :erlang.term_to_binary(term)

  def bytes_to_term(bytes) when is_binary(bytes), do: :erlang.binary_to_term(bytes)

  def term_to_payload(term) do
    payload_from_bytes(term_to_bytes(term))
  end

  def payload_to_term(%{data: data}) when data in [nil, ""], do: {:ok, nil}

  def payload_to_term(%{data: data}) when is_binary(data) do
    {:ok, bytes_to_term(data)}
  rescue
    ArgumentError -> {:error, "payload is not ETF encoded"}
  end

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

  defp payload_from_bytes(data) do
    %{
      metadata: %{"encoding" => @etf_encoding},
      data: data,
      external_payloads: []
    }
  end

  defp json_payload(value) do
    case Jason.encode(value) do
      {:ok, data} ->
        {:ok, %{metadata: %{"encoding" => @json_encoding}, data: data, external_payloads: []}}

      {:error, error} ->
        {:error, Exception.message(error)}
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

  defp finite_float?(value),
    do: value == value and value not in [:math.pow(1.0, 309), -:math.pow(1.0, 309)]
end
