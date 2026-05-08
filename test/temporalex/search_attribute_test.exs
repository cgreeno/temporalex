defmodule Temporalex.SearchAttributeTest do
  use ExUnit.Case, async: true

  alias Temporalex.SearchAttribute

  test "constructors produce typed search attribute values" do
    assert %SearchAttribute{type: :bool, value: true} = SearchAttribute.bool(true)
    assert %SearchAttribute{type: :double, value: 1.5} = SearchAttribute.double(1.5)
    assert %SearchAttribute{type: :double, value: 2.0} = SearchAttribute.double(2)
    assert %SearchAttribute{type: :int, value: 42} = SearchAttribute.int(42)

    assert %SearchAttribute{type: :keyword, value: "order-123"} =
             SearchAttribute.keyword("order-123")

    assert %SearchAttribute{type: :keyword_list, value: ["a", "b"]} =
             SearchAttribute.keyword_list(["a", "b"])

    assert %SearchAttribute{type: :text, value: "free text"} = SearchAttribute.text("free text")
  end

  test "datetime constructors normalize values to ISO-8601 strings with offsets" do
    assert %SearchAttribute{type: :datetime, value: "2026-05-08T10:15:30Z"} =
             SearchAttribute.datetime(~U[2026-05-08 10:15:30Z])

    assert %SearchAttribute{type: :datetime, value: "2026-05-08T10:15:30Z"} =
             SearchAttribute.datetime(~N[2026-05-08 10:15:30])

    assert %SearchAttribute{type: :datetime, value: "2026-05-08T00:00:00Z"} =
             SearchAttribute.datetime(~D[2026-05-08])
  end

  test "datetime constructor rejects strings without an offset" do
    assert_raise ArgumentError, ~r/with an offset/, fn ->
      SearchAttribute.datetime("2026-05-08T10:15:30")
    end
  end

  test "validate_map stringifies keys and accepts explicit and primitive values" do
    assert %{
             "CustomKeywordField" => %SearchAttribute{type: :keyword, value: "alpha"},
             "CustomIntField" => 7
           } =
             SearchAttribute.validate_map!(%{
               "CustomIntField" => 7,
               CustomKeywordField: SearchAttribute.keyword("alpha")
             })
  end

  test "keyword lists must contain strings" do
    assert_raise ArgumentError, ~r/must be strings/, fn ->
      SearchAttribute.keyword_list(["ok", 1])
    end

    assert_raise ArgumentError, ~r/lists must contain only strings/, fn ->
      SearchAttribute.validate!([:not_a_string])
    end
  end
end
