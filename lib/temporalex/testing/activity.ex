defmodule Temporalex.Testing.Activity do
  @moduledoc """
  Testing handle for a scheduled activity command.

  Activity handles are returned by `Temporalex.Testing.assert_next_activity/2`
  and must be used to complete or fail that exact scheduled activity.
  """

  defstruct [
    :run,
    :ref,
    :seq,
    :thread_id,
    :activity_id,
    :type,
    input: [],
    opts: []
  ]
end
