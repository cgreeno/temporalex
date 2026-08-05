defmodule Temporalex.Workflow do
  @moduledoc """
  Declares a workflow module and generates its call-side surface.

      defmodule Booking do
        use Temporalex.Workflow, queue: "bookings"

        @impl true
        def id(%Fresha.Booking{id: pk}), do: "booking-\#{pk}"
        def id(pk) when is_integer(pk), do: "booking-\#{pk}"

        @impl true
        def run(booking_id) do
          # ...
        end
      end

      handle  = Booking.start!(booking_id)
      receipt = Booking.execute!(booking_id)
      :ok     = Booking.signal!(booking_id, "capture_completed", %{status: "ok"})

  ## `use` options

    * `:queue` — the task queue this workflow's work and workers meet on.
      Required to generate the call-side surface; a module without it still
      compiles and can be started through the low-level `Temporalex.Client`.
    * `:name` — the wire type; defaults to the module name. Set it when the
      type must outlive the module name.
    * `:client` — the client the generated functions use; defaults to the
      app's default client (`Temporalex.Client`).

  ## Callbacks

  `id/1` derives the workflow id — Temporal's idempotency key — from whatever
  callers naturally hold. Required to use the generated surface; return
  `:generate` to opt out of derived ids deliberately.

  `input/1` (optional) maps the value callers pass into the durable input
  history records. Defaults to identity. `run/1` receives that input after
  the client codec's round-trip — see RFC 0002 §9.

  ## Client-side only

  The generated functions are live client calls and **raise inside workflow
  code**: on replay they would be nondeterministic. From within a workflow,
  use `Temporalex.Workflow.API.execute_child_workflow/3` and
  `API.signal_child_workflow/4` instead.
  """

  alias Temporalex.Start

  @callback run(term()) :: term()
  @callback id(input :: term()) :: String.t() | :generate
  @callback input(term()) :: term()
  @callback handle_query(String.t(), [term()], term()) :: {:reply, term()} | {:error, term()}
  @optional_callbacks handle_query: 3, id: 1, input: 1

  defmacro __using__(opts) do
    queue = Keyword.get(opts, :queue)
    wire_name = Keyword.get(opts, :name)
    client = Keyword.get(opts, :client)

    declarations =
      quote do
        @behaviour Temporalex.Workflow

        unquote(
          if wire_name do
            quote do
              def __workflow_type__, do: unquote(wire_name)
            end
          else
            quote do
              def __workflow_type__, do: inspect(__MODULE__)
            end
          end
        )

        def __queue__, do: unquote(queue)
        def __client__, do: unquote(client)

        def handle_query(query_type, _args, _published_state) do
          {:error, {:unknown_query, query_type}}
        end

        defoverridable handle_query: 3
      end

    if queue do
      [declarations | surface()]
    else
      declarations
    end
  end

  # The generated call-side surface — only when the module declared a queue,
  # so pre-existing modules gain nothing they did not ask for. Split by
  # concern to keep each quoted block readable.
  defp surface do
    [start_surface(), signal_surface(), query_surface(), surface_overrides()]
  end

  defp start_surface do
    quote do
      @doc "Builds a `Temporalex.Start` for this workflow. Pure data — nothing happens."
      def new(input, opts \\ []) do
        Temporalex.Start.new(__MODULE__, input, opts)
      end

      @doc "Starts the workflow and returns `{:ok, handle}` — nobody waits."
      def start(input, opts \\ []) do
        Temporalex.Workflow.refuse_inside_workflow!(__MODULE__, :start)
        input |> new(opts) |> Temporalex.start()
      end

      @doc "Like `start/2`; returns the handle, raises on failure."
      def start!(input, opts \\ []) do
        Temporalex.Workflow.refuse_inside_workflow!(__MODULE__, :start!)
        input |> new(opts) |> Temporalex.start!()
      end

      @doc "Starts the workflow and waits for its result."
      def execute(input, opts \\ []) do
        Temporalex.Workflow.refuse_inside_workflow!(__MODULE__, :execute)
        input |> new(opts) |> Temporalex.execute()
      end

      @doc "Like `execute/2`; returns the result, raises on failure."
      def execute!(input, opts \\ []) do
        Temporalex.Workflow.refuse_inside_workflow!(__MODULE__, :execute!)
        input |> new(opts) |> Temporalex.execute!()
      end
    end
  end

  defp signal_surface do
    quote do
      @doc """
      Signals the running workflow, addressed by anything `id/1` accepts.
      Errors if the workflow does not exist.
      """
      def signal(address, name, payload \\ nil, opts \\ []) when is_binary(name) do
        Temporalex.Workflow.refuse_inside_workflow!(__MODULE__, :signal)
        Temporalex.Workflow.__signal__(__MODULE__, address, name, payload, opts)
      end

      @doc "Like `signal/4`; raises on failure."
      def signal!(address, name, payload \\ nil, opts \\ []) when is_binary(name) do
        Temporalex.Workflow.refuse_inside_workflow!(__MODULE__, :signal!)

        Temporalex.unwrap!(
          Temporalex.Workflow.__signal__(__MODULE__, address, name, payload, opts)
        )
      end
    end
  end

  defp query_surface do
    quote do
      @doc "Queries the running workflow, addressed by anything `id/1` accepts."
      def query(address, name, args \\ [], opts \\ [])
          when is_binary(name) and is_list(args) do
        Temporalex.Workflow.refuse_inside_workflow!(__MODULE__, :query)
        Temporalex.Workflow.__query__(__MODULE__, address, name, args, opts)
      end

      @doc "Like `query/4`; returns the reply, raises on failure."
      def query!(address, name, args \\ [], opts \\ [])
          when is_binary(name) and is_list(args) do
        Temporalex.Workflow.refuse_inside_workflow!(__MODULE__, :query!)
        Temporalex.unwrap!(Temporalex.Workflow.__query__(__MODULE__, address, name, args, opts))
      end
    end
  end

  defp surface_overrides do
    quote do
      defoverridable new: 1,
                     new: 2,
                     start: 1,
                     start: 2,
                     start!: 1,
                     start!: 2,
                     execute: 1,
                     execute: 2,
                     execute!: 1,
                     execute!: 2,
                     signal: 2,
                     signal: 3,
                     signal: 4,
                     signal!: 2,
                     signal!: 3,
                     signal!: 4,
                     query: 2,
                     query: 3,
                     query: 4,
                     query!: 2,
                     query!: 3,
                     query!: 4
    end
  end

  @doc false
  def __signal__(module, address, name, payload, opts) do
    workflow_id = Start.resolve_address!(module, address)
    args = if is_nil(payload), do: [], else: [payload]

    Temporalex.Client.signal_workflow(
      resolve_client(module, opts),
      workflow_id,
      name,
      args,
      opts
    )
  end

  @doc false
  def __query__(module, address, name, args, opts) do
    workflow_id = Start.resolve_address!(module, address)
    Temporalex.Client.query_workflow(resolve_client(module, opts), workflow_id, name, args, opts)
  end

  @doc false
  # A generated function called from inside workflow code is a live client
  # call during replay — nondeterminism, one token away from the legal
  # child-workflow API. Refused mechanically rather than by documentation.
  # `what` is a module for generated wrappers and chain starts, and the wire
  # type string for awaits — inspect/1 renders both readably.
  def refuse_inside_workflow!(what, fun) do
    case Process.get(Temporalex.Workflow.API.context_key()) do
      nil ->
        :ok

      _context ->
        raise RuntimeError,
              "#{inspect(what)}.#{fun} was called from inside workflow code. " <>
                "Client calls are not replayable — use " <>
                "Temporalex.Workflow.API.execute_child_workflow/3 or " <>
                "API.signal_child_workflow/4 instead"
    end
  end

  defp resolve_client(module, opts) do
    Keyword.get(opts, :client) || module.__client__() || Temporalex.default_client()
  end
end
