defmodule Temporalex.ActivityFailure do
  @moduledoc "Raised when an activity fails or crashes."
  defexception [:activity_type, :activity_id, :cause, :message]

  @impl true
  def message(%{activity_type: type, cause: cause}) do
    "Activity #{type} failed: #{inspect(cause)}"
  end
end

defmodule Temporalex.ChildWorkflowFailure do
  @moduledoc "Raised when a child workflow fails."
  defexception [:workflow_type, :workflow_id, :cause, :message]

  @impl true
  def message(%{workflow_type: type, workflow_id: id, cause: cause}) do
    "Child workflow #{type} (#{id}) failed: #{inspect(cause)}"
  end
end

defmodule Temporalex.ApplicationError do
  @moduledoc "Application-level error, optionally non-retryable."
  defexception [:type, :message, :non_retryable, :details]

  @impl true
  def message(%{message: msg, type: type}) do
    "ApplicationError(#{type}): #{msg}"
  end
end

defmodule Temporalex.TimeoutError do
  @moduledoc "Raised when an operation times out."
  defexception [:timeout_type, :message]

  @impl true
  def message(%{timeout_type: type}) do
    "Timeout: #{type}"
  end
end

defmodule Temporalex.CancelledError do
  @moduledoc "Raised when a workflow or activity is cancelled."
  defexception [:details, :message]

  @impl true
  def message(%{details: details}) do
    "Cancelled: #{inspect(details)}"
  end
end

defmodule Temporalex.NondeterminismError do
  @moduledoc "Raised when replay detects a divergence from recorded history."
  defexception [:message]
end
