# Changelog

## 0.2.0

First public release on Hex.

`0.2.0` is a clean rewrite. The pre-release `0.1.0` SDK was never published;
the API is intentionally not backwards-compatible with that version.

### Programming model

Workflows read top-to-bottom as sequential code. Concurrency is explicit and
structured — the only ways to introduce it are `API.receive/2` (a message
loop with signal/update handlers) and `API.parallel/1` (concurrent fan-out).
Every spawned handler must complete before the receive returns.

### Features

- `Temporalex.Workflow` — workflow modules with `run/1` and `handle_query/3`.
- `Temporalex.Activity` — `defactivity` macro for both regular and
  `local: true` activities. Local activities are durable across worker
  crashes (recorded in workflow history).
- `Temporalex.Workflow.API`:
  - Sequential primitives: `execute_activity/3`, `execute_local_activity/3`,
    `sleep/1`, `wait_for_signal/1`, `publish_state/1`, `patched?/1`,
    `cancelled?/0`.
  - Structured concurrency: `receive/2` with signal/update handlers and an
    optional `:timeout`; `parallel/1` for fan-out.
  - Async-only: `update_state/1` for atomic mutations from inside an
    `{:async, fn, _}` handler.
- `Temporalex.Worker` — supervisor for one task queue. Drop into an OTP
  supervision tree.
- `Temporalex.Client` — start, signal, query, cancel workflows from
  outside workflow code.
- `Temporalex.Testing` — step-by-step test driver. The same call protocol
  as the production executor, so workflow code is unchanged between
  tests and real runs.
- ETF as the default payload encoding (preserves full Elixir type fidelity).

### Robustness

This release shipped after several rounds of bug-hunting. Notable fixes
worth knowing about:

- **Updates respond end-to-end.** Update handler return values are now
  emitted as `UpdateResponse` commands (Accepted → Completed / Rejected).
  Without this, the Temporal Update API caller would hang until update
  timeout.
- **Multi-signal-in-one-activation.** When Temporal delivers several
  signals in a single activation, all handlers run in dispatch order and
  every state mutation lands.
- **Cancelled activities and child workflows replay correctly.** Replay
  log builds entries for `:cancelled` resolutions; runtime apply path
  handles them. Local-activity backoffs are filtered from the replay log.
- **Receive timer / handler stop race.** Timer fires while a sync handler
  is in flight; first stop wins, executor doesn't crash on a cleared
  `receive_from`.
- **Heartbeat details encode as a Payload.** Details now round-trip
  through Temporal history with metadata intact, instead of being sent
  as raw ETF bytes.
- **Bounded buffers.** `signal_buffer` and `pending_handler_queue` are
  capped (defaults: 10_000 each, configurable per executor). Floods drop
  oldest with a warning; updates beyond the queue cap surface a
  `:rejected` response instead of hanging.
- **Worker shutdown awaits drain.** `terminate/2` calls the async
  `shutdown_worker` NIF and waits up to 30s (configurable) for Core to
  finish in-flight activations before returning.
- **Server crash takes the worker tree with it.** Worker supervisor uses
  `:one_for_all` so a Server crash doesn't leave executors orphaned with
  stale `WorkerResource` references.
- **Query and validator handlers are crash-protected.** A throwing or
  exiting query/validator no longer kills the executor — surfaces as
  `{:error, _}` to the caller.
- **Native command encoding propagates errors.** Malformed commands and
  malformed payloads inside command lists now surface as `{:error, _}`
  from `encode_workflow_completion` instead of silently disappearing.

### Status

Suitable for evaluation and small-scale production. 301 unit tests + 28
integration tests pass against a live Temporal dev server. The API surface
in `Temporalex.Workflow.API` is stable for `0.2.x`; lower-level modules
(`Worker.Server`, `Worker.Executor`, `Native`) are public for testing
hooks but not part of the API contract — those will likely change.
