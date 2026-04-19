defmodule Temporalex.FailureConverter do
  @moduledoc """
  Converts between Temporal Failure protos and Elixir error structs.

  Handles encoding Elixir exceptions into Temporal failures (for sending
  to the server) and decoding Temporal failures back into Elixir error structs.
  """
  require Logger

  alias Temporal.Api.Failure.V1.Failure

  alias Temporalex.Error.{
    ActivityFailure,
    ApplicationError,
    CancelledError,
    ChildWorkflowFailure,
    TimeoutError
  }

  @typedoc false
  @type failure :: Failure.t()

  @doc "Convert an Elixir exception or error term into a Temporal Failure proto."
  @spec to_failure(term()) :: failure()
  def to_failure(%ActivityFailure{} = e) do
    %Failure{
      message: Exception.message(e),
      failure_info:
        {:application_failure_info,
         %Temporal.Api.Failure.V1.ApplicationFailureInfo{
           type: "ActivityFailure"
         }}
    }
  end

  def to_failure(%TimeoutError{} = e) do
    %Failure{
      message: Exception.message(e),
      failure_info:
        {:timeout_failure_info,
         %Temporal.Api.Failure.V1.TimeoutFailureInfo{
           timeout_type: timeout_type_to_proto(e.timeout_type)
         }}
    }
  end

  def to_failure(%CancelledError{} = e) do
    %Failure{
      message: Exception.message(e),
      failure_info: {:canceled_failure_info, %Temporal.Api.Failure.V1.CanceledFailureInfo{}}
    }
  end

  def to_failure(%ApplicationError{} = e) do
    %Failure{
      message: Exception.message(e),
      failure_info:
        {:application_failure_info,
         %Temporal.Api.Failure.V1.ApplicationFailureInfo{
           type: e.type || "",
           non_retryable: e.non_retryable || false
         }}
    }
  end

  def to_failure(%ChildWorkflowFailure{} = e) do
    %Failure{
      message: Exception.message(e),
      cause: if(e.cause, do: to_failure(e.cause), else: nil),
      failure_info:
        {:child_workflow_execution_failure_info,
         %Temporal.Api.Failure.V1.ChildWorkflowExecutionFailureInfo{
           workflow_type: %Temporal.Api.Common.V1.WorkflowType{name: e.workflow_type || ""},
           workflow_execution: %Temporal.Api.Common.V1.WorkflowExecution{
             workflow_id: e.workflow_id || ""
           }
         }}
    }
  end

  def to_failure(%{__exception__: true} = e) do
    %Failure{message: Exception.message(e)}
  end

  def to_failure(reason) when is_binary(reason) do
    %Failure{message: reason}
  end

  def to_failure(reason) do
    %Failure{message: inspect(reason)}
  end

  @doc "Convert a Temporal Failure proto into an Elixir error struct."
  @spec from_failure(failure()) :: Exception.t()
  def from_failure(%Failure{failure_info: {:timeout_failure_info, info}} = f) do
    %TimeoutError{
      message: f.message || "timeout",
      timeout_type: proto_to_timeout_type(info.timeout_type)
    }
  end

  def from_failure(%Failure{failure_info: {:canceled_failure_info, _}} = f) do
    %CancelledError{
      message: f.message || "cancelled",
      details: nil
    }
  end

  def from_failure(%Failure{failure_info: {:application_failure_info, info}} = f) do
    %ApplicationError{
      message: f.message || "application error",
      type: if(info.type == "", do: nil, else: info.type),
      non_retryable: info.non_retryable || false,
      details: nil
    }
  end

  def from_failure(%Failure{failure_info: {:activity_failure_info, info}} = f) do
    %ActivityFailure{
      message: f.message || "activity failed",
      activity_type: info.activity_type && info.activity_type.name,
      activity_id: info.activity_id,
      cause: if(f.cause, do: from_failure(f.cause), else: nil)
    }
  end

  def from_failure(%Failure{failure_info: {:child_workflow_execution_failure_info, info}} = f) do
    %ChildWorkflowFailure{
      message: f.message || "child workflow failed",
      workflow_type: info.workflow_type && info.workflow_type.name,
      workflow_id: info.workflow_execution && info.workflow_execution.workflow_id,
      cause: if(f.cause, do: from_failure(f.cause), else: nil)
    }
  end

  def from_failure(%Failure{} = f) do
    %ApplicationError{
      message: f.message || "unknown failure",
      type: nil,
      non_retryable: false,
      details: nil
    }
  end

  # Timeout type conversions
  defp timeout_type_to_proto(:start_to_close), do: :TIMEOUT_TYPE_START_TO_CLOSE
  defp timeout_type_to_proto(:schedule_to_start), do: :TIMEOUT_TYPE_SCHEDULE_TO_START
  defp timeout_type_to_proto(:schedule_to_close), do: :TIMEOUT_TYPE_SCHEDULE_TO_CLOSE
  defp timeout_type_to_proto(:heartbeat), do: :TIMEOUT_TYPE_HEARTBEAT
  defp timeout_type_to_proto(_), do: :TIMEOUT_TYPE_UNSPECIFIED

  defp proto_to_timeout_type(:TIMEOUT_TYPE_START_TO_CLOSE), do: :start_to_close
  defp proto_to_timeout_type(:TIMEOUT_TYPE_SCHEDULE_TO_START), do: :schedule_to_start
  defp proto_to_timeout_type(:TIMEOUT_TYPE_SCHEDULE_TO_CLOSE), do: :schedule_to_close
  defp proto_to_timeout_type(:TIMEOUT_TYPE_HEARTBEAT), do: :heartbeat
  defp proto_to_timeout_type(_), do: :unspecified
end
