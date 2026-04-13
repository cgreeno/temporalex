defmodule Temporalex.Converter do
  @moduledoc """
  Encodes and decodes workflow/activity payloads.

  Default encoding is ETF (Erlang Term Format), which preserves full Elixir
  type fidelity. Payloads are represented as `%{metadata: map, data: binary}`
  matching the Temporal Payload protobuf structure.
  """

  @etf "binary/etf"
  @plain "binary/plain"
  @json "json/plain"

  @doc "Encode a term into a payload map."
  def encode(term) when is_binary(term), do: %{metadata: %{"encoding" => @plain}, data: term}
  def encode(term), do: %{metadata: %{"encoding" => @etf}, data: :erlang.term_to_binary(term)}

  @doc "Decode a payload map back to a term."
  def decode(%{metadata: %{"encoding" => @etf}, data: data}),
    do: :erlang.binary_to_term(data, [:safe])

  def decode(%{metadata: %{"encoding" => @plain}, data: data}), do: data
  def decode(%{metadata: %{"encoding" => @json}, data: data}), do: Jason.decode!(data)
  def decode(%{data: data}), do: data

  @doc "Encode a list of terms into payload maps."
  def encode_args(args), do: Enum.map(args, &encode/1)

  @doc "Decode a list of payload maps into terms."
  def decode_args(payloads), do: Enum.map(payloads, &decode/1)
end
