defmodule Temporalex.Testing do
  @moduledoc """
  Test executor for Temporalex workflows.

  Implements the same `GenServer.call` protocol as the production executor,
  but operates in step-by-step mode. Workflow code can't tell the difference.

  ## Usage

      test "checkout charges then sends receipt" do
        {:ok, exec} = Temporalex.Testing.start_workflow(MyWorkflow, %{"id" => "123"})

        assert {:activity, call} = Temporalex.Testing.next(exec)
        assert call.type == "MyApp.Activities.Payment.charge"

        assert {:activity, call} = Temporalex.Testing.resolve(exec, {:ok, "charge_123"})
        assert call.type == "MyApp.Activities.Email.send_receipt"

        assert {:ok, result} = Temporalex.Testing.resolve(exec, {:ok, :sent})
        assert result == %{charge_id: "charge_123"}
      end
  """

  alias Temporalex.Testing.Executor

  @doc """
  Start a workflow in test mode. Returns `{:ok, executor_pid}`.

  Options:
    * `:is_replaying` — when true, `patched?/1` returns false for patches
      that haven't been marked as seen (via `:seen_patches` or
      `mark_patch_seen/2`). Models a Temporal replay activation.
    * `:seen_patches` — a list of patch ids to pre-populate as "seen",
      mirroring `notify_has_patch` jobs from an activation's history.
  """
  def start_workflow(module, args \\ %{}, opts \\ []) do
    GenServer.start_link(Executor, {module, args, opts})
    |> case do
      {:ok, pid} -> {:ok, pid}
      error -> error
    end
  end

  @doc """
  Returns what the workflow is currently blocked on.

  Possible returns:
  - `{:activity, %{type, input, opts}}` — waiting for an activity result
  - `{:sleep, duration_ms}` — waiting for a timer
  - `{:signal, name}` — waiting for a signal (via `wait_for_signal`)
  - `{:side_effect, fun}` — waiting for side effect resolution
  - `{:receive, %{signals: [...], updates: [...], timeout: ...}}` — in a receive loop
  - `{:ok, result}` — workflow completed successfully
  - `{:error, reason}` — workflow failed
  - `{:continue_as_new, args}` — workflow wants to restart
  """
  def next(exec), do: GenServer.call(exec, :next, 5000)

  @doc """
  Provide a result for the current blocking call and advance to the next one.
  Returns the same values as `next/1`.
  """
  def resolve(exec, result), do: GenServer.call(exec, {:resolve, result}, 5000)

  @doc "Send a signal into the workflow. Works both inside and outside `receive`."
  def send_signal(exec, name, payload \\ nil),
    do: GenServer.call(exec, {:send_signal, name, payload}, 5000)

  @doc """
  Send an update into the workflow. Only works inside `receive` with a matching handler.

  Returns the handler's reply value, or `{:error, reason}` if validation fails.
  """
  def send_update(exec, name, args \\ []),
    do: GenServer.call(exec, {:send_update, name, args}, 5000)

  @doc "Query the workflow's published state."
  def query(exec, name, args \\ nil), do: GenServer.call(exec, {:query, name, args}, 5000)

  @doc "Set the workflow's cancelled flag."
  def cancel(exec), do: GenServer.call(exec, :cancel, 5000)

  @doc """
  Flip the executor into replay mode. Subsequent `patched?` calls that
  haven't seen the patch id (via `mark_patch_seen/2`) will return false.
  """
  def set_replaying(exec), do: GenServer.call(exec, :set_replaying, 5000)

  @doc """
  Mark a patch id as "seen in history" — mirrors what a notify_has_patch
  job would do during replay. After this, `patched?(id)` returns true.
  """
  def mark_patch_seen(exec, patch_id),
    do: GenServer.call(exec, {:mark_patch_seen, patch_id}, 5000)

  @doc """
  Run a workflow with a pre-loaded operation log. Convenience wrapper
  that feeds results automatically and returns the final workflow result.

  ## Example

      {:ok, result} = Temporalex.Testing.run_workflow(MyWorkflow, %{"id" => "123"},
        log: [
          {:activity, "MyApp.Activities.Payment.charge", {:ok, "charge_123"}},
          {:activity, "MyApp.Activities.Email.send_receipt", {:ok, :sent}}
        ]
      )
  """
  def run_workflow(module, args, opts \\ []) do
    log = Keyword.get(opts, :log, [])
    {:ok, exec} = start_workflow(module, args)
    run_with_log(exec, log)
  end

  defp run_with_log(exec, []) do
    next(exec)
  end

  defp run_with_log(exec, [{:activity, expected_type, result} | rest]) do
    case next(exec) do
      {:activity, %{type: type}} ->
        if expected_type != :any and type != expected_type do
          {:error, {:unexpected_activity, expected: expected_type, got: type}}
        else
          resolve(exec, result)
          run_with_log(exec, rest)
        end

      {:ok, _} = done ->
        done

      {:error, _} = err ->
        err

      other ->
        {:error, {:expected_activity, got: other}}
    end
  end

  defp run_with_log(exec, [{:child_workflow, expected_type, result} | rest]) do
    case next(exec) do
      {:child_workflow, %{workflow_type: type}} ->
        if expected_type != :any and type != expected_type do
          {:error, {:unexpected_child_workflow, expected: expected_type, got: type}}
        else
          resolve(exec, result)
          run_with_log(exec, rest)
        end

      other ->
        {:error, {:expected_child_workflow, got: other}}
    end
  end

  defp run_with_log(exec, [{:sleep, result} | rest]) do
    case next(exec) do
      {:sleep, _} ->
        resolve(exec, result)
        run_with_log(exec, rest)

      other ->
        {:error, {:expected_sleep, got: other}}
    end
  end

  @doc """
  Run an activity function directly for testing.

  ## Example

      {:ok, result} = Temporalex.Testing.run_activity(MyActivities, :charge, [100])
  """
  def run_activity(module, function, args \\ []) do
    impl_fn = :"__#{function}__"
    apply(module, impl_fn, args)
  end
end
