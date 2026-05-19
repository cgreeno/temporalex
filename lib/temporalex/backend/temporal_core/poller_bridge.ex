defmodule Temporalex.Backend.TemporalCore.PollerBridge do
  @moduledoc false

  alias Temporalex.Backend.TemporalCore.Codec

  def start_link(owner_pid) when is_pid(owner_pid) do
    pid = spawn_link(__MODULE__, :loop, [owner_pid])
    {:ok, pid}
  end

  def loop(owner_pid) do
    receive do
      {:workflow_activation, bytes} when is_binary(bytes) ->
        forward_decode(
          owner_pid,
          :workflow_activation,
          bytes,
          &Codec.workflow_activation_from_bytes/1
        )

        loop(owner_pid)

      {:activity_task, bytes} when is_binary(bytes) ->
        forward_decode(owner_pid, :activity_task, bytes, &Codec.activity_task_from_bytes/1)
        loop(owner_pid)

      {:backend_error, _reason} = message ->
        send(owner_pid, message)
        loop(owner_pid)

      {:poll_loop_exited, _kind, _reason} = message ->
        send(owner_pid, message)
        loop(owner_pid)

      :stop ->
        :ok
    end
  end

  defp forward_decode(owner_pid, tag, bytes, decoder) do
    case decoder.(bytes) do
      {:ok, value} -> send(owner_pid, {tag, value})
      {:error, reason} -> send(owner_pid, {:backend_error, reason})
    end
  end
end
