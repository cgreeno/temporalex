defmodule Temporalex.Testing.Run do
  @moduledoc """
  Handle for a workflow run driven by `Temporalex.Testing`.

  The handle is process-backed. Keep passing the same value to testing helpers;
  the runner process owns the executor, command queue, unresolved operation
  handles, and replay transcript.
  """

  defstruct [:pid, :workflow_module, :workflow_id, :run_id]
end
