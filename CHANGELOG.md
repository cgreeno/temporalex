# Changelog

## 0.3.1

### Interop: JSON payload codec

- **Inbound payloads** are now auto-detected by `encoding` metadata.
  Workers transparently decode `json/plain` payloads in addition to the
  default `binary/erlang-eterm`. Workflows can be started by the
  official `temporal` CLI (or the Python/Go/Java SDKs) with
  JSON-encoded inputs without configuration changes.
- **Outbound payloads** are configurable per worker via
  `payload_codec: :etf | :json` (default `:etf`). With `:json`,
  workflow results, activity completions, query responses, and
  update responses are encoded as `json/plain` — enabling
  `temporal workflow result` and other CLI rendering paths that don't
  understand ETF.
- JSON encoding is lossy by design (atoms collapse to strings, tuples
  serialize as `<unsupported>`). Workflows that need full Elixir term
  fidelity should keep the default ETF codec.

### Internal

- CI workflows (`.github/workflows/ci.yml`, `release.yml`) updated for
  the v0.3.0 crate rename and `--include external` integration filter.

163 tests pass (160 prior + 3 new — 1 CLI JSON-input + 2 JSON output
round-trip).

## 0.3.0

Architectural rewrite. The 0.x line is **not** backwards-compatible with 0.2.0.

### Feature surface (parity with 0.2.0)

- **Child workflows.** `API.execute_child_workflow/3` starts a child and
  blocks until it completes. Start failure, child failure, and child
  cancellation each surface as a structured `Temporalex.ChildWorkflowFailure`
  wrapping the underlying cause.
- **`API.signal_child_workflow/4`.** Send a durable signal to a child
  workflow by id. Blocks until Temporal confirms delivery (or fails).
  Works from inside `run/1`, parallel branches, sync handlers, and async
  update handlers.

### Bug fix in this release

- **Activation-time update race.** Updates arriving in the same activation
  as `InitializeWorkflow` (replay scenarios after a cache eviction) were
  being rejected with `{:not_accepting_update, _}` before the workflow
  runner had a chance to enter its phase. Fixed by processing activation
  jobs in two phases — input jobs (initialize, resolutions) first, drain
  scheduler to drain workflow code to its parked state, then message
  jobs (signals, updates, queries). Caught by the `update_workflow`
  integration test, which is now stable across runs.

- **Error unwrap consistency.** `fail_thread/3` now unwraps internal
  `{:exception, struct, stacktrace}` tuples uniformly across all thread
  kinds — root, parallel branch, phase dispatch, async update handler.
  Previously only root paths unwrapped, so a workflow that pattern-
  matched on `{:error, %ApplicationError{}}` would silently miss
  failures coming from `parallel/1` branches or `{:async, _, _}`
  handlers.

### Test coverage

160 tests total — 130 unit (against `Backend.Test`) and 30 live-Temporal
integration tests including 6 CLI-driven tests that exercise the
external-tooling interop path (`temporal workflow start/signal/describe/
cancel/terminate/list`).

The core design — deterministic cooperative scheduler, `Temporalex.Backend`
boundary, phase / parallel / scheduler rounds — is authored by
[@hansihe](https://github.com/hansihe). See
[`docs/scheduler_and_replay.md`](docs/scheduler_and_replay.md) and
[`docs/implementation_principles.md`](docs/implementation_principles.md) for
the design source-of-truth.

### What changed

- **Deterministic cooperative scheduler.** The executor owns thread ordering;
  BEAM scheduling and mailbox arrival no longer affect command emission order.
  `parallel` branches and handler dispatches have stable thread ids and run in
  deterministic rounds. This eliminates a latent replay correctness gap in
  0.2.0 where parallel command order depended on activity timing.
- **Backend boundary.** `Temporalex.Backend` is a behaviour. Two implementations
  ship: `Temporalex.Backend.TemporalCore` (Rustler + Temporal Core, production)
  and `Temporalex.Backend.Test` (in-memory, deterministic, for unit tests).
  All Rust / NIF / protobuf details live inside the backend; the executor
  speaks `%Temporalex.Core.Activation{}` / `%Temporalex.Core.Completion{}`.
- **Layer split.** Worker (supervisor) → Server (orchestration, backend state,
  executor registry, activity task supervision) → Executor (deterministic
  workflow state) → Backend (transport).
- **Internal protocol as structs.** `Temporalex.Core.{Activation, Job.*,
  Command.*, Completion, Op.*}` replace the tuple-and-keyword-list messages
  used in 0.2.0. Easier to read, harder to misuse.

### Public API changes

- **`API.receive/2` → `API.phase/2`.** Same shape (reducer state, signal /
  update handlers, optional `:timeout`), better name (`receive` is a BEAM
  keyword).
- **`Temporalex.Client`** is handle-based: `start_workflow/4` returns a
  `%Client.Handle{}`; subsequent operations (`signal_workflow`,
  `query_workflow`, `update_workflow`, `get_result`, `cancel_workflow`,
  `terminate_workflow`, `describe_workflow`) take the handle. `update_workflow`
  is now first-class — no more CLI workaround.
- **Workflow execution returns a typed activation transcript.** Workflows
  return `{:ok, result}` / `{:error, reason}` / `{:continue_as_new, args}` —
  same as 0.2.0.
- **`API.side_effect/1` removed.** It was knowingly non-durable across cache
  evictions in 0.2.0; the design admits primitives only when they have a
  precise replay contract. Use an activity (or a local activity once
  re-added — see Known limitations).
- **Worker config.** Workers now take a `:name` and `:backend` module:
  ```elixir
  {Temporalex.Worker,
   name: MyApp.Temporal,
   backend: Temporalex.Backend.TemporalCore,
   target: "http://127.0.0.1:7233",
   namespace: "default",
   task_queue: "checkout",
   workflows: [...],
   activities: [...]}
  ```

### Restored from 0.2.0

- **Local activities.** `defactivity foo, local: true do ... end` plus
  `API.execute_local_activity/3`. Runs the activity body on the worker
  that scheduled it, with durability via Temporal's history-marker
  mechanism. Verified end-to-end against a live Temporal server.
- **Structured error types** with full proto round-trip:
  `Temporalex.ApplicationError` (type, message, non_retryable, details),
  `CancelledError`, `TimeoutError`, `ActivityFailure` (wraps a cause and
  carries activity identity), `ChildWorkflowFailure`, `NondeterminismError`.
  Raised in an activity, they reach the workflow as
  `%ActivityFailure{cause: %ApplicationError{...}}` with the right fields
  on the wire and in the Temporal UI.

### Known limitations

- **Child workflows.** Not yet re-added in 0.3.0. Tracked for 0.3.1
  alongside cascading cancel and signal-child surface.

### Migration from 0.2.0

`0.2.0` was a clean-slate prototype with the same package name. There are no
production users we're aware of, so there is no migration path documented.
If you were experimenting with 0.2.0, treat 0.3.0 as a fresh start:

- rename `API.receive/2` → `API.phase/2`
- remove any `API.side_effect/1` calls (use an activity)
- update worker config to take `:name` and `:backend`
- update client calls to use a handle returned by `start_workflow/4`

### Build & test

- Tests use `Temporalex.Backend.Test` and do not require a Temporal server.
- Integration tests (`@moduletag :external`) require `temporal server start-dev`
  and run via `mix test --include external`.
- NIF builds against `temporalio/sdk-rust` v0.4.0 (was `temporalio/sdk-core`
  pinned rev in 0.2.0).

## 0.2.0

First public release on Hex. Superseded by 0.3.0.

The 0.2.0 surface (`API.receive`, `defactivity ..., local: true`, child
workflows, `Temporalex.Converter`, etc.) is preserved in git history at tag
`v0.2.0` for reference but is no longer maintained. See
[git log v0.2.0](https://github.com/cgreeno/temporalex/releases/tag/v0.2.0)
for the original release notes.
