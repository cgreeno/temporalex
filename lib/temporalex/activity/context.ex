defmodule Temporalex.Activity.Context do
  @moduledoc """
  Context for a running activity task.

  Stored in the process dictionary and accessible via `current/0`.
  Provides `heartbeat/1` for long-running activities and `cancelled?/0`
  for checking cancellation.
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
    :server_pid,
    :cancel_ref
  ]

  @doc "Get the current activity context from the process dictionary."
  def current do
    Process.get(:__temporal_activity_context__) ||
      raise "Activity.Context accessed outside of an activity task"
  end

  @doc """
  Send a heartbeat for the current activity. The Core SDK handles throttling.

  Returns `:ok` or `{:cancelled, reason}` if the activity has been cancelled.
  """
  def heartbeat(details \\ nil) do
    ctx = current()

    if cancelled?(ctx) do
      {:cancelled, :activity_cancelled}
    else
      payload = encode_heartbeat_payload(details)
      Temporalex.Native.record_activity_heartbeat(ctx.worker, ctx.task_token, payload)
    end
  end

  @doc false
  # Encode heartbeat details to the same Payload shape as activity I/O so the
  # encoding metadata survives the round-trip through Temporal history.
  def encode_heartbeat_payload(nil), do: nil
  def encode_heartbeat_payload(details), do: Temporalex.Converter.encode(details)

  @doc "Check if the activity has been cancelled."
  def cancelled? do
    cancelled?(current())
  end

  defp cancelled?(%{cancel_ref: nil}), do: false

  defp cancelled?(%{cancel_ref: ref}) do
    :atomics.get(ref, 1) == 1
  end

  @doc false
  def new_cancel_ref do
    :atomics.new(1, signed: false)
  end

  @doc false
  def set_cancelled(ref) do
    :atomics.put(ref, 1, 1)
  end
end
