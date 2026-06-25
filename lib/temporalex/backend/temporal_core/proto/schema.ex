defmodule Temporalex.Backend.TemporalCore.Proto.Schema do
  @moduledoc false

  use MiniPB.Schema,
    descriptor: "priv/proto/temporal_core.binpb",
    projections: Temporalex.Backend.TemporalCore.Proto.Adapters.projections()
end
