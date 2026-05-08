defmodule Temporalex.Failure.ApplicationError do
  @moduledoc """
  Application failure with retry metadata.
  """

  defexception message: "Temporalex application failure",
               type: "Temporalex.ApplicationError",
               details: [],
               retryable?: true,
               source: "Temporalex",
               stack_trace: nil,
               cause: nil
end

defmodule Temporalex.Failure.CancelledError do
  @moduledoc """
  Temporal cancellation failure.
  """

  defexception message: "Temporalex cancelled",
               details: [],
               identity: nil,
               source: "Temporalex",
               stack_trace: nil,
               cause: nil
end

defmodule Temporalex.Failure.TimeoutError do
  @moduledoc """
  Temporal timeout failure.
  """

  defexception message: "Temporalex timeout",
               timeout_type: nil,
               last_heartbeat_details: [],
               source: "Temporalex",
               stack_trace: nil,
               cause: nil
end

defmodule Temporalex.Failure.ActivityError do
  @moduledoc """
  Failure wrapper for a failed Activity Execution.
  """

  defexception message: "Temporalex activity failure",
               activity_id: nil,
               activity_type: nil,
               retry_state: nil,
               identity: nil,
               source: "Temporalex",
               stack_trace: nil,
               cause: nil
end

defmodule Temporalex.Failure.WorkflowExecutionError do
  @moduledoc """
  Failure wrapper for a failed Child Workflow Execution.
  """

  defexception message: "Temporalex workflow execution failure",
               namespace: nil,
               workflow_id: nil,
               run_id: nil,
               workflow_type: nil,
               retry_state: nil,
               source: "Temporalex",
               stack_trace: nil,
               cause: nil
end

defmodule Temporalex.Failure.UnknownError do
  @moduledoc """
  Fallback for Temporal failures not yet modeled by Temporalex.
  """

  defexception message: "Temporalex unknown failure",
               failure_type: nil,
               source: nil,
               stack_trace: nil,
               cause: nil
end

defmodule Temporalex.Failure do
  @moduledoc """
  Helpers for constructing structured Temporal failures.
  """

  alias Temporalex.Failure.ApplicationError
  alias Temporalex.Failure.CancelledError

  @doc """
  Build an application failure.

  `:type` is the stable string matched by Temporal retry policies.
  `:retryable?` defaults to true and is inverted when encoded to Temporal's
  `non_retryable` wire field.
  """
  def application(message, opts \\ []) do
    %ApplicationError{
      message: to_string(message),
      type: Keyword.get(opts, :type, "Temporalex.ApplicationError"),
      details: List.wrap(Keyword.get(opts, :details, [])),
      retryable?: Keyword.get(opts, :retryable?, true),
      cause: Keyword.get(opts, :cause)
    }
  end

  @doc "Raise an application failure."
  def application!(message, opts \\ []) do
    raise application(message, opts)
  end

  @doc "Build a cancellation failure."
  def cancelled(message \\ "cancelled", opts \\ []) do
    %CancelledError{
      message: to_string(message),
      details: List.wrap(Keyword.get(opts, :details, [])),
      cause: Keyword.get(opts, :cause)
    }
  end
end
