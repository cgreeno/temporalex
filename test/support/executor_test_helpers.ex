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

  @doc """
  Assert the wire-protocol invariant: each activation an executor receives
  must be followed by exactly one workflow completion before the next
  activation arrives. Drains start markers and flushes from the test
  process mailbox, pairs them into windows, and fails on any window that
  has 0 or >1 flushes.

  Window definition: `:activation_start` to the next `:activation_start`
  (or end of `timeout`). The flush can happen at any point within the
  window — during the activation's `handle_info` or after via a
  `handle_call` (e.g. the runner entering a receive).

  Catches the wire-protocol bugs the basic flush_to seam misses.
  """
  def assert_one_flush_per_activation(timeout \\ 200) do
    events = collect_activation_events([], deadline(timeout))
    windows = group_into_windows(events, nil, [])

    Enum.each(windows, fn
      {run_id, :out_of_band} ->
        ExUnit.Assertions.flunk(
          "Out-of-band flush for run_id=#{run_id}: a flush arrived without a " <>
            "preceding :activation_start. The Temporal Core SDK rejects this " <>
            "as 'Task not found when completing'."
        )

      {run_id, count} ->
        ExUnit.Assertions.assert(
          count == 1,
          "Activation window for run_id=#{run_id} produced #{count} flushes; " <>
            "exactly 1 is required by the Temporal Core SDK protocol. " <>
            "0 means the activation was never completed; >1 means we tried to " <>
            "complete a closed workflow task."
        )
    end)

    windows
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp collect_activation_events(acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:activation_start, _run_id} = m ->
        collect_activation_events([m | acc], deadline)

      {:flushed, _run_id, _cmds} = m ->
        collect_activation_events([m | acc], deadline)
    after
      remaining -> Enum.reverse(acc)
    end
  end

  # Pair events into windows. Each window opens on :activation_start and
  # closes when the next :activation_start arrives (or the event stream
  # ends). Counts :flushed messages within the window.
  defp group_into_windows([], nil, windows), do: Enum.reverse(windows)

  defp group_into_windows([], {run_id, count}, windows),
    do: Enum.reverse([{run_id, count} | windows])

  defp group_into_windows([{:activation_start, run_id} | rest], nil, windows) do
    group_into_windows(rest, {run_id, 0}, windows)
  end

  defp group_into_windows([{:activation_start, new_run_id} | rest], {run_id, count}, windows) do
    group_into_windows(rest, {new_run_id, 0}, [{run_id, count} | windows])
  end

  defp group_into_windows([{:flushed, _, _} | rest], nil, windows) do
    group_into_windows(rest, nil, [{:no_run, :out_of_band} | windows])
  end

  defp group_into_windows([{:flushed, _, _} | rest], {run_id, count}, windows) do
    group_into_windows(rest, {run_id, count + 1}, windows)
  end
end
