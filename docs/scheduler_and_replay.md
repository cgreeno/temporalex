# Scheduler And Replay

This document defines how the executor schedules workflow units and how replay validates command decisions. These rules are part of the core correctness contract.

The executor must make this true:

> Given the same workflow code, input, and ordered activation transcript, the executor emits the same ordered command decisions or fails with nondeterminism.

BEAM process scheduling, mailbox arrival order, and wall-clock timing must not affect command order.

## Scope

This document covers the v1 executor model:

- deterministic cooperative scheduling
- scheduler rounds
- pause points
- activation turns
- command decisions
- replay matching

It does not require access to a raw "next history event" stream from Temporal. If a future backend exposes enough ordered-history information, true history-synchronized parallel runner execution can be considered later. The v1 model must be correct without that.

## Workflow Units

A workflow unit is a schedulable process of workflow execution.

Units include:

- the root workflow runner
- `API.parallel/1` branches
- signal handlers
- update handlers
- async phase handlers

Every unit has a stable thread id:

```elixir
[]                 # root runner
[{:p, 0}]          # first parallel branch
[{:p, 1}, {:p, 0}] # nested parallel branch
[{:h, 2}]          # third handler dispatch
```

Thread ids are assigned by structure, not by process timing.

Conceptually, executor state tracks:

```elixir
%Executor.State{
  threads: %{thread_id => %Thread{}},
  scheduler: %Scheduler{
    round: non_neg_integer(),
    current_round: :queue.queue(thread_id),
    next_round: :queue.queue(thread_id),
    running: thread_id | nil
  },
  pending: %{seq => %Pending{}},
  commands: [Command.t()],
  next_seq: non_neg_integer()
}
```

The exact structs may evolve, but the ownership does not: only the executor may mark units runnable, grant turns, assign sequence numbers, and append commands.

## Pause Points

A unit's scheduler step runs until it pauses, completes, fails, or explicitly yields.

Pausing operations are workflow operations that cannot return from currently-known executor state, such as:

- `API.execute_activity/2`
- `API.sleep/1`
- `API.wait_for_signal/1` when no matching signal is buffered
- waiting for a child workflow result
- waiting for a phase condition
- waiting for a future/handle if such an API is added

When a unit pauses, the executor records the pending caller and does not reply to the `GenServer.call/3` until a later activation resolves the operation.

Non-pausing operations return immediately and do not end the unit's scheduler step:

- `API.now/0`
- `API.random/0`
- `API.uuid4/0`
- `API.workflow_info/0`
- `API.cancelled?/0`
- `API.publish_state/1`
- command-emitting operations that do not wait for a result, such as search-attribute upserts

Command-emitting non-pausing operations still append commands through the executor, but the currently running unit keeps its turn.

## Scheduler Rounds

The scheduler runs at most one unit at a time.

A round is a deterministic pass over units that are runnable at the start of that round.

Rules:

1. At the start of a round, the executor snapshots the currently runnable units in stable order.
2. Each unit in the snapshot gets at most one step.
3. A step runs until pause, completion, failure, or explicit yield.
4. A unit that becomes runnable during a round is deferred to the next round.
5. A paused unit whose awaited event has not arrived is not runnable and does not constrain progress.
6. When the current round is empty, the executor starts the next round from deferred runnable units.

This provides durable concurrency without making BEAM scheduling part of workflow semantics.

Example:

```elixir
API.parallel([
  fn -> API.execute_activity(A); API.execute_activity(C) end,
  fn -> API.execute_activity(B); API.execute_activity(D) end
])
```

Initial activation:

1. The parent enters `parallel` and pauses on the parallel scope.
2. Branches `{:p, 0}` and `{:p, 1}` become runnable for the next round.
3. Branch `{:p, 0}` schedules activity `A` and pauses.
4. Branch `{:p, 1}` schedules activity `B` and pauses.
5. The activation completion emits `A` then `B`.

If only `A` resolves in a later activation, only branch `{:p, 0}` is runnable. It may consume `A`, schedule `C`, and pause. Branch `{:p, 1}` does not block progress while still waiting for `B`.

If `A` and `B` resolve in the same activation, both branches are runnable. The round runs branch `{:p, 0}` before `{:p, 1}`, so `C` is emitted before `D`.

## Stable Ordering

Runnable units are ordered by executor-owned stable keys.

The default ordering is:

1. root unit `[]`
2. existing parallel branches by thread id
3. handler dispatches by dispatch order

Nested thread ids are compared lexicographically by their path segments. Handler dispatch ids are assigned from activation job order and phase dispatch order.

The exact ordering policy can be refined, but it must remain a total order over stable executor-owned identities. It must never depend on process pid, mailbox timing, or scheduler timing.

## Activation Turn

Each activation is one deterministic turn for a workflow run.

The executor processes an activation in this order:

1. Apply activation metadata to executor state.
2. Apply jobs in activation order.
3. Resolve pending operations, enqueue handlers, buffer signals/updates, apply cancellation, update patches, and update random seed state.
4. If the activation is eviction-only, complete successfully without running workflow code.
5. If the activation is query-only, run query handlers and complete without advancing workflow units.
6. Otherwise, drain scheduler rounds until no unit is runnable.
7. Emit exactly one completion for the activation.

Blocked workflow calls remain unreplied across activations. A later activation can make their units runnable again.

## Command Decisions

A command decision is the executor's deterministic intent to ask Temporal for durable work.

Command decisions include:

- command type
- sequence number, where the Temporal command has one
- thread id, where the command is emitted by a workflow unit
- semantic target fields, such as activity id, activity type, or timer duration
- decoded payload terms
- options that affect Temporal command semantics

Backend-only fields are not part of command identity.

Sequence numbers are assigned by the executor when it decides to emit a durable command. They are not assigned when an Elixir process happens to call into the executor.

Sequence numbers are local to one workflow run and do not reset between activations.

## Replay Matching

Replay is normal workflow execution against historical activations.

During replay, workflow code still emits command decisions. Those decisions are matched against the replay transcript in order. They are not new user-visible effects.

Matching rules:

- A missing command is nondeterminism.
- An extra command is nondeterminism.
- A reordered command is nondeterminism.
- A command with different deterministic fields is nondeterminism.
- Resolution jobs must wake the pending caller for the matched sequence number.
- Replay transcript entries are consumed exactly once.

Fields compared for command identity include operation type and every field that affects Temporal semantics, such as activity id, activity type, input, timer duration, child workflow type, patch id, and relevant options.

Fields ignored for command identity are backend transport details, task tokens, worker handles, protobuf metadata, and other data not visible to workflow semantics.

Nondeterminism fails the activation. It is not represented as a workflow failure command.

## Process Rules

Workflow code may execute only when the executor has granted a scheduler turn to that unit.

Only one unit may be running workflow code at a time in v1. Other units are blocked before entering user workflow code or blocked inside executor-mediated calls.

If a non-running unit calls the executor as though it were running, that is an internal scheduler violation. The implementation should fail fast in tests and avoid silently accepting out-of-turn command emission.

Closures executed inside the executor, such as `API.update_state/1`, must be deterministic, synchronous, and non-blocking. They must not call workflow APIs, activities, sleep, or any operation that would call back into the executor.

## Test Requirements

Scheduler and replay tests should assert the rules directly:

- `parallel` schedules first-step activity commands in branch order.
- If only branch `A` resolves, branch `A` may continue without waiting for branch `B`.
- If branches `A` and `B` resolve in the same activation, their next commands are emitted in stable order.
- Newly runnable units are deferred to the next round.
- Non-pausing APIs do not end the current scheduler step.
- Command-emitting non-pausing APIs append commands without yielding the turn.
- Replay fails on missing, extra, reordered, or changed commands.
- Resolution jobs wake only the pending caller for the matched sequence number.
- Query-only activations do not advance workflow units.
- Eviction-only activations do not run workflow code.
- Out-of-turn runner calls are detected as scheduler violations.

These tests should run against the pure core harness before the real Temporal backend exists.
