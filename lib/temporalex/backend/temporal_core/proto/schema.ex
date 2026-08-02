defmodule Temporalex.Backend.TemporalCore.Proto.Schema do
  @moduledoc false

  alias Temporalex.Backend.TemporalCore.Proto.Adapters

  use PB.Schema,
    descriptor: "priv/proto/temporal_core.binpb",
    projections: Adapters.projections()
end
