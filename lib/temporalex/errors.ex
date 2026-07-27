defmodule Temporalex.ApplicationError do
  @moduledoc """
  Generic application-level failure raised from inside an activity or workflow.

  When raised in an activity body, the worker translates it into a Temporal
  `ApplicationFailureInfo` with the given `type`, `message`, `non_retryable`,
  and `details` fields. The workflow sees it wrapped in a
  `Temporalex.ActivityFailure` whose `cause` is this struct.

  Setting `non_retryable: true` instructs Temporal not to retry the activity
  even if the activity's retry policy would otherwise allow another attempt.
  """

  defexception [:message, :type, :details, non_retryable: false]

  @type t :: %__MODULE__{
          message: String.t(),
          type: String.t() | nil,
          non_retryable: boolean(),
          details: term() | nil
        }

  @doc ~S|Convenience constructor: `ApplicationError.new("boom", type: "InvalidSku", non_retryable: true)`.|
  def new(message, opts \\ []) when is_binary(message) do
    %__MODULE__{
      message: message,
      type: Keyword.get(opts, :type, "ApplicationError"),
      non_retryable: Keyword.get(opts, :non_retryable, false),
      details: Keyword.get(opts, :details)
    }
  end
end

defmodule Temporalex.CancelledError do
  @moduledoc """
  Raised when an activity, child workflow, or workflow is cancelled.
  """

  defexception [:message, :details]

  @type t :: %__MODULE__{message: String.t(), details: term() | nil}

  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      message: Keyword.get(opts, :message, "cancelled"),
      details: Keyword.get(opts, :details)
    }
  end
end

defmodule Temporalex.TimeoutError do
  @moduledoc """
  Raised when an activity or workflow times out.

  `timeout_type` is one of `:start_to_close`, `:schedule_to_close`,
  `:schedule_to_start`, or `:heartbeat`.
  """

  defexception [:message, :timeout_type, :details]

  @type timeout_type :: :start_to_close | :schedule_to_close | :schedule_to_start | :heartbeat

  @type t :: %__MODULE__{
          message: String.t(),
          timeout_type: timeout_type() | nil,
          details: term() | nil
        }

  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      message: Keyword.get(opts, :message, "timed out"),
      timeout_type: Keyword.get(opts, :timeout_type),
      details: Keyword.get(opts, :details)
    }
  end
end

defmodule Temporalex.ActivityFailure do
  @moduledoc """
  Failure raised in workflow code when an activity attempt ends in failure.

  Wraps the underlying `cause` (typically a `Temporalex.ApplicationError`,
  `Temporalex.CancelledError`, or `Temporalex.TimeoutError`) alongside the
  activity identity. Workflow code typically pattern-matches on `cause`.
  """

  defexception [
    :message,
    :activity_id,
    :activity_type,
    :attempt,
    :retry_state,
    :cause
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          activity_id: String.t() | nil,
          activity_type: String.t() | nil,
          attempt: non_neg_integer() | nil,
          retry_state: atom() | nil,
          cause: Exception.t() | nil
        }
end

defmodule Temporalex.ChildWorkflowFailure do
  @moduledoc """
  Failure raised in parent workflow code when a child workflow ends in failure.

  Wraps the underlying `cause` from the child alongside the child's identity.
  """

  defexception [
    :message,
    :workflow_id,
    :workflow_type,
    :run_id,
    :namespace,
    :retry_state,
    :cause
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          workflow_id: String.t() | nil,
          workflow_type: String.t() | nil,
          run_id: String.t() | nil,
          namespace: String.t() | nil,
          retry_state: atom() | nil,
          cause: Exception.t() | nil
        }
end

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
