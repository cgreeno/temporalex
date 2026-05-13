# Changelog

## 0.3.0

Architectural rewrite. The 0.x line is **not** backwards-compatible with 0.2.0.

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

### Known limitations

The following 0.2.0 features are **not yet present in 0.3.0** and are tracked
for follow-up releases:

- **Local activities** (`defactivity foo, local: true do ... end`,
  `API.execute_local_activity/3`). Returning after the core lands.
- **Child workflows.** Same — re-adding once the executor scheduler proves
  out in production use.
- **Structured error types** (`Temporalex.ActivityFailure`, `ApplicationError`,
  `CancelledError`, `NondeterminismError`, `TimeoutError`,
  `ChildWorkflowFailure`). Currently the runtime surfaces failures as
  raw error tuples; richer error types are queued.

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
