# Observability

Temporalex emits telemetry events and supports OpenTelemetry for distributed tracing.

## Telemetry Events

Every workflow, activity, and activation emits `:telemetry` events:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:temporalex, :workflow, :start]` | — | workflow_id, workflow_type, run_id, task_queue |
| `[:temporalex, :workflow, :stop]` | duration | workflow_id, workflow_type, run_id, result |
| `[:temporalex, :workflow, :exception]` | duration | workflow_id, workflow_type, kind, reason |
| `[:temporalex, :activity, :start]` | — | activity_type, activity_id, task_queue |
| `[:temporalex, :activity, :stop]` | duration | activity_type, activity_id, result |
| `[:temporalex, :activity, :exception]` | duration | activity_type, activity_id, kind, reason |
| `[:temporalex, :worker, :activation]` | duration, job_count, command_count | run_id, task_queue |

### Attaching a Handler

```elixir
:telemetry.attach("my-handler", [:temporalex, :workflow, :stop], fn event, measurements, metadata, _config ->
  duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

  Logger.info("Workflow completed",
    workflow_type: metadata.workflow_type,
    duration_ms: duration_ms,
    result: metadata.result
  )
end, nil)
```

### With Telemetry.Metrics

```elixir
[
  Telemetry.Metrics.counter("temporalex.workflow.stop.count", tags: [:workflow_type, :result]),
  Telemetry.Metrics.distribution("temporalex.workflow.stop.duration",
    unit: {:native, :millisecond},
    tags: [:workflow_type]
  ),
  Telemetry.Metrics.counter("temporalex.activity.stop.count", tags: [:activity_type, :result])
]
```

## OpenTelemetry

For distributed tracing across services, add the OpenTelemetry dependencies:

```elixir
{:opentelemetry, "~> 1.5"},
{:opentelemetry_api, "~> 1.4"},
{:opentelemetry_exporter, "~> 1.8"}
```

Then set up in your application start:

```elixir
def start(_type, _args) do
  Temporalex.OpenTelemetry.setup()

  children = [
    {Temporalex, name: MyApp.Temporal, ...}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

This creates spans for every workflow and activity:

- `temporalex.workflow.ProcessOrder` — with workflow_id, run_id, task_queue attributes
- `temporalex.activity.ChargePayment` — linked to the parent workflow span

### Trace Context Propagation

Propagate trace context across service boundaries:

```elixir
# Before starting a workflow from an HTTP handler
headers = Temporalex.OpenTelemetry.inject_context()
# Pass headers through workflow input or Temporal headers

# Inside a workflow or activity
Temporalex.OpenTelemetry.extract_context(headers)
# Subsequent spans will be children of the original trace
```

## What's Next

Review all [configuration options](configuration.md).
