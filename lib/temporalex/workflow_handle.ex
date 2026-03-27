defmodule Temporalex.WorkflowHandle do
  @moduledoc "Handle to a running or completed workflow execution."

  defstruct [:workflow_id, :run_id, :conn]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          run_id: String.t(),
          conn: atom() | pid() | nil
        }
end
