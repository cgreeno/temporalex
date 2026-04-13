defmodule Temporalex.ConverterTest do
  use ExUnit.Case, async: true

  alias Temporalex.Converter

  describe "encode/decode round-trip" do
    test "map" do
      term = %{name: "Alice", count: 42}
      assert term == Converter.decode(Converter.encode(term))
    end

    test "list" do
      term = [1, 2, 3, "hello"]
      assert term == Converter.decode(Converter.encode(term))
    end

    test "atom" do
      assert :hello == Converter.decode(Converter.encode(:hello))
    end

    test "integer" do
      assert 999 == Converter.decode(Converter.encode(999))
    end

    test "tuple" do
      term = {:ok, "result"}
      assert term == Converter.decode(Converter.encode(term))
    end

    test "nil" do
      assert nil == Converter.decode(Converter.encode(nil))
    end
  end

  describe "binary passthrough" do
    test "raw binary uses plain encoding" do
      payload = Converter.encode("raw bytes")
      assert payload.metadata["encoding"] == "binary/plain"
      assert payload.data == "raw bytes"
      assert "raw bytes" == Converter.decode(payload)
    end
  end

  describe "ETF encoding" do
    test "non-binary terms use ETF" do
      payload = Converter.encode(%{key: "val"})
      assert payload.metadata["encoding"] == "binary/etf"
      assert is_binary(payload.data)
    end
  end

  describe "JSON decoding" do
    test "decodes JSON payloads" do
      payload = %{metadata: %{"encoding" => "json/plain"}, data: ~s({"name":"Bob"})}
      assert %{"name" => "Bob"} == Converter.decode(payload)
    end
  end

  describe "fallback" do
    test "payload without encoding returns raw data" do
      assert "raw" == Converter.decode(%{data: "raw"})
    end
  end

  describe "encode_args / decode_args" do
    test "round-trips a list of terms" do
      terms = [100, "hello", %{x: 1}]
      payloads = Converter.encode_args(terms)
      assert length(payloads) == 3
      assert terms == Converter.decode_args(payloads)
    end
  end
end
