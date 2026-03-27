# Changelog

## 0.1.0

Initial release.

- Workflow execution via Rust Core SDK NIFs
- Activity support with `defactivity` macro and `use Temporalex.Activity`
- Signals, queries, timers, and continue-as-new
- Versioning with `patched?/1` for replay-safe workflow evolution
- Retry policies on activities
- Client API: start, signal, query, cancel, terminate workflows
- `Temporalex.Testing` module for unit-testing workflows without Temporal server
- Telemetry events for workflows, activities, and worker activations
- Optional OpenTelemetry integration
- Graceful shutdown with in-flight activity draining
