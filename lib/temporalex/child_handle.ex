defmodule Temporalex.ChildHandle do
  @moduledoc """
  Reference to a child workflow that has been started by the current
  workflow execution.

  Returned by `Temporalex.Workflow.API.start_child_workflow/3`. Used to
  signal, cancel, or await the child's eventual completion.

  Fields:

    * `:workflow_id` — the child's workflow id (durable identifier)
    * `:run_id` — the run id assigned by Temporal when the child started
    * `:workflow_type` — the workflow-type string of the child
    * `:seq` — internal sequence number that ties the handle to its
      pending entry in the executor; used by `await_child_workflow/1`
      to wait on the right completion
  """

  defstruct [:workflow_id, :run_id, :workflow_type, :seq]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          run_id: String.t() | nil,
          workflow_type: String.t() | nil,
          seq: non_neg_integer()
        }
end
