defmodule Temporalex.Backend do
  @moduledoc """
  Server-facing backend boundary.

  Backends deliver decoded core structs to `Temporalex.Server` and accept core
  completions from it. Backend-specific transport, protobuf, native resources,
  and worker handles must stay behind this behaviour.
  """

  @type state :: term()

  @callback start_worker(opts :: keyword(), owner_pid :: pid()) ::
              {:ok, state()} | {:error, term()}

  @callback complete_workflow_activation(
              state(),
              Temporalex.Core.Completion.t()
            ) :: :ok | {:error, term()}

  @callback complete_activity_task(
              state(),
              Temporalex.Core.ActivityCompletion.t()
            ) :: :ok | {:error, term()}

  @callback record_activity_heartbeat(
              state(),
              task_token :: binary(),
              details :: term()
            ) :: :ok | {:error, term()}

  @callback shutdown_worker(state()) :: :ok | {:error, term()}
end
