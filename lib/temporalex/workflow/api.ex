defmodule Temporalex.Workflow.API do
  @moduledoc false
  # Functions imported into workflow modules. Each runs inside the
  # workflow's own BEAM process, communicating with the WorkflowTaskExecutor
  # GenServer via process dictionary and GenServer.call.

  @doc """
  Schedule an activity and block until the result is available.

  On replay, if the result is already in the executor's replay_results map,
  returns immediately without issuing a command. On first execution, sends
  the command to the executor and blocks until the result arrives.
  """
  @spec execute_activity(module(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_activity(activity_module, input, opts \\ []) do
    case get_activity_stub(activity_module) do
      {:ok, stub_fn} ->
        record_activity_call(activity_module, input)
        stub_fn.(input)

      :none ->
        opts = merge_activity_defaults(activity_module, opts)
        activity_type = activity_module.__activity_type__()
        executor = get_executor!()
        GenServer.call(executor, {:execute_activity, activity_type, input, opts}, :infinity)
    end
  end

  @doc """
  Schedule a local activity and block until the result is available.

  Local activities run in the worker process, skipping the task queue round-trip.
  Best for short, fast operations (< 1 second). They don't appear in the
  Temporal UI as separate activity executions.

  Same interface as `execute_activity/3` but uses the local activity optimization.

  ## Example

      {:ok, result} = execute_local_activity(MyApp.Activities.QuickLookup, %{id: id})
  """
  @spec execute_local_activity(module(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_local_activity(activity_module, input, opts \\ []) do
    case get_activity_stub(activity_module) do
      {:ok, stub_fn} ->
        record_activity_call(activity_module, input)
        stub_fn.(input)

      :none ->
        opts = merge_activity_defaults(activity_module, opts)
        activity_type = activity_module.__activity_type__()
        executor = get_executor!()
        GenServer.call(executor, {:execute_local_activity, activity_type, input, opts}, :infinity)
    end
  end

  @doc """
  Start a durable timer. Blocks until the timer fires.

  Takes a duration in milliseconds. Works with `:timer` helpers:

      sleep(5_000)                  # 5 seconds
      sleep(:timer.seconds(30))    # 30 seconds
      sleep(:timer.minutes(5))     # 5 minutes
      sleep(:timer.hours(1))       # 1 hour

  Maximum duration is 5 years (~157 billion ms). For longer workflows,
  use `continue_as_new/2` to reset history.
  """
  # ~5 years in milliseconds
  @max_sleep_ms 157_680_000_000

  @spec sleep(pos_integer()) :: :ok
  def sleep(duration_ms)
      when is_integer(duration_ms) and duration_ms > 0 and duration_ms <= @max_sleep_ms do
    executor = get_executor!()
    GenServer.call(executor, {:sleep, duration_ms}, :infinity)
  end

  def sleep(duration_ms) when is_integer(duration_ms) and duration_ms <= 0 do
    raise ArgumentError, "sleep duration must be positive, got: #{duration_ms}"
  end

  def sleep(duration_ms) when is_integer(duration_ms) do
    raise ArgumentError,
          "sleep duration exceeds maximum (#{@max_sleep_ms}ms / ~5 years), got: #{duration_ms}"
  end

  def sleep(other) do
    raise ArgumentError,
          "sleep duration must be a positive integer (milliseconds), got: #{inspect(other)}"
  end

  @doc """
  Transition this workflow to a new execution with fresh state.

  This is used for long-running workflows that accumulate large history.
  The current execution completes and a new one starts with the given args.

  By default, continues as the same workflow type on the same task queue.
  Override with opts.

  ## Options

    * `:workflow_type` — override the workflow type (default: current)
    * `:task_queue` — override the task queue (default: current)
    * `:workflow_run_timeout` — max run time in ms
    * `:retry_policy` — keyword list or `Temporalex.RetryPolicy`

  ## Example

      def run(%{page: page}) do
        {:ok, items} = execute_activity(FetchPage, %{page: page})
        continue_as_new(%{page: page + 1})
      end
  """
  @spec continue_as_new() :: no_return()
  @spec continue_as_new(term()) :: no_return()
  @spec continue_as_new(term(), keyword()) :: no_return()
  def continue_as_new(args \\ [], opts \\ []) do
    info = Process.get(:__temporal_workflow_info__, %{})

    raise %Temporalex.Error.ContinueAsNew{
      workflow_type: Keyword.get(opts, :workflow_type, info[:workflow_type]),
      task_queue: Keyword.get(opts, :task_queue, info[:task_queue]),
      args: List.wrap(args),
      opts: opts
    }
  end

  @doc """
  Start a child workflow and block until it completes.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.

  ## Options

    * `:id` — child workflow ID (required)
    * `:task_queue` — task queue (default: parent's task queue)
    * `:workflow_execution_timeout` — max total time including retries (ms)
    * `:workflow_run_timeout` — max single run time (ms)
    * `:parent_close_policy` — `:terminate`, `:abandon`, or `:request_cancel`
    * `:retry_policy` — keyword list or `Temporalex.RetryPolicy`

  ## Example

      {:ok, result} = execute_child_workflow(
        MyApp.Workflows.ProcessOrder,
        %{order_id: order_id},
        id: "order-\#{order_id}",
        task_queue: "orders"
      )
  """
  @spec execute_child_workflow(module(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_child_workflow(workflow_module, input \\ nil, opts \\ []) do
    case get_child_workflow_stub(workflow_module) do
      {:ok, stub_fn} ->
        record_child_workflow_call(workflow_module, input)
        stub_fn.(input)

      :none ->
        executor = get_executor!()
        workflow_type = workflow_module.__workflow_type__()
        GenServer.call(executor, {:execute_child_workflow, workflow_type, input, opts}, :infinity)
    end
  end

  @doc """
  Upsert search attributes on the current workflow execution.

  ## Example

      upsert_search_attributes(%{"CustomField" => "value", "Priority" => 5})
  """
  @spec upsert_search_attributes(map()) :: :ok
  def upsert_search_attributes(attrs) when is_map(attrs) do
    search_attrs =
      Enum.map(attrs, fn {key, value} ->
        payload = Temporalex.Converter.to_payload(value)
        {to_string(key), payload}
      end)
      |> Map.new()

    command = %Coresdk.WorkflowCommands.WorkflowCommand{
      variant:
        {:upsert_workflow_search_attributes,
         %Coresdk.WorkflowCommands.UpsertWorkflowSearchAttributes{
           search_attributes: search_attrs
         }}
    }

    executor = get_executor!()
    GenServer.call(executor, {:add_command, command})
    :ok
  end

  @doc """
  Check if a patch is active. Used for workflow versioning.

  When you need to change workflow logic that has running executions,
  wrap the new code in a `patched?/1` check. Old executions (replay)
  will take the else branch; new executions will take the if branch.

  Once all old executions have completed, you can remove the patch guard
  and call `deprecate_patch/1` to mark it as no longer needed.

  ## Example

      def run(args) do
        result =
          if patched?("use-new-algorithm") do
            execute_activity(NewAlgorithm, args)
          else
            execute_activity(OldAlgorithm, args)
          end

        {:ok, result}
      end
  """
  @spec patched?(String.t()) :: boolean()
  def patched?(patch_id) when is_binary(patch_id) do
    # Check if this patch was notified in the activation (replay path)
    notified_patches = Process.get(:__temporal_patches__, MapSet.new())

    if MapSet.member?(notified_patches, patch_id) do
      true
    else
      command = %Coresdk.WorkflowCommands.WorkflowCommand{
        variant:
          {:set_patch_marker,
           %Coresdk.WorkflowCommands.SetPatchMarker{
             patch_id: patch_id,
             deprecated: false
           }}
      }

      executor = get_executor!()
      GenServer.call(executor, {:add_command, command})
      true
    end
  end

  @doc """
  Mark a patch as deprecated. Call this after all old executions using
  the patch have completed. Emits a deprecated patch marker.
  """
  @spec deprecate_patch(String.t()) :: :ok
  def deprecate_patch(patch_id) when is_binary(patch_id) do
    command = %Coresdk.WorkflowCommands.WorkflowCommand{
      variant:
        {:set_patch_marker,
         %Coresdk.WorkflowCommands.SetPatchMarker{
           patch_id: patch_id,
           deprecated: true
         }}
    }

    executor = get_executor!()
    GenServer.call(executor, {:add_command, command})
    :ok
  end

  @doc """
  Generate a deterministic random float in [0.0, 1.0).

  Safe to use inside workflows — produces the same value on replay
  because it's derived from the workflow's run_id and command sequence.

  ## Example

      discount = if random() > 0.5, do: 0.1, else: 0.05
  """
  @spec random() :: float()
  def random do
    executor = get_executor!()
    GenServer.call(executor, :random, :infinity)
  end

  @doc """
  Generate a deterministic UUID v4 string.

  Safe to use inside workflows — produces the same UUID on replay.

  ## Example

      idempotency_key = uuid4()
  """
  @spec uuid4() :: String.t()
  def uuid4 do
    executor = get_executor!()
    GenServer.call(executor, :uuid4, :infinity)
  end

  @doc """
  Execute a non-deterministic operation safely within a workflow.

  On first execution the function runs and the result is returned.

  **Limitation:** side effect values are not yet recorded in workflow history,
  so replay cannot return the original value. Calling `side_effect/1` during
  replay will raise. This will be resolved in a future release that persists
  side effect results.
  """
  @spec side_effect((-> term())) :: term()
  def side_effect(fun) when is_function(fun, 0) do
    executor = get_executor!()
    GenServer.call(executor, {:side_effect, fun}, :infinity)
  end

  @doc """
  Block until a signal with the given name is received.

  Returns the signal payload. If the signal has already been buffered
  (e.g. it arrived during a previous activation), returns immediately.

  ## Example

      {:ok, confirmation} = wait_for_signal("confirm_shipment")

  """
  @spec wait_for_signal(String.t()) :: {:ok, term()}
  def wait_for_signal(signal_name) when is_binary(signal_name) do
    # First check if the signal is already buffered in the process dictionary
    case pop_buffered_signal(signal_name) do
      {:ok, _payload} = result ->
        result

      nil ->
        executor = get_executor!()
        wf_state = Process.get(:__temporal_state__)
        GenServer.call(executor, {:yield, wf_state}, :infinity)
        wait_for_signal_receive(signal_name)
    end
  end

  # Block until we receive the target signal, buffering others
  defp wait_for_signal_receive(signal_name) do
    receive do
      {:signal, ^signal_name, payload} ->
        {:ok, payload}

      {:signal, other_name, payload} ->
        buffer_signal(other_name, payload)
        wait_for_signal_receive(signal_name)

      {:notify_has_patch, patch_id} ->
        patches = Process.get(:__temporal_patches__, MapSet.new())
        Process.put(:__temporal_patches__, MapSet.put(patches, patch_id))
        wait_for_signal_receive(signal_name)

      {:cancel_workflow} ->
        Process.put(:__temporal_cancelled__, true)
        wait_for_signal_receive(signal_name)
    end
  end

  # Buffered signal management via process dictionary
  defp pop_buffered_signal(signal_name) do
    buffer = Process.get(:__temporal_signal_buffer__, [])

    case List.keytake(buffer, signal_name, 0) do
      {{^signal_name, payload}, rest} ->
        Process.put(:__temporal_signal_buffer__, rest)
        {:ok, payload}

      nil ->
        nil
    end
  end

  @doc false
  def buffer_signal(signal_name, payload) do
    buffer = Process.get(:__temporal_signal_buffer__, [])
    Process.put(:__temporal_signal_buffer__, buffer ++ [{signal_name, payload}])
  end

  @doc "Set the workflow's user state (stored in process dictionary)."
  @spec set_state(term()) :: :ok
  def set_state(state) do
    Process.put(:__temporal_state__, state)
    :ok
  end

  @doc "Get the workflow's user state."
  @spec get_state() :: term()
  def get_state, do: Process.get(:__temporal_state__)

  @doc """
  Check if this workflow has been cancelled.

  Use this in long-running loops to gracefully handle cancellation:

      def run(args) do
        for item <- items do
          if cancelled?(), do: raise Temporalex.Error.CancelledError, message: "workflow cancelled"
          execute_activity(ProcessItem, item)
        end
        {:ok, "done"}
      end
  """
  @spec cancelled?() :: boolean()
  def cancelled? do
    Process.get(:__temporal_cancelled__, false)
  end

  @doc "Get workflow metadata."
  @spec workflow_info() :: map()
  def workflow_info do
    Process.get(:__temporal_workflow_info__, %{})
  end

  # -- Internal helpers --

  defp get_executor! do
    Process.get(:__temporal_executor__) ||
      raise RuntimeError,
            "Temporal workflow executor not found. " <>
              "This function can only be called from within a workflow execution. " <>
              "If you're in a test, use Temporalex.Testing helpers."
  end

  # Activity stub system for testing — stubs live in process dictionary
  defp get_activity_stub(module) do
    case Process.get(:__temporal_activity_stubs__, %{}) do
      %{^module => fun} -> {:ok, fun}
      _ -> :none
    end
  end

  defp record_activity_call(module, input) do
    calls = Process.get(:__temporal_activity_calls__, [])
    Process.put(:__temporal_activity_calls__, [{module, input} | calls])
  end

  defp merge_activity_defaults(module, opts) do
    if function_exported?(module, :__activity_defaults__, 0) do
      Keyword.merge(module.__activity_defaults__(), opts)
    else
      opts
    end
  end

  # Child workflow stub system — same pattern as activity stubs
  defp get_child_workflow_stub(module) do
    case Process.get(:__temporal_child_workflow_stubs__, %{}) do
      %{^module => fun} -> {:ok, fun}
      _ -> :none
    end
  end

  defp record_child_workflow_call(module, input) do
    calls = Process.get(:__temporal_child_workflow_calls__, [])
    Process.put(:__temporal_child_workflow_calls__, [{module, input} | calls])
  end
end
