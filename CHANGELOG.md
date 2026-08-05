# Changelog

## 0.5.0 — 2026-08-05

### The client surface (RFC 0002, Phase 1)

- **`use Temporalex.Workflow` takes `queue:`, `name:`, and `client:`** and —
  when `queue:` is given — generates the call-side surface: `new/2`,
  `start!/2`, `execute!/2`, `signal!/4`, `query!/4`, and tuple-returning
  twins (all `defoverridable`). The shortest call is now
  `Greet.execute!("Fresha")`.
- **`id/1` derives the workflow id from the input** — Temporal's idempotency
  key, stated once on the module instead of invented at every call site.
  Starting with neither `id/1` nor `id:` raises with instructions;
  `:generate` is the deliberate opt-out and stays a sentinel until the
  terminal verb, so a reused `%Start{}` draws a fresh id per start.
  `input/1` (optional) maps the caller's value to the durable input.
- **Duplicate starts attach by default.** The generated surface pins
  `id_conflict_policy: :use_existing` (Temporal's own default *fails*
  duplicates); pass `id_conflict_policy: :fail` for loud duplicates.
- **`Temporalex.Start` + chain steps on `Temporalex`**: `id`, `queue`,
  `client`, `input`, `timeout`, `retry`, `priority`, `fairness`, `index`,
  `headers`, `cron`, `run_timeout`, `execution_timeout`; terminal verbs
  `start!`/`execute!` (and twins); `await!`/`await` on handles. Builders are
  inert; a chain has exactly one terminal verb. A `timeout` on a
  `start!`-ended chain rides the handle as the later await's default.
- **The generated surface and the chain both raise inside workflow code** —
  a live client call on replay is nondeterminism; the error points at the
  child-workflow API. Activities are unaffected.
- **Workers derive their queue** from the workflow modules (`Code.ensure_loaded?`
  first, so lazily-loaded dev environments derive correctly), with a boot
  error when modules disagree; `name:` and `client:` default too. The legacy
  inherit-the-client's-queue fallback survives this phase and dies in
  Phase 2.
- **An unnamed `Temporalex.Client` now registers as the default client**
  (`Temporalex.Client`), so single-connection apps configure nothing.
  `name: nil` keeps a client deliberately unregistered. Two unnamed clients
  — previously legal — now collide at boot.
- `Temporalex.await/2` is the primary way to collect a result;
  `Client.get_result/2` remains and is soft-deprecated in docs.
- The low-level random-workflow-id fallback now logs a warning pointing at
  `id/1` / `id: :generate`; it raises in Phase 2.
- `__workflow_defaults__/0` (generated, documented, read by nothing) is
  removed.

## 0.4.2 — 2026-08-03

- Fix worker-crash blast radius: the poller bridge was spawn_linked from
  inside the client process, so a violently-killed worker propagated an exit
  through the bridge link and took the shared client down with it. The
  bridge now monitors its owning worker (no link) and exits when it does.
- Fix task-queue lockout after a violent worker death: the owner-death
  monitor on the worker resource was attached from a tokio thread with a
  NULL env, which the BEAM only honours from ERTS-created threads. The attach
  failed and its error was discarded (`let _ =`), so `down/4` never fired,
  the sdk-core `SlotKey` stayed registered, and supervised restarts on the
  same task queue failed indefinitely with "Registration of multiple
  workers ...". The monitor is now attached from the owning server via a new
  `monitor_worker/1` NIF (a real NIF context), and the death path drives the
  worker shutdown so the registration is released. Measured queue release
  after a `:kill` is ~0.75s, letting supervised restarts succeed. Covered by
  a new external regression test in `temporal_worker_restart_test.exs`.

## 0.4.1 — 2026-08-03

- Fix Hex packaging: ship `priv/proto/temporal_core.binpb` — the Elixir proto
  codec compiles its schema from this descriptor, and 0.4.0 omitted it from
  the package files, breaking every consumer install.

## 0.4.0 — 2026-08-02 (breaking)

### Failure vocabulary unified on `Temporalex.Failure.*`

The legacy `Temporalex.*` failure structs are removed in favour of the
structured failure model under `Temporalex.Failure.*` (the vocabulary the
Rust NIF encodes and decodes). Migration map:

| Removed (`Temporalex.*`)      | Replacement (`Temporalex.Failure.*`) | Field change              |
| ----------------------------- | ------------------------------------ | ------------------------- |
| `ApplicationError`            | `Failure.ApplicationError`           | `non_retryable: b` → `retryable?: not b` |
| `CancelledError`              | `Failure.CancelledError`             | —                         |
| `TimeoutError`                | `Failure.TimeoutError`               | —                         |
| `ActivityFailure`             | `Failure.ActivityError`              | —                         |
| `ChildWorkflowFailure`        | `Failure.WorkflowExecutionError`     | —                         |

`Temporalex.NondeterminismError` is retained (no `Failure.*` equivalent).
Activity/workflow code that raised or matched the old structs must switch to
the `Failure.*` structs; `retryable?: false` replaces `non_retryable: true`.
`Failure` details are a list of detail payloads (use `Failure.application/2`,
which `List.wrap`s them).

### Metrics

Core telemetry was previously unreachable: the runtime was built with
`RuntimeOptions::default()`, which hardcodes it off, so no SDK metrics were
exported at all. Clients now accept a `:telemetry` option carrying one
exporter.

- **`telemetry: [prometheus: [bind_address: "0.0.0.0:9464"]]`** starts a
  Prometheus endpoint serving core's worker metrics — `num_pollers`,
  `worker_task_slots_used`, `workflow_task_schedule_to_start_latency`,
  `workflow_task_execution_latency`, `workflow_endtoend_latency`, and others.
  `schedule_to_start` is the metric worth autoscaling workers on.
- **`telemetry: [otlp: [url: "http://localhost:4317"]]`** exports over OTLP
  instead, with `:protocol` (`:grpc` / `:http`), `:metric_temporality`
  (`:cumulative` / `:delta`), `:metric_periodicity_ms`, and `:headers`. This
  turns on the `otel` feature of `temporalio-common`.
- Shared keys: `:global_tags`, `:metric_prefix`, `:attach_service_name`,
  `:durations_as_seconds`. `:prometheus` and `:otlp` are mutually exclusive.
- Metrics remain **off by default** — omitting `:telemetry` behaves exactly as
  before: no exporter, no bound port.

### Configurable build id

- **`build_id: "..."`** on a worker replaces the hardcoded
  `temporalex-<crate version>`, which made every worker on a given SDK version
  indistinguishable. The build id is stamped on every `WorkflowTaskCompleted`
  event, so history and the Web UI can attribute a task to a release.
- Identification only — the versioning strategy remains `None`, so routing is
  unaffected. Worker Deployment Versioning is still not exposed.

## 0.3.2

### Non-blocking child workflows + cancel

- **`API.start_child_workflow/3`** returns a `%Temporalex.ChildHandle{}`
  as soon as the child is started by Temporal (does NOT block until
  completion). The parent can then signal, cancel, or `await_child_workflow/1`
  the result on its own schedule.
- **`API.await_child_workflow/1`** blocks until the child reaches a
  terminal state and returns the result tuple. If the child completed
  before `await_child_workflow/1` was called, the cached result is
  returned immediately (no extra activation).
- **`API.cancel_child_workflow/1`** sends a durable `RequestCancelExternalWorkflowExecution`
  to the child by workflow id. Blocks until Temporal confirms delivery.
- `API.signal_child_workflow/4` and `API.cancel_child_workflow/2` both
  accept a `ChildHandle` or a raw workflow id, for ergonomics.
- `API.execute_child_workflow/3` (blocking) stays unchanged — it's the
  composition of start + await.

### Tests

177 tests pass (172 prior + 5 new — 3 unit + 2 live-Temporal
integration covering start+signal+await and start+cancel+await).

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
