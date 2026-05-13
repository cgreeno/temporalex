defmodule Temporalex.Backend.Test do
  @moduledoc """
  In-memory backend for server and integration tests.

  It sends decoded core structs directly to the server and stores submitted
  completions for assertions.
  """

  @behaviour Temporalex.Backend

  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.ActivityTask
  alias Temporalex.Core.Activation
  alias Temporalex.Core.Completion

  defmodule State do
    @moduledoc false
    defstruct [:agent, :owner_pid]
  end

  @impl Temporalex.Backend
  def start_worker(opts, _owner_pid) do
    owner_pid = Keyword.get(opts, :test_owner, self())

    Agent.start_link(fn ->
      %{
        workflow_completions: [],
        activity_completions: [],
        errors: [],
        shutdown?: false
      }
    end)
    |> case do
      {:ok, agent} -> {:ok, %State{agent: agent, owner_pid: owner_pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Temporalex.Backend
  def complete_workflow_activation(%State{} = state, %Completion{} = completion) do
    Agent.update(state.agent, fn data ->
      Map.update!(data, :workflow_completions, &(&1 ++ [completion]))
    end)

    send(state.owner_pid, {:temporalex_test_backend, :workflow_completion, completion})
    :ok
  end

  @impl Temporalex.Backend
  def complete_activity_task(%State{} = state, %ActivityCompletion{} = completion) do
    Agent.update(state.agent, fn data ->
      Map.update!(data, :activity_completions, &(&1 ++ [completion]))
    end)

    send(state.owner_pid, {:temporalex_test_backend, :activity_completion, completion})
    :ok
  end

  @impl Temporalex.Backend
  def record_activity_heartbeat(%State{}, _task_token, _details), do: :ok

  @impl Temporalex.Backend
  def shutdown_worker(%State{} = state) do
    if Process.alive?(state.agent) do
      Agent.update(state.agent, &Map.put(&1, :shutdown?, true))
    end

    :ok
  end

  def send_activation(worker, %Activation{} = activation) do
    send(server_pid!(worker), {:workflow_activation, activation})
    :ok
  end

  def send_activity_task(worker, %ActivityTask{} = task) do
    send(server_pid!(worker), {:activity_task, task})
    :ok
  end

  def workflow_completions(worker) do
    worker
    |> state!()
    |> Agent.get(& &1.workflow_completions)
  end

  def activity_completions(worker) do
    worker
    |> state!()
    |> Agent.get(& &1.activity_completions)
  end

  def fetch_workflow_completion(worker, run_id, timeout \\ 1_000) do
    wait_until(timeout, fn ->
      worker
      |> workflow_completions()
      |> Enum.find(&(&1.run_id == run_id))
    end)
  end

  def fetch_activity_completion(worker, task_token, timeout \\ 1_000) do
    wait_until(timeout, fn ->
      worker
      |> activity_completions()
      |> Enum.find(&(&1.task_token == task_token))
    end)
  end

  def clear_completions(worker) do
    worker
    |> state!()
    |> Agent.update(fn data ->
      %{data | workflow_completions: [], activity_completions: []}
    end)
  end

  defp wait_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(10)
          do_wait_until(deadline, fun)
        end

      value ->
        value
    end
  end

  defp state!(worker) do
    server = server_pid!(worker)
    %State{agent: agent} = Temporalex.Server.backend_state(server)
    agent
  end

  defp server_pid!(pid) when is_pid(pid), do: pid

  defp server_pid!(worker_name) when is_atom(worker_name) do
    case Temporalex.Worker.server_pid(worker_name) do
      nil -> raise ArgumentError, "no Temporalex worker server found for #{inspect(worker_name)}"
      pid -> pid
    end
  end
end
