defmodule Temporalex.Interceptor do
  @moduledoc """
  Wraps client operations so cross-cutting concerns can observe and extend them.

  An interceptor sees the operation name and its options, may change the options,
  and calls `next` to continue the chain. Register them on a client:

      {Temporalex.Client,
       name: MyApp.Temporal,
       backend: Temporalex.Backend.TemporalCore,
       target: "http://127.0.0.1:7233",
       namespace: "default",
       interceptors: [MyApp.Tracing, MyApp.Auth]}

  They run outside-in: the first in the list wraps the second, and so on, with
  the real operation innermost. This is the hook for trace-context injection,
  logging, metrics, and auth headers.

  Interceptors do not apply to `Temporalex.Testing`, which is an in-process
  harness rather than a client.

  ## Trace context, and why this is client-side only

  Temporal propagates context in workflow headers, so an interceptor injects it
  by adding to `:headers`:

      defmodule MyApp.Tracing do
        @behaviour Temporalex.Interceptor

        alias Temporalex.Interceptor.Context

        @impl true
        def intercept(%Context{operation: :start_workflow}, opts, next) do
          headers = Map.put(Keyword.get(opts, :headers, %{}), "traceparent", current_traceparent())
          next.(Keyword.put(opts, :headers, headers))
        end

        def intercept(%Context{}, opts, next), do: next.(opts)
      end

  Client operations are never replayed, so an interceptor here may do whatever it
  likes — read the clock, mint an id, call out to a service.

  That is **not** true inside a workflow. Workflow code is re-executed on replay
  and must emit the same commands every time, so a value minted per call (a fresh
  span id, say) would land in a command and differ on replay — nondeterminism.
  Propagating context onward from a workflow therefore means copying values that
  came from history, never generating new ones. See
  `docs/scheduler_and_replay.md`. Workflow-side interception is deliberately not
  part of this module.

  ## Failure

  An interceptor is ordinary code in the caller's process. If it raises, the
  operation raises — it is not isolated, and it must not be used for anything the
  caller's correctness depends on being optional.
  """

  defmodule Context do
    @moduledoc """
    What is being intercepted.

    A struct rather than a bare operation atom so fields can be added without
    breaking every existing interceptor. Match on `:operation` and ignore the
    rest:

        def intercept(%Context{operation: :start_workflow}, opts, next), do: ...
        def intercept(%Context{}, opts, next), do: next.(opts)
    """

    defstruct [:operation, :client]

    @type t :: %__MODULE__{operation: atom(), client: term()}
  end

  @typedoc "Continues the chain with (possibly modified) options."
  @type next :: (keyword() -> term())

  @doc """
  Wraps a client operation, returning whatever the operation returns.

  Call `next.(opts)` exactly once. Not calling it short-circuits the operation,
  which is legitimate but rarely intended. Calling it twice runs the operation
  twice and returns the second result — for `start_workflow` that means the
  second attempt is an already-started error, returned in place of the handle.

  Write a catch-all clause. Validation cannot check clause coverage, so an
  interceptor that only matches `:start_workflow` passes startup and then raises
  `FunctionClauseError` on the first other operation.
  """
  @callback intercept(Context.t(), opts :: keyword(), next()) :: term()

  @doc false
  # Outside-in: the head wraps the tail, the real operation is innermost.
  def run([], %Context{}, opts, fun), do: fun.(opts)

  def run([interceptor | rest], %Context{} = context, opts, fun) do
    interceptor.intercept(context, opts, fn next_opts ->
      run(rest, context, next_opts, fun)
    end)
  end
end
