defmodule Temporalex.CodecTest do
  use ExUnit.Case, async: true

  alias Temporalex.Codec
  alias Temporal.Api.Common.V1.Payload

  # Test codec that base64-encodes data
  defmodule Base64Codec do
    @behaviour Temporalex.Codec

    @impl true
    def encode(%Payload{data: data} = payload) do
      {:ok,
       %{
         payload
         | data: Base.encode64(data),
           metadata: Map.put(payload.metadata, "codec", "base64")
       }}
    end

    @impl true
    def decode(%Payload{metadata: %{"codec" => "base64"}} = payload) do
      {:ok,
       %{
         payload
         | data: Base.decode64!(payload.data),
           metadata: Map.delete(payload.metadata, "codec")
       }}
    end

    def decode(payload), do: {:ok, payload}
  end

  # Test codec that prefixes data
  defmodule PrefixCodec do
    @behaviour Temporalex.Codec

    @impl true
    def encode(%Payload{data: data} = payload) do
      {:ok, %{payload | data: "PREFIX:" <> data}}
    end

    @impl true
    def decode(%Payload{data: "PREFIX:" <> rest} = payload) do
      {:ok, %{payload | data: rest}}
    end

    def decode(payload), do: {:ok, payload}
  end

  # Test codec that always fails
  defmodule FailCodec do
    @behaviour Temporalex.Codec
    @impl true
    def encode(_payload), do: {:error, "encode failed"}
    @impl true
    def decode(_payload), do: {:error, "decode failed"}
  end

  describe "apply_encode/2" do
    test "nil codec passes through" do
      payload = %Payload{data: "hello", metadata: %{}}
      assert {:ok, ^payload} = Codec.apply_encode(payload, nil)
    end

    test "single codec transforms payload" do
      payload = %Payload{data: "hello", metadata: %{"encoding" => "json/plain"}}
      assert {:ok, encoded} = Codec.apply_encode(payload, Base64Codec)
      assert encoded.data == Base.encode64("hello")
      assert encoded.metadata["codec"] == "base64"
    end

    test "codec chain applies in order" do
      payload = %Payload{data: "hello", metadata: %{}}
      assert {:ok, encoded} = Codec.apply_encode(payload, [PrefixCodec, Base64Codec])
      # PrefixCodec runs first, then Base64Codec
      assert encoded.data == Base.encode64("PREFIX:hello")
    end

    test "error in chain halts" do
      payload = %Payload{data: "hello", metadata: %{}}
      assert {:error, "encode failed"} = Codec.apply_encode(payload, [PrefixCodec, FailCodec])
    end
  end

  describe "apply_decode/2" do
    test "nil codec passes through" do
      payload = %Payload{data: "hello", metadata: %{}}
      assert {:ok, ^payload} = Codec.apply_decode(payload, nil)
    end

    test "single codec transforms payload" do
      payload = %Payload{data: Base.encode64("hello"), metadata: %{"codec" => "base64"}}
      assert {:ok, decoded} = Codec.apply_decode(payload, Base64Codec)
      assert decoded.data == "hello"
    end

    test "codec chain applies in reverse order" do
      # Encode: PrefixCodec then Base64Codec
      # Decode: Base64Codec first (reverse), then PrefixCodec
      original = %Payload{data: "hello", metadata: %{}}
      {:ok, encoded} = Codec.apply_encode(original, [PrefixCodec, Base64Codec])

      assert {:ok, decoded} = Codec.apply_decode(encoded, [PrefixCodec, Base64Codec])
      assert decoded.data == "hello"
    end

    test "round-trip preserves data" do
      codecs = [PrefixCodec, Base64Codec]
      original = %Payload{data: ~s({"key":"value"}), metadata: %{"encoding" => "json/plain"}}

      {:ok, encoded} = Codec.apply_encode(original, codecs)
      {:ok, decoded} = Codec.apply_decode(encoded, codecs)

      assert decoded.data == original.data
    end
  end
end
