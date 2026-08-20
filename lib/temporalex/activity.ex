defmodule Temporalex.Activity do
  @moduledoc """
  Activities: module-owned definitions with a workflow-side call surface.

      defmodule Bookings.Activities do
        use Temporalex.Activity, start_to_close_timeout: 30_000

        defactivity charge(amount), name: "bookings.charge" do
          {:ok, PaymentGateway.charge(amount)}
        end
      end

      # inside a workflow — a plain call; policy lives at the definition:
      receipt = Activities.charge!(amount)

      # call-site overrides are keyword options, validated against what the
      # backend actually honours:
      Activities.charge!(amount, timeout: 10_000)

  The generated `name/N` dispatch returns `{:ok, value}` or `{:error, error}`
  (a cancelled activity is `{:error, %Temporalex.Failure.CancelledError{}}`);
  `name!/N` unwraps success and raises failures. The implementation body runs
  on the worker — unit-test it directly with
  `Temporalex.Testing.run_activity/4`, no Temporal anywhere.

  Options given to `use Temporalex.Activity` become module-wide defaults;
  per-activity options override them key by key. Declared options are part
  of a scheduled activity's replay identity, so treat module defaults as
  values you will not change while runs are in flight — editing one shifts
  the identity of every activity in the module at once. `local: true` marks a local
  activity (runs inside the workflow task) and narrows the allowed options —
  local activities cannot heartbeat or target another task queue.

  Declaring `ctx` (or `context`) as the first argument opts the implementation
  into a `Temporalex.Activity.Context` — invisible to workflow-side callers.

  See `docs/rfcs/0003-activity-surface.md`.
  """

  alias Temporalex.Activity.Context

  # Mirrors the command builder's allowlist. Anything else raises at the
  # definition or the call — a misspelled option that silently does nothing
  # is the defect class the surface exists to remove.
  @dispatch_opts [
    :activity_id,
    :task_queue,
    :timeout,
    :schedule_to_close_timeout,
    :schedule_to_start_timeout,
    :start_to_close_timeout,
    :heartbeat_timeout,
    :headers,
    :retry_policy,
    :cancellation_type,
    :do_not_eagerly_execute
  ]

  # Local activities run inside the workflow task: no cross-queue dispatch,
  # no heartbeats, no eager-execution toggle.
  @local_dispatch_opts [
    :activity_id,
    :timeout,
    :schedule_to_close_timeout,
    :schedule_to_start_timeout,
    :start_to_close_timeout,
    :headers,
    :retry_policy,
    :cancellation_type
  ]

  defmacro __using__(opts) do
    quote do
      import Temporalex.Activity, only: [defactivity: 2, defactivity: 3]

      Module.register_attribute(__MODULE__, :temporalex_activities, accumulate: true)

      @temporalex_activity_defaults Temporalex.Activity.__module_defaults__!(
                                      __MODULE__,
                                      unquote(opts)
                                    )

      @before_compile Temporalex.Activity
    end
  end

  defmacro defactivity(head, do: body) do
    build_activity(__CALLER__, head, [], body)
  end

  defmacro defactivity(head, opts, do: body) when is_list(opts) do
    build_activity(__CALLER__, head, opts, body)
  end

  defmacro __before_compile__(_env) do
    quote do
      def __temporal_activities__, do: Enum.reverse(@temporalex_activities)
    end
  end

  @doc """
  Records a heartbeat for a running activity.

  Returns `:ok`, or `{:cancelled, reason}` when the server has requested
  cancellation — the duality is the point of heartbeating: it is how a
  long-running activity learns it should stop. Delegates to
  `Temporalex.Activity.Context.heartbeat/2`.
  """
  defdelegate heartbeat(context, details \\ nil), to: Context

  @doc "Whether cancellation has been requested for this activity."
  defdelegate cancelled?(context), to: Context

  @doc false
  def __dispatch_opts__(true), do: @local_dispatch_opts
  def __dispatch_opts__(false), do: @dispatch_opts

  @doc false
  def __module_defaults__!(module, defaults) do
    where = "use Temporalex.Activity in #{inspect(module)}"
    validate_single_timeout!(defaults, where)
    validate_keys!(defaults, @dispatch_opts, where, false)
    defaults
  end

  # :timeout and :start_to_close_timeout are two spellings of one knob (the
  # command builder reads them via find_option in that order). The set is
  # owned by the command builder; a staleness test pins this copy to it.
  @timeout_aliases [:timeout, :start_to_close_timeout]

  @doc false
  def __timeout_aliases__, do: @timeout_aliases

  @doc false
  # The one merge rule, applied at every layer (module defaults → per-activity
  # options → call-site options): an override supplying either timeout
  # spelling retires BOTH spellings from the base — otherwise a base :timeout
  # would outrank an override :start_to_close_timeout purely by the command
  # builder's alias order.
  def __merge_opts__(base, override) do
    base =
      if Enum.any?(@timeout_aliases, &Keyword.has_key?(override, &1)) do
        Keyword.drop(base, @timeout_aliases)
      else
        base
      end

    Keyword.merge(base, override)
  end

  @doc false
  # Runtime twin of the definition-time validation: call-site options must
  # survive the same allowlist, then override the declared options.
  def __call_opts__!(local?, declared, call_opts) do
    validate_single_timeout!(call_opts, "this activity call")
    validate_keys!(call_opts, __dispatch_opts__(local?), "this activity call", local?)
    __merge_opts__(declared, call_opts)
  end

  @doc false
  # Evaluation-time twin of the expansion-time check: module defaults are
  # only known once the module body runs, so the defaults+opts union is
  # validated here (spliced first into every defactivity's generated code).
  # Duplicate names are refused outright: two same-name activities would
  # share one wire type (the server registry would silently keep one) and
  # their generated default heads collide.
  def __validate_declared__!(module, name, local?, declared_keys, registered) do
    if Enum.any?(registered, &(&1.name == name)) do
      raise ArgumentError,
            "defactivity #{name} is already defined in #{inspect(module)} — " <>
              "activity names must be unique: the wire type derives from the " <>
              "name, so a second definition would shadow the first on the " <>
              "server. Use a different name (or name: to pin distinct wire types)"
    end

    validate_keys!(
      Enum.map(declared_keys, &{&1, true}),
      __dispatch_opts__(local?),
      "defactivity #{name} in #{inspect(module)} (module `use` defaults included)",
      local?
    )
  end

  @doc false
  # One result shape regardless of what delivered the cancellation: the real
  # codec hands a CancelledError struct, the testing kit a raw reason. The
  # normalization itself lives in Workflow.API so the bang and tuple paths
  # can never drift.
  defdelegate __cancelled_error__(reason),
    to: Temporalex.Workflow.API,
    as: :cancellation_error

  defp build_activity(caller, {name, meta, args_ast}, opts, body) when is_atom(name) do
    args_ast = args_ast || []
    {name_override, opts} = Keyword.pop(opts, :name)
    {local?, opts} = Keyword.pop(opts, :local, false)
    validate_identity_opts!(caller.module, name, name_override, local?)

    # Module defaults are set when the `use` line *evaluates*, which happens
    # after this macro *expands* — so they can only be read from generated
    # code. Per-activity opts have literal keys and validate right here.
    validate_single_timeout!(opts, "defactivity #{name} in #{inspect(caller.module)}")

    validate_keys!(
      opts,
      if(local?, do: @local_dispatch_opts, else: @dispatch_opts),
      "defactivity #{name} in #{inspect(caller.module)}",
      local?
    )

    impl_name = :"__#{name}__"
    bang_name = :"#{name}!"
    {dispatch_args, context?} = dispatch_args(args_ast)
    # The dispatch/bang wrappers always read every arg (to build the activity
    # input list), so strip any leading underscore the author used to mark the
    # arg unused in the implementation body. This lets `defactivity foo(_x)`
    # compile warning-free: the wrapper reads `x`, the impl leaves `_x` unused.
    # (A bare `_` has no name to read and is unsupported — args must be named.)
    validate_arg_shapes!(caller.module, name, args_ast)

    # The dispatch/bang wrappers forward values; they never destructure. So
    # their heads are opaque generated vars rather than the author's patterns.
    # That matters three ways: a bare `_` has no name to forward, two args
    # like (_x, x) would collide once the underscore was stripped, and a
    # pattern such as %{amount: amount} used to be re-built as an expression
    # in the input list — silently dropping every other key on the way to the
    # activity. The implementation keeps the author's patterns verbatim.
    public_args =
      dispatch_args
      |> Enum.with_index()
      |> Enum.map(fn {_arg, index} -> Macro.var(:"arg#{index}", __MODULE__) end)

    call_opts_var = Macro.var(:call_opts, __MODULE__)
    dispatch_head = {name, meta, public_args ++ [{:\\, [], [call_opts_var, []]}]}
    bang_head = {bang_name, meta, public_args ++ [{:\\, [], [call_opts_var, []]}]}

    type_ast =
      name_override || quote(do: "#{inspect(__MODULE__)}.#{unquote(Atom.to_string(name))}")

    declared_ast =
      quote(do: Temporalex.Activity.__merge_opts__(@temporalex_activity_defaults, unquote(opts)))

    dispatch_call = dispatch_call(local?)
    bang_dispatch_call = bang_dispatch_call(local?)

    quote do
      Temporalex.Activity.__validate_declared__!(
        __MODULE__,
        unquote(name),
        unquote(local?),
        Keyword.keys(@temporalex_activity_defaults) ++ unquote(Keyword.keys(opts)),
        @temporalex_activities
      )

      @temporalex_activities %{
        name: unquote(name),
        type: unquote(type_ast),
        implementation: unquote(impl_name),
        arity: unquote(length(public_args)),
        implementation_arity: unquote(length(args_ast)),
        context?: unquote(context?),
        local?: unquote(local?),
        opts: unquote(declared_ast)
      }

      def unquote(dispatch_head) do
        type = unquote(type_ast)
        input = [unquote_splicing(public_args)]

        opts =
          Temporalex.Activity.__call_opts__!(
            unquote(local?),
            unquote(declared_ast),
            unquote(call_opts_var)
          )

        unquote(dispatch_call)
      end

      def unquote(bang_head) do
        type = unquote(type_ast)
        input = [unquote_splicing(public_args)]

        opts =
          Temporalex.Activity.__call_opts__!(
            unquote(local?),
            unquote(declared_ast),
            unquote(call_opts_var)
          )

        unquote(bang_dispatch_call)
      end

      def unquote(impl_name)(unquote_splicing(args_ast)) do
        unquote(body)
      end
    end
  end

  # `type`, `input`, and `opts` are bound by the generated dispatch heads;
  # the quotes share this module's hygiene context, so the vars unify.
  defp dispatch_call(true) do
    quote do
      case Temporalex.Workflow.API.execute_local_activity(type, input, opts) do
        {:cancelled, error} -> {:error, Temporalex.Activity.__cancelled_error__(error)}
        other -> other
      end
    end
  end

  defp dispatch_call(false) do
    quote do
      case Temporalex.Workflow.API.execute_activity(type, input, opts) do
        {:cancelled, error} -> {:error, Temporalex.Activity.__cancelled_error__(error)}
        other -> other
      end
    end
  end

  defp bang_dispatch_call(true) do
    quote(do: Temporalex.Workflow.API.execute_local_activity!(type, input, opts))
  end

  defp bang_dispatch_call(false) do
    quote(do: Temporalex.Workflow.API.execute_activity!(type, input, opts))
  end

  defp validate_identity_opts!(module, name, name_override, local?) do
    unless is_nil(name_override) or is_binary(name_override) do
      raise ArgumentError,
            "name: on defactivity #{name} in #{inspect(module)} must be a literal " <>
              "string — it is the wire type Temporal schedules by"
    end

    unless is_boolean(local?) do
      raise ArgumentError,
            "local: on defactivity #{name} in #{inspect(module)} must be a literal boolean"
    end
  end

  # Both spellings of the timeout in ONE keyword list is a code defect —
  # find_option would keep :timeout and silently drop the other. Only ever
  # called on a single layer's list: ACROSS layers both spellings are legal,
  # because the override retires the base's aliases (__merge_opts__/2).
  defp validate_single_timeout!(opts, where) do
    case Enum.filter(@timeout_aliases, &Keyword.has_key?(opts, &1)) do
      [_, _ | _] = both ->
        raise ArgumentError,
              "#{inspect(both)} given together for #{where} — they are two " <>
                "spellings of one knob; keep exactly one"

      _ ->
        :ok
    end
  end

  defp validate_keys!(opts, allowed, where, local?) do
    unknown = opts |> Keyword.keys() |> Enum.uniq() |> Kernel.--(allowed)

    if unknown != [] do
      hint =
        cond do
          local? and :heartbeat_timeout in unknown ->
            " Local activities run inside the workflow task and cannot heartbeat — " <>
              "drop heartbeat_timeout: or make this a regular activity."

          local? and :task_queue in unknown ->
            " Local activities run on the workflow's own worker — task_queue: " <>
              "only applies to regular activities."

          true ->
            ""
        end

      raise ArgumentError,
            "unknown option(s) #{inspect(unknown)} for #{where} — " <>
              "allowed#{if local?, do: " for local: true", else: ""}: #{inspect(allowed)}." <>
              hint
    end

    :ok
  end

  defp dispatch_args([{name, _meta, context} | rest])
       when name in [:ctx, :context] and is_atom(context) do
    {rest, true}
  end

  defp dispatch_args(args), do: {args, false}

  # Default-valued arguments cannot work: dispatch appends its own optional
  # options argument, so `charge(amount, currency \\ "GBP")` would produce
  # arities 1..3 and `charge(100, [timeout: 5_000])` would be ambiguous — is
  # the list a currency or the call options? Refused with that explanation
  # rather than resolved cleverly.
  defp validate_arg_shapes!(module, name, args_ast) do
    Enum.each(args_ast, fn
      {:\\, _meta, [_arg, _default]} ->
        raise ArgumentError,
              "defactivity #{name} in #{inspect(module)} has a default-valued " <>
                "argument, which is not supported: the generated dispatch " <>
                "appends its own optional options argument, so the arities " <>
                "would overlap and a trailing keyword list would be ambiguous " <>
                "(currency or call options?). Define a second activity, or " <>
                "take a map and default inside the body."

      _arg ->
        :ok
    end)
  end
end
