defmodule Temporalex.Test.ExecutorHelpers do
  @moduledoc false
  # Helpers for driving the production executor in unit tests without a real
  # Temporal worker NIF resource. Pass `flush_to: self()` to the executor so
  # workflow completions arrive as `{:flushed, run_id, commands}` messages.

  alias Temporalex.Worker.Executor

  @doc """
  Start a production Worker.Executor wired to send completions to the calling
  process. `worker_module` is the Elixir workflow module to dispatch.
  """
  def start_executor(workflow_module, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "run-#{System.unique_integer([:positive])}")
    task_queue = Keyword.get(opts, :task_queue, "test-queue")

    base = %{
      server_pid: self(),
      worker: nil,
      run_id: run_id,
      task_queue: task_queue,
      workflow_module: workflow_module,
      flush_to: self()
    }

    overrides =
      opts
      |> Keyword.take([:max_signal_buffer, :max_pending_handlers])
      |> Map.new()

    Executor.start_link(Map.merge(base, overrides))
  end

  @doc "Pre-built activation for `:initialize_workflow`, optional extra jobs."
  def init_activation(workflow_module, args \\ %{}, extra_jobs \\ []) do
    type = workflow_module |> to_string() |> String.trim_leading("Elixir.")

    %{
      run_id: "ignored",
      is_replaying: false,
      jobs:
        [
          {:initialize_workflow,
           %{workflow_type: type, arguments: [Temporalex.Converter.encode(args)]}}
        ] ++ extra_jobs
    }
  end

  @doc "Pre-built activation containing only the given jobs (no init)."
  def activation(jobs, opts \\ []) do
    %{
      run_id: "ignored",
      is_replaying: Keyword.get(opts, :is_replaying, false),
      jobs: jobs
    }
  end

  @doc "Send an activation to an executor pid."
  def send_activation(exec, activation) do
    send(exec, {:activation, activation})
    :ok
  end
end
