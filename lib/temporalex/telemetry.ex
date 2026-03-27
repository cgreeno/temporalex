defmodule Temporalex.Telemetry do
  @moduledoc """
  Telemetry events emitted by Temporalex.

  ## Workflow Events

    * `[:temporalex, :workflow, :start]` — Workflow execution started
      - Measurements: `%{system_time: integer()}`
      - Metadata: `%{workflow_id: String.t(), workflow_type: String.t(), run_id: String.t(), task_queue: String.t()}`

    * `[:temporalex, :workflow, :stop]` — Workflow execution completed
      - Measurements: `%{duration: integer()}` (native time units)
      - Metadata: `%{workflow_id: String.t(), workflow_type: String.t(), run_id: String.t(), result: :ok | :error | :continue_as_new}`

    * `[:temporalex, :workflow, :exception]` — Workflow execution crashed
      - Measurements: `%{duration: integer()}`
      - Metadata: `%{workflow_id: String.t(), workflow_type: String.t(), run_id: String.t(), kind: :error | :exit | :throw, reason: term()}`

  ## Activity Events

    * `[:temporalex, :activity, :start]` — Activity execution started
      - Measurements: `%{system_time: integer()}`
      - Metadata: `%{activity_type: String.t(), activity_id: String.t(), task_queue: String.t()}`

    * `[:temporalex, :activity, :stop]` — Activity execution completed
      - Measurements: `%{duration: integer()}`
      - Metadata: `%{activity_type: String.t(), activity_id: String.t(), result: :ok | :error}`

    * `[:temporalex, :activity, :exception]` — Activity execution crashed
      - Measurements: `%{duration: integer()}`
      - Metadata: `%{activity_type: String.t(), activity_id: String.t(), kind: :error | :exit | :throw, reason: term()}`

  ## Worker Events

    * `[:temporalex, :worker, :activation]` — Worker processed an activation
      - Measurements: `%{duration: integer(), job_count: integer(), command_count: integer()}`
      - Metadata: `%{run_id: String.t(), task_queue: String.t()}`

  ## Attaching Handlers

      :telemetry.attach_many(
        "my-temporalex-handler",
        [
          [:temporalex, :workflow, :start],
          [:temporalex, :workflow, :stop],
          [:temporalex, :activity, :stop]
        ],
        &MyApp.TemporalexHandler.handle_event/4,
        nil
      )
  """

  @doc false
  def workflow_start(metadata) do
    :telemetry.execute(
      [:temporalex, :workflow, :start],
      %{system_time: System.system_time()},
      metadata
    )

    System.monotonic_time()
  end

  @doc false
  def workflow_stop(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:temporalex, :workflow, :stop],
      %{duration: duration},
      metadata
    )
  end

  @doc false
  def workflow_exception(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:temporalex, :workflow, :exception],
      %{duration: duration},
      metadata
    )
  end

  @doc false
  def activity_start(metadata) do
    :telemetry.execute(
      [:temporalex, :activity, :start],
      %{system_time: System.system_time()},
      metadata
    )

    System.monotonic_time()
  end

  @doc false
  def activity_stop(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:temporalex, :activity, :stop],
      %{duration: duration},
      metadata
    )
  end

  @doc false
  def activity_exception(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:temporalex, :activity, :exception],
      %{duration: duration},
      metadata
    )
  end

  @doc false
  def worker_activation(duration, metadata) do
    :telemetry.execute(
      [:temporalex, :worker, :activation],
      %{
        duration: duration,
        job_count: Map.get(metadata, :job_count, 0),
        command_count: Map.get(metadata, :command_count, 0)
      },
      metadata
    )
  end
end
