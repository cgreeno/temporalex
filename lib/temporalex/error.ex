defmodule Temporalex.Error do
  @moduledoc """
  Generic Temporalex operation error and helpers for public client results.

  `Temporalex.Failure.*` structs model Temporal failure trees. The structs in
  this file model operation-level failures returned by public client APIs.
  """

  defexception message: "Temporalex operation failed",
               operation: nil,
               category: :unknown,
               cause: nil

  alias Temporalex.Failure.ActivityError
  alias Temporalex.Failure.ApplicationError
  alias Temporalex.Failure.CancelledError
  alias Temporalex.Failure.TimeoutError
  alias Temporalex.Failure.UnknownError
  alias Temporalex.Failure.WorkflowExecutionError

  @public_operation_errors [
    __MODULE__,
    Temporalex.TransportError,
    Temporalex.ClientUnavailableError,
    Temporalex.WorkflowAlreadyStartedError,
    Temporalex.WorkflowNotFoundError,
    Temporalex.WorkflowFailedError,
    Temporalex.WorkflowCancelledError,
    Temporalex.WorkflowTerminatedError,
    Temporalex.WorkflowTimedOutError,
    Temporalex.WorkflowContinuedAsNewError,
    Temporalex.QueryRejectedError,
    Temporalex.UpdateFailedError
  ]

  @doc false
  def normalize_client_reason(reason, opts \\ [])

  def normalize_client_reason(%{__struct__: module} = error, _opts)
      when module in @public_operation_errors,
      do: error

  def normalize_client_reason(%{__struct__: failure} = error, opts)
      when failure in [
             ActivityError,
             ApplicationError,
             CancelledError,
             TimeoutError,
             UnknownError,
             WorkflowExecutionError
           ] do
    failed_error(error, opts)
  end

  def normalize_client_reason({:already_started, run_id}, opts) do
    struct!(Temporalex.WorkflowAlreadyStartedError,
      message: workflow_message("workflow already started", opts),
      operation: operation(opts),
      workflow_id: Keyword.get(opts, :workflow_id),
      workflow_type: Keyword.get(opts, :workflow_type),
      run_id: nil_if_empty(run_id),
      cause: {:already_started, run_id}
    )
  end

  def normalize_client_reason(:not_found, opts) do
    struct!(Temporalex.WorkflowNotFoundError,
      message: workflow_message("workflow not found", opts),
      operation: operation(opts),
      workflow_id: Keyword.get(opts, :workflow_id),
      run_id: Keyword.get(opts, :run_id),
      cause: :not_found
    )
  end

  def normalize_client_reason({:failed, failure}, opts), do: failed_error(failure, opts)

  def normalize_client_reason({:cancelled, %CancelledError{} = cancellation}, opts) do
    cancelled_error(cancellation.details, Keyword.put(opts, :cause, cancellation))
  end

  def normalize_client_reason({:cancelled, details}, opts) do
    cancelled_error(details, Keyword.put(opts, :cause, {:cancelled, details}))
  end

  def normalize_client_reason({:terminated, details}, opts) do
    struct!(Temporalex.WorkflowTerminatedError,
      message: workflow_message("workflow terminated", opts),
      operation: operation(opts),
      workflow_id: Keyword.get(opts, :workflow_id),
      run_id: Keyword.get(opts, :run_id),
      details: normalize_details(details),
      cause: {:terminated, details}
    )
  end

  def normalize_client_reason(:timed_out, opts) do
    struct!(Temporalex.WorkflowTimedOutError,
      message: workflow_message("workflow timed out", opts),
      operation: operation(opts),
      workflow_id: Keyword.get(opts, :workflow_id),
      run_id: Keyword.get(opts, :run_id),
      cause: :timed_out
    )
  end

  def normalize_client_reason(:continued_as_new, opts) do
    struct!(Temporalex.WorkflowContinuedAsNewError,
      message: workflow_message("workflow continued as new", opts),
      operation: operation(opts),
      workflow_id: Keyword.get(opts, :workflow_id),
      run_id: Keyword.get(opts, :run_id),
      cause: :continued_as_new
    )
  end

  def normalize_client_reason({:rejected, status}, opts) do
    struct!(Temporalex.QueryRejectedError,
      message: workflow_message("query rejected", opts),
      operation: operation(opts),
      workflow_id: Keyword.get(opts, :workflow_id),
      run_id: Keyword.get(opts, :run_id),
      query_name: Keyword.get(opts, :query_name),
      status: status,
      cause: {:rejected, status}
    )
  end

  def normalize_client_reason({:client_down, reason}, opts) do
    client_unavailable(:client_down, reason, opts)
  end

  def normalize_client_reason({:client_not_started, name}, opts) do
    client_unavailable(:client_not_started, name, Keyword.put_new(opts, :client, name))
  end

  def normalize_client_reason({:payload_conversion, message}, opts) do
    transport_error(:payload_conversion, message, {:payload_conversion, message}, opts)
  end

  def normalize_client_reason({:invalid_options, message}, opts) do
    transport_error(:invalid_options, message, {:invalid_options, message}, opts)
  end

  def normalize_client_reason({:rpc, message}, opts) do
    transport_error(:rpc, message, {:rpc, message}, opts)
  end

  def normalize_client_reason({:unsupported_backend_operation, backend}, opts) do
    message = "backend #{inspect(backend)} does not support #{operation(opts)}"

    transport_error(
      :unsupported_backend_operation,
      message,
      {:unsupported_backend_operation, backend},
      opts
    )
  end

  def normalize_client_reason({:connect_error, reason}, opts),
    do: transport_error(:connect, reason, {:connect_error, reason}, opts)

  def normalize_client_reason({:connect_timeout, timeout}, opts),
    do: timeout_error(:connect_timeout, timeout, opts)

  def normalize_client_reason({:worker_error, reason}, opts),
    do: transport_error(:worker, reason, {:worker_error, reason}, opts)

  def normalize_client_reason({:worker_start_timeout, timeout}, opts),
    do: timeout_error(:worker_start_timeout, timeout, opts)

  def normalize_client_reason({:shutdown_error, reason}, opts),
    do: transport_error(:shutdown, reason, {:shutdown_error, reason}, opts)

  def normalize_client_reason({:shutdown_timeout, timeout}, opts),
    do: timeout_error(:shutdown_timeout, timeout, opts)

  def normalize_client_reason({tag, :timeout, timeout} = reason, opts)
      when is_atom(tag) and is_integer(timeout) do
    opts = Keyword.put_new(opts, :operation, operation_from_native_tag(tag))
    timeout_error(tag, timeout, Keyword.put(opts, :cause, reason))
  end

  def normalize_client_reason(reason, opts) when is_binary(reason) do
    transport_error(:native, reason, reason, opts)
  end

  def normalize_client_reason(%{__exception__: true} = exception, opts) do
    transport_error(:exception, Exception.message(exception), exception, opts)
  end

  def normalize_client_reason(reason, opts) do
    transport_error(:unknown, inspect(reason), reason, opts)
  end

  defp failed_error(failure, opts) do
    case operation(opts) do
      :update_workflow ->
        struct!(Temporalex.UpdateFailedError,
          message: workflow_message("workflow update failed", opts),
          operation: :update_workflow,
          workflow_id: Keyword.get(opts, :workflow_id),
          run_id: Keyword.get(opts, :run_id),
          update_name: Keyword.get(opts, :update_name),
          cause: failure
        )

      _ ->
        struct!(Temporalex.WorkflowFailedError,
          message: workflow_message("workflow failed", opts),
          operation: operation(opts),
          workflow_id: Keyword.get(opts, :workflow_id),
          run_id: Keyword.get(opts, :run_id),
          workflow_type: Keyword.get(opts, :workflow_type),
          cause: failure
        )
    end
  end

  defp cancelled_error(details, opts) do
    struct!(Temporalex.WorkflowCancelledError,
      message: workflow_message("workflow cancelled", opts),
      operation: operation(opts),
      workflow_id: Keyword.get(opts, :workflow_id),
      run_id: Keyword.get(opts, :run_id),
      details: normalize_details(details),
      cause: Keyword.get(opts, :cause)
    )
  end

  defp client_unavailable(category, reason, opts) do
    struct!(Temporalex.ClientUnavailableError,
      message: "Temporalex client is unavailable",
      operation: operation(opts),
      client: Keyword.get(opts, :client),
      category: category,
      reason: reason,
      cause: {category, reason}
    )
  end

  defp transport_error(category, message, cause, opts) do
    struct!(Temporalex.TransportError,
      message: to_message(message),
      operation: operation(opts),
      category: category,
      cause: cause
    )
  end

  defp timeout_error(category, timeout, opts) do
    transport_error(
      :timeout,
      "#{category} timed out after #{timeout}ms",
      Keyword.get(opts, :cause, {category, timeout}),
      opts
    )
  end

  defp operation(opts), do: Keyword.get(opts, :operation, :client_operation)

  defp workflow_message(prefix, opts) do
    case Keyword.get(opts, :workflow_id) do
      nil -> prefix
      "" -> prefix
      workflow_id -> "#{prefix}: #{workflow_id}"
    end
  end

  defp normalize_details(nil), do: []
  defp normalize_details(details) when is_list(details), do: details
  defp normalize_details(details), do: [details]

  defp nil_if_empty(nil), do: nil
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  defp to_message(message) when is_binary(message), do: message
  defp to_message(message), do: inspect(message)

  defp operation_from_native_tag(:workflow_started), do: :start_workflow
  defp operation_from_native_tag(:workflow_result), do: :get_result
  defp operation_from_native_tag(:workflow_signalled), do: :signal_workflow
  defp operation_from_native_tag(:workflow_queried), do: :query_workflow
  defp operation_from_native_tag(:workflow_updated), do: :update_workflow
  defp operation_from_native_tag(:workflow_cancelled), do: :cancel_workflow
  defp operation_from_native_tag(:workflow_terminated), do: :terminate_workflow
  defp operation_from_native_tag(:workflow_described), do: :describe_workflow
  defp operation_from_native_tag(other), do: other
end

defmodule Temporalex.TransportError do
  @moduledoc """
  Transport, payload conversion, option validation, or backend infrastructure error.
  """

  defexception message: "Temporalex transport error",
               operation: nil,
               category: :transport,
               cause: nil
end

defmodule Temporalex.ClientUnavailableError do
  @moduledoc """
  The client owner process was not available while a client operation was running.
  """

  defexception message: "Temporalex client is unavailable",
               operation: nil,
               client: nil,
               category: :client_down,
               reason: nil,
               cause: nil
end

defmodule Temporalex.WorkflowAlreadyStartedError do
  @moduledoc """
  A workflow start request conflicted with an existing workflow execution.
  """

  defexception message: "workflow already started",
               operation: :start_workflow,
               workflow_id: nil,
               workflow_type: nil,
               run_id: nil,
               cause: nil
end

defmodule Temporalex.WorkflowNotFoundError do
  @moduledoc """
  The requested workflow execution was not found.
  """

  defexception message: "workflow not found",
               operation: nil,
               workflow_id: nil,
               run_id: nil,
               cause: nil
end

defmodule Temporalex.WorkflowFailedError do
  @moduledoc """
  A workflow completed with a Temporal failure.
  """

  defexception message: "workflow failed",
               operation: :get_result,
               workflow_id: nil,
               run_id: nil,
               workflow_type: nil,
               cause: nil
end

defmodule Temporalex.WorkflowCancelledError do
  @moduledoc """
  A workflow completed as cancelled.
  """

  defexception message: "workflow cancelled",
               operation: :get_result,
               workflow_id: nil,
               run_id: nil,
               details: [],
               cause: nil
end

defmodule Temporalex.WorkflowTerminatedError do
  @moduledoc """
  A workflow completed as terminated.
  """

  defexception message: "workflow terminated",
               operation: :get_result,
               workflow_id: nil,
               run_id: nil,
               details: [],
               cause: nil
end

defmodule Temporalex.WorkflowTimedOutError do
  @moduledoc """
  A workflow execution timed out.
  """

  defexception message: "workflow timed out",
               operation: :get_result,
               workflow_id: nil,
               run_id: nil,
               cause: nil
end

defmodule Temporalex.WorkflowContinuedAsNewError do
  @moduledoc """
  A workflow result request observed a continue-as-new terminal state.
  """

  defexception message: "workflow continued as new",
               operation: :get_result,
               workflow_id: nil,
               run_id: nil,
               cause: nil
end

defmodule Temporalex.QueryRejectedError do
  @moduledoc """
  A workflow query was rejected by Temporal because of workflow execution status.
  """

  defexception message: "query rejected",
               operation: :query_workflow,
               workflow_id: nil,
               run_id: nil,
               query_name: nil,
               status: nil,
               cause: nil
end

defmodule Temporalex.UpdateFailedError do
  @moduledoc """
  A workflow update completed or was rejected with a Temporal failure.
  """

  defexception message: "workflow update failed",
               operation: :update_workflow,
               workflow_id: nil,
               run_id: nil,
               update_name: nil,
               cause: nil
end
