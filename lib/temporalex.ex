defmodule Temporalex do
  @moduledoc """
  Durable workflows for Elixir, on Temporal.

  The shortest honest call:

      greeting = Greet.execute!("Fresha")

  A workflow module declares what it *is* — behaviour, identity, address —
  and `use Temporalex.Workflow` generates the call-side surface:

      defmodule Greet do
        use Temporalex.Workflow, queue: "greetings"

        @impl true
        def id(name), do: "greet-\#{name}"

        @impl true
        def run(name), do: {:ok, "Hello, \#{name}!"}
      end

  This module holds what happens *between* building a start and running it:
  the chain steps that shape a `Temporalex.Start`, the terminal verbs that
  perform it, and `await` for collecting a result later.

      booking_id
      |> Booking.new()
      |> Temporalex.retry(max_attempts: 3)
      |> Temporalex.fairness(salon_id)
      |> Temporalex.index(salon_id: salon_id)
      |> Temporalex.execute!()

  Builders are inert; terminal verbs run; a bang raises. A chain has exactly
  one terminal verb, at the end — everything before it is data.

  See `docs/rfcs/0002-client-surface.md` for the full design.
  """

  alias Temporalex.Client
  alias Temporalex.Start

  @default_client Temporalex.Client

  ## Chain steps — each takes and returns a %Start{}; none touch Temporal.

  @doc "Overrides the workflow id (`id/1` normally derived it in `new`)."
  @spec id(Start.t(), String.t() | :generate) :: Start.t()
  def id(%Start{} = start, id) when is_binary(id), do: %{start | id: id}
  def id(%Start{} = start, :generate), do: %{start | id: :generate}

  @doc "Overrides the task queue — for starting on someone else's queue."
  @spec queue(Start.t(), String.t()) :: Start.t()
  def queue(%Start{} = start, queue) when is_binary(queue), do: %{start | queue: queue}

  @doc "Selects a named client instead of the default one."
  @spec client(Start.t(), atom()) :: Start.t()
  def client(%Start{} = start, client) when is_atom(client), do: %{start | client: client}

  @doc "Overrides the durable input — rare: when address and input diverge."
  @spec input(Start.t(), term()) :: Start.t()
  def input(%Start{} = start, input), do: %{start | input: input}

  @doc """
  How long a waiter waits. Expiring never touches the workflow.

  On an `execute!` ending this bounds the call; on a `start!` ending it is
  carried on the handle as the default for a later `await!`.
  """
  @spec timeout(Start.t(), pos_integer() | :infinity) :: Start.t()
  def timeout(%Start{} = start, timeout)
      when (is_integer(timeout) and timeout > 0) or timeout == :infinity,
      do: %{start | timeout: timeout}

  @doc "Workflow retry policy."
  @spec retry(Start.t(), keyword()) :: Start.t()
  def retry(%Start{} = start, policy) when is_list(policy),
    do: put_opt(start, :retry_policy, policy)

  @doc "Queue priority band — smaller is higher."
  @spec priority(Start.t(), pos_integer()) :: Start.t()
  def priority(%Start{} = start, key) when is_integer(key) and key >= 1,
    do: merge_opt(start, :priority, priority_key: key)

  @doc """
  Fair dispatch key, typically a tenant id — tasks sharing a key are
  dispatched in proportion to their weight, so one noisy tenant cannot
  monopolise a queue.
  """
  @spec fairness(Start.t(), String.t() | integer(), float()) :: Start.t()
  def fairness(%Start{} = start, key, weight \\ 1.0) when is_number(weight),
    do: merge_opt(start, :priority, fairness_key: to_string(key), fairness_weight: weight)

  @doc """
  Indexed search attributes — machine-findable via
  `temporal workflow list --query`. The unindexed, human-readable counterpart
  is the memo.
  """
  @spec index(Start.t(), keyword() | map()) :: Start.t()
  def index(%Start{} = start, attributes) do
    attributes = Map.new(attributes, fn {k, v} -> {to_string(k), v} end)
    merge_map_opt(start, :search_attributes, attributes)
  end

  @doc "Header payloads — usually an interceptor's job, not the call site's."
  @spec headers(Start.t(), keyword() | map()) :: Start.t()
  def headers(%Start{} = start, headers) do
    headers = Map.new(headers, fn {k, v} -> {to_string(k), v} end)
    merge_map_opt(start, :headers, headers)
  end

  @doc """
  A signal delivered atomically with the start — signal-with-start.

  The workflow is signalled if it is already running and started if it is
  not, in one request, so the signal cannot be lost between a check and a
  send. Use it where an external event can arrive before the workflow it
  belongs to exists.

      order_id
      |> Checkout.new()
      |> Temporalex.with_signal("payment_settled", [settlement])
      |> Temporalex.start!()

  The signal is delivered before the workflow's first task, so it lands
  before any `phase/2` has declared a handler for it. It waits in the signal
  buffer and is consumed when a phase that handles it opens.

  Refused in combination, because Temporal's signal-with-start request cannot
  carry them: `priority/2` and `fairness/3`, and `id_conflict_policy: :fail`.
  `retry/2`, `cron/2`, `index/2`, `headers/2` and both timeouts are carried.

  A duplicate reports `Temporalex.WorkflowAlreadyStartedError` with its run id,
  the same as a plain start.
  """
  @spec with_signal(Start.t(), String.t(), list()) :: Start.t()
  def with_signal(%Start{} = start, name, args \\ [])
      when is_binary(name) and name != "" and is_list(args),
      do: put_opt(start, :start_signal, name: name, args: args)

  @doc "Cron schedule for a recurring workflow."
  @spec cron(Start.t(), String.t()) :: Start.t()
  def cron(%Start{} = start, expression) when is_binary(expression),
    do: put_opt(start, :cron_schedule, expression)

  @doc """
  One run's lifetime. Consequential: expiry destroys the run without
  compensation — which is why there is no default.
  """
  @spec run_timeout(Start.t(), pos_integer()) :: Start.t()
  def run_timeout(%Start{} = start, ms) when is_integer(ms) and ms > 0,
    do: put_opt(start, :run_timeout, ms)

  @doc """
  The whole chain's lifetime, retries and continue-as-new included. As
  consequential as `run_timeout/2`, and as deliberately undefaulted.
  """
  @spec execution_timeout(Start.t(), pos_integer()) :: Start.t()
  def execution_timeout(%Start{} = start, ms) when is_integer(ms) and ms > 0,
    do: put_opt(start, :execution_timeout, ms)

  ## Terminal verbs — the only functions here that touch Temporal.

  @doc """
  Performs the start and returns `{:ok, handle}` — nobody waits.

  A duplicate start (same workflow id, still running) attaches to the
  existing execution by default (`id_conflict_policy: :use_existing`); pass
  `id_conflict_policy: :fail` on `new/2` to make duplicates loud errors.
  """
  @spec start(Start.t()) :: {:ok, Client.Handle.t()} | {:error, Exception.t()}
  def start(%Start{} = start) do
    # The generated wrappers guard too, but the chain form must be equally
    # refused — `new(...) |> Temporalex.start!()` inside workflow code is the
    # same replay nondeterminism as the short form.
    Temporalex.Workflow.refuse_inside_workflow!(start.workflow, :start)
    Start.refuse_dropped_with_signal_opts!(start.opts)

    opts =
      start.opts
      |> Keyword.put(:workflow_id, resolve_generate(start.id))
      |> Keyword.put(:task_queue, start.queue)
      |> Keyword.put_new(:id_conflict_policy, :use_existing)

    with {:ok, handle} <-
           Client.start_workflow(resolve_client(start), start.workflow, start.input, opts) do
      {:ok, %{handle | await_timeout: start.timeout}}
    end
  end

  @doc "Like `start/1` but returns the handle and raises on failure."
  @spec start!(Start.t()) :: Client.Handle.t()
  def start!(%Start{} = start), do: start |> start() |> unwrap!()

  @doc "Performs the start and waits for the result: `start/1` + `await/2`."
  @spec execute(Start.t()) :: {:ok, term()} | {:error, Exception.t()}
  def execute(%Start{} = start) do
    with {:ok, handle} <- start(start) do
      await(handle)
    end
  end

  @doc "Like `execute/1` but returns the result and raises on failure."
  @spec execute!(Start.t()) :: term()
  def execute!(%Start{} = start), do: start |> execute() |> unwrap!()

  ## Awaiting — collect a result from a handle, now or much later.

  @doc """
  Waits for the workflow's result.

  A timeout is the *caller* giving up: the workflow keeps running and the
  handle stays valid, so awaiting again later is legitimate. The wait bound
  is `opts[:timeout]`, else the timeout the start chain carried onto the
  handle, else the client's `workflow_result_timeout` (60 seconds by
  default).
  """
  @spec await(Client.Handle.t(), keyword()) :: {:ok, term()} | {:error, Exception.t()}
  def await(%Client.Handle{} = handle, opts \\ []) do
    Temporalex.Workflow.refuse_inside_workflow!(handle.workflow_type, :await)

    case Keyword.get(opts, :timeout) || handle.await_timeout do
      nil -> Client.get_result(handle, opts)
      timeout -> Client.get_result(handle, Keyword.put(opts, :timeout, timeout))
    end
  end

  @doc "Like `await/2` but returns the result and raises on failure."
  @spec await!(Client.Handle.t(), keyword()) :: term()
  def await!(%Client.Handle{} = handle, opts \\ []), do: handle |> await(opts) |> unwrap!()

  @doc """
  Raises an application failure describing a business outcome.

      Temporalex.fail!("amount exceeds limit", type: "AmountTooLarge", retry: false)

  Called from an activity, this fails the current attempt. Temporal retries
  it under the activity's retry policy unless `retry: false`. `type:` is the
  stable string that retry policies and workflow matches key on.

  Called from workflow code, this fails the workflow. That is final unless
  the workflow was started with a retry policy, in which case `retry: false`
  makes it final.

  Options: `type:` (a non-empty string — the wire value Temporal matches
  retry policies against; anything else, `nil` included, is refused rather
  than silently replaced when encoded — omit the option to get the default
  type), `retry:` (`true` or `false`, default `true`),
  `details:`. Use `Temporalex.Failure.application!/2` to set a nested
  `:cause`.
  """
  @spec fail!(String.t() | atom()) :: no_return()
  def fail!(message), do: fail!(message, [])

  @spec fail!(String.t() | atom(), keyword()) :: no_return()
  def fail!(message, opts) when is_list(opts) do
    case Enum.uniq(Keyword.keys(opts)) -- [:type, :retry, :details] do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) #{inspect(unknown)} for Temporalex.fail!/2. " <>
                "allowed: [:type, :retry, :details]"
    end

    {retry, opts} = Keyword.pop(opts, :retry, true)
    validate_retry!(retry)

    case Keyword.fetch(opts, :type) do
      :error -> :ok
      {:ok, type} -> validate_type!(type)
    end

    Temporalex.Failure.application!(message, Keyword.put(opts, :retryable?, retry))
  end

  # Validated here rather than left to the codec: `non_retryable: not retryable?`
  # raises a bare "argument error" at the encoding boundary, naming neither
  # fail!/2 nor retry:, and by then the activity has already failed.
  defp validate_retry!(retry) when is_boolean(retry), do: :ok

  defp validate_retry!(retry) do
    raise ArgumentError,
          "retry: must be true or false, got: #{inspect(retry)}"
  end

  # A non-binary type is worse than unsupported: it survives in-process (so a
  # unit test matching on it passes) and is then replaced by the generic
  # default when the codec encodes it, so retry policies and remote matches
  # silently never fire. Refused rather than stringified, because coercing
  # would break an in-process match on the original term instead.
  defp validate_type!(type) when is_binary(type) and type != "", do: :ok

  defp validate_type!(type) do
    raise ArgumentError,
          "type: must be a non-empty String.t(), got: #{inspect(type)} — it is " <>
            "the wire string Temporal matches retry policies and other SDKs " <>
            "against, and a non-string is replaced by a generic default when " <>
            "encoded"
  end

  @doc false
  def default_client, do: @default_client

  @doc false
  def unwrap!(result) do
    case result do
      {:ok, value} -> value
      :ok -> :ok
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  defp resolve_client(%Start{client: nil}), do: @default_client
  defp resolve_client(%Start{client: client}), do: client

  # Generation happens at the terminal verb: a reused %Start{} built with
  # :generate must start a fresh execution each time, not attach to the id
  # its first use happened to draw.
  defp resolve_generate(:generate), do: Start.generate_id()
  defp resolve_generate(id) when is_binary(id), do: id

  defp put_opt(%Start{} = start, key, value),
    do: %{start | opts: Keyword.put(start.opts, key, value)}

  defp merge_opt(%Start{} = start, key, kv) do
    merged = start.opts |> Keyword.get(key, []) |> Keyword.merge(kv)
    %{start | opts: Keyword.put(start.opts, key, merged)}
  end

  defp merge_map_opt(%Start{} = start, key, map) do
    merged = start.opts |> Keyword.get(key, %{}) |> Map.merge(map)
    %{start | opts: Keyword.put(start.opts, key, merged)}
  end
end
