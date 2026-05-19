defmodule Temporalex.Workflow.API do
  @moduledoc """
  Workflow primitives available from executor-owned workflow processes.
  """

  alias Temporalex.Core.Context
  alias Temporalex.Core.Op
  alias Temporalex.Failure
  alias Temporalex.Failure.CancelledError

  @context_key :__temporal_context__
  @op_reply :temporalex_op_reply

  def execute_activity(type, input, opts \\ []) when is_binary(type) and is_list(input) do
    case call(%Op.ExecuteActivity{type: type, input: input, opts: opts}) do
      {:ok, result} -> result
      {:cancelled, error} -> {:cancelled, error}
      {:error, reason} -> raise_error(reason)
    end
  end

  def execute_activity!(type, input, opts \\ []) when is_binary(type) and is_list(input) do
    case execute_activity(type, input, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise_error(reason)
      {:cancelled, error} -> raise cancellation_error(error)
      other -> raise "Temporalex activity returned invalid result: #{inspect(other)}"
    end
  end

  def sleep(duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    case call(%Op.Sleep{duration_ms: duration_ms}) do
      {:ok, :ok} -> :ok
      {:cancelled, error} -> {:cancelled, error}
      {:error, reason} -> raise_error(reason)
    end
  end

  def sleep!(duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    call!(%Op.Sleep{duration_ms: duration_ms})
  end

  def wait_for_signal(name) when is_binary(name) do
    case call(%Op.WaitForSignal{name: name}) do
      {:ok, args} -> {:ok, args}
      {:cancelled, error} -> {:cancelled, error}
      {:error, reason} -> raise_error(reason)
    end
  end

  def wait_for_signal!(name) when is_binary(name) do
    call!(%Op.WaitForSignal{name: name})
  end

  @spec continue_as_new!(term(), keyword()) :: no_return()
  def continue_as_new!(input, opts \\ []) when is_list(opts) do
    case call(%Op.ContinueAsNew{input: input, opts: opts}) do
      {:ok, value} ->
        raise "Temporalex continue_as_new!/2 returned unexpectedly: #{inspect(value)}"

      {:cancelled, error} ->
        raise cancellation_error(error)

      {:error, reason} ->
        raise_error(reason)
    end
  end

  def publish_state(state) do
    call!(%Op.PublishState{state: state})
  end

  def workflow_info do
    call!(%Op.WorkflowInfo{})
  end

  def cancelled? do
    call!(%Op.Cancelled{})
  end

  def cancellation do
    call!(%Op.Cancellation{})
  end

  def non_cancellable(fun) when is_function(fun, 0) do
    :ok = call!(%Op.EnterNonCancellable{})

    try do
      fun.()
    after
      :ok = call!(%Op.ExitNonCancellable{})
    end
  end

  def now do
    call!(%Op.Now{})
  end

  def random do
    call!(%Op.Random{})
  end

  def uuid4 do
    call!(%Op.UUID4{})
  end

  def patched?(patch_id) when is_binary(patch_id) do
    call!(%Op.Patched{id: patch_id})
  end

  def deprecate_patch(patch_id) when is_binary(patch_id) do
    call!(%Op.DeprecatePatch{id: patch_id})
  end

  def upsert_search_attributes(attrs) when is_map(attrs) do
    call!(%Op.UpsertSearchAttributes{attrs: Temporalex.SearchAttribute.validate_map!(attrs)})
  end

  def parallel(funs) when is_list(funs) do
    case call(%Op.Parallel{funs: funs}) do
      {:ok, results} -> {:ok, results}
      {:cancelled, error} -> {:cancelled, error}
      {:error, reason} -> raise_error(reason)
    end
  end

  def parallel!(funs) when is_list(funs) do
    call!(%Op.Parallel{funs: funs})
  end

  def phase(initial_state, opts) when is_list(opts) do
    case call(%Op.Phase{initial_state: initial_state, opts: opts}) do
      {:ok, {:timeout, state}} -> {:timeout, state}
      {:ok, state} -> {:ok, state}
      {:cancelled, error} -> {:cancelled, error}
      {:error, reason} -> raise_error(reason)
    end
  end

  def phase!(initial_state, opts) when is_list(opts) do
    call!(%Op.Phase{initial_state: initial_state, opts: opts})
  end

  def update_state(fun) when is_function(fun, 1) do
    case call(%Op.UpdateState{fun: fun}) do
      {:ok, result} ->
        result

      {:error, %{__exception__: true} = error} ->
        raise error

      {:error, reason} ->
        raise "Temporalex.Workflow.API.update_state/1 failed: #{inspect(reason)}"

      {:cancelled, error} ->
        raise cancellation_error(error)
    end
  end

  def context! do
    case Process.get(@context_key) do
      %Context{} = context ->
        context

      nil ->
        raise """
        Temporalex workflow API called outside workflow execution.

        Workflow primitives and activity dispatch functions may only be called from an executor-owned workflow process.
        """

      other ->
        raise "invalid Temporalex workflow context: #{inspect(other)}"
    end
  end

  def install_context(%Context{} = context) do
    Process.put(@context_key, context)
  end

  def context_key, do: @context_key

  defp call(op) do
    %Context{executor: executor, thread_id: thread_id} = context!()

    case GenServer.call(executor, {:workflow_op, thread_id, op}, :infinity) do
      {@op_reply, :ok, value} ->
        {:ok, value}

      {@op_reply, :cancelled, error} ->
        {:cancelled, cancellation_error(error)}

      {@op_reply, :error, reason} ->
        {:error, reason}

      other ->
        raise "invalid Temporalex executor reply: #{inspect(other)}"
    end
  end

  defp call!(op) do
    case call(op) do
      {:ok, value} -> value
      {:cancelled, error} -> raise cancellation_error(error)
      {:error, reason} -> raise_error(reason)
    end
  end

  defp cancellation_error(%CancelledError{} = error), do: error

  defp cancellation_error(reason) when is_binary(reason) do
    Failure.cancelled(reason)
  end

  defp cancellation_error(reason) do
    Failure.cancelled("cancelled", details: List.wrap(reason))
  end

  defp raise_error(%{__exception__: true} = error), do: raise(error)

  defp raise_error(reason) do
    raise "Temporalex workflow operation failed: #{inspect(reason)}"
  end
end
