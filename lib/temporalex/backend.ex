defmodule Temporalex.Backend do
  @moduledoc """
  Backend boundary for Temporal client and worker transport.

  Backends own client resources, worker resources, and protocol translation.
  They deliver decoded core structs to `Temporalex.Server`, accept core
  completions from it, and execute public client operations for
  `Temporalex.Client`. Backend-specific transport, protobuf, native resources,
  and worker handles must stay behind this behaviour.
  """

  @type client_state :: term()
  @type worker_state :: term()

  @callback start_client(opts :: keyword(), owner_pid :: pid()) ::
              {:ok, client_state()} | {:error, term()}

  @callback shutdown_client(client_state()) :: :ok | {:error, term()}

  @callback start_worker(client_state(), opts :: keyword(), owner_pid :: pid()) ::
              {:ok, worker_state()} | {:error, term()}

  @callback start_workflow(
              client_state(),
              workflow_type :: binary(),
              input :: term(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback get_workflow_result(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @callback signal_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              signal_name :: binary(),
              args :: list(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @callback query_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              query_name :: binary(),
              args :: list(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @callback update_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              update_name :: binary(),
              args :: list(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @callback cancel_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @callback terminate_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @callback describe_workflow(
              client_state(),
              workflow_id :: binary(),
              run_id :: binary() | nil,
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @callback complete_workflow_activation(
              worker_state(),
              Temporalex.Core.Completion.t()
            ) :: :ok | {:error, term()}

  @callback complete_activity_task(
              worker_state(),
              Temporalex.Core.ActivityCompletion.t()
            ) :: :ok | {:error, term()}

  @callback record_activity_heartbeat(
              worker_state(),
              task_token :: binary(),
              details :: term()
            ) :: :ok | {:error, term()}

  @callback shutdown_worker(worker_state()) :: :ok | {:error, term()}
end
