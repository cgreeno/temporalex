defmodule Temporalex.NondeterminismError do
  @moduledoc """
  Raised when a workflow's emitted command decisions diverge from its
  recorded history during replay.

  This is the public alias for `Temporalex.Core.Nondeterminism` and is the
  exception users should pattern-match against.
  """

  defexception [:message, :expected, :actual]

  @type t :: %__MODULE__{message: String.t(), expected: term() | nil, actual: term() | nil}

  @doc false
  def from_core(%Temporalex.Core.Nondeterminism{
        message: message,
        expected: expected,
        actual: actual
      }) do
    %__MODULE__{message: message, expected: expected, actual: actual}
  end
end
