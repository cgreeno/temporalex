defmodule Temporalex.Activity do
  @moduledoc """
  Minimal activity DSL.

  The generated public function is a workflow-side dispatch function. The generated
  `__name__/N` function is the implementation entry point intended for later server
  integration.
  """

  defmacro __using__(_opts) do
    quote do
      import Temporalex.Activity, only: [defactivity: 2, defactivity: 3]

      Module.register_attribute(__MODULE__, :temporalex_activities, accumulate: true)

      @before_compile Temporalex.Activity
    end
  end

  defmacro defactivity(head, do: body) do
    build_activity(head, [], body)
  end

  defmacro defactivity(head, opts, do: body) when is_list(opts) do
    build_activity(head, opts, body)
  end

  defmacro __before_compile__(_env) do
    quote do
      def __temporal_activities__, do: Enum.reverse(@temporalex_activities)
    end
  end

  defp build_activity({name, meta, args_ast}, opts, body) when is_atom(name) do
    args_ast = args_ast || []
    impl_name = :"__#{name}__"
    {dispatch_args, context?} = dispatch_args(args_ast)
    dispatch_head = {name, meta, dispatch_args}

    quote do
      @temporalex_activities %{
        name: unquote(name),
        type: "#{inspect(__MODULE__)}.#{unquote(name)}",
        implementation: unquote(impl_name),
        arity: unquote(length(dispatch_args)),
        implementation_arity: unquote(length(args_ast)),
        context?: unquote(context?),
        opts: unquote(opts)
      }

      def unquote(dispatch_head) do
        type = "#{inspect(__MODULE__)}.#{unquote(name)}"
        input = [unquote_splicing(dispatch_args)]
        Temporalex.Workflow.API.execute_activity(type, input, unquote(opts))
      end

      def unquote(impl_name)(unquote_splicing(args_ast)) do
        unquote(body)
      end
    end
  end

  defp dispatch_args([{name, _meta, context} | rest])
       when name in [:ctx, :context] and is_atom(context) do
    {rest, true}
  end

  defp dispatch_args(args), do: {args, false}
end
