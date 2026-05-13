defmodule Temporalex.Workflow.API do
  @moduledoc """
  Workflow primitives available from executor-owned workflow processes.
  """

  alias Temporalex.Core.Context
  alias Temporalex.Core.Op

  @context_key :__temporal_context__

  def execute_activity(type, input, opts \\ []) when is_binary(type) and is_list(input) do
    call(%Op.ExecuteActivity{type: type, input: input, opts: opts})
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
    call(%Op.UpsertSearchAttributes{attrs: attrs})
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
    GenServer.call(executor, {:workflow_op, thread_id, op}, :infinity)
  end
end
