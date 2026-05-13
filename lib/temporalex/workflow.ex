defmodule Temporalex.Workflow do
  @moduledoc """
  Minimal workflow module DSL for the core slices.
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Temporalex.Workflow

      def __workflow_type__, do: inspect(__MODULE__)
      def __workflow_defaults__, do: []

      def handle_query(query_type, _args, _published_state) do
        {:error, {:unknown_query, query_type}}
      end

      defoverridable handle_query: 3
    end
  end

  @callback run(term()) :: term()
  @callback handle_query(String.t(), [term()], term()) :: {:reply, term()} | {:error, term()}
  @optional_callbacks handle_query: 3
end
