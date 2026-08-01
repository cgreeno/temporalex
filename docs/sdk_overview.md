# Temporalex SDK Overview

Temporalex is an experimental Elixir SDK for Temporal. The SDK is built around a deterministic Elixir workflow core and a backend boundary implemented for Temporal Core via Rustler.

This document is the architecture map. Detailed contracts live in focused docs:

| Document | Purpose |
|---|---|
| [programming_model.md](programming_model.md) | Public workflow programming model: activities, workflow API, signals, updates, queries, `phase`, `parallel`, and determinism guidance. |
| [public_api.md](public_api.md) | Public module-level API: workflow DSL, activity DSL, client API shape, retry policy, and error structs. |
| [testing.md](testing.md) | Public workflow testing helpers for fast local workflow tests without a Temporal server. |
| [implementation_principles.md](implementation_principles.md) | Internal implementation rules, invariants, API admission criteria, and review checklist. |
| [implementation_slice.md](implementation_slice.md) | Core implementation slices: sequential core first, then structured concurrency with `parallel`, `phase`, signals, updates, and queries. |
| [review_gates.md](review_gates.md) | Completed Slice 1, Slice 2, and native integration review-gate notes, evidence, outcomes, and beta limits. |
| [core.md](core.md) | Deterministic executor/runner kernel, internal structs, replay rules, scheduling, and invariants. |
| [scheduler_and_replay.md](scheduler_and_replay.md) | Deterministic scheduler rounds, pause points, activation turns, command decisions, and replay matching. |
| [core_testing.md](core_testing.md) | Test harness and test strategy for validating the core without Temporal or Rustler. |
| [temporal_core_mapping.md](temporal_core_mapping.md) | Mapping between Temporal Core's worker-facing activation/completion protocol and Temporalex core structs. |
| [backend.md](backend.md) | Backend behaviour that combines transport and protocol translation for server-facing integration. |
| [server.md](server.md) | Worker server responsibilities, supervision, pending activations, executor registry, and activity task handling. |
| [native.md](native.md) | Rustler and Temporal Core implementation notes for the real backend. |

## Design Principles

1. **The core comes first.** The interaction between executor and runner processes, replay, command ordering, and deterministic scheduling must be solid before the outer layers are built.

2. **The executor is the workflow coordination point.** All deterministic workflow runtime state lives in the executor GenServer. Workflow processes carry exactly one process dictionary key, `:__temporal_context__`, containing the executor PID and deterministic thread ID.

3. **The core is Temporal-independent.** It speaks internal structs for activations, jobs, commands, completions, and activation transcripts. It does not know about protobuf, Rustler, NIF resources, task tokens, or Temporal Core wire types.

4. **The backend owns external protocol and transport.** The server talks to a `Temporalex.Backend` behaviour. The real backend will decode Temporal Core messages into core structs and encode core completions back to Temporal Core.

5. **OTP conventions over custom protocols.** Process links, monitors, supervision, exit reasons, and telemetry are preferred over bespoke lifecycle mechanisms.

6. **No test infrastructure in production paths.** Testing uses the same core structs and server/backend contracts. Test backends substitute for real backends without changing the core.

## Architecture

```
User workflow code
  |
  | Workflow API calls
  v
Temporalex.Core.Executor
  |
  | Core completions
  v
Temporalex.Server
  |
  | Backend behaviour callbacks
  v
Temporalex.Backend.TemporalCore
  |
  | Rustler NIF calls and protobuf bytes
  v
Temporal Core / Temporal Server
```

The core is the only layer that decides deterministic workflow behavior. The server owns orchestration and lifecycle. The backend owns all external protocol and transport details.

## Core Boundary

The core receives `%Temporalex.Core.Activation{}` structs and emits status-bearing `%Temporalex.Core.Completion{}` structs. It owns:

- executor GenServer
- runner process lifecycle
- workflow operation protocol
- replay command matching
- nondeterminism detection
- command sequencing
- signal and update buffering
- published query state
- deterministic scheduling for `parallel` and handlers
- workflow completion, failure, and continue-as-new semantics

The core does not own:

- protobuf encoding or decoding
- NIF resources
- Temporal Core worker/client handles
- worker polling
- activity task process supervision
- network calls to Temporal

The main invariant:

> Given the same workflow code, input, and ordered activation transcript, the core emits the same ordered command decisions or fails with nondeterminism.

See [core.md](core.md) and [temporal_core_mapping.md](temporal_core_mapping.md).

## Backend Boundary

The server is parameterized by a backend module. A backend starts workers, delivers core activations to the server, and accepts core completions from the server.

The real backend, `Temporalex.Backend.TemporalCore`, handles:

- Rustler calls
- Temporal Core worker lifecycle
- protobuf activation/completion encoding
- ETF payload conversion with `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1`
- poll loop messages
- completion submission

A test backend can send core structs directly. This lets server and core integration tests stay valid when the real Temporal backend is added.

See [backend.md](backend.md) and [temporal_core_mapping.md](temporal_core_mapping.md).

## Supervision Overview

The native backend creates Temporal Core runtime/client resources in `Temporalex.Client`. Workers receive an explicit client and start pollers from that shared client state.

```
Temporalex.Supervisor
└── Temporalex.Runtime
```

Each user worker instance owns its own worker tree:

```
MyApp.Temporal (Supervisor, strategy: :rest_for_one)
├── MyApp.TemporalClient
└── MyApp.TemporalWorker (Supervisor, strategy: :one_for_all)
    ├── MyApp.TemporalWorker.ExecutorSupervisor
    ├── MyApp.TemporalWorker.ActivitySupervisor
    └── MyApp.TemporalWorker.Server
```

The server owns worker backend state and monitors both the client owner and each executor. Executors trap exits and link to their runner processes. Activity work runs under the activity supervisor.

See [server.md](server.md).

## Public Surface Summary

The public workflow model is documented in [programming_model.md](programming_model.md). The module-level API is documented in [public_api.md](public_api.md). At a high level:

- Workflows are modules with `run/1`.
- Activities are defined with `use Temporalex.Activity` and `defactivity`.
- Workflow code calls activities, sleeps, waits for signals, reads workflow time, publishes query state, and uses deterministic random helpers through `Temporalex.Workflow.API`.
- `API.parallel/1`/`API.parallel!/1` and `API.phase/2`/`API.phase!/2` are the structured concurrency hosts.
- Queries read only the last state explicitly published by `API.publish_state/1`.
- Updates are accepted only while the workflow is inside a matching `API.phase/2`.

## Data Conversion

For v1, payload conversion is fixed:

```elixir
:erlang.term_to_binary(term)
:erlang.binary_to_term(binary)
```

No `[:safe]` option is used. The trust model is that payloads are produced and consumed inside the same application boundary. There is no pluggable converter layer in v1.

## Build Order

The authoritative implementation plan is [implementation_slice.md](implementation_slice.md):

1. Slice 1: sequential core, activity/timer blocking, replay matching, and core test harness.
2. Intermission: review Slice 1 for design impedance before adding concurrency.
3. Slice 2: deterministic scheduler rounds, `parallel`, `phase`, signals, updates, and queries.
4. Intermission: review full core concurrency before server/backend integration.
5. Server with test backend.
6. Real Temporal backend with Rustler, Temporal Core, and protobuf conversion.

The outer layers should not be built until the core slices and review gates are complete.

Current repository status:

- Slice 1 and Slice 2 core behavior are implemented in `lib/temporalex/core/*`, `lib/temporalex/workflow/*`, and `lib/temporalex/activity.ex`.
- Core verification lives in `test/temporalex/core_executor_test.exs` and covers sequential execution, replay matching, deterministic `parallel`, `phase`, signals, updates, queries, and process lifecycle.
- Server/test-backend integration is implemented through `Temporalex.Worker`, `Temporalex.Server`, `Temporalex.Backend`, and `Temporalex.Backend.Test`.
- Server verification lives in `test/temporalex/server_integration_test.exs` and covers worker supervision, executor registry cleanup, activation routing, activity task supervision, query routing, eviction, and completion submission.
- `Temporalex.Backend.TemporalCore` is implemented through `Temporalex.Native`, Rustler resources, Temporal Core worker/client calls, native poll loops, protobuf conversion, and ETF payload conversion.
- `Temporalex.Client` is implemented for Temporal Core-backed workers with workflow start/result, signal, query, update, cancel, terminate, and describe operations.
- `test/temporalex/integration/temporal_core_integration_test.exs` starts a Temporal dev server and verifies workflow execution, activity execution, heartbeats, invalid client option handling, signal/query/update/describe, termination, and result decoding through the Rust NIF.
- `test/temporalex/integration/temporal_worker_restart_test.exs` verifies worker restart and real-history replay with the Temporal dev server.
