defmodule Temporalex.Activity.Context do
  @moduledoc """
  Context passed to activity callbacks.

  Holds activity metadata and provides heartbeat functionality.
  """
  require Logger

  defstruct [
    :activity_id,
    :activity_type,
    :task_token,
    :workflow_id,
    :workflow_type,
    :workflow_namespace,
    :run_id,
    :task_queue,
    :attempt,
    :heartbeat_timeout,
    :is_local,
    # Internal: reference to the worker for heartbeat calls
    :worker_pid
  ]

  @type t :: %__MODULE__{
          activity_id: String.t(),
          activity_type: String.t(),
          task_token: binary(),
          workflow_id: String.t(),
          workflow_type: String.t(),
          workflow_namespace: String.t(),
          run_id: String.t(),
          task_queue: String.t(),
          attempt: non_neg_integer(),
          heartbeat_timeout: non_neg_integer() | nil,
          is_local: boolean(),
          worker_pid: pid() | nil
        }

  @doc "Build a context from an activity Start task."
  @spec from_start(map(), keyword()) :: t()
  def from_start(start, opts \\ []) do
    ctx = %__MODULE__{
      activity_id: value_or_empty(start.activity_id),
      activity_type: value_or_empty(start.activity_type),
      task_token: Keyword.get(opts, :task_token, <<>>),
      workflow_namespace: value_or_empty(start.workflow_namespace),
      workflow_type: value_or_empty(start.workflow_type),
      workflow_id: workflow_execution_value(start, :workflow_id),
      run_id: workflow_execution_value(start, :run_id),
      attempt: start.attempt || 1,
      heartbeat_timeout: parse_duration_ms(start.heartbeat_timeout),
      is_local: start.is_local || false,
      # task_queue not in proto — passed from worker config
      task_queue: Keyword.get(opts, :task_queue, ""),
      worker_pid: Keyword.get(opts, :worker_pid)
    }

    Logger.debug("Activity.Context created",
      activity_id: ctx.activity_id,
      activity_type: ctx.activity_type,
      workflow_id: ctx.workflow_id,
      workflow_type: ctx.workflow_type,
      task_queue: ctx.task_queue,
      attempt: ctx.attempt,
      is_local: ctx.is_local,
      has_heartbeat_timeout: ctx.heartbeat_timeout != nil
    )

    ctx
  end

  @doc """
  Send a heartbeat to indicate the activity is still alive.
  Pass details (any serializable term) to report progress.

  ## Example

      def perform(ctx, %{file: path}) do
        for chunk <- stream_file(path) do
          process(chunk)
          Temporalex.Activity.Context.heartbeat(ctx, %{progress: chunk.index})
        end
        {:ok, "done"}
      end
  """
  @spec heartbeat(t(), term()) :: :ok
  def heartbeat(%__MODULE__{} = ctx, details \\ nil) do
    Logger.debug("Activity heartbeat",
      activity_id: ctx.activity_id,
      activity_type: ctx.activity_type,
      has_details: details != nil
    )

    details_bytes =
      if is_nil(details) do
        <<>>
      else
        payload = Temporalex.Converter.to_payload(details)
        Protobuf.encode(%Temporal.Api.Common.V1.Payloads{payloads: [payload]})
      end

    # Send heartbeat request to the Worker, which holds the worker resource
    if ctx.worker_pid && Process.alive?(ctx.worker_pid) do
      send(ctx.worker_pid, {:activity_heartbeat, ctx.task_token, details_bytes})
    end

    :ok
  end

  # Convert google.protobuf.Duration to milliseconds
  defp value_or_empty(nil), do: ""
  defp value_or_empty(value), do: value

  defp workflow_execution_value(%{workflow_execution: workflow_execution}, _field)
       when is_nil(workflow_execution),
       do: ""

  defp workflow_execution_value(%{workflow_execution: workflow_execution}, field) do
    workflow_execution |> Map.get(field) |> value_or_empty()
  end

  defp workflow_execution_value(_start, _field), do: ""

  defp parse_duration_ms(nil), do: nil

  defp parse_duration_ms(%{seconds: seconds, nanos: nanos}) do
    seconds * 1000 + div(nanos, 1_000_000)
  end

  defp parse_duration_ms(_), do: nil
end
