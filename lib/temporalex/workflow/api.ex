defmodule Temporalex.Workflow.API do
  @moduledoc """
  Functions available to workflow code. All calls delegate to the executor
  via `Process.get(:__temporal_executor__)`.

  ## Sequential primitives (available anywhere)

  - `execute_activity/3` — schedule an activity, block until result
  - `sleep/1` — durable timer
  - `wait_for_signal/1` — block until a named signal arrives
  - `side_effect/1` — run once, replay from history
  - `publish_state/1` — set query-visible state
  - `patched?/1` / `deprecate_patch/1` — workflow versioning
  - `cancelled?/0` — check cancellation flag

  ## Structured concurrency hosts

  - `receive/2` — message loop with signal/update handlers
  - `parallel/1` — concurrent fan-out

  ## Async-only (inside `{:async, fn, state}` handlers)

  - `update_state/1` — atomic read-modify-write of receive state
  """

  defp executor do
    Process.get(:__temporal_executor__) ||
      raise "Temporalex.Workflow.API called outside of a workflow process"
  end

  # --- Sequential primitives ---

  @doc "Execute an activity. Blocks until the activity completes or fails."
  def execute_activity(type, input, opts \\ []) do
    GenServer.call(executor(), {:execute_activity, type, input, opts}, :infinity)
  end

  @doc """
  Execute a *local* activity. Blocks until completion.

  Local activities are short, in-process operations that the worker
  runs directly without round-tripping through the Temporal task queue.
  Use them for cheap deterministic-with-side-effects work (id
  generation, current time, small lookups). Their result is recorded
  in workflow history, so they survive worker crashes — unlike
  `side_effect/1` — making them the safe replacement for non-durable
  inline functions.

  Options:
  - `:start_to_close_timeout_ms` (default 30_000)
  """
  def execute_local_activity(type, input, opts \\ []) do
    GenServer.call(executor(), {:execute_local_activity, type, input, opts}, :infinity)
  end

  @doc "Durable timer. Blocks for `duration_ms` milliseconds."
  def sleep(duration_ms) do
    GenServer.call(executor(), {:sleep, duration_ms}, :infinity)
  end

  @doc "Block until a signal with `name` arrives. Consumes one from the buffer."
  def wait_for_signal(name) do
    GenServer.call(executor(), {:wait_for_signal, name}, :infinity)
  end

  @doc """
  Execute `fun` once and return its value.

  **Deprecated for non-deterministic work.** Use `execute_local_activity/3`
  (or `defactivity ..., local: true`) instead — local activities are
  recorded in workflow history and survive worker crashes/cache evictions.

  `side_effect/1` is **not durable across cache evictions**: if the
  workflow is evicted and later re-activated on a different worker,
  `fun` runs again with a new value. Safe only for values whose
  re-computation is acceptable (e.g. monitoring or logging
  instrumentation).
  """
  def side_effect(fun) do
    GenServer.call(executor(), {:side_effect, fun}, :infinity)
  end

  @doc "Publish a state snapshot visible to query handlers. Replaces previous state."
  def publish_state(state) do
    GenServer.call(executor(), {:publish_state, state}, :infinity)
  end

  @doc "Workflow versioning. Returns true on new executions, replays from history."
  def patched?(patch_id) do
    GenServer.call(executor(), {:patched?, patch_id}, :infinity)
  end

  @doc "Mark a patch as deprecated after all pre-patch executions complete."
  def deprecate_patch(patch_id) do
    GenServer.call(executor(), {:deprecate_patch, patch_id}, :infinity)
  end

  @doc "Check if the workflow has been cancelled."
  def cancelled? do
    GenServer.call(executor(), :cancelled?, :infinity)
  end

  # --- Structured concurrency hosts ---

  @doc """
  Enter a message-processing loop. Blocks the caller.

  ## Options

  - `:signal` — map of signal name to handler function
  - `:update` — map of update name to handler (or `{handler, validator: fn}`)
  - `:timeout` — milliseconds before auto-exit with `{:timeout, state}`

  ## Handler return values

  Signal handlers: `{:noreply, state}`, `{:stop, state}`, `{:async, fn, state}`
  Update handlers: `{:reply, response, state}`, `{:stop, response, state}`, `{:async, fn, state}`

  The `state` in `{:async, fn, state}` is ignored; use `update_state/1` inside
  the async fn to mutate the receive state safely alongside other async work.
  """
  def receive(initial_state, opts) do
    if Process.get(:__temporal_in_handler__) do
      raise ArgumentError,
            "Temporalex.Workflow.API.receive/2 cannot be called from inside a signal/update handler or parallel branch"
    end

    GenServer.call(executor(), {:receive, initial_state, opts}, :infinity)
  end

  @doc """
  Start a child workflow. Blocks until the child completes or fails.

  Options: `:workflow_id`, `:task_queue`, `:cancellation_type`, `:parent_close_policy`.
  """
  def start_child_workflow(module, args, opts \\ []) do
    workflow_type = module.__temporal_workflow_type__()
    GenServer.call(executor(), {:start_child_workflow, workflow_type, args, opts}, :infinity)
  end

  @doc """
  Execute functions concurrently. Blocks until all complete.
  Returns results in the same order as input functions.
  """
  def parallel(fns) do
    GenServer.call(executor(), {:parallel, fns}, :infinity)
  end

  # --- Async-only ---

  @doc """
  Atomically read-modify-write the enclosing receive block's state.
  Only available inside async handler processes.

  The function receives current state and returns `{return_value, new_state}`.
  """
  def update_state(fun) do
    GenServer.call(executor(), {:update_state, fun}, :infinity)
  end
end
