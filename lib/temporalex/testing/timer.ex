defmodule Temporalex.Testing.Timer do
  @moduledoc """
  Testing handle for a started timer command.

  Timer handles are returned by `Temporalex.Testing.assert_next_timer/2` and
  must be used to fire that exact timer.
  """

  defstruct [:run, :ref, :seq, :thread_id, :duration_ms]
end
