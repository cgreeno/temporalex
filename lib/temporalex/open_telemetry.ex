defmodule Temporalex.OpenTelemetry do
  @moduledoc """
  OpenTelemetry integration for Temporalex.

  Attaches handlers to Temporalex telemetry events and converts them
  into OpenTelemetry spans with detailed timing and attributes.

  ## Setup

  Add to your application start:

      def start(_type, _args) do
        Temporalex.OpenTelemetry.setup()

        children = [
          {Temporalex, name: MyApp.Temporal, task_queue: "orders", ...}
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  ## Required dependencies

  Add these to your mix.exs:

      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"}

  ## Spans emitted

  - `temporalex.workflow.<type>` — Workflow execution (start to complete/fail)
  - `temporalex.activity.<type>` — Activity execution with duration
  - `temporalex.activation` — Server activation processing cycle

  Activity spans are linked to their parent workflow span when both are
  in the same worker process.

  ## Trace Context Propagation

  Use `inject_context/0` and `extract_context/1` to propagate trace context
  across Temporal workflow boundaries (e.g., in workflow headers).

  ## Attributes

  All spans include `temporal.*` attributes:
  - `temporal.workflow.id`, `temporal.workflow.type`, `temporal.workflow.run_id`
  - `temporal.activity.type`, `temporal.activity.id`
  - `temporal.task_queue`
  """

  require Logger

  @handler_id "temporalex-opentelemetry"

  @doc """
  Attach OpenTelemetry handlers to all Temporalex telemetry events.

  Returns `:ok` if OpenTelemetry is available, `{:error, :not_loaded}` otherwise.

  ## Options

  - `:prefix` — span name prefix (default: `"temporalex"`)
  """
  def setup(opts \\ []) do
    if otel_available?() do
      prefix = Keyword.get(opts, :prefix, "temporalex")

      events = [
        [:temporalex, :workflow, :start],
        [:temporalex, :workflow, :stop],
        [:temporalex, :workflow, :exception],
        [:temporalex, :activity, :start],
        [:temporalex, :activity, :stop],
        [:temporalex, :activity, :exception],
        [:temporalex, :worker, :activation]
      ]

      :telemetry.attach_many(
        @handler_id,
        events,
        &__MODULE__.handle_event/4,
        %{prefix: prefix}
      )

      Logger.info("Temporalex OpenTelemetry instrumentation attached")
      :ok
    else
      Logger.warning(
        "Temporalex OpenTelemetry setup skipped: opentelemetry_api not loaded. " <>
          "Add {:opentelemetry_api, \"~> 1.4\"} to your dependencies."
      )

      {:error, :not_loaded}
    end
  end

  @doc "Detach OpenTelemetry handlers."
  def teardown do
    :telemetry.detach(@handler_id)
  end

  @doc """
  Inject the current trace context into a map of string headers.

  Use this to propagate trace context through Temporal workflow headers.
  Returns a map like `%{"traceparent" => "00-...", "tracestate" => "..."}`.
  """
  @spec inject_context() :: %{String.t() => String.t()}
  def inject_context do
    if otel_available?() do
      # Dynamic call to avoid compile-time warnings for optional dependency
      apply(:otel_propagator_text_map, :inject, [%{}, &Map.put(&1, &2, &3)])
    else
      %{}
    end
  end

  @doc """
  Extract trace context from a map of string headers and set as the current context.

  Call this before creating spans to establish parent-child relationships
  across process/service boundaries.
  """
  @spec extract_context(%{String.t() => String.t()}) :: :ok
  def extract_context(headers) when is_map(headers) do
    if otel_available?() do
      # Dynamic call to avoid compile-time warnings for optional dependency
      apply(:otel_propagator_text_map, :extract, [headers, &Map.keys/1, &Map.get(&1, &2)])
    end

    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, config) do
    if otel_available?() do
      do_handle_event(event, measurements, metadata, config)
    end
  end

  # -- Workflow lifecycle --

  defp do_handle_event([:temporalex, :workflow, :start], _measurements, metadata, config) do
    tracer = :opentelemetry.get_application_tracer(:temporalex)
    wf_type = metadata[:workflow_type] || "unknown"
    span_name = "#{config.prefix}.workflow.#{wf_type}"

    attributes = [
      {"temporal.workflow.id", metadata[:workflow_id] || ""},
      {"temporal.workflow.type", wf_type},
      {"temporal.workflow.run_id", metadata[:run_id] || ""},
      {"temporal.task_queue", metadata[:task_queue] || ""}
    ]

    span_ctx = :otel_tracer.start_span(tracer, span_name, %{attributes: attributes})
    store_span_ctx(:workflow, metadata[:run_id], span_ctx)
  end

  defp do_handle_event([:temporalex, :workflow, :stop], measurements, metadata, _config) do
    case pop_span_ctx(:workflow, metadata[:run_id]) do
      nil ->
        :ok

      span_ctx ->
        duration_ms = native_to_ms(measurements[:duration])

        :otel_span.set_attributes(span_ctx, [
          {"temporal.workflow.result", to_string(metadata[:result])},
          {"temporal.workflow.duration_ms", duration_ms || 0}
        ])

        if metadata[:result] in [:error, :cancelled] do
          :otel_span.set_status(span_ctx, :error, to_string(metadata[:result]))
        end

        :otel_span.end_span(span_ctx)
    end
  end

  defp do_handle_event([:temporalex, :workflow, :exception], measurements, metadata, _config) do
    case pop_span_ctx(:workflow, metadata[:run_id]) do
      nil ->
        :ok

      span_ctx ->
        duration_ms = native_to_ms(measurements[:duration])

        :otel_span.set_attributes(span_ctx, [
          {"temporal.workflow.duration_ms", duration_ms || 0},
          {"error.kind", to_string(metadata[:kind])},
          {"error.message", inspect(metadata[:reason])}
        ])

        :otel_span.set_status(span_ctx, :error, inspect(metadata[:reason]))
        :otel_span.end_span(span_ctx)
    end
  end

  # -- Activity lifecycle --

  defp do_handle_event([:temporalex, :activity, :start], _measurements, metadata, config) do
    tracer = :opentelemetry.get_application_tracer(:temporalex)
    act_type = metadata[:activity_type] || "unknown"
    span_name = "#{config.prefix}.activity.#{act_type}"

    attributes = [
      {"temporal.activity.type", act_type},
      {"temporal.activity.id", metadata[:activity_id] || ""},
      {"temporal.task_queue", metadata[:task_queue] || ""}
    ]

    # Link to parent workflow span if available in this process
    links =
      case get_active_workflow_span() do
        nil ->
          []

        wf_span_ctx ->
          try do
            [
              %{
                span_id: :otel_span.span_id(wf_span_ctx),
                trace_id: :otel_span.trace_id(wf_span_ctx),
                attributes: []
              }
            ]
          rescue
            _ -> []
          end
      end

    opts = %{attributes: attributes}
    opts = if links != [], do: Map.put(opts, :links, links), else: opts

    span_ctx = :otel_tracer.start_span(tracer, span_name, opts)
    store_span_ctx(:activity, metadata[:activity_id], span_ctx)
  end

  defp do_handle_event([:temporalex, :activity, :stop], measurements, metadata, _config) do
    case pop_span_ctx(:activity, metadata[:activity_id]) do
      nil ->
        :ok

      span_ctx ->
        duration_ms = native_to_ms(measurements[:duration])

        :otel_span.set_attributes(span_ctx, [
          {"temporal.activity.result", to_string(metadata[:result])},
          {"temporal.activity.duration_ms", duration_ms || 0}
        ])

        if metadata[:result] == :error do
          :otel_span.set_status(span_ctx, :error, "activity failed")
        end

        :otel_span.end_span(span_ctx)
    end
  end

  defp do_handle_event([:temporalex, :activity, :exception], measurements, metadata, _config) do
    case pop_span_ctx(:activity, metadata[:activity_id]) do
      nil ->
        :ok

      span_ctx ->
        duration_ms = native_to_ms(measurements[:duration])

        :otel_span.set_attributes(span_ctx, [
          {"temporal.activity.duration_ms", duration_ms || 0},
          {"error.kind", to_string(metadata[:kind])},
          {"error.message", inspect(metadata[:reason])}
        ])

        :otel_span.set_status(span_ctx, :error, inspect(metadata[:reason]))
        :otel_span.end_span(span_ctx)
    end
  end

  # -- Activation (fire-and-forget span) --

  defp do_handle_event([:temporalex, :worker, :activation], measurements, metadata, config) do
    tracer = :opentelemetry.get_application_tracer(:temporalex)
    span_name = "#{config.prefix}.activation"
    duration_ms = native_to_ms(measurements[:duration])

    attributes = [
      {"temporal.activation.run_id", metadata[:run_id] || ""},
      {"temporal.task_queue", metadata[:task_queue] || ""},
      {"temporal.activation.job_count", measurements[:job_count] || 0},
      {"temporal.activation.command_count", measurements[:command_count] || 0},
      {"temporal.activation.duration_ms", duration_ms || 0}
    ]

    span_ctx = :otel_tracer.start_span(tracer, span_name, %{attributes: attributes})
    :otel_span.end_span(span_ctx)
  end

  # -- Helpers --

  defp otel_available? do
    Code.ensure_loaded?(:opentelemetry) and Code.ensure_loaded?(:otel_tracer)
  end

  defp store_span_ctx(kind, id, ctx) do
    Process.put({:temporalex_otel, kind, id}, ctx)

    # Also track the active workflow span for activity linking
    if kind == :workflow do
      Process.put(:temporalex_otel_active_workflow, ctx)
    end
  end

  defp pop_span_ctx(kind, id) do
    case Process.delete({:temporalex_otel, kind, id}) do
      nil ->
        if id do
          Logger.debug("OpenTelemetry span context not found",
            span_kind: kind,
            span_id: id
          )
        end

        nil

      ctx ->
        ctx
    end
  end

  defp get_active_workflow_span do
    Process.get(:temporalex_otel_active_workflow)
  end

  defp native_to_ms(nil), do: nil
  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
