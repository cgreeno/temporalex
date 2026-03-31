# Temporalex — Roadmap

Everything that needs to happen after v0.1.0.

## v0.2 — Missing Features

| # | Item | Impact | Effort |
|---|------|--------|--------|
| F1 | Signal-with-start — atomic start + signal in one client call | High | Small — new NIF + Client wrapper |
| F2 | Async activity completion — activity completes externally via token | High | Medium — new NIF + Activity.Context API |
| F3 | Workflow replayer — replay from JSON history without a server | High | Medium — new module, uses Core SDK replay |
| F4 | Schedules API — create, pause, trigger, backfill schedules | Medium | Medium — new NIFs + Client wrappers |
| F5 | Core SDK metrics bridge — expose Rust Prometheus metrics via :telemetry | Medium | Medium — Rust metric callback + Elixir bridge |

## v0.2 — Polish

| # | Item | Impact | Effort |
|---|------|--------|--------|
| P1 | Telemetry: add payload size measurements to workflow/activity events | Low | Small |
| P2 | `ApplicationError.type` empty string vs nil — normalize on encode/decode | Low | Small |
| P3 | Error types: add optional `stacktrace` field to ActivityFailure/ApplicationError | Medium | Small |
| P4 | FailureConverter: preserve `details` field on round-trip | Low | Small |
| P5 | Consolidate `bugfix_test.exs` into relevant test files | Low | Small |

## v0.2 — Test Coverage

### Unit tests

| # | Item | Status |
|---|------|--------|
| T1 | RetryPolicy (defaults, new/1, to_proto, ms_to_duration) | DONE — 12 tests |
| T2 | Activity perform/1 vs perform/2 compile-time enforcement | DONE — 6 tests |
| T3 | Connection lifecycle (validation, defaults, get/1) | DONE — 7 tests |
| T4 | Client internals (resolve_connection, argument validation) | DONE — 7 tests |
| T5 | Activity cancel race — server-level test | DONE — 2 tests |
| T6 | Concurrent completion attribution test | DONE — 3 tests |

### E2E tests

| # | Item | Status |
|---|------|--------|
| T7 | Workflow ID reuse — AlreadyStarted error | DONE |
| T8 | Parallel activities — fan-out 5 activities, collect results | DONE |
| T9 | Child workflow lifecycle — parent starts child, gets result | DONE |
| T10 | Saga pattern — activity fails, compensations run | DONE |
| T11 | Activity retry exhausted — max_attempts reached | DONE |
| T12 | Activity non-retryable error — stops immediately | DONE |
| T13 | Signal ordering — send A, B, C; receive A, B, C | DONE |
| T14 | Query after workflow completes | DONE |

### Conformance tests

| # | Item | Status |
|---|------|--------|
| T15 | Start conformance suite against `temporalio/features` repo | TODO |

## Done (v0.1.0)

All completed during architecture review sessions:

### Bugs (11)
- [x] BUG-1: NIF send_and_clear silent failures (12 sites)
- [x] BUG-3: ChildWorkflowFailure missing from FailureConverter
- [x] BUG-4: NIF resource lifetime not enforced
- [x] BUG-5: defactivity silently drops multi-arg
- [x] BUG-6: OTel span lookup silent failure
- [x] FIX-1: side_effect/1 crashes executor
- [x] FIX-2: Activity cancel duplicate completion
- [x] FIX-3: completing_run_id global attribution
- [x] FIX-4: Telemetry duration always zero
- [x] FIX-5: connect_client DirtyCpu -> DirtyIo
- [x] FIX-6: Activity failures missing ApplicationFailureInfo (Temporal server rejects bare Failure protos)

### Reliability (5)
- [x] Poll failure exponential backoff with jitter
- [x] Config validation (max_concurrent, address format)
- [x] Async NIF timeouts on completions + client ops
- [x] shutdown_worker 30s timeout
- [x] Connection retry with backoff (3 attempts)

### Ease of Use (6)
- [x] sleep/1 docs, guards, :timer examples, max bound
- [x] Signal simulation in Testing (send_signal, :signals opt)
- [x] Child workflow stubs in Testing (stub_child_workflow, :child_workflows opt)
- [x] from_payload! includes encoding + data_bytes in errors
- [x] README updated with all undocumented features
- [x] random/0 and uuid4/0 exposed in Workflow.API

### Naming & Conventions (4)
- [x] max_concurrent_activities -> max_concurrent_activity_tasks
- [x] start_workflow vs execute_workflow documented
- [x] Removed unused _namespace param from connect_client NIF
- [x] Standardized NIF error format ({e} not {e:?})

### Features (5)
- [x] API key auth + custom headers on Connection
- [x] describe_workflow and list_workflows on Client
- [x] OpenTelemetry trace context propagation (inject/extract, typed span names, linking)
- [x] Payload Codec behaviour (encryption/compression)
- [x] Interceptor framework

### Docs & Infra
- [x] README rewrite — billboard + checkout flow quickstart + badges
- [x] 16 guide pages (installation, workflows, activities, signals, timers, child workflows, errors, DSL, testing, observability, config, production, 4 recipes)
- [x] GitHub repo (cgreeno/temporalex)
- [x] CI workflow (lint + unit tests + E2E with Temporal dev server)
- [x] Hex release workflow (tag-triggered + manual dispatch)
