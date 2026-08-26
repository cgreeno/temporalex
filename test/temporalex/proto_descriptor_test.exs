defmodule Temporalex.ProtoDescriptorTest do
  @moduledoc """
  That the committed descriptor was generated from the sdk-rust revision the
  NIF is built against.

  A stale descriptor does not fail — it decodes, minus whatever the newer proto
  tree added, so a field the server did send reads as absent and every
  assertion about it passes for the wrong reason. That is the failure
  `priority_decode_test.exs` warns about for one field; this covers the tree.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Temporalex.Gen.Proto
  alias Temporalex.Backend.TemporalCore.Codec
  alias Temporalex.Backend.TemporalCore.Proto.Schema

  test "the descriptor matches the pinned sdk-rust revision" do
    pinned = Proto.pinned_revision!()

    assert Proto.committed_revision() == pinned,
           """
           priv/proto/temporal_core.binpb was generated from \
           #{inspect(Proto.committed_revision())}, but Cargo.lock pins \
           #{String.slice(pinned, 0, 7)}.

           Run: mix temporalex.gen.proto
           """
  end

  test "the descriptor decodes a history the schema knows" do
    assert {:ok, bytes} =
             Schema.encode(
               %{events: [%{event_id: 1}]},
               :"temporal.api.history.v1.History"
             )

    assert {:ok, [event]} = Codec.history_from_bytes(bytes)
    assert event.id == 1
  end
end
