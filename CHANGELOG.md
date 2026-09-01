# Changelog

## Unreleased

### Fixed

- **Signals arriving in the same activation as a cancel or a phase timeout are
  no longer discarded.** A cancel or the phase's own timeout marked the phase
  `stopping?` during pass one of activation processing, and
  `phase_accepts_signal?/2` then rejected every signal in pass two — so a phase
  cancelled or timed out alongside its own signals reported none of them.

  sdk-core sorts `SignalWorkflow` and `DoUpdate` ahead of `FireTimer` and
  `CancelWorkflow` before shipping an activation (`prepare_to_ship_activation`).
  Temporalex applied the two in the opposite order, which is why neither the Go
  SDK — where signals land on a buffered channel that cancellation never touches
  — nor the TypeScript SDK, which takes core's order as given, has this problem.

  A stop that lands on an open phase is now deferred until after the
  activation's signals and updates have been dispatched. Cancellation is still
  recorded immediately, so `API.cancelled?/0` and the refusal of new cancellable
  work are unchanged.

  This also affected the timeout path, which is not new to this release.

  **Breaking for runs in flight — read this before upgrading.** Messages that
  used to be refused now run, so a workflow task emits different commands than
  it did before. A run that took a cancel-with-signal, cancel-with-update or
  timeout-with-message workflow task under 0.5.4 or earlier, and then replays
  after the upgrade — on a worker restart, a cache eviction, or a reset —
  re-executes handlers whose responses have no counterpart in its history.
  sdk-core reports that as nondeterminism and fails the workflow task, so the
  run parks retrying rather than failing cleanly, and needs a reset to recover.

  Who is affected: only runs that were *parked in an `API.phase/2`* when a
  cancel or a phase timeout arrived alongside a signal or update. Runs that
  never took such a task are unaffected, as is anything started after the
  upgrade.

  What to do, in order of preference:

  1. **Drain.** Let phases complete before deploying. If your phases are short —
     minutes, not days — this costs nothing and there is no window.
  2. **Check before deploying.** `temporal workflow list --query
     'ExecutionStatus="Running"'` narrows it; runs parked in a phase are the
     ones to watch.
  3. **Reset after the fact.** A parked run reports its failed task via
     `Temporalex.History.stuck_reason/1`. Reset it to the workflow task before
     the bad one and it replays cleanly against the new code.

  Queries in an activation that also carries signals or updates are now answered
  after those handlers run, so a query sees the post-handler published state.
  Previously it saw the state as it stood before them. This changes an answer's
  value, not its determinism.

### Changed

- **Breaking: `API.phase/2` and `API.parallel/1` return `{:cancelled, error, partial}`**
  on cancellation, where they previously returned `{:cancelled, error}`. `partial`
  is the state the phase had accumulated, or every parallel branch's outcome in
  input order — cancelled branches as `{:error, %CancelledError{}}`.

  Cancellation is when compensation matters most, and both primitives were
  discarding the work they already held: a checkout cancelled after two of three
  payments settled could only compensate from the state as it stood *before* the
  wait, so those two were never refunded.

  **Migration.** A `case` on a phase or parallel result needs its cancellation
  branch widened:

  ```elixir
  # before
  {:cancelled, _error} -> Checkout.abandon(checkout, "cancelled")

  # after
  {:cancelled, _error, partial} -> Checkout.abandon(partial, "cancelled")
  ```

  A branch left as the two-tuple raises `CaseClauseError`, which fails the
  workflow — deliberately loud, because those are the branches losing data
  today. The bang forms are unchanged: `phase!/2` and `parallel!/1` still raise
  and discard the partial.

  The other seven operations that share this reply path — activities, local
  activities, and the five child-workflow calls — still return
  `{:cancelled, error}`. A cancelled activity has nothing to hand back.

## 0.5.4 — 2026-08-21

### Changed

- **The Rust NIF now builds against `temporalio/sdk-rust` v0.7.0** (from
  v0.4.0, three releases back). No Elixir-facing behaviour changes: the whole
  bump is absorbed inside the NIF, and the full suite — 466 tests including
  the live external ones — passes unchanged.

  What actually moved, for anyone tracing it: `WorkerDeploymentOptions`
  became `#[non_exhaustive]` with a builder; `VersioningBehavior` and
  `WorkflowExecutionStatus` now each exist in two crates as distinct types;
  a failed workflow arrives as `IncomingError` (which still exposes the proto
  `Failure` and its `cause`, so the failure tree is intact); cancelled and
  terminated results carry a `WorkflowResultDetails` wrapper;
  `WorkflowQueryError::Rejected` became a struct variant; and start options
  take typed `SearchAttributes` and `RetryPolicy` rather than raw protos —
  both converted inside the NIF so Temporal's typing does not reach the
  Elixir surface.

  The client's `WorkflowExecutionStatus` is also forward-compatible now, so
  an unrecognised status maps to `:unspecified` instead of being reported as
  something it is not.
- **`:priority` needs a current server, and the suite now says so.** Servers
  1.29.7 and 1.31.2 record all three fields exactly as sent; server 1.27.4 — the
  `temporalio/auto-setup:1.27` container in use locally when this was written —
  accepts them and silently drops them. The external suite now asserts the round-trip,
  so the difference fails loudly with the version to check instead of being
  rediscovered. Whether priority changes dispatch *order* is unresolved:
  measurements on trivial workflows were too noisy to call, and settling it
  needs the execution-concurrency limits we do not expose yet (issue #47). The
  option itself is unchanged.

  `TEMPORAL_ADDRESS` now points the version-sensitive tests at another server,
  so you can check against a current one without touching your local server.

### Fixed

- **`defactivity` argument shapes.** The generated dispatch wrappers used the
  author's argument patterns as *expressions* to build the activity input,
  which broke three ways. A bare `_` failed to compile with Elixir's "invalid
  use of `_`", blaming the language rather than the macro. Two arguments like
  `(_x, x)` collided once the underscore was stripped, turning the wrapper
  head into a match of `x` against itself. Worst, a **pattern argument was
  re-built** rather than forwarded — `defactivity charge(%{amount: amount})`
  sent `%{amount: amount}` to the activity, silently dropping every other key
  the caller passed. Wrappers now forward opaque values and never
  destructure; the implementation keeps the author's patterns.

  **Upgrading with runs in flight.** The input a scheduled activity carries is
  part of that command's replay identity, so a run that already scheduled a
  pattern-argument activity replays against the old input and fails the
  comparison. A nondeterminism failure is an activation failure, so such a run
  sticks with a retrying workflow task rather than failing cleanly, and needs
  a reset. Drain or complete those runs before upgrading. Runs that schedule
  activities with plain (non-pattern) arguments are unaffected, as are runs
  started after the upgrade.

  A child workflow start is compared by its whole command struct rather than a
  field list, so its input counts toward replay identity in the same way, and
  a child replays in its own history: a stuck child leaves its parent waiting
  on a result that never arrives.
- **Guarded heads work.** `defactivity positive(n) when is_integer(n)` used to
  fail with an error naming a `__when__/2` the author never wrote: a guarded
  head is `{:when, _, [call, guard]}` and `:when` is itself an atom, so the
  macro bound the activity name to `:when` and treated the real call and the
  guard as its two arguments. The guard now rides with the implementation,
  where it belongs — wrappers forward values, so there is nothing for them to
  guard. A value the guard rejects fails in the implementation on the worker,
  the same place a pattern mismatch surfaces.
- **A default inside a guarded head is refused too**, by the same check. It
  previously slipped past, for the reason above, and failed later as
  `undefined function \\/2`.
- **Default-valued arguments now refuse to compile, with the reason.**
  `defactivity charge(amount, currency \\ "GBP")` cannot work: dispatch
  appends its own optional options argument, so the arities overlap and
  `charge(100, [timeout: 5_000])` would silently swallow the call options as
  the default's value. Previously this failed with "undefined function
  `\\/2`". The refusal names the offending argument.

## 0.5.3 — 2026-08-19

### Added

- **`Temporalex.fail!/2`** raises an application failure from named options:
  `Temporalex.fail!("amount exceeds limit", type: "AmountTooLarge", retry: false)`.
  It delegates to `Temporalex.Failure.application!/2`, which stays. `retry:`
  maps to `retryable?:`. The error shape is unchanged, so this release is
  additive: activity dispatch still returns the
  `%Temporalex.Failure.ActivityError{}` wrapper with the raised error as its
  `cause`.
  `type:` must be a non-empty string and `retry:` a boolean; both are
  refused at the call site rather than downgraded or crashing later in the
  codec (an atom `type:` used to survive in-process and then be replaced by
  a generic default on the wire, so retry policies silently never matched).
- **`Temporalex.Failure.is_failure/2`** — a guard for matching a failure by
  its Temporal type, in `case`, `with`, and function heads:

  ```elixir
  import Temporalex.Failure, only: [is_failure: 2]

  {:error, e} when is_failure(e, "AmountTooLarge") -> refund(e)
  ```

  It checks the three depths Temporal nests failures at: the error itself (a
  local activity's failure arrives bare), its cause (a remote activity's is
  wrapped in `%ActivityError{}`), and its cause's cause (a child workflow
  wrapping one of those). A guard cannot recurse, so deeper nesting — nested
  child workflows — needs `failure?/2` below. The error stays whole, so
  `e.retry_state` and `e.activity_type` remain reachable. Shapes with no
  type to compare — a `nil` cause, an unstructured `raise`, a non-map
  reason — do not match rather than raising.
- **`Temporalex.Failure.failure?/2`** — the unbounded companion to the
  guard: walks the whole cause chain, at the cost of being a function rather
  than usable in `when`.
- **`Temporalex.Failure.types/1`, `type/1`, `cause/1`, `retry_state/1` and
  `activity_type/1`** — nil-safe accessors for logging and telemetry paths
  where patterns do not reach. `types/1` flattens the cause chain outermost
  first; `retry_state/1` and `activity_type/1` find their field at whatever
  depth it sits, so a child workflow's wrapper does not hide which activity
  failed or whether its retries were exhausted.

### Documented

- **Local and task-queue activity failures do not share a shape.** A failed
  task-queue activity reaches the workflow wrapped in
  `%Temporalex.Failure.ActivityError{}`. A failed `local: true` activity
  reaches it as the raised error itself, unwrapped. Workflow code cannot use
  one match for both. Behaviour is unchanged and was previously undocumented.
  Failed local activities now have test coverage in
  `test/temporalex/integration/local_activity_test.exs`, where they had none.

## 0.5.2 — 2026-08-18

### Added

- **`fetch_workflow_history/2,3` returns parsed history** (#27, breaking):
  `{:ok, %Temporalex.History{}}` with every event's id, server timestamp,
  kind (`:workflow_execution_started`, `:activity_task_scheduled`, …) and
  attributes. `raw: true` returns the encoded protobuf replay-fixture form
  (the old shape). The docstring's reference to a nonexistent
  `Temporalex.Replay` is gone (#35).
- **`Temporalex.Replay`** (#28): replay a recorded history against current
  workflow code — the pre-deploy compatibility check. `replay(history,
  workflows: [...])` returns `:ok` or `{:error, {:nondeterminism, detail}}`;
  `decode/1` reads `raw: true` fixture files for CI suites. Covers starts,
  activities (parallel and failed included, **inputs compared** — input
  drift is nondeterminism), timers, signals, cancellation,
  and terminals; anything else refuses loudly
  with `{:unsupported_event, type, id}` — a replay that skips part of the
  record proves nothing. Concretely: histories containing **patch markers,
  continue-as-new, child workflows, local activities, or updates** are
  declined outright for now (patches first on the roadmap) — a refusal,
  not a false verdict. Built on the deterministic executor's own
  divergence detection (not the vacuous core replay path abandoned in May).
- **`Temporalex.History.stuck_reason/1`** (#29): the SDK-native answer to
  "why is this workflow stuck" — reads the latest failed workflow task's
  failure message, cause, and event id out of history, no CLI or Web UI
  required. Plus `History.events/2` and `History.last/2` filters.

### Fixed

- **Failure messages now speak.** A workflow-task failure recorded from an
  exception carries the exception's own message, and non-exception reasons
  are inspected into the message rather than discarded — previously both
  collapsed to the string "Temporalex activation failure", which is what an
  operator saw in the UI and in `stuck_reason/1`.

## 0.5.1 — 2026-08-18

### Changed

- **A worker's task queue now has exactly one source** (#30, breaking).
  When the workflow modules declare `queue:`, passing `task_queue:` at all
  refuses to boot — a contradicting value made the worker poll the wrong
  queue while the modules' generated starts sat unclaimed forever, and an
  agreeing value is drift waiting to happen. When no module declares,
  `task_queue:` is **required**: the pre-RFC-0002 fallback of silently
  inheriting the client's queue is gone (Phase 2 of RFC 0002 §11, executed
  early). Migration: workers of queue-declaring modules drop `task_queue:`;
  activity-only and legacy workers state it explicitly. Also newly caught:
  workflow modules that disagree **among themselves** now raise even when an
  explicit `task_queue:` is present — the explicit value used to mask the
  broken module set entirely.
### Precompiled NIFs (#25)

- **Consumers no longer need a Rust toolchain or protoc.** `Temporalex.Native`
  now loads a precompiled NIF from the GitHub release matching the package
  version (mac arm64/x86_64, linux gnu/musl × arm64/x86_64, NIF 2.15),
  pinned by a checksum file shipped in the hex package. Set
  `TEMPORALEX_BUILD=1` to compile from source instead (requires Rust and
  protoc, exactly as before). Building from a checkout of this repo always
  compiles from source.
- Releases now build the NIF matrix in CI and attach artifacts to the
  GitHub release before publishing to hex; the same matrix validates on
  any PR touching `native/**`.

### Fixed

- **`schedule_to_close_timeout` no longer defaults to `start_to_close_timeout`**
  (#22). ScheduleToClose caps total time across all retry attempts, so the old
  default made the whole-order budget equal one attempt's budget — any attempt
  that timed out consumed the entire cap and the server reported the failure
  non-retryable, silently disabling timeout-driven retries. Fast-failing raises
  retried fine, which hid the bug until the first genuinely hung call. Now
  unset unless the caller passes `schedule_to_close_timeout:` (Temporal's own
  convention: capped by the workflow run timeout). Applies to regular and
  local activities.
  **Replay note (regular activities only):** the scheduled-activity command
  identity includes this field, so in-flight runs started under the old
  implicit default will fail replay on workers running this version. Drain
  in-flight runs across the upgrade, or pin the old behaviour explicitly
  with `schedule_to_close_timeout:` equal to your `start_to_close_timeout:`.
  Local activities are unaffected: their command identity carries the raw
  options, which this fix does not touch.

### The activity surface (RFC 0003)

- **Module-level option defaults**: `use Temporalex.Activity, start_to_close_timeout: 30_000`
  applies to every activity in the module; per-activity options override key
  by key.
- **`name:` on `defactivity`** decouples the wire type from the module name,
  so renaming a module no longer strands in-flight workflows that scheduled
  the old type.
- **Call-site keyword options on dispatch**: `Activities.charge!(amount, timeout: 10_000)`
  overrides the declaration for one call. Unknown options raise listing what
  is allowed — at the definition, at the call, and (new) on local-activity
  dispatch, which previously accepted anything and silently dropped it.
- **`local: true` definitions validate what local activities can honour** —
  `heartbeat_timeout:` or `task_queue:` on a local activity now refuses to
  compile with the why.
- **Giving both `timeout:` and `start_to_close_timeout:` in one option list
  raises** — they are two spellings of one knob and one would silently lose.
  (Across layers both remain legal: the override retires the base's aliases.)
- **`Temporalex.Testing.run_activity/4`** (and `run_activity!/4`) runs an activity's real
  implementation directly (no Temporal): fabricates a
  `Temporalex.Activity.Context` for `ctx`-taking activities, `context:`
  merges overrides, `cancelled: true` seeds a working cancellation flag.
- **Breaking: duplicate activity names in one module refuse to compile.**
  Previously `defactivity foo(a)` + `defactivity foo(a, b)` compiled but
  shared one wire type, and the server registry silently kept only one.
  Now the second definition raises at compile time.
- **Breaking: cancelled activities are `{:error, %Temporalex.Failure.CancelledError{}}`.**
  Generated dispatch no longer returns the third `{:cancelled, error}` shape;
  rewrite matches as `{:error, %Temporalex.Failure.CancelledError{} = e}`.
  (The low-level `Temporalex.Workflow.API.execute_activity/3` is unchanged.)
- **`Temporalex.Activity.heartbeat/2` and `cancelled?/1`** as short
  spellings of the `Context` verbs.

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
