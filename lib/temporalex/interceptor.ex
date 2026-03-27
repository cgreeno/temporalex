defmodule Temporalex.Interceptor do
  @moduledoc """
  Behaviour for intercepting Temporal client and worker operations.

  Interceptors are middleware that wrap client calls and worker execution.
  Use them for auth token injection, logging, metrics, data masking, or
  any cross-cutting concern.

  ## Implementing an Interceptor

      defmodule MyApp.LoggingInterceptor do
        @behaviour Temporalex.Interceptor

        @impl true
        def intercept_client(:start_workflow, input, next) do
          Logger.info("Starting workflow", workflow_id: input[:workflow_id])
          next.(input)
        end

        def intercept_client(_operation, input, next), do: next.(input)

        @impl true
        def intercept_activity(activity_type, input, ctx, next) do
          start = System.monotonic_time()
          result = next.(input, ctx)
          duration = System.monotonic_time() - start
          Logger.info("Activity completed", type: activity_type, duration: duration)
          result
        end

        @impl true
        def intercept_workflow(workflow_type, args, next) do
          Logger.info("Workflow starting", type: workflow_type)
          next.(args)
        end
      end

  ## Configuration

      {Temporalex,
        name: MyApp.Temporal,
        interceptors: [MyApp.LoggingInterceptor, MyApp.AuthInterceptor],
        ...}

  Interceptors are called in order. Each must call `next` to continue the chain.
  """

  @type client_operation ::
          :start_workflow
          | :signal_workflow
          | :query_workflow
          | :cancel_workflow
          | :terminate_workflow
          | :describe_workflow
          | :list_workflows

  @doc """
  Intercept a client operation.

  `operation` identifies which client method is being called.
  `input` is a map of the operation's parameters.
  `next` is a function to call the next interceptor (or the real implementation).

  Must call `next.(input)` to continue, or return a result directly to short-circuit.
  """
  @callback intercept_client(client_operation(), map(), (map() -> term())) :: term()

  @doc """
  Intercept an activity execution.

  Called before the activity's `perform` function runs.
  `next` takes `(input, ctx)` and returns the activity result.
  """
  @callback intercept_activity(
              activity_type :: String.t(),
              input :: term(),
              ctx :: Temporalex.Activity.Context.t(),
              (term(), Temporalex.Activity.Context.t() -> term())
            ) :: term()

  @doc """
  Intercept a workflow execution.

  Called before the workflow's `run` function runs.
  `next` takes `(args)` and returns the workflow result.
  """
  @callback intercept_workflow(
              workflow_type :: String.t(),
              args :: term(),
              (term() -> term())
            ) :: term()

  @optional_callbacks [intercept_client: 3, intercept_activity: 4, intercept_workflow: 3]

  @doc """
  Build a client interceptor chain.

  Returns a function that, when called with `input`, runs through all
  interceptors then calls `final_fn`.
  """
  @spec chain_client(client_operation(), [module()], (map() -> term())) :: (map() -> term())
  def chain_client(_operation, [], final_fn), do: final_fn

  def chain_client(operation, [interceptor | rest], final_fn) do
    next = chain_client(operation, rest, final_fn)

    fn input ->
      if function_exported?(interceptor, :intercept_client, 3) do
        interceptor.intercept_client(operation, input, next)
      else
        next.(input)
      end
    end
  end

  @doc """
  Build an activity interceptor chain.
  """
  @spec chain_activity(String.t(), [module()], (term(), term() -> term())) ::
          (term(), term() -> term())
  def chain_activity(_type, [], final_fn), do: final_fn

  def chain_activity(activity_type, [interceptor | rest], final_fn) do
    next = chain_activity(activity_type, rest, final_fn)

    fn input, ctx ->
      if function_exported?(interceptor, :intercept_activity, 4) do
        interceptor.intercept_activity(activity_type, input, ctx, next)
      else
        next.(input, ctx)
      end
    end
  end

  @doc """
  Build a workflow interceptor chain.
  """
  @spec chain_workflow(String.t(), [module()], (term() -> term())) :: (term() -> term())
  def chain_workflow(_type, [], final_fn), do: final_fn

  def chain_workflow(workflow_type, [interceptor | rest], final_fn) do
    next = chain_workflow(workflow_type, rest, final_fn)

    fn args ->
      if function_exported?(interceptor, :intercept_workflow, 3) do
        interceptor.intercept_workflow(workflow_type, args, next)
      else
        next.(args)
      end
    end
  end
end
