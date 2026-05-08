# Production Readiness Review

Review date: May 8, 2026.

This document tracks the implementation review performed after the native Temporal Core integration. It compares the current Temporalex surface against the local Temporal documentation in `../../documentation`, Temporal API protos in `../../temporal-api`, and the checked-out Temporal Core SDK in `../../temporal-sdk-core`.

The current architecture looks broadly sane for Elixir: workflow command construction is executor-owned, backend transport stays behind `Temporalex.Backend`, workflow code uses BEAM processes for durable blocking, and the Rust NIF wraps Temporal Core without exposing protobufs to workflow code. The remaining items below are the issues that keep the library from being production-ready.

## High Priority

### Search Attributes Must Be Server-Readable

Status: completed on May 8, 2026.

Original concern:

- `native/temporalex_nif/src/lib.rs` uses `term_to_payload_map/1` for headers and search attributes.
- `payload_from_term/1` encodes values as ETF payloads with `encoding = binary/erlang-eterm`.
- Temporal Search Attributes are indexed visibility fields; Temporal's proto states that Search Attribute payloads are not user-defined serialization.
- Temporal Core's own payload visitor skips Search Attribute payload encoding so the server can read them.

Implemented:

- Added `Temporalex.SearchAttribute` typed constructors for Bool, Datetime, Double, Int, Keyword, KeywordList, and Text values.
- Kept ETF encoding for normal payloads and switched Search Attribute maps to `json/plain` payloads in the native encoder.
- Wired typed Search Attributes through workflow start and `Workflow.API.upsert_search_attributes/1`.
- Added constructor/unit tests, native codec validation coverage, and a Temporal dev-server visibility test that registers custom Search Attributes, upserts from workflow code, and lists by Search Attribute query.

References:

- `../native/temporalex_nif/src/lib.rs`: `payload_from_term`, `term_to_payload_map`, workflow start search attributes, upsert search attributes.
- `../../temporal-api/temporal/api/common/v1/message.proto`: `Payload`, `SearchAttributes`.
- `../../temporal-sdk-core/crates/common/src/payload_visitor.rs`: search attributes skipped during payload encoding.
- `../../documentation/docs/encyclopedia/visibility/search-attributes.mdx`: supported Search Attribute types and visibility behavior.

Remaining follow-up:

- Reuse the same typed encoder when continue-as-new and child workflow Search Attributes are added.

### Workflow Cancellation Semantics Are Incomplete

Status: completed on May 8, 2026.

Original concern:

- `Job.CancelWorkflow` only sets `cancelled?: true`.
- `Workflow.API.cancelled?/0` only reads that flag.
- Cancellation does not unblock timers, signal waits, phases, activities, parallel branches, or update/signal handlers.
- `{:cancelled, reason}` drops the cancellation reason/details when emitting `Command.CancelWorkflow`.
- Temporal distinguishes graceful cancellation from termination. Cancellation should schedule workflow code so it can clean up.

Implemented:

- Added `Workflow.API.cancellation/0` and `Workflow.API.non_cancellable/1`.
- Workflow cancellation now interrupts cancellable blocking primitives by raising `%Temporalex.Failure.CancelledError{}`.
- `sleep`, signal waits, activities, phases, async phase handlers, and parallel branches are unblocked or canceled through executor-owned deterministic state transitions.
- The executor emits `CancelTimer` and `RequestCancelActivity` commands where appropriate and ignores late resolutions for operations canceled with immediate semantics.
- Activity cancellation honors `:wait_cancellation_completed`, `:try_cancel`, and `:abandon`.
- Terminal `Command.CancelWorkflow` now carries the structured cancellation reason internally.
- Added pure core tests plus Temporal dev-server coverage for timer and activity cancellation.

References:

- `../lib/temporalex/core/executor.ex`: `Job.CancelWorkflow`, `Cancelled` op, root `{:cancelled, _reason}` handling.
- `../lib/temporalex/core/structs.ex`: `Command.CancelWorkflow`.
- `../native/temporalex_nif/src/lib.rs`: `CancelWorkflowExecution` command encoding.
- `../../temporal-api/temporal/api/command/v1/message.proto`: `CancelWorkflowExecutionCommandAttributes.details`.
- `../../documentation/docs/develop/rust/workflows/cancellation.mdx`: cancel versus terminate behavior.

Remaining follow-up:

- Temporalex preserves terminal cancellation details in core structs, but Temporal Core's local `CancelWorkflowExecution` command currently exposes no details field, so real-server canceled results may not include those details until Core exposes that field.
- Add real-server coverage for cancellation while blocked in update handlers and parallel branches if those scenarios prove flaky in production-like workloads.

### Failure Modeling Is Too Flat

Status: completed on May 8, 2026.

Original concern:

- `failure_from_term/2` turns every workflow, query, and update failure into `Temporalex.ApplicationError`.
- `non_retryable` is always false.
- Failure details are a single ETF payload of the original term.
- Retry policies using `non_retryable_error_types` cannot be expressed well by users.

Implemented:

- Added public `Temporalex.Failure` structs for application, cancellation, timeout, activity, child workflow, and unknown failures.
- Exposed application failure retry control as `retryable?`, which maps to the inverse of Temporal's `ApplicationFailureInfo.non_retryable`.
- Preserved failure `cause` recursively when decoding server/core failures and when encoding decoded wrappers back to Temporal.
- Routed workflow, activity, query, and update rejection failures through the structured native encoder.
- Added core, codec, and Temporal dev-server tests proving `retryable?`, `non_retryable_error_types`, and activity retry attempts are observed by Temporal.

References:

- `../native/temporalex_nif/src/lib.rs`: `failure_from_term`, `failure_to_term`.
- `../../temporal-api/temporal/api/common/v1/message.proto`: `RetryPolicy.non_retryable_error_types`.
- `../../temporal-api/temporal/api/failure/v1/message.proto`: Temporal failure variants.

Remaining follow-up:

- Decide whether update-specific rejected/completed errors need a dedicated public wrapper once update ergonomics are revisited.
- Decide whether raised non-Temporalex exceptions should default `ApplicationError.type` to the exception module name.

### Continue-As-New Is Under-Modeled

Status: open.

Current concern:

- Workflow code can only return `{:continue_as_new, args}`.
- The NIF encodes only workflow type, task queue, and arguments.
- Temporal supports run timeout, task timeout, retry policy, header, memo, search attributes, start backoff, and versioning behavior on continue-as-new.

References:

- `../lib/temporalex/core/executor.ex`: root `{:continue_as_new, args}` handling.
- `../native/temporalex_nif/src/lib.rs`: `ContinueAsNewWorkflowExecution` command encoding.
- `../../temporal-api/temporal/api/command/v1/message.proto`: `ContinueAsNewWorkflowExecutionCommandAttributes`.
- `../../documentation/docs/develop/rust/workflows/continue-as-new.mdx`: continue-as-new usage and suggestion API.

Needed:

- Add a workflow API helper for continue-as-new with options.
- Support continue-as-new options that Temporal Core exposes and that fit deterministic workflow semantics.
- Carry typed Search Attributes through the new Search Attribute encoder.
- Expose `continue_as_new_suggested` and history length/size through workflow info if not already complete.
- Add core tests and real-server tests for chained runs and option propagation.

## Medium Priority

### Client Should Not Require A Running Worker

Status: open.

Current concern:

- `Temporalex.Client` routes operations through a running `Temporalex.Worker` and its backend state.
- This is convenient for local integration tests but is not the usual SDK model.
- A production client should be usable from web processes, jobs, IEx, or services that do not host workflow workers.

References:

- `../lib/temporalex/client.ex`: public client API and worker lookup.
- `../lib/temporalex/backend/temporal_core.ex`: native client operations.

Needed:

- Introduce a supervised client process or resource independent of workers.
- Keep worker APIs ergonomic by allowing workers to reuse an existing client or build one from config.
- Ensure handles can be used with a client without retaining a worker name.

### Missing Client Operations And Options

Status: open.

Current concern:

The current client covers start, get result, signal, query, execute update, cancel, terminate, and describe. Useful SDK primitives/options are still missing:

- Signal-with-start.
- Start update/update handle, not only execute update.
- Update-with-start.
- Query reject condition.
- Workflow list/count/history fetch.
- Workflow start request id, memo, start delay, priority, links, callbacks, versioning override, on-conflict options, and eager execution controls where supported.

References:

- `../lib/temporalex/client.ex`: current public API.
- `../native/temporalex_nif/src/lib.rs`: `workflow_start_options`, `query_options`, `update_options`.
- `../../temporal-api/temporal/api/workflowservice/v1/request_response.proto`: `StartWorkflowExecutionRequest`, `SignalWithStartWorkflowExecutionRequest`, `QueryWorkflowRequest`, `UpdateWorkflowExecutionRequest`, `ExecuteMultiOperationRequest`.
- `../../documentation/docs/develop/rust/workflows/message-passing.mdx`: signal-with-start and update handle behavior.

Needed:

- Add these incrementally with backend conformance tests and real-server tests.
- Prefer Elixir-friendly handles and option names while preserving Temporal semantics.

### Missing Workflow Primitives

Status: open.

Current concern:

The current workflow API covers activities, timers, signals, queries/updates through phase, deterministic time/random/uuid, patch markers, Search Attribute upsert, parallel, and state publishing. Production SDK parity needs more primitives:

- Child workflows.
- External workflow signal/cancel.
- Cancellation scopes or cancellation handles.
- Local activities.
- Side effects and mutable side effects, if they can be modeled without weakening replay.
- Memo upsert.
- A general `wait_condition` or await-predicate API.
- Workflow logging/interceptors/headers where they can be deterministic and useful.

References:

- `../lib/temporalex/workflow/api.ex`: current workflow primitives.
- `../lib/temporalex/core/structs.ex`: current job, op, and command structs.
- `../../temporal-api/temporal/api/command/v1/message.proto`: child workflow, external signal/cancel, memo modification, Nexus commands.
- `../../documentation/docs/develop/rust/workflows/child-workflows.mdx`: child workflow behavior.
- `../../documentation/docs/develop/rust/workflows/message-passing.mdx`: wait conditions and handler patterns.

Needed:

- Add primitives only when they satisfy `docs/implementation_principles.md`.
- Each primitive needs executor-level command/replay tests before relying on the real backend.

### Retry Policy Validation Bug

Status: completed on May 8, 2026.

Original concern:

- `retry_policy_from_term/1` rejects negative `backoff_coefficient` but allows values between 0 and 1.
- Temporal requires the coefficient to be 1 or larger.

Implemented:

- Native retry policy validation now rejects explicit `backoff_coefficient` values below `1.0`, including `0.0`.
- Codec tests cover `0.0` and `0.5`.

References:

- `../native/temporalex_nif/src/lib.rs`: `retry_policy_from_term`.
- `../../temporal-api/temporal/api/common/v1/message.proto`: `RetryPolicy.backoff_coefficient`.

Remaining follow-up:

- Consider validating `maximum_interval >= initial_interval` if Temporal Core/server does not already give a clear error.

## Testing Strategy Gaps

Status: open.

Current coverage:

- The real Temporal dev-server integration test covers worker startup, workflow start/result, timers, activities, heartbeats, signal/query/update/describe, termination, and one invalid start option path.
- Core tests cover deterministic command emission, replay mismatch, phase/update/query behavior, patch markers, and process teardown for the implemented surface.

Missing production-confidence tests:

- Additional Search Attribute visibility cases beyond the current start/upsert smoke path, if needed.
- Additional real-server cancellation permutations beyond the current timer and activity cases, if needed.
- Activity retry and non-retryable error behavior against the server.
- Continue-as-new chains, including result retrieval across runs and option propagation.
- Workflow ID reuse/conflict policies against running and closed workflows.
- Query reject condition behavior.
- Update rejection, async update completion, and update handles when implemented.
- Worker restart/replay against real history.
- Backend conformance tests that compare fake backend and Temporal Core backend behavior for shared operations.
- Payload/failure decoder tests for all public error surfaces.

## Lower Priority Or Explicitly Deferred

These are not tracked as blockers in this document unless priorities change:

- Sibling checkout dependencies for `../temporal-sdk-core` and `../temporal-api`.
- Pluggable data converters or safe ETF mode.
- Production packaging, CI, and release automation.
- Nexus support, unless it becomes a near-term product requirement.
