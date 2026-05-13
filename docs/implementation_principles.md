# Implementation Principles

This document is the implementation standard for code that touches the workflow core, replay, process lifecycle, backend integration, or public workflow API.

Temporalex may make Temporal feel Elixir-native, but it must not weaken Temporal's execution model. If ergonomics conflict with deterministic replay, command ordering, process ownership, or backend isolation, the invariant wins.

## Prime Invariant

Given the same workflow code, input, and ordered activation transcript, Temporalex must emit the same ordered command decisions or fail with nondeterminism.

This is the rule every internal design choice must preserve.

## Layer Ownership

Each layer has a narrow job:

| Layer | Owns | Must Not Own |
|---|---|---|
| Workflow API | User-facing primitives and context lookup | Backend calls, command sequencing, replay decisions |
| Executor | Deterministic workflow state, runner scheduling, replay matching, command construction | Polling, protobuf, NIF resources, activity process supervision |
| Server | Backend state, activation routing, executor registry, activity task supervision, completion submission | Deterministic workflow state |
| Backend | Translation between core structs and Temporal/Core transport | Workflow semantics |

Outer layers may route data, supervise processes, and translate protocols. They must not bypass executor invariants for convenience.

## Workflow Context

Workflow code may call Temporalex workflow primitives only from an executor-owned runner or handler process.

The process dictionary is limited to one Temporalex key:

```elixir
:__temporal_context__
```

That value identifies the executor PID and deterministic thread ID. No other hidden workflow runtime state should live in the process dictionary.

## Determinism

Workflow execution must not depend on hidden process, OS, VM, application, or network state.

Allowed sources of changing values are only those represented in Temporal's workflow model and delivered through activations, such as:

- workflow input
- signals, updates, and queries
- activity results
- timer completions
- workflow activation timestamp
- deterministic random seed updates
- patch notifications

External reads, writes, service calls, filesystem access, and environment/config lookup belong outside workflow execution, usually in activities or workflow input.

Convenience APIs are admitted only when they map to a real Temporal concept with a clear replay contract.

## Replay

Replay is normal workflow execution against historical activations.

The executor must not make replay pass by skipping command emission. During replay, workflow code runs again and emits the same command decisions in the same order. The executor validates those decisions against the activation transcript and fails the activation on mismatch.

Scheduler and replay details are specified in [scheduler_and_replay.md](scheduler_and_replay.md).

Replay-specific rules:

- Query-only activations must not advance workflow threads.
- Eviction-only activations must not run workflow code.
- Update validators run only when the activation says they should run.
- Patch/version APIs must follow Temporal patch marker semantics.
- Nondeterminism is an activation failure, not a workflow failure command.

## Command Discipline

The executor owns command construction and ordering.

- Command sequence numbers are workflow-run-local and deterministic.
- Commands are emitted only through executor state transitions.
- A successful activation completion contains the full ordered command list for that activation.
- Activation failure is distinct from commands that fail or complete the workflow.
- Terminal workflow intent still flows through a successful activation completion.

No server, backend, or public API helper may append, reorder, suppress, or reinterpret workflow commands.

## Process Lifecycle

One executor owns one workflow run.

- Runners and handler processes are linked to their executor.
- The executor traps exits and owns teardown on crash, cancellation, and eviction.
- Blocked workflow calls remain blocked in `GenServer.call/3` until the executor resolves, fails, or tears them down.
- Runner exits are executor lifecycle events first; they are not silently converted into workflow results.

Lifecycle behavior must be tested because process leaks and orphaned runners can corrupt later workflow work.

## Backend Boundary

The backend behaviour is the only boundary for Temporal/Core transport.

Core structs are the stable internal protocol. The real backend may use Rustler, protobuf, Temporal Core handles, and binary payload conversion, but those details must not leak into executor semantics or workflow APIs.

The in-memory test backend and real Temporal backend should satisfy the same server-facing contract.

## Serialization

Payload conversion is currently fixed:

```elixir
:erlang.term_to_binary(term)
:erlang.binary_to_term(binary)
```

The serializer is not part of workflow determinism. It must preserve application terms across the backend boundary without introducing workflow-visible behavior differences.

## API Admission Rule

A new workflow API primitive is allowed only if all of these are true:

- It can be expressed as an executor operation.
- Its replay behavior is precise.
- Its command emission, if any, maps to Temporal/Core behavior.
- It can be tested without the real Temporal backend.
- It does not give workflow code hidden access to external state.

If a feature cannot satisfy these rules, model it as an activity, workflow input, client operation, or server/backend concern instead.

## Testing Standard

Core tests should prove behavior at the level Temporal cares about:

- emitted commands
- command ordering
- activation completion status
- replay match and mismatch
- runner blocking and unblocking
- process teardown
- query/update/signal scheduling
- backend contract conformance

Every workflow primitive needs tests for initial execution and replay. Tests should fail on missing commands, extra commands, reordered commands, incorrect completion status, leaked processes, or replay-only behavior.

The real Temporal backend should enter through backend conformance tests, not by replacing core tests.

## Review Checklist

For any change touching the core, workflow API, server/backend boundary, or serialization, check:

- Does the executor still own deterministic state and command construction?
- Can the behavior be replayed from activations alone?
- Are activation failure and workflow failure still distinct?
- Are query-only and eviction-only activations handled without advancing workflow execution?
- Does the API avoid hidden external state?
- Does the test suite assert commands and replay behavior directly?
- Could a fake backend and the real backend both satisfy the same contract?

If any answer is unclear, the implementation is not ready.
