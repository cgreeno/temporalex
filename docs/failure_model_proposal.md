# Failure Model Proposal

This proposal addresses the current flat failure conversion where every workflow, query, update, and activity failure becomes `Temporalex.ApplicationError` with `non_retryable = false`.

## Goals

- Preserve Temporal's failure tree instead of collapsing failures into strings or opaque maps.
- Let users intentionally control retry behavior through application error type and a public `retryable?` flag.
- Keep normal workflow code Elixir-native: returning `{:error, reason}` remains possible, while structured failures are available when retry semantics matter.
- Keep activation failure separate from workflow failure. Nondeterminism and runtime bugs should still fail the workflow task, not complete the workflow with a failure command.
- Keep payload conversion fixed to ETF for application failure details until the broader converter story changes.

## Public Types

Add a small public failure namespace:

```elixir
defmodule Temporalex.Failure.ApplicationError do
  defexception [:message, :type, details: [], retryable?: true, cause: nil]
end

defmodule Temporalex.Failure.CancelledError do
  defexception [:message, details: [], cause: nil]
end

defmodule Temporalex.Failure.TimeoutError do
  defexception [:message, :timeout_type, :last_heartbeat_details]
end

defmodule Temporalex.Failure.ActivityError do
  defexception [:message, :activity_id, :activity_type, :retry_state, :cause]
end

defmodule Temporalex.Failure.WorkflowExecutionError do
  defexception [:message, :workflow_id, :run_id, :workflow_type, :retry_state, :cause]
end
```

`ApplicationError.type` should default to the exception module name for raised exceptions and to `"Temporalex.ApplicationError"` only for untyped terms. Users can set a stable string type when they want retry policies such as `non_retryable_error_types: ["PaymentDeclined"]`.

## Outbound Conversion

Workflow failures:

- `{:error, %Temporalex.Failure.ApplicationError{} = error}` emits `FailWorkflowExecution` with `ApplicationFailureInfo`.
- `raise %Temporalex.Failure.ApplicationError{}` also emits an application failure from workflow result and async update boundaries.
- `{:error, %Temporalex.Failure.ActivityError{} = error}` and other decoded failure wrappers round-trip with their nested `cause`.
- `{:error, reason}` remains supported and becomes an application failure with type `"Temporalex.ApplicationError"` and one detail payload containing `reason`.
- `{:cancelled, reason}` emits `CancelWorkflowExecution` with cancellation details, not an application failure.

Activity failures:

- `{:error, %ApplicationError{} = error}` responds with an application failure preserving type, details, and retryability.
- `{:error, reason}` remains supported as the untyped application failure fallback.
- Activity cancellation should use `CancelledError`/canceled failure details when cancellation propagation is implemented.

Query and update failures:

- Query handler `{:error, reason}` should preserve existing behavior but route through the same application failure encoder.
- Update rejection should use `ApplicationError` so rejected update types/details are stable and decodable by clients.
- Update handler failure after acceptance should complete the update with an application failure rather than collapse to a string.

## Inbound Conversion

Decode Temporal failure protos into the public structs recursively:

- `ApplicationFailureInfo` -> `%ApplicationError{message, type, details, retryable?}`
- `CanceledFailureInfo` -> `%CancelledError{message, details}`
- `TimeoutFailureInfo` -> `%TimeoutError{message, timeout_type, last_heartbeat_details}`
- `ActivityFailureInfo` -> `%ActivityError{activity_id, activity_type, retry_state, cause}`
- `ChildWorkflowExecutionFailureInfo` -> `%WorkflowExecutionError{workflow_id, run_id, workflow_type, retry_state, cause}`

Client workflow result APIs keep tuple status for now:

```elixir
{:error, {:failed, %Temporalex.Failure.ActivityError{}}}
{:error, {:failed, %Temporalex.Failure.ApplicationError{}}}
{:error, {:canceled, %Temporalex.Failure.CancelledError{}}}
```

This preserves the existing `{:ok, value} | {:error, reason}` style while giving callers structured causes.

## Retry Semantics

- `ApplicationError.type` is the string matched by Temporal retry policy `non_retryable_error_types`.
- `ApplicationError.retryable?` maps to the inverse of `ApplicationFailureInfo.non_retryable`.
- `details` is a list of ETF payloads, not a single term. Convenience constructors may wrap a single detail.
- The default untyped `{:error, reason}` fallback should remain retryable to avoid changing existing behavior.

## Proposed API Helpers

```elixir
alias Temporalex.Failure

raise Failure.application("declined",
  type: "PaymentDeclined",
  details: [%{payment_id: id}],
  retryable?: false
)

{:error,
 Failure.application("inventory unavailable",
   type: "InventoryUnavailable",
   details: [sku]
 )}
```

The helper module should return exception structs but not require users to raise them.

## Implementation Plan

1. Add public failure structs and helper constructors.
2. Update native outbound failure encoding to inspect those structs.
3. Update native inbound failure decoding to build those structs recursively.
4. Update executor tests for workflow, query, update, and activity failures.
5. Add real-server retry tests proving `retryable?` and `non_retryable_error_types` interact correctly.
6. Preserve legacy tagged terms temporarily only where tests or API ergonomics require them.

## Open Questions

- Should raised non-Temporalex exceptions default to the exception module as `type`, or should they remain `"Temporalex.ApplicationError"` until users opt in?
- Should client `get_result/2` preserve current tagged tuples for canceled/timed-out/terminated states, or migrate all of them to structs in one breaking change?
- Should failure details be decoded eagerly, or should structs carry both decoded terms and raw payloads for forward compatibility?
