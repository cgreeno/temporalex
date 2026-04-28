defmodule Temporalex.Activity do
  @moduledoc """
  Defines activities that workflows can call.

      defmodule MyApp.Activities.Payment do
        use Temporalex.Activity

        defactivity charge(amount), timeout: 30_000 do
          Stripe.charge(amount)
        end
      end

  Each `defactivity` generates two functions:

  1. **`charge(amount)`** — dispatch function called from workflow code.
     Sends `{:execute_activity, type, input, opts}` to the executor.

  2. **`__charge__/1`** — implementation function called by the server
     when an activity task arrives. Public for direct use in tests.

  The module also generates `__temporal_activities__/0` returning
  `[{name, opts}]` for registration.
  """

  defmacro __using__(_opts) do
    quote do
      import Temporalex.Activity, only: [defactivity: 2, defactivity: 3]
      Module.register_attribute(__MODULE__, :temporal_activities, accumulate: true)
      @before_compile Temporalex.Activity
    end
  end

  @doc """
  Define an activity with a name, optional options, and a body.

  Options:
  - `:timeout` — schedule-to-close timeout in ms (default: 30_000)
  - `:heartbeat_timeout` — heartbeat timeout in ms
  - `:retry_policy` — retry configuration map
  - `:local` — when true, the dispatch function calls
    `execute_local_activity/3` instead. Use for short, in-process
    operations (id generation, current time, lookups). Local activities
    are recorded in workflow history and survive worker crashes.
  - `:start_to_close_timeout_ms` — local activity timeout (default: 30_000)
  """
  defmacro defactivity(head, opts \\ [], do: body) do
    {name, args} = parse_head(head)
    impl_name = :"__#{name}__"
    activity_type = activity_type_string(__CALLER__.module, name)
    local? = Keyword.get(opts, :local, false)

    dispatch_call =
      if local? do
        quote do
          Temporalex.Workflow.API.execute_local_activity(
            unquote(activity_type),
            input,
            unquote(opts)
          )
        end
      else
        quote do
          Temporalex.Workflow.API.execute_activity(
            unquote(activity_type),
            input,
            unquote(opts)
          )
        end
      end

    quote do
      # Register for __temporal_activities__/0
      @temporal_activities {unquote(name), unquote(opts)}

      # Dispatch function — called from workflow code
      def unquote(name)(unquote_splicing(args)) do
        input = unquote(args)
        unquote(dispatch_call)
      end

      # Implementation function — called by server when activity task arrives
      def unquote(impl_name)(unquote_splicing(args)) do
        unquote(body)
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __temporal_activities__, do: @temporal_activities
    end
  end

  # --- Helpers ---

  defp parse_head({name, _, nil}), do: {name, []}
  defp parse_head({name, _, args}), do: {name, args}

  defp activity_type_string(module, name) do
    module_str = module |> to_string() |> String.trim_leading("Elixir.")
    "#{module_str}.#{name}"
  end
end
