defmodule Temporalex.Testing.Update do
  @moduledoc """
  Testing handle for an update delivered to a workflow run.
  """

  defstruct [:run, :id, :protocol_instance_id, :name]
end
