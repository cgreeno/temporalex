defmodule Temporalex.Activity do
  @moduledoc """
  Minimal activity DSL.

  The generated public functions are workflow-side dispatch functions. The generated
  `name/N` function returns `{:ok, value}`, `{:error, reason}`, or `{:cancelled, error}`;
  `name!/N` unwraps success and raises failures or cancellation. The generated `__name__/N`
  function is the implementation entry point intended for later server integration.
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
    bang_name = :"#{name}!"
    {dispatch_args, context?} = dispatch_args(args_ast)
    # The dispatch/bang wrappers always read every arg (to build the activity
    # input list), so strip any leading underscore the author used to mark the
    # arg unused in the implementation body. This lets `defactivity foo(_x)`
    # compile warning-free: the wrapper reads `x`, the impl leaves `_x` unused.
    public_args = Enum.map(dispatch_args, &strip_underscore/1)
    dispatch_head = {name, meta, public_args}
    {local?, dispatch_opts} = Keyword.pop(opts, :local, false)

    dispatch_call =
      if local? do
        quote do
          Temporalex.Workflow.API.execute_local_activity(type, input, unquote(dispatch_opts))
        end
      else
        quote do
          Temporalex.Workflow.API.execute_activity(type, input, unquote(dispatch_opts))
        end
      end

    bang_dispatch_call =
      if local? do
        quote do
          Temporalex.Workflow.API.execute_local_activity!(type, input, unquote(dispatch_opts))
        end
      else
        quote do
          Temporalex.Workflow.API.execute_activity!(type, input, unquote(dispatch_opts))
        end
      end

    bang_head = {bang_name, meta, public_args}

    quote do
      @temporalex_activities %{
        name: unquote(name),
        type: "#{inspect(__MODULE__)}.#{unquote(name)}",
        implementation: unquote(impl_name),
        arity: unquote(length(public_args)),
        implementation_arity: unquote(length(args_ast)),
        context?: unquote(context?),
        local?: unquote(local?),
        opts: unquote(dispatch_opts)
      }

      def unquote(dispatch_head) do
        type = "#{inspect(__MODULE__)}.#{unquote(name)}"
        input = [unquote_splicing(public_args)]
        unquote(dispatch_call)
      end

      def unquote(bang_head) do
        type = "#{inspect(__MODULE__)}.#{unquote(name)}"
        input = [unquote_splicing(public_args)]
        unquote(bang_dispatch_call)
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

  defp strip_underscore({name, meta, context}) when is_atom(name) do
    case Atom.to_string(name) do
      "_" <> rest when rest != "" -> {String.to_atom(rest), meta, context}
      _ -> {name, meta, context}
    end
  end

  defp strip_underscore(arg), do: arg
end
