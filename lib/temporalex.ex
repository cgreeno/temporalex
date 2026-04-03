defmodule Temporalex do
  @moduledoc """
  Workflow orchestration framework for Elixir built on Temporal.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Temporalex.Runtime
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Temporalex.Supervisor)
  end
end
