defmodule Temporalex.Error do
  @moduledoc """
  Error types for Temporal workflow and activity failures.

  These map to Temporal's failure model and provide structured error
  information that propagates correctly through the Temporal system.
  """

  defmodule ActivityFailure do
    @moduledoc """
    Raised when an activity execution fails.

    Contains the activity type, ID, and the underlying cause.
    """
    defexception [:message, :activity_type, :activity_id, :cause]

    @type t :: %__MODULE__{
            message: String.t(),
            activity_type: String.t() | nil,
            activity_id: String.t() | nil,
            cause: term()
          }

    @impl true
    def message(%{message: msg, activity_type: type, activity_id: id}) do
      "Activity failed: #{msg} (type=#{type || "unknown"}, id=#{id || "unknown"})"
    end
  end

  defmodule TimeoutError do
    @moduledoc """
    Raised when a workflow or activity times out.

    The `timeout_type` indicates which timeout was exceeded:
    `:start_to_close`, `:schedule_to_start`, `:schedule_to_close`, `:heartbeat`.
    """
    defexception [:message, :timeout_type]

    @type t :: %__MODULE__{
            message: String.t(),
            timeout_type: atom()
          }

    @impl true
    def message(%{message: msg, timeout_type: type}) do
      "Timeout: #{msg} (type=#{type})"
    end
  end

  defmodule CancelledError do
    @moduledoc """
    Raised when a workflow or activity is cancelled.
    """
    defexception [:message, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            details: term()
          }

    @impl true
    def message(%{message: msg}) do
      "Cancelled: #{msg}"
    end
  end

  defmodule ApplicationError do
    @moduledoc """
    Application-level error that can be thrown from workflow or activity code.

    Supports a `type` field for error categorization and `non_retryable` flag.
    """
    defexception [:message, :type, :non_retryable, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            type: String.t() | nil,
            non_retryable: boolean(),
            details: term()
          }

    @impl true
    def message(%{message: msg, type: type}) do
      if type, do: "ApplicationError[#{type}]: #{msg}", else: "ApplicationError: #{msg}"
    end
  end

  defmodule ContinueAsNew do
    @moduledoc """
    Raised internally to signal a continue-as-new transition.

    Not a real error — this is caught by the Worker and converted into
    the `ContinueAsNewWorkflowExecution` command.
    """
    defexception [:workflow_type, :task_queue, :args, :opts]

    @type t :: %__MODULE__{
            workflow_type: String.t() | nil,
            task_queue: String.t() | nil,
            args: list(),
            opts: keyword()
          }

    @impl true
    def message(_), do: "continue_as_new"
  end

  defmodule Nondeterminism do
    @moduledoc """
    Raised when workflow code diverges from replay history.

    This means the workflow code changed in a way that produces a different
    sequence of commands than the original execution. For example, calling
    an activity where the original execution called `sleep`, or vice versa.
    """
    defexception [:message]

    @type t :: %__MODULE__{message: String.t()}

    @impl true
    def message(%{message: msg}), do: "Nondeterminism error: #{msg}"
  end

  defmodule ChildWorkflowFailure do
    @moduledoc """
    Raised when a child workflow execution fails.
    """
    defexception [:message, :workflow_type, :workflow_id, :cause]

    @type t :: %__MODULE__{
            message: String.t(),
            workflow_type: String.t() | nil,
            workflow_id: String.t() | nil,
            cause: term()
          }

    @impl true
    def message(%{message: msg, workflow_type: type, workflow_id: id}) do
      "Child workflow failed: #{msg} (type=#{type || "unknown"}, id=#{id || "unknown"})"
    end
  end
end
