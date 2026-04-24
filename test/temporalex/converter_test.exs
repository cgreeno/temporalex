defmodule Temporalex.ConverterTest do
  @moduledoc """
  Priority 7 — Data Conversion (D1-D12) from TESTS_V2.md.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Converter

  # Used by the D7 nested-struct test.
  defmodule Address do
    defstruct [:street, :city]
  end

  defmodule User do
    defstruct [:id, :name, :address]
  end

  describe "encode/decode round-trip" do
    test "D1 — map" do
      term = %{name: "Alice", count: 42}
      assert term == Converter.decode(Converter.encode(term))
    end

    test "D2 — list" do
      term = [1, 2, 3, "hello"]
      assert term == Converter.decode(Converter.encode(term))
    end

    test "D3 — atom" do
      assert :hello == Converter.decode(Converter.encode(:hello))
    end

    test "D4 — integer" do
      assert 999 == Converter.decode(Converter.encode(999))
    end

    test "D5 — tuple" do
      term = {:ok, "result"}
      assert term == Converter.decode(Converter.encode(term))
    end

    test "D6 — nil" do
      assert nil == Converter.decode(Converter.encode(nil))
    end

    test "D7 — nested struct" do
      user = %User{
        id: 42,
        name: "Alice",
        address: %Address{street: "1 Elm", city: "Portland"}
      }

      assert user == Converter.decode(Converter.encode(user))
    end
  end

  describe "D8 — binary passthrough" do
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

  describe "D9 — JSON decoding" do
    test "decodes JSON payloads" do
      payload = %{metadata: %{"encoding" => "json/plain"}, data: ~s({"name":"Bob"})}
      assert %{"name" => "Bob"} == Converter.decode(payload)
    end
  end

  describe "D10 — payload without encoding returns raw data" do
    test "no metadata → raw passthrough" do
      assert "raw" == Converter.decode(%{data: "raw"})
    end
  end

  describe "D11 — encode_args / decode_args" do
    test "round-trips a list of terms" do
      terms = [100, "hello", %{x: 1}]
      payloads = Converter.encode_args(terms)
      assert length(payloads) == 3
      assert terms == Converter.decode_args(payloads)
    end
  end

  describe "D12 — safe binary_to_term" do
    test "ETF decode refuses to create new atoms from untrusted payloads" do
      # Craft an ETF-encoded binary that names an atom that definitely does
      # not exist in the runtime. With :safe, binary_to_term raises rather
      # than allocating a new atom.
      bogus = :erlang.term_to_binary(:__temporalex_bogus_nonexistent_atom__)

      # Generate a fresh, never-seen atom name each test run.
      unique_name = "__temporalex_never_seen_#{System.unique_integer([:positive])}__"
      unique_bogus = String.replace(bogus, "__temporalex_bogus_nonexistent_atom__", unique_name)

      payload = %{metadata: %{"encoding" => "binary/etf"}, data: unique_bogus}

      assert_raise ArgumentError, fn ->
        Converter.decode(payload)
      end
    end

    test "ETF decode succeeds for atoms that already exist" do
      # :ok is a known atom, so :safe decoding succeeds.
      payload = Converter.encode(:ok)
      assert :ok == Converter.decode(payload)
    end
  end
end
