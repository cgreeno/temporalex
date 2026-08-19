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

  defguardp typed(error, type)
            when is_map(error) and is_map_key(error, :type) and
                   :erlang.map_get(:type, error) == type

  defguardp caused(error)
            when is_map(error) and is_map_key(error, :cause) and
                   is_map(:erlang.map_get(:cause, error))

  @doc """
  True when `error` is a failure of `type`, at any of the depths
  Temporal nests failures at.

  A guard, so it works in `case`, `with`, and function heads:

      import Temporalex.Failure, only: [is_failure: 2]

      case Payments.charge(amount) do
        {:ok, charge}                                    -> ship(charge)
        {:error, e} when is_failure(e, "AmountTooLarge") -> refund(e)
        {:error, e}                                      -> escalate(e)
      end

  Both depths are checked because failures arrive in two shapes: a remote
  activity's failure is wrapped in a `Temporalex.Failure.ActivityError` whose
  `cause` carries the `type`, while a local activity's arrives as the
  business error itself. `e` stays whole either way, so the wrapper's
  diagnostics (`retry_state`, `activity_type`) remain reachable.

  Shapes with no type to compare — a `nil` cause, an unstructured `raise`
  whose cause is a bare exception, a non-map reason — simply do not match,
  rather than raising.

  A guard cannot recurse, so this checks **three levels**: the error, its
  cause, and its cause's cause. That covers the shapes Temporal produces —
  a remote activity failure (`ActivityError` → `ApplicationError`) and a
  child workflow wrapping one (`WorkflowExecutionError` → `ActivityError` →
  `ApplicationError`). For arbitrary depth — nested child workflows — use
  `failure?/2`, which walks the whole chain but is a function rather than a
  guard.
  """
  defguard is_failure(error, type)
           when typed(error, type) or
                  (caused(error) and typed(:erlang.map_get(:cause, error), type)) or
                  (caused(error) and caused(:erlang.map_get(:cause, error)) and
                     typed(:erlang.map_get(:cause, :erlang.map_get(:cause, error)), type))

  @doc """
  Every Temporal failure type in the error's cause chain, outermost first.

  Temporal nests failures: a failed remote activity arrives as an
  `ActivityError` wrapping the business `ApplicationError`, and a child
  workflow wraps that again. This flattens the chain to the types it
  carries, so callers do not walk it by hand.
  """
  def types(error), do: error |> chain() |> Enum.flat_map(&List.wrap(own_type(&1)))

  @doc """
  Whether `type` appears anywhere in the error's cause chain.

  The unbounded companion to `is_failure/2`: a function rather than a guard,
  so it works at any nesting depth but not in a `when` clause.
  """
  def failure?(error, type), do: type in types(error)

  @doc """
  The failure's Temporal type string — the outermost one in the chain — or
  `nil`.

  For the places patterns do not reach — logging, telemetry, error
  reporting — so call sites stop hand-writing `error.cause.type`.
  """
  def type(error), do: error |> types() |> List.first()

  @doc "The wrapped cause, one level down, or `nil`."
  def cause(%{cause: cause}), do: cause
  def cause(_error), do: nil

  @doc """
  How a failed activity ended — `:non_retryable_failure`,
  `:maximum_attempts_reached`, … — or `nil` when nothing in the chain
  carries one. Found at whatever depth it sits, so a child workflow's
  wrapper does not hide the activity's retry state.
  """
  def retry_state(error), do: first_field(error, :retry_state)

  @doc "Which activity failed, at whatever depth it sits, or `nil`."
  def activity_type(error), do: first_field(error, :activity_type)

  # The cause chain, outermost first. A non-map (or absent) cause ends it,
  # so an unstructured raise or a bare reason terminates cleanly.
  defp chain(error) when is_map(error) do
    case Map.get(error, :cause) do
      nil -> [error]
      cause -> [error | chain(cause)]
    end
  end

  defp chain(_error), do: []

  defp own_type(%{type: type}), do: type
  defp own_type(_error), do: nil

  defp first_field(error, key) do
    error |> chain() |> Enum.find_value(fn link -> Map.get(link, key) end)
  end

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

  @doc """
  Normalize a failure for encoding: wrap scalar `details` (and
  `last_heartbeat_details`) into lists and normalize the `cause` chain.

  The NIF's typed encoder requires payload lists; the constructors in this
  module already guarantee that, but failures built as struct literals
  (`raise %ApplicationError{details: %{...}}`) may carry scalars. Applied
  at the encode boundaries so user code never has to remember.
  """
  def normalize(%_{} = failure) when is_exception(failure) do
    failure
    |> wrap_field(:details)
    |> wrap_field(:last_heartbeat_details)
    |> normalize_cause()
  end

  def normalize(other), do: other

  defp wrap_field(%_{} = failure, key) do
    case Map.fetch(failure, key) do
      {:ok, value} -> Map.put(failure, key, List.wrap(value))
      :error -> failure
    end
  end

  defp normalize_cause(%{cause: %_{} = cause} = failure),
    do: %{failure | cause: normalize(cause)}

  defp normalize_cause(failure), do: failure

  @doc "Raise an application failure."
  @spec application!(term()) :: no_return()
  @spec application!(term(), keyword()) :: no_return()
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
