defmodule Temporalex.Backend.TemporalCore.PollerBridge do
  @moduledoc false

  alias Temporalex.Backend.TemporalCore.Codec

  # Deliberately NOT start_link: this process is started from inside the
  # client GenServer (backend calls run there), but its lifetime belongs to
  # the WORKER it decodes for. A link would tie a worker crash to the shared
  # client — one dead worker must never take the node's connection down.
  # Instead the bridge monitors its owner and exits when the owner does.
  def start(owner_pid, payload_codec) when is_pid(owner_pid) do
    pid = spawn(__MODULE__, :init, [owner_pid, payload_codec])
    {:ok, pid}
  end

  def init(owner_pid, payload_codec) do
    Process.monitor(owner_pid)
    loop(owner_pid, payload_codec)
  end

  def loop(owner_pid, payload_codec) do
    receive do
      {:DOWN, _ref, :process, _owner, _reason} ->
        :ok

      {:workflow_activation, bytes} when is_binary(bytes) ->
        forward_decode(owner_pid, :workflow_activation, fn ->
          Codec.workflow_activation_from_bytes(bytes, payload_codec: payload_codec)
        end)

        loop(owner_pid, payload_codec)

      {:activity_task, bytes} when is_binary(bytes) ->
        forward_decode(owner_pid, :activity_task, fn ->
          Codec.activity_task_from_bytes(bytes, payload_codec: payload_codec)
        end)

        loop(owner_pid, payload_codec)

      {:backend_error, _reason} = message ->
        send(owner_pid, message)
        loop(owner_pid, payload_codec)

      {:poll_loop_exited, _kind, _reason} = message ->
        send(owner_pid, message)
        loop(owner_pid, payload_codec)

      :stop ->
        :ok
    end
  end

  defp forward_decode(owner_pid, tag, decode) do
    case decode.() do
      {:ok, value} -> send(owner_pid, {tag, value})
      {:error, {:undecodable, _id, _reason} = undecodable} -> send(owner_pid, {tag, undecodable})
      {:error, reason} -> send(owner_pid, {:backend_error, reason})
    end
  end
end
