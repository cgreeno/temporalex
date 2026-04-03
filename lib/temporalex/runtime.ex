defmodule Temporalex.Runtime do
  @moduledoc """
  Singleton GenServer holding the Temporal CoreRuntime + Tokio runtime.

  Auto-started by the Temporalex OTP application. All workers share
  a single runtime — obtain it with `get/0`.
  """
  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the RuntimeResource handle."
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @impl true
  def init(_opts) do
    case Temporalex.Native.create_runtime() do
      {:ok, runtime} ->
        Logger.info("Temporalex runtime started")
        {:ok, %{runtime: runtime}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get, _from, %{runtime: runtime} = state) do
    {:reply, {:ok, runtime}, state}
  end
end
