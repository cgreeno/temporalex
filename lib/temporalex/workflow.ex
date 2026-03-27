defmodule Temporalex.Workflow do
  @moduledoc """
  Behaviour for defining Temporal workflows.

  Workflows are the core orchestration unit in Temporal. They must be deterministic --
  no random numbers, no system time, no HTTP calls, no DB queries inside workflow code.
  Use activities for all side-effectful operations.

  ## Usage

      defmodule MyApp.Workflows.Greeter do
        use Temporalex.Workflow,
          task_queue: "greetings"

        def run(%{name: name}) do
          {:ok, greeting} = execute_activity(MyApp.Activities.Greet, %{name: name})
          {:ok, greeting}
        end
      end

  ## Module Options

  Options set here become defaults when starting this workflow.
  They can be overridden at the call site.

    * `:task_queue` — default task queue for this workflow
    * `:execution_timeout` — max total workflow time including retries (ms)
    * `:run_timeout` — max time for a single workflow run (ms)

  ## Callbacks

  - `run/1` -- Main workflow logic. Receives decoded input arguments.
  - `handle_signal/3` -- Handle an incoming signal (optional)
  - `handle_query/3` -- Handle a query, return data without mutating state (optional)
  """

  @doc "Main workflow logic. Receives decoded input arguments."
  @callback run(args :: term()) ::
              {:ok, result :: term()}
              | {:error, reason :: term()}

  @doc "Handle a named signal. Return updated state."
  @callback handle_signal(signal_name :: String.t(), payload :: term(), state :: term()) ::
              {:noreply, state :: term()}

  @doc "Handle a named query. Return data without mutating state."
  @callback handle_query(query_name :: String.t(), args :: term(), state :: term()) ::
              {:reply, result :: term()}

  @optional_callbacks handle_signal: 3, handle_query: 3

  @known_opts [:task_queue, :execution_timeout, :run_timeout]

  defmacro __using__(opts) do
    defaults = Keyword.take(opts, @known_opts)

    quote do
      @behaviour Temporalex.Workflow

      require Logger

      import Temporalex.Workflow.API,
        only: [
          execute_activity: 2,
          execute_activity: 3,
          execute_local_activity: 2,
          execute_local_activity: 3,
          execute_child_workflow: 2,
          execute_child_workflow: 3,
          sleep: 1,
          wait_for_signal: 1,
          continue_as_new: 0,
          continue_as_new: 1,
          continue_as_new: 2,
          patched?: 1,
          deprecate_patch: 1,
          cancelled?: 0,
          side_effect: 1,
          random: 0,
          uuid4: 0,
          set_state: 1,
          get_state: 0,
          workflow_info: 0,
          upsert_search_attributes: 1
        ]

      @temporalex_workflow_defaults unquote(Macro.escape(defaults))

      @doc false
      def __workflow_type__ do
        __MODULE__ |> Module.split() |> Enum.join(".")
      end

      @doc false
      def __workflow_defaults__ do
        @temporalex_workflow_defaults
      end

      # Default implementations for optional callbacks
      @impl Temporalex.Workflow
      def handle_signal(signal_name, _payload, state) do
        Logger.warning("Unhandled signal in workflow",
          signal_name: signal_name,
          module: __MODULE__
        )

        {:noreply, state}
      end

      @impl Temporalex.Workflow
      def handle_query(query_name, _args, _state) do
        Logger.warning("Unhandled query in workflow",
          query_name: query_name,
          module: __MODULE__
        )

        {:reply, nil}
      end

      defoverridable handle_signal: 3, handle_query: 3
    end
  end
end
