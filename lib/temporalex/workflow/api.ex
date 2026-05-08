defmodule Temporalex.Workflow.API do
  @moduledoc """
  Workflow primitives available from executor-owned workflow processes.
  """

  alias Temporalex.Core.Context
  alias Temporalex.Core.Op
  alias Temporalex.Failure
  alias Temporalex.Failure.CancelledError

  @context_key :__temporal_context__
  @raise_reply :__temporalex_raise__

  def execute_activity(type, input, opts \\ []) when is_binary(type) and is_list(input) do
    case call(%Op.ExecuteActivity{type: type, input: input, opts: opts}) do
      {:cancelled, reason} -> raise cancellation_error(reason)
      result -> result
    end
  end

  @doc """
  Schedule a local activity — runs in-process on this worker rather than via
  the Temporal task queue, with durability provided by a history marker.

  Faster than regular activities for short, deterministic work that doesn't
  need cross-worker scheduling. The activity body still runs in the activity
  task supervisor; Temporal Core records a marker so replay is correct.
  """
  def execute_local_activity(type, input, opts \\ []) when is_binary(type) and is_list(input) do
    call(%Op.ExecuteLocalActivity{type: type, input: input, opts: opts})
  end

  @doc """
  Start a child workflow and block until it completes.

  `workflow` may be a module that uses `Temporalex.Workflow` (its
  `__workflow_type__/0` is consulted) or a workflow type string.

  Options:
  - `:workflow_id` (required) — child workflow identifier
  - `:task_queue` — defaults to the parent's task queue
  - `:execution_timeout_ms`, `:run_timeout_ms`, `:task_timeout_ms`
  - `:retry_policy` — keyword list, same shape as activity retry policies
  - `:parent_close_policy` — `:terminate` (default), `:abandon`, `:request_cancel`
  - `:workflow_id_reuse_policy` — `:allow_duplicate` (default), `:allow_duplicate_failed_only`, `:reject_duplicate`, `:terminate_if_running`

  Returns `{:ok, result}` on completion, `{:error, %Temporalex.ChildWorkflowFailure{...}}` on
  child failure or start failure, `{:cancelled, ...}` on cancellation.
  """
  def execute_child_workflow(workflow, input, opts \\ []) when is_list(input) do
    type =
      cond do
        is_binary(workflow) ->
          workflow

        is_atom(workflow) and function_exported?(workflow, :__workflow_type__, 0) ->
          workflow.__workflow_type__()

        is_atom(workflow) ->
          inspect(workflow)
      end

    call(%Op.ExecuteChildWorkflow{workflow_type: type, input: input, opts: opts})
  end

  @doc """
  Start a child workflow and return a handle as soon as the child is
  started by Temporal (does NOT block until completion).

  Use the returned `Temporalex.ChildHandle` to signal, cancel, or
  `await_child_workflow/1` for the eventual result.

  Returns `{:ok, %Temporalex.ChildHandle{}}` on successful start, or
  `{:error, %Temporalex.ChildWorkflowFailure{}}` if the start fails.
  """
  def start_child_workflow(workflow, input, opts \\ []) when is_list(input) do
    type =
      cond do
        is_binary(workflow) ->
          workflow

        is_atom(workflow) and function_exported?(workflow, :__workflow_type__, 0) ->
          workflow.__workflow_type__()

        is_atom(workflow) ->
          inspect(workflow)
      end

    call(%Op.StartChildWorkflow{workflow_type: type, input: input, opts: opts})
  end

  @doc """
  Block until a child workflow (started via `start_child_workflow/3`)
  completes. Returns its result tuple — `{:ok, value}`, `{:error, _}`,
  or `{:cancelled, _}`.

  If the child has already completed, returns the cached result
  immediately. Otherwise blocks the calling thread until the child
  reaches a terminal state.
  """
  def await_child_workflow(%Temporalex.ChildHandle{seq: seq}) do
    call(%Op.AwaitChildWorkflow{seq: seq})
  end

  @doc """
  Request cancellation of a child workflow started by this workflow.

  Accepts either a `Temporalex.ChildHandle` or a raw workflow id string.

  Cancellation is durable and the call blocks until Temporal confirms
  the cancel request has been delivered. The child receives the cancel
  via its `API.cancelled?/0` flag — it's the child's responsibility to
  observe and act on it.
  """
  def cancel_child_workflow(handle_or_id, opts \\ [])

  def cancel_child_workflow(%Temporalex.ChildHandle{workflow_id: id}, opts) do
    cancel_child_workflow(id, opts)
  end

  def cancel_child_workflow(workflow_id, opts) when is_binary(workflow_id) do
    call(%Op.CancelChildWorkflow{workflow_id: workflow_id, opts: opts})
  end

  @doc """
  Send a signal to a child workflow that was started by this workflow.

  `workflow_id` must match the `workflow_id` you used in
  `execute_child_workflow/3`. The signal is sent durably — the call
  blocks until Temporal confirms delivery (or fails).

  Returns `:ok` on successful delivery, `{:error, %Temporalex.ApplicationError{}}`
  if the target workflow doesn't exist or the signal can't be delivered.

  This is a "fire and confirm delivery" primitive: the signal handler in
  the child runs asynchronously to the parent; success only means Temporal
  has accepted the signal for delivery.
  """
  def signal_child_workflow(handle_or_id, signal_name, args \\ [], opts \\ [])

  def signal_child_workflow(%Temporalex.ChildHandle{workflow_id: id}, signal_name, args, opts) do
    signal_child_workflow(id, signal_name, args, opts)
  end

  def signal_child_workflow(workflow_id, signal_name, args, opts)
      when is_binary(workflow_id) and is_binary(signal_name) and is_list(args) do
    call(%Op.SignalChildWorkflow{
      workflow_id: workflow_id,
      signal_name: signal_name,
      args: args,
      opts: opts
    })
  end

  def sleep(duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    call(%Op.Sleep{duration_ms: duration_ms})
  end

  def wait_for_signal(name) when is_binary(name) do
    call(%Op.WaitForSignal{name: name})
  end

  def publish_state(state) do
    call(%Op.PublishState{state: state})
  end

  def workflow_info do
    call(%Op.WorkflowInfo{})
  end

  def cancelled? do
    call(%Op.Cancelled{})
  end

  def cancellation do
    call(%Op.Cancellation{})
  end

  def non_cancellable(fun) when is_function(fun, 0) do
    :ok = call(%Op.EnterNonCancellable{})

    try do
      fun.()
    after
      :ok = call(%Op.ExitNonCancellable{})
    end
  end

  def now do
    call(%Op.Now{})
  end

  def random do
    call(%Op.Random{})
  end

  def uuid4 do
    call(%Op.UUID4{})
  end

  def patched?(patch_id) when is_binary(patch_id) do
    call(%Op.Patched{id: patch_id})
  end

  def deprecate_patch(patch_id) when is_binary(patch_id) do
    call(%Op.DeprecatePatch{id: patch_id})
  end

  def upsert_search_attributes(attrs) when is_map(attrs) do
    call(%Op.UpsertSearchAttributes{attrs: Temporalex.SearchAttribute.validate_map!(attrs)})
  end

  def parallel(funs) when is_list(funs) do
    call(%Op.Parallel{funs: funs})
  end

  def phase(initial_state, opts) when is_list(opts) do
    call(%Op.Phase{initial_state: initial_state, opts: opts})
  end

  def update_state(fun) when is_function(fun, 1) do
    case call(%Op.UpdateState{fun: fun}) do
      {:error, %{__exception__: true} = error} ->
        raise error

      {:error, reason} ->
        raise "Temporalex.Workflow.API.update_state/1 failed: #{inspect(reason)}"

      result ->
        result
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
      {@raise_reply, %{__exception__: true} = error} -> raise error
      result -> result
    end
  end

  defp cancellation_error(%CancelledError{} = error), do: error

  defp cancellation_error(reason) when is_binary(reason) do
    Failure.cancelled(reason)
  end

  defp cancellation_error(reason) do
    Failure.cancelled("cancelled", details: List.wrap(reason))
  end
end
