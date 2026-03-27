defmodule Temporalex.DSL do
  @moduledoc """
  Simplified DSL for defining Temporal workflows and activities.

  Activities become regular functions that transparently schedule through
  Temporal when called from a workflow, call stubs in tests, or execute
  directly when called outside any context.

  ## Example

      defmodule MyApp.Orders do
        use Temporalex.DSL

        defactivity charge_payment(amount), timeout: 30_000 do
          Stripe.charge(amount)
        end

        defactivity ship_order(charge_id), timeout: 60_000 do
          Warehouse.ship(charge_id)
        end

        def process_order(%{order_id: order_id}) do
          with {:ok, amount} <- lookup_amount(order_id),
               {:ok, charge_id} <- charge_payment(amount),
               {:ok, tracking} <- ship_order(charge_id) do
            {:ok, tracking}
          end
        end
      end

  ## Three execution modes — zero configuration

  The generated activity functions automatically do the right thing:

  1. **Workflow mode** — called inside a Temporal workflow process,
     schedules the activity through Temporal and waits for the result.

  2. **Test mode** — if a stub is registered in the process dictionary,
     calls the stub and records the call for assertions.

  3. **Direct mode** — no workflow context, no stubs — just runs the
     activity implementation inline. Perfect for integration tests.

  ## Registration

      # In your supervision tree
      {Temporalex.Server,
        task_queue: "orders",
        workflows: [{"ProcessOrder", &MyApp.Orders.process_order/1}],
        activities: [MyApp.Orders]}
  """

  defmacro __using__(_opts) do
    quote do
      import Temporalex.DSL, only: [defactivity: 2, defactivity: 3]

      import Temporalex.Workflow.API,
        only: [
          sleep: 1,
          wait_for_signal: 1,
          continue_as_new: 0,
          continue_as_new: 1,
          continue_as_new: 2,
          patched?: 1,
          deprecate_patch: 1,
          cancelled?: 0,
          side_effect: 1,
          set_state: 1,
          get_state: 0,
          workflow_info: 0,
          upsert_search_attributes: 1
        ]

      Module.register_attribute(__MODULE__, :__temporal_activities__, accumulate: true)
      @before_compile Temporalex.DSL
    end
  end

  @doc """
  Define an activity as a regular function.

  ## Options

    * `:timeout` — start-to-close timeout in ms (default: 30_000)
    * `:schedule_timeout` — schedule-to-close timeout in ms
    * `:heartbeat` — heartbeat timeout in ms
    * `:task_queue` — override task queue
    * `:retry_policy` — retry policy keyword list

  ## Examples

      defactivity charge_payment(amount), timeout: 30_000 do
        Stripe.charge(amount)
      end

      defactivity send_email(params) do
        Mailer.deliver(params)
      end
  """
  defmacro defactivity(call, do: body) do
    build_defactivity(call, [], body)
  end

  defmacro defactivity(call, opts, do: body) do
    build_defactivity(call, opts, body)
  end

  defp build_defactivity(call, opts, body) do
    {name, args} = decompose_call(call)
    impl_name = :"__temporal_perform_#{name}__"

    # Single-arg activities only — matches Temporal's model
    arg =
      case args do
        [single] ->
          single

        [] ->
          quote(do: _)

        multi when is_list(multi) ->
          raise CompileError,
            description:
              "defactivity #{name} has #{length(multi)} arguments, but Temporal activities " <>
                "accept only a single argument (typically a map). " <>
                "Use `defactivity #{name}(%{key1: val1, key2: val2})` instead."
      end

    quote do
      @__temporal_activities__ {unquote(name), unquote(Macro.escape(opts))}

      @doc false
      def unquote(impl_name)(unquote(arg)), do: unquote(body)

      def unquote(name)(unquote(arg)) do
        Temporalex.DSL.__call_activity__(
          __MODULE__,
          unquote(name),
          unquote(arg),
          unquote(Macro.escape(opts))
        )
      end
    end
  end

  defp decompose_call({:when, _, [call | _]}), do: decompose_call(call)
  defp decompose_call({name, _, args}) when is_atom(name), do: {name, args || []}

  # -- Runtime dispatch (called from generated functions) --

  @doc false
  def __call_activity__(module, name, input, opts) do
    key = {module, name}
    stubs = Process.get(:__temporal_activity_stubs__, %{})

    cond do
      # Test mode: stub registered for this activity
      Map.has_key?(stubs, key) ->
        calls = Process.get(:__temporal_activity_calls__, [])
        Process.put(:__temporal_activity_calls__, [{key, input} | calls])
        stubs[key].(input)

      # Executor mode: running inside a WorkflowTaskExecutor runner
      (executor = Process.get(:__temporal_executor__)) != nil ->
        activity_type = activity_type_string(module, name)
        api_opts = translate_opts(opts)
        GenServer.call(executor, {:execute_activity, activity_type, input, api_opts}, :infinity)

      # Direct mode: no context, just run the implementation
      true ->
        impl_fn = :"__temporal_perform_#{name}__"
        apply(module, impl_fn, [input])
    end
  end

  @doc false
  def activity_type_string(module, name) do
    "#{module |> Module.split() |> Enum.join(".")}.#{name}"
  end

  # Map DSL shorthand opts to standard Temporal API opts
  defp translate_opts(opts) do
    opts
    |> Keyword.take([:timeout, :schedule_timeout, :heartbeat, :task_queue, :retry_policy])
    |> Enum.flat_map(fn
      {:timeout, v} -> [start_to_close_timeout: v]
      {:schedule_timeout, v} -> [schedule_to_close_timeout: v]
      {:heartbeat, v} -> [heartbeat_timeout: v]
      {k, v} -> [{k, v}]
    end)
  end

  # -- Compile-time hooks --

  defmacro __before_compile__(env) do
    activities = Module.get_attribute(env.module, :__temporal_activities__) |> Enum.reverse()

    quote do
      @doc false
      def __temporal_activities__, do: unquote(Macro.escape(activities))
    end
  end
end
