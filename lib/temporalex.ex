defmodule Temporalex do
  @moduledoc """
  Elixir SDK for [Temporal](https://temporal.io), built on the official Rust Core SDK via Rustler NIFs.

  ## Quick Start

  Define workflows and activities with the DSL:

      defmodule MyApp.Orders do
        use Temporalex.DSL

        defactivity charge(amount), timeout: 30_000 do
          Stripe.charge(amount)
        end

        def process_order(%{"amount" => amount}) do
          {:ok, charge_id} = charge(amount)
          {:ok, charge_id}
        end
      end

  Add to your supervision tree:

      children = [
        {Temporalex,
          name: MyApp.Temporal,
          task_queue: "orders",
          workflows: [{"ProcessOrder", &MyApp.Orders.process_order/1}],
          activities: [MyApp.Orders]}
      ]

  Or use `Temporalex.Server` directly for more control:

      children = [
        {Temporalex.Server,
          task_queue: "orders",
          workflows: [{"ProcessOrder", &MyApp.Orders.process_order/1}],
          activities: [MyApp.Orders]}
      ]

  ## Architecture

  `Temporalex` is a Supervisor that starts:

  - `Temporalex.Connection` -- GenServer managing NIF runtime + client resources
  - `Temporalex.Server` -- GenServer running poll/complete loops via WorkflowTaskExecutor

  Additional modules:

  - `Temporalex.DSL` -- `defactivity` macro for defining workflows and activities
  - `Temporalex.Client` -- Start, signal, query, cancel, and terminate workflows
  - `Temporalex.Converter` -- JSON data converter (Jason-based)
  """

  use Supervisor

  @doc """
  Start the Temporalex supervisor.

  ## Options

    * `:name` — instance name, used to derive child process names (required)
    * `:address` — Temporal server address (default: `"http://localhost:7233"`)
    * `:namespace` — Temporal namespace (default: `"default"`)
    * `:task_queue` — task queue name (required)
    * `:workflows` — list of workflow modules (default: `[]`)
    * `:activities` — list of activity modules (default: `[]`)
    * `:max_concurrent_workflow_tasks` — max concurrent workflow tasks (default: 5)
    * `:max_concurrent_activity_tasks` — max concurrent activities (default: 5)
    * `:api_key` — API key for Temporal Cloud auth (default: none)
    * `:headers` — custom gRPC headers as `[{"key", "value"}]` (default: `[]`)
  """
  def start_link(opts) do
    name =
      opts[:name] ||
        raise ArgumentError,
              "Temporalex.start_link requires :name option (e.g., name: MyApp.Temporal)"

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name =
      opts[:name] ||
        raise ArgumentError,
              "Temporalex requires :name option (e.g., name: MyApp.Temporal)"

    conn_name = connection_name(name)

    conn_opts =
      [
        name: conn_name,
        address: Keyword.get(opts, :address, "http://localhost:7233"),
        namespace: Keyword.get(opts, :namespace, "default")
      ] ++ Keyword.take(opts, [:api_key, :headers])

    task_queue =
      opts[:task_queue] ||
        raise ArgumentError,
              "Temporalex requires :task_queue option (e.g., task_queue: \"my-queue\")"

    worker_opts =
      [
        connection: conn_name,
        task_queue: task_queue,
        workflows: Keyword.get(opts, :workflows, []),
        activities: Keyword.get(opts, :activities, [])
      ] ++
        Keyword.take(opts, [:max_concurrent_workflow_tasks, :max_concurrent_activity_tasks])

    children = [
      {Temporalex.Connection, conn_opts},
      {Temporalex.Server, worker_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Derive the connection process name for a Temporalex instance.

      conn = Temporalex.connection_name(MyApp.Temporal)
      {:ok, handle} = Temporalex.start_workflow(conn, MyWorkflow, %{key: "value"})
  """
  @spec connection_name(atom()) :: atom()
  def connection_name(instance_name), do: Module.concat(instance_name, Connection)

  # --- Client API ---

  @doc """
  Start a workflow execution.

  See `Temporalex.Client.start_workflow/4` for full options.
  """
  @spec start_workflow(atom() | pid() | map(), module(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_workflow(conn, workflow_module, args \\ [], opts \\ []) do
    Temporalex.Client.start_workflow(conn, workflow_module, args, opts)
  end

  @doc """
  Wait for a workflow to complete and return its result.

  Accepts a `WorkflowHandle` (returned by `start_workflow`) or a connection + workflow ID.
  """
  @spec get_result(Temporalex.WorkflowHandle.t()) :: {:ok, term()} | {:error, term()}
  def get_result(%Temporalex.WorkflowHandle{} = handle) do
    Temporalex.Client.get_result(handle)
  end

  @spec get_result(Temporalex.WorkflowHandle.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_result(%Temporalex.WorkflowHandle{} = handle, opts) when is_list(opts) do
    Temporalex.Client.get_result(handle, opts)
  end

  @spec get_result(atom() | pid() | map(), String.t() | map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def get_result(conn, handle_or_id, opts \\ []) do
    Temporalex.Client.get_result(conn, handle_or_id, opts)
  end

  @doc "Send a signal to a running workflow. See `Temporalex.Client.signal_workflow/5`."
  @spec signal_workflow(atom() | pid() | map(), String.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def signal_workflow(conn, workflow_id, signal_name, args \\ nil, opts \\ []) do
    Temporalex.Client.signal_workflow(conn, workflow_id, signal_name, args, opts)
  end

  @doc "Query a running workflow's state. See `Temporalex.Client.query_workflow/5`."
  @spec query_workflow(atom() | pid() | map(), String.t(), String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def query_workflow(conn, workflow_id, query_type, args \\ nil, opts \\ []) do
    Temporalex.Client.query_workflow(conn, workflow_id, query_type, args, opts)
  end

  @doc "Cancel a running workflow. See `Temporalex.Client.cancel_workflow/3`."
  @spec cancel_workflow(atom() | pid() | map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def cancel_workflow(conn, workflow_id, opts \\ []) do
    Temporalex.Client.cancel_workflow(conn, workflow_id, opts)
  end

  @doc "Terminate a running workflow immediately. See `Temporalex.Client.terminate_workflow/3`."
  @spec terminate_workflow(atom() | pid() | map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def terminate_workflow(conn, workflow_id, opts \\ []) do
    Temporalex.Client.terminate_workflow(conn, workflow_id, opts)
  end
end
