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
- Added public client operation error structs, including `Temporalex.UpdateFailedError` for update failures and rejections observed by the client.
- Added core, codec, and Temporal dev-server tests proving `retryable?`, `non_retryable_error_types`, and activity retry attempts are observed by Temporal.

References:

- `../native/temporalex_nif/src/lib.rs`: `failure_from_term`, `failure_to_term`.
- `../../temporal-api/temporal/api/common/v1/message.proto`: `RetryPolicy.non_retryable_error_types`.
- `../../temporal-api/temporal/api/failure/v1/message.proto`: Temporal failure variants.

Remaining follow-up:

- Decide whether raised non-Temporalex exceptions should default `ApplicationError.type` to the exception module name.

### Continue-As-New Is Under-Modeled

Status: completed on May 8, 2026.

Original concern:

- Workflow code can only return `{:continue_as_new, args}`.
- The NIF encodes only workflow type, task queue, and arguments.
- Temporal supports run timeout, task timeout, retry policy, header, memo, search attributes, start backoff, and versioning behavior on continue-as-new.

Implemented:

- Added `Workflow.API.continue_as_new!/2` as a terminal workflow operation that does not return to user code after the executor accepts it.
- Removed the return-tuple path from the executor; continue-as-new now flows through an explicit executor op.
- Restricted continue-as-new to the running root workflow thread when it is the only live workflow thread, with no active phase, parallel scope, or pending workflow operation.
- Added continue-as-new options for workflow type, task queue, run timeout, task timeout, memo, headers, typed Search Attributes, retry policy, versioning intent, and initial versioning behavior.
- Extended workflow info with activation timestamp, replay flag, history length/size, and `continue_as_new_suggested`.
- Added core tests for terminal behavior, option propagation, replay identity, root-thread enforcement, and workflow info exposure.
- Added native codec coverage and a Temporal dev-server test for a chained continue-as-new run whose final result is retrieved across runs and whose Search Attributes are visible.

References:

- `../lib/temporalex/workflow/api.ex`: `continue_as_new!/2`.
- `../lib/temporalex/core/executor.ex`: `Op.ContinueAsNew` handling.
- `../native/temporalex_nif/src/lib.rs`: `ContinueAsNewWorkflowExecution` command encoding.
- `../../temporal-api/temporal/api/command/v1/message.proto`: `ContinueAsNewWorkflowExecutionCommandAttributes`.
- `../../documentation/docs/develop/rust/workflows/continue-as-new.mdx`: continue-as-new usage and suggestion API.

Remaining follow-up:

- Temporal API exposes `backoff_start_interval`, but the Temporal Core `ContinueAsNewWorkflowExecution` command currently does not expose that field through the local Core command proto. Add it if/when Core exposes it.

## Medium Priority

### Client Should Not Require A Running Worker

Status: completed on May 8, 2026.

Original concern:

- `Temporalex.Client` routes operations through a running `Temporalex.Worker` and its backend state.
- This is convenient for local integration tests but is not the usual SDK model.
- A production client should be usable from web processes, jobs, IEx, or services that do not host workflow workers.

Implemented:

- `Temporalex.Client` is now a supervised owner process for backend client resources.
- `Temporalex.Worker` requires an explicit `:client`; it never creates an internal client.
- Workers resolve the client once at startup, hold the native backend handles they need, monitor the client owner pid, and stop with `{:client_down, reason}` if the client exits.
- The worker subtree uses `:one_for_all`, so server, executor supervisor, and activity supervisor restart together after worker-local failures.
- Workflow handles carry a client reference instead of a worker reference.
- Client operations resolve the backend handle and call the backend directly; the client process is not a request proxy.
- The backend behaviour now names the client-operation callbacks used by `Temporalex.Client`, so the client/backend contract is explicit.
- Long-running client operations monitor the client owner while waiting and return `{:error, %Temporalex.ClientUnavailableError{}}` if it exits.
- Public client operation errors are stable exception structs, with Temporal failure trees stored under `cause` where applicable.
- Added server/backend tests for explicit client wiring and worker shutdown on client exit, plus Temporal dev-server coverage with a standalone client and worker sharing the same native client resources.

References:

- `../lib/temporalex/client.ex`: client owner process and public workflow operations.
- `../lib/temporalex/worker.ex`: mandatory client option and worker subtree strategy.
- `../lib/temporalex/server.ex`: client resolution and monitor handling.
- `../lib/temporalex/backend/temporal_core.ex`: native client operations.

Remaining follow-up:

- Add a small public type/spec pass once the next client-operation expansion settles.

### Missing Client Operations And Options

Status: open.

Current concern:

The current client covers start, get result, signal, query, execute update, cancel, terminate, and describe. Useful SDK primitives/options are still missing:

- Signal-with-start.
- Start update/update handle, not only execute update.
- Update-with-start.
- Workflow list/count/history fetch.
- Workflow start request id, memo, start delay, priority, links, callbacks, versioning override, on-conflict options, and eager execution controls where supported.

Recently added:

- Query reject condition is implemented for client queries and covered by real Temporal dev-server tests.

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

- `Temporalex.Testing` provides a public, local workflow testing surface that runs workflows through the real executor, exposes emitted activity/timer/update commands in deterministic order, lets tests resolve operation handles manually, and replays recorded activation transcripts.
- Consumer-style workflow tests using `Temporalex.Testing` cover signal waits, continue-as-new, non-cancellable cleanup, blocked cancellable cleanup, activity cancellation modes, parallel cancellation, async signal handlers, async update handlers, update rejection, and safe-mode failures.
- The real Temporal dev-server integration tests cover standalone client startup, worker startup from an explicit client, workflow start/result, timers, activities, heartbeats, signal/query/update/describe, termination, continue-as-new chains, activity retry/non-retryable behavior, Search Attribute visibility, one invalid start option path, workflow ID conflict/reuse behavior, not-found errors across client operations, query reject condition behavior, update rejection, and worker restart/replay against real history for timers, activities, signals, and continue-as-new.
- Core tests cover deterministic command emission, replay mismatch, phase/update/query behavior, patch markers, and process teardown for the implemented surface.

Missing production-confidence tests:

- More consumer-style workflow tests for larger realistic workflows and future primitives as they are added.
- Additional Search Attribute visibility cases beyond the current start/upsert smoke path, if needed.
- Additional real-server cancellation permutations beyond the current timer and activity cases, if needed.
- Additional workflow ID policy permutations if needed beyond running conflict, closed rejection, and closed allow-duplicate reuse.
- Async update completion and update handles when implemented.
- Backend conformance tests that compare fake backend and Temporal Core backend behavior for shared operations.
- Additional payload/failure decoder tests for Temporal failure variants that are still represented as `Temporalex.Failure.UnknownError`.

## Lower Priority Or Explicitly Deferred

These are not tracked as blockers in this document unless priorities change:

- Sibling checkout dependencies for `../temporal-sdk-core` and `../temporal-api`.
- Pluggable data converters or safe ETF mode.
- Production packaging, CI, and release automation.
- Nexus support, unless it becomes a near-term product requirement.
