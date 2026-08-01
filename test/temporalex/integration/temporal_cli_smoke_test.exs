defmodule Temporalex.TemporalCliSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :external

  test "Temporal CLI starts a local development server" do
    server = Temporalex.TestSupport.TemporalDevServer.start!()

    try do
      assert is_integer(server.port)
    after
      Temporalex.TestSupport.TemporalDevServer.stop(server)
    end
  end
end
