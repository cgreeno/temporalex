defmodule Temporalex.Activity.Context do
  @moduledoc """
  Runtime context passed to activity implementations that declare a context
  argument.

  Heartbeats are submitted through the worker backend when the activity is running
  under a `Temporalex.Server`.
  """

  defstruct activity_id: nil,
            activity_type: nil,
            task_token: nil,
            workflow_id: nil,
            workflow_type: nil,
            workflow_namespace: nil,
            run_id: nil,
            task_queue: nil,
            attempt: 1,
            heartbeat_timeout: nil,
            is_local: false,
            worker: nil,
            cancelled: nil,
            cancel_reason: nil

  def heartbeat(%__MODULE__{} = context, details \\ nil) do
    if cancelled?(context) do
      {:cancelled, context.cancel_reason || :cancelled}
    else
      with :ok <- submit_heartbeat(context, details) do
        if cancelled?(context) do
          {:cancelled, context.cancel_reason || :cancelled}
        else
          :ok
        end
      end
    end
  end

  def cancelled?(%__MODULE__{cancelled: nil}), do: false

  def cancelled?(%__MODULE__{cancelled: cancelled}) do
    :atomics.get(cancelled, 1) == 1
  end

  defp submit_heartbeat(%__MODULE__{worker: nil}, _details), do: :ok
  defp submit_heartbeat(%__MODULE__{task_token: nil}, _details), do: :ok

  defp submit_heartbeat(%__MODULE__{} = context, details) do
    Temporalex.Server.record_activity_heartbeat(context.worker, context.task_token, details)
  end
end
