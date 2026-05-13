defmodule Temporalex.Worker do
  @moduledoc """
  Supervisor for one Temporalex worker instance.
  """

  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    worker_name = Keyword.fetch!(opts, :name)
    server_name = server_name(worker_name)
    executor_supervisor_name = executor_supervisor_name(worker_name)
    activity_supervisor_name = activity_supervisor_name(worker_name)

    server_opts =
      opts
      |> Keyword.put(:server_name, server_name)
      |> Keyword.put(:executor_supervisor, executor_supervisor_name)
      |> Keyword.put(:activity_supervisor, activity_supervisor_name)

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: executor_supervisor_name},
      {Task.Supervisor, name: activity_supervisor_name},
      {Temporalex.Server, server_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def server_name(worker_name), do: Module.concat(worker_name, Server)
  def executor_supervisor_name(worker_name), do: Module.concat(worker_name, ExecutorSupervisor)
  def activity_supervisor_name(worker_name), do: Module.concat(worker_name, ActivitySupervisor)

  def server_pid(worker_name) when is_atom(worker_name) do
    worker_name
    |> server_name()
    |> Process.whereis()
  end

  def server_pid(pid) when is_pid(pid), do: pid
end
