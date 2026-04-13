defmodule Temporalex.Activity.Context do
  @moduledoc """
  Context for a running activity task.

  Stored in the process dictionary and accessible via `current/0`.
  Provides `heartbeat/1` for long-running activities.
  """

  defstruct [
    :task_token,
    :activity_id,
    :activity_type,
    :workflow_namespace,
    :workflow_type,
    :workflow_id,
    :workflow_run_id,
    :task_queue,
    :attempt,
    :heartbeat_details,
    :worker,
    :server_pid
  ]

  @doc "Get the current activity context from the process dictionary."
  def current do
    Process.get(:__temporal_activity_context__) ||
      raise "Activity.Context accessed outside of an activity task"
  end

  @doc """
  Send a heartbeat for the current activity. The Core SDK handles throttling.

  Returns `:ok`. Heartbeats are fire-and-forget — failures are silent.
  """
  def heartbeat(details \\ nil) do
    ctx = current()
    details_bytes = if details, do: :erlang.term_to_binary(details), else: <<>>
    Temporalex.Native.record_activity_heartbeat(ctx.worker, ctx.task_token, details_bytes)
  end
end
