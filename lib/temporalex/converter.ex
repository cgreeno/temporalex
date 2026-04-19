defmodule Temporalex.Converter do
  @moduledoc """
  Default JSON data converter using Jason.

  Encodes Elixir terms to Temporal Payloads and decodes Payloads back to terms.
  All data crossing the workflow/activity boundary passes through this module.

  Supports encodings: `json/plain`, `binary/null`, `binary/plain`.

  By default, JSON maps are decoded with atom keys (using `keys: :atoms!`
  which only converts to existing atoms). Pass `keys: :strings` to decode
  with string keys instead.
  """
  require Logger

  alias Temporal.Api.Common.V1.Payload

  @typedoc false
  @type payload :: Payload.t()

  @json_encoding "json/plain"
  @binary_null "binary/null"
  @binary_plain "binary/plain"

  @doc "Encode an Elixir term into a Temporal Payload."
  @spec to_payload(term()) :: payload()
  def to_payload(nil) do
    %Payload{metadata: %{"encoding" => @binary_null}, data: ""}
  end

  def to_payload(value) when is_binary(value) do
    case Jason.encode(value) do
      {:ok, data} -> %Payload{metadata: %{"encoding" => @json_encoding}, data: data}
      {:error, _} -> %Payload{metadata: %{"encoding" => @binary_plain}, data: value}
    end
  end

  def to_payload(value) do
    case Jason.encode(value) do
      {:ok, data} -> %Payload{metadata: %{"encoding" => @json_encoding}, data: data}
      {:error, _} -> %Payload{metadata: %{"encoding" => @binary_plain}, data: inspect(value)}
    end
  end

  @doc "Encode a list of terms into a list of Payloads."
  @spec to_payloads(list()) :: [payload()]
  def to_payloads(values) when is_list(values) do
    Enum.map(values, &to_payload/1)
  end

  @doc """
  Decode a Temporal Payload back to an Elixir term.

  Options:
    * `:keys` — `:atoms!` (default, safe) or `:strings`
  """
  @spec from_payload(payload(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def from_payload(payload, opts \\ [])

  def from_payload(%Payload{data: "", metadata: %{"encoding" => @binary_null}}, _opts),
    do: {:ok, nil}

  def from_payload(%Payload{data: ""}, _opts), do: {:ok, nil}

  def from_payload(%Payload{data: data, metadata: metadata}, opts) do
    encoding = Map.get(metadata, "encoding", @json_encoding)

    case encoding do
      @json_encoding ->
        jason_opts = json_decode_opts(opts)

        case Jason.decode(data, jason_opts) do
          {:ok, term} ->
            {:ok, term}

          {:error, %Jason.DecodeError{} = err} ->
            {:error, "JSON decode error at position #{err.position}: #{Exception.message(err)}"}
        end

      @binary_null ->
        {:ok, nil}

      @binary_plain ->
        {:ok, data}

      other ->
        {:error,
         "unsupported payload encoding: #{inspect(other)}. Supported: json/plain, binary/null, binary/plain"}
    end
  end

  @doc "Decode a Temporal Payload, raising on error."
  @spec from_payload!(payload(), keyword()) :: term()
  def from_payload!(payload, opts \\ []) do
    case from_payload(payload, opts) do
      {:ok, term} ->
        term

      {:error, reason} ->
        encoding = payload.metadata["encoding"]
        data_len = byte_size(payload.data)

        raise "Converter.from_payload! failed: #{reason} " <>
                "(encoding=#{inspect(encoding)}, data_bytes=#{data_len})"
    end
  end

  @doc "Decode a list of Payloads back to Elixir terms."
  @spec from_payloads([payload()], keyword()) :: {:ok, [term()]} | {:error, String.t()}
  def from_payloads(payloads, opts \\ []) when is_list(payloads) do
    payloads
    |> Enum.reduce_while({:ok, []}, fn payload, {:ok, acc} ->
      case from_payload(payload, opts) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      error -> error
    end
  end

  defp json_decode_opts(opts) do
    case Keyword.get(opts, :keys, :atoms!) do
      :atoms! -> [keys: :atoms!]
      :strings -> []
      _ -> [keys: :atoms!]
    end
  end
end
