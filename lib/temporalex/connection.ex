defmodule Temporalex.Connection do
  @moduledoc """
  GenServer managing the Temporal connection lifecycle.

  Wraps the NIF runtime and client resources. Other modules
  (Worker, Client) retrieve connection details via `get/1`.

  Retries connection with exponential backoff on failure before
  giving up and stopping (which lets the supervisor restart it).

  ## Usage in supervision tree

      {Temporalex.Connection, [
        name: MyApp.TemporalConnection,
        address: "localhost:7233",
        namespace: "default"
      ]}
  """
  use GenServer
  require Logger

  defstruct [
    :name,
    :address,
    :namespace,
    :api_key,
    :runtime,
    :client,
    headers: [],
    connect_attempts: 0
  ]

  @type t :: %__MODULE__{
          name: atom(),
          address: String.t(),
          namespace: String.t(),
          api_key: String.t() | nil,
          headers: [{String.t(), String.t()}],
          runtime: reference() | nil,
          client: reference() | nil,
          connect_attempts: non_neg_integer()
        }

  @max_connect_attempts 3
  @base_backoff_ms 1_000
  @max_backoff_ms 10_000

  # --- Public API ---

  def start_link(opts) do
    name =
      opts[:name] ||
        raise ArgumentError,
              "Temporalex.Connection requires :name option (e.g., name: MyApp.TemporalConnection)"

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get the connection state (runtime + client resources)."
  @spec get(atom() | pid()) :: {:ok, t()} | {:error, term()}
  def get(conn) do
    GenServer.call(conn, :get)
  end

  @doc "Get the raw NIF runtime resource."
  @spec get_runtime(atom() | pid()) :: {:ok, reference()}
  def get_runtime(conn) do
    GenServer.call(conn, :get_runtime)
  end

  @doc "Get the raw NIF client resource."
  @spec get_client(atom() | pid()) :: {:ok, reference()}
  def get_client(conn) do
    GenServer.call(conn, :get_client)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    address = Keyword.get(opts, :address, "http://localhost:7233")
    namespace = Keyword.get(opts, :namespace, "default")
    api_key = Keyword.get(opts, :api_key)
    headers = Keyword.get(opts, :headers, [])

    uri = URI.parse(address)

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      raise ArgumentError,
            "Invalid Temporal server address: #{inspect(address)}. " <>
              "Expected a URL like \"http://localhost:7233\" or \"https://my-ns.tmprl.cloud:7233\""
    end

    state = %__MODULE__{
      name: name,
      address: address,
      namespace: namespace,
      api_key: api_key,
      headers: headers
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    Logger.info("Connection starting",
      name: state.name,
      address: state.address,
      namespace: state.namespace,
      attempt: state.connect_attempts + 1
    )

    case connect(state.address, state.api_key, state.headers) do
      {:ok, runtime, client} ->
        Logger.info("Connection established",
          name: state.name,
          address: state.address,
          namespace: state.namespace
        )

        {:noreply, %{state | runtime: runtime, client: client, connect_attempts: 0}}

      {:error, reason} ->
        attempts = state.connect_attempts + 1

        if attempts >= @max_connect_attempts do
          Logger.error("Connection failed after #{attempts} attempts — stopping",
            name: state.name,
            address: state.address,
            error: inspect(reason)
          )

          {:stop, {:connection_failed, reason}, state}
        else
          backoff = connect_backoff_ms(attempts)

          Logger.warning("Connection failed — retrying after #{backoff}ms",
            name: state.name,
            address: state.address,
            attempt: attempts,
            error: inspect(reason)
          )

          Process.send_after(self(), :retry_connect, backoff)
          {:noreply, %{state | connect_attempts: attempts}}
        end
    end
  end

  @impl true
  def handle_info(:retry_connect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(msg, state) do
    Logger.warning("Connection received unexpected message", message: inspect(msg))
    {:noreply, state}
  end

  @impl true
  def handle_call(:get, _from, %{runtime: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:get, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:get_runtime, _from, %{runtime: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:get_runtime, _from, state) do
    {:reply, {:ok, state.runtime}, state}
  end

  @impl true
  def handle_call(:get_client, _from, %{client: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:get_client, _from, state) do
    {:reply, {:ok, state.client}, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Connection terminating",
      name: state.name,
      address: state.address,
      reason: inspect(reason)
    )

    # Explicitly nil out NIF resources so they're eligible for GC immediately
    %{state | runtime: nil, client: nil}
    :ok
  end

  # --- Private ---

  defp connect(address, api_key, headers) do
    Logger.debug("Creating NIF runtime", address: address)

    with {:ok, runtime} <- Temporalex.Native.create_runtime(),
         _ = Logger.debug("NIF runtime created, connecting client", address: address),
         {:ok, client} <-
           Temporalex.Native.connect_client(runtime, address, api_key || "", headers || []) do
      Logger.debug("NIF client connected", address: address)
      {:ok, runtime, client}
    else
      {:error, reason} ->
        Logger.error("NIF connection error", error: inspect(reason))
        {:error, reason}
    end
  end

  defp connect_backoff_ms(attempts) do
    base = @base_backoff_ms * Integer.pow(2, attempts - 1)
    capped = min(base, @max_backoff_ms)
    jitter = :rand.uniform(div(capped, 2) + 1)
    capped + jitter
  end
end
