defmodule Temporalex.Backend.TemporalCore.PayloadConverter do
  @moduledoc false

  def term_to_bytes(term), do: :erlang.term_to_binary(term)

  def bytes_to_term(bytes) when is_binary(bytes), do: :erlang.binary_to_term(bytes)
end
