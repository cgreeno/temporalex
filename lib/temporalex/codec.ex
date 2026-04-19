defmodule Temporalex.Codec do
  @moduledoc """
  Behaviour for payload codecs that transform payloads between the
  Converter and the wire.

  Codecs run after encoding (before sending to Temporal) and before
  decoding (after receiving from Temporal). Common uses:

  - **Encryption** — encrypt payload data before it's stored in Temporal
  - **Compression** — reduce payload size for high-throughput workloads

  ## Implementing a Codec

      defmodule MyApp.EncryptionCodec do
        @behaviour Temporalex.Codec

        @impl true
        def encode(%{data: data, metadata: meta} = payload) do
          encrypted = MyApp.Crypto.encrypt(data)
          {:ok, %{payload | data: encrypted, metadata: Map.put(meta, "encoding", "binary/encrypted")}}
        end

        @impl true
        def decode(%{metadata: %{"encoding" => "binary/encrypted"}} = payload) do
          decrypted = MyApp.Crypto.decrypt(payload.data)
          {:ok, %{payload | data: decrypted, metadata: Map.put(payload.metadata, "encoding", "json/plain")}}
        end

        def decode(payload), do: {:ok, payload}
      end

  ## Configuration

      {Temporalex,
        name: MyApp.Temporal,
        codec: MyApp.EncryptionCodec,
        ...}

  Or for a chain of codecs (applied in order on encode, reversed on decode):

      {Temporalex,
        name: MyApp.Temporal,
        codec: [MyApp.CompressionCodec, MyApp.EncryptionCodec],
        ...}
  """

  alias Temporal.Api.Common.V1.Payload

  @typedoc false
  @type payload :: Payload.t()

  @doc "Transform a payload before sending to Temporal."
  @callback encode(payload()) :: {:ok, payload()} | {:error, term()}

  @doc "Transform a payload after receiving from Temporal."
  @callback decode(payload()) :: {:ok, payload()} | {:error, term()}

  @doc """
  Apply a codec (or list of codecs) to encode a payload.

  Codecs are applied in order. Returns `{:ok, payload}` or `{:error, reason}`.
  """
  @spec apply_encode(payload(), module() | [module()] | nil) ::
          {:ok, payload()} | {:error, term()}
  def apply_encode(payload, nil), do: {:ok, payload}
  def apply_encode(payload, codec) when is_atom(codec), do: codec.encode(payload)

  def apply_encode(payload, codecs) when is_list(codecs) do
    Enum.reduce_while(codecs, {:ok, payload}, fn codec, {:ok, p} ->
      case codec.encode(p) do
        {:ok, encoded} -> {:cont, {:ok, encoded}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Apply a codec (or list of codecs) to decode a payload.

  Codecs are applied in reverse order (last encoder is first decoder).
  """
  @spec apply_decode(payload(), module() | [module()] | nil) ::
          {:ok, payload()} | {:error, term()}
  def apply_decode(payload, nil), do: {:ok, payload}
  def apply_decode(payload, codec) when is_atom(codec), do: codec.decode(payload)

  def apply_decode(payload, codecs) when is_list(codecs) do
    codecs
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, payload}, fn codec, {:ok, p} ->
      case codec.decode(p) do
        {:ok, decoded} -> {:cont, {:ok, decoded}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
