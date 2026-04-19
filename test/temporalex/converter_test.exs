defmodule Temporalex.ConverterTest do
  @moduledoc """
  Tests for the JSON data converter. Updated for binary/null support.
  """
  use ExUnit.Case, async: true

  alias Temporal.Api.Common.V1.Payload
  alias Temporalex.Converter

  describe "to_payload/1" do
    test "encodes a string" do
      payload = Converter.to_payload("hello")
      assert %Payload{data: data, metadata: %{"encoding" => "json/plain"}} = payload
      assert data == ~s("hello")
    end

    test "encodes an integer" do
      payload = Converter.to_payload(42)
      assert payload.data == "42"
    end

    test "encodes a map" do
      payload = Converter.to_payload(%{name: "Chris", age: 30})
      decoded = Jason.decode!(payload.data)
      assert decoded["name"] == "Chris"
      assert decoded["age"] == 30
    end

    test "encodes a list" do
      payload = Converter.to_payload([1, 2, 3])
      assert payload.data == "[1,2,3]"
    end

    test "encodes nil as binary/null" do
      payload = Converter.to_payload(nil)
      assert payload.metadata["encoding"] == "binary/null"
      assert payload.data == ""
    end
  end

  describe "from_payload/1" do
    test "decodes a string payload" do
      payload = %Payload{data: ~s("hello"), metadata: %{"encoding" => "json/plain"}}
      assert {:ok, "hello"} = Converter.from_payload(payload)
    end

    test "decodes a map payload (atom keys by default)" do
      payload = %Payload{data: ~s({"name":"Chris"}), metadata: %{"encoding" => "json/plain"}}
      assert {:ok, %{name: "Chris"}} = Converter.from_payload(payload)
    end

    test "decodes a map payload with explicit string keys" do
      payload = %Payload{data: ~s({"name":"Chris"}), metadata: %{"encoding" => "json/plain"}}
      assert {:ok, %{"name" => "Chris"}} = Converter.from_payload(payload, keys: :strings)
    end

    test "returns error for invalid JSON" do
      payload = %Payload{data: "not valid json{", metadata: %{"encoding" => "json/plain"}}
      assert {:error, _} = Converter.from_payload(payload)
    end

    test "decodes binary/null as nil" do
      payload = %Payload{data: "", metadata: %{"encoding" => "binary/null"}}
      assert {:ok, nil} = Converter.from_payload(payload)
    end

    test "decodes binary/plain as raw binary" do
      payload = %Payload{data: "raw bytes", metadata: %{"encoding" => "binary/plain"}}
      assert {:ok, "raw bytes"} = Converter.from_payload(payload)
    end

    test "returns error for unsupported encoding" do
      payload = %Payload{data: "data", metadata: %{"encoding" => "protobuf/json"}}
      assert {:error, msg} = Converter.from_payload(payload)
      assert msg =~ "unsupported payload encoding"
      assert msg =~ "protobuf/json"
    end
  end

  describe "round-trip" do
    test "string round-trips" do
      assert {:ok, "hello"} = "hello" |> Converter.to_payload() |> Converter.from_payload()
    end

    test "map round-trips (atom keys by default)" do
      input = %{"name" => "Chris", "count" => 42}
      {:ok, result} = input |> Converter.to_payload() |> Converter.from_payload()
      assert result == %{name: "Chris", count: 42}
    end

    test "map round-trips (explicit string keys)" do
      input = %{"name" => "Chris", "count" => 42}

      assert {:ok, ^input} =
               input |> Converter.to_payload() |> Converter.from_payload(keys: :strings)
    end

    test "list round-trips" do
      input = [1, "two", 3.0]
      assert {:ok, ^input} = input |> Converter.to_payload() |> Converter.from_payload()
    end

    test "nil round-trips" do
      assert {:ok, nil} = nil |> Converter.to_payload() |> Converter.from_payload()
    end
  end

  describe "to_payloads/1 and from_payloads/1" do
    test "round-trips a list of values" do
      values = ["hello", 42, %{"key" => "val"}]
      payloads = Converter.to_payloads(values)
      assert length(payloads) == 3
      assert {:ok, decoded} = Converter.from_payloads(payloads)
      assert decoded == ["hello", 42, %{key: "val"}]
    end

    test "empty list" do
      assert [] = Converter.to_payloads([])
      assert {:ok, []} = Converter.from_payloads([])
    end
  end
end
