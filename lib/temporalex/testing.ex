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

  @doc "Start a workflow in test mode. Returns `{:ok, executor_pid}`."
  def start_workflow(module, args \\ %{}) do
    GenServer.start_link(Executor, {module, args})
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
end
