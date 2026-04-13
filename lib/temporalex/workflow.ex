defmodule Temporalex.Workflow do
  @moduledoc """
  Defines a Temporal workflow.

  A workflow is a module with a `run/1` function that reads top-to-bottom
  as sequential code. Concurrency is introduced through `API.receive`
  and `API.parallel`.

      defmodule MyApp.Workflows.Checkout do
        use Temporalex.Workflow

        def handle_query("status", _args, state), do: {:reply, state}

        def run(args) do
          {:ok, charge} = Activities.Payment.charge(args)
          {:ok, %{charge_id: charge.id}}
        end
      end

  ## Return values from `run/1`

  - `{:ok, result}` — workflow completes successfully
  - `{:error, reason}` — workflow fails
  - `{:continue_as_new, args}` — workflow restarts with fresh history
  """

  defmacro __using__(_opts) do
    quote do
      alias Temporalex.Workflow.API

      @before_compile Temporalex.Workflow

      @doc false
      def __temporal_workflow_type__, do: to_string(__MODULE__)

      @doc false
      def handle_query(_name, _args, _state), do: {:reply, nil}
      defoverridable handle_query: 3
    end
  end

  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:run, 1}) do
      raise CompileError,
        file: env.file,
        line: 0,
        description: "#{inspect(env.module)} must define run/1"
    end

    :ok
  end
end
