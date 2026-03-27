defmodule Temporalex.Activity do
  @moduledoc """
  Behaviour for defining Temporal activities.

  Activities are where side-effectful work happens: HTTP calls, database queries,
  file I/O, external APIs. Unlike workflows, activities do NOT need to be deterministic.

  ## Usage

      defmodule MyApp.Activities.Greet do
        use Temporalex.Activity,
          start_to_close_timeout: :timer.seconds(30)

        @impl true
        def perform(%{name: name}) do
          {:ok, "Hello, \#{name}!"}
        end
      end

  ## Module Options

  Options set here become defaults for every `execute_activity` call.
  They can be overridden at the call site.

    * `:start_to_close_timeout` — max time for a single attempt (ms)
    * `:schedule_to_start_timeout` — max time waiting in queue (ms)
    * `:schedule_to_close_timeout` — max total time including retries (ms)
    * `:heartbeat_timeout` — max time between heartbeats (ms)
    * `:retry_policy` — keyword list or `Temporalex.RetryPolicy` struct
    * `:task_queue` — override the worker's default task queue

  ## Callbacks

  Implement either `perform/1` (just args) or `perform/2` (context + args).
  Use `perform/2` when you need heartbeat or activity metadata.

      # Simple — no context needed (the common case)
      def perform(%{name: name}), do: {:ok, "Hello, \#{name}!"}

      # With context — for heartbeats and metadata
      def perform(ctx, %{file: path}) do
        Temporalex.Activity.Context.heartbeat(ctx)
        {:ok, process(path)}
      end
  """

  alias Temporalex.Activity.Context

  @doc "Execute the activity. Return {:ok, result} or {:error, reason}."
  @callback perform(input :: term()) ::
              {:ok, result :: term()}
              | {:error, reason :: term()}

  @doc "Execute the activity with context. Return {:ok, result} or {:error, reason}."
  @callback perform(ctx :: Context.t(), input :: term()) ::
              {:ok, result :: term()}
              | {:error, reason :: term()}

  @optional_callbacks perform: 1, perform: 2

  @known_opts [
    :start_to_close_timeout,
    :schedule_to_start_timeout,
    :schedule_to_close_timeout,
    :heartbeat_timeout,
    :retry_policy,
    :task_queue
  ]

  defmacro __using__(opts) do
    defaults = Keyword.take(opts, @known_opts)

    quote do
      @behaviour Temporalex.Activity

      require Logger

      alias Temporalex.Activity.Context

      @temporalex_activity_defaults unquote(Macro.escape(defaults))

      @before_compile Temporalex.Activity

      @doc false
      def __activity_type__ do
        __MODULE__ |> Module.split() |> Enum.join(".")
      end

      @doc false
      def __activity_defaults__ do
        @temporalex_activity_defaults
      end
    end
  end

  # Generate a perform/2 wrapper if only perform/1 is defined.
  # This way the Worker always calls perform(ctx, args) — no runtime checks.
  defmacro __before_compile__(env) do
    has_perform_1 = Module.defines?(env.module, {:perform, 1})
    has_perform_2 = Module.defines?(env.module, {:perform, 2})

    cond do
      has_perform_1 and has_perform_2 ->
        raise CompileError,
          description: "#{inspect(env.module)} defines both perform/1 and perform/2. Choose one.",
          file: env.file,
          line: 0

      has_perform_1 ->
        # Generate perform/2 that drops ctx and delegates to perform/1
        quote do
          @doc false
          def perform(_ctx, input), do: perform(input)
        end

      has_perform_2 ->
        # User defined perform/2, nothing to generate
        nil

      true ->
        raise CompileError,
          description: "#{inspect(env.module)} must implement perform/1 or perform/2.",
          file: env.file,
          line: 0
    end
  end
end
