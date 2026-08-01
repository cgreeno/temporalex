# Core Testing

Core tests validate deterministic workflow behavior without Temporal Core, Rustler, protobuf, or a backend worker.

The test harness drives the executor with core structs in the same shape the real backend will eventually produce.

Scheduler and replay expectations are specified in [scheduler_and_replay.md](scheduler_and_replay.md).

## Goals

The tests should prove:

- first execution emits the expected core commands
- replay emits the same command decisions and consumes matching activation jobs
- mismatched replay fails with nondeterminism
- command ordering is deterministic
- runner and executor process lifecycle behaves correctly
- signals, updates, phases, and parallel branches obey the programming model

The test harness is the foundation for `Temporalex.Testing`, the public local
workflow testing API. The core harness remains lower-level so internal tests can
assert exact activation/completion structs directly.

## Harness Shape

The core test harness should expose a small API:

```elixir
{:ok, exec} =
  Temporalex.Core.TestHarness.start_workflow(MyWorkflow, input,
    replay: nil
  )

assert {:yield, [%Command.ScheduleActivity{} = cmd]} =
  Temporalex.Core.TestHarness.next(exec)

assert {:complete, {:ok, result}} =
  Temporalex.Core.TestHarness.resolve(exec, %Job.ActivityResolved{
    seq: cmd.seq,
    result: {:ok, "charge_123"}
  })
```

Expected return shapes:

```elixir
{:yield, [Temporalex.Core.Command.t()]}
{:waiting, Temporalex.Core.PhaseInfo.t()}
{:complete, {:ok, term()}}
{:complete, {:error, term()}}
{:continue_as_new, term()}
{:failed, %Temporalex.Core.Nondeterminism{}}
{:failed, term()}
```

The exact names can evolve, but the harness should make tests read as workflow transcripts.

## Three Tests Per Durable Primitive

Every durable primitive should be tested in three modes.

### First Execution

The workflow emits commands and blocks:

```elixir
{:ok, exec} = start_workflow(CheckoutWorkflow, %{"order_id" => "123"})

assert {:yield, [%Command.ScheduleActivity{} = cmd]} = next(exec)
assert cmd.seq == 0
assert cmd.type == "MyApp.Activities.Payment.charge"
assert cmd.input == [%{"order_id" => "123"}]
```

### Replay

The same workflow emits the same command decision during replay. The harness matches that command against the transcript and then delivers the recorded resolution job:

```elixir
{:ok, exec} =
  start_workflow(CheckoutWorkflow, %{"order_id" => "123"},
    replay: %Transcript{
      commands: [
        %Command.ScheduleActivity{
          seq: 0,
          type: "MyApp.Activities.Payment.charge",
          input: [%{"order_id" => "123"}]
        }
      ],
      jobs: [
        %Job.ActivityResolved{seq: 0, result: {:ok, "charge_123"}}
      ]
    }
  )

assert {:yield, [%Command.ScheduleActivity{seq: 0}]} = next(exec)

assert {:complete, {:ok, %{charge_id: "charge_123"}}} =
  deliver_replay_jobs(exec)
```

Replay commands are command decisions returned to the backend or harness for matching. They are not new server-side work.

### Nondeterminism

A mismatched replay command fails clearly:

```elixir
{:ok, exec} =
  start_workflow(CheckoutWorkflow, %{"order_id" => "123"},
    replay: %Transcript{
      commands: [
        %Command.StartTimer{seq: 0, duration_ms: 1000}
      ]
    }
  )

assert {:failed, %Temporalex.Core.Nondeterminism{}} = next(exec)
```

## Transcript Tests

Transcript tests validate the central replay invariant.

```elixir
assert {:ok, transcript, result} =
  TestHarness.record(CheckoutWorkflow, input, fn
    %Command.ScheduleActivity{type: "Payment.charge"} ->
      {:ok, "charge_123"}

    %Command.ScheduleActivity{type: "Email.send_receipt"} ->
      {:ok, :sent}
  end)

assert {:ok, ^result} =
  TestHarness.replay(CheckoutWorkflow, input, transcript)
```

Recording turns emitted commands and supplied results into an activation transcript. Replay runs the same workflow with those activations and must emit the same command decisions in the same order.

## Primitive Coverage

Each primitive gets first-execution, replay, and nondeterminism tests:

| Primitive | First execution | Replay | Mismatch |
|---|---|---|---|
| activity | emits `ScheduleActivity` | emits matching schedule command and consumes activity resolution | wrong type/input/options |
| sleep | emits `StartTimer` | emits matching timer command and consumes timer fire | wrong duration or event type |
| workflow time | reads activation timestamp | reads replayed activation timestamp | wrong timestamp in transcript |
| random/uuid | reads deterministic random seed | reads replayed seed updates | wrong seed update ordering |
| patch marker | emits `SetPatchMarker` | reads patch notification and emits matching marker when expected | wrong patch ordering |
| child workflow | emits start child command | emits matching start command and consumes child result | wrong child type/options |
| continue-as-new | emits terminal command | terminal command is stable | incompatible terminal command |

Some rows can wait until the primitive exists, but this is the testing pattern.

## Process Lifecycle Tests

Lifecycle tests should exercise real processes:

- runner success becomes `CompleteWorkflow`
- runner `{:error, reason}` becomes `FailWorkflow`
- `API.continue_as_new!/2` becomes terminal `ContinueAsNew`
- unsupported runner return values become `FailWorkflow`
- runner crash becomes workflow failure
- executor crash tears down linked runner
- blocked runner remains alive while waiting for resolution
- no workflow process carries process dictionary keys other than `:__temporal_context__`
- executor receives `{:EXIT, runner_pid, reason}` for runner termination

These tests protect the OTP semantics that the rest of the SDK depends on.

## Invariant Tests

The test harness should expose inspection helpers for invariant checks:

```elixir
TestHarness.pending_calls(exec)
TestHarness.replay_remaining_commands(exec)
TestHarness.commands(exec)
TestHarness.published_state(exec)
TestHarness.phase_state(exec)
TestHarness.thread_states(exec)
```

Important invariants:

- replay transcript entries are consumed exactly once
- replay transcript entries are consumed in order
- replay emits command decisions that match the transcript exactly
- command sequence numbers are unique and monotonic
- command order is stable across repeated runs
- every blocking command has one pending caller
- every resolution wakes at most one caller
- updates outside matching phase scopes are rejected
- signal buffering preserves arrival order
- phase state and published query state are separate

## Parallel Tests

Parallel tests must prove command order does not depend on BEAM scheduling.

Example workflow:

```elixir
def run(_) do
  API.parallel!([
    fn -> Activities.Work.run(:a) end,
    fn -> Activities.Work.run(:b) end,
    fn -> Activities.Work.run(:c) end
  ])
end
```

Expected command order:

```elixir
assert [
  %Command.ScheduleActivity{thread_id: [{:p, 0}]},
  %Command.ScheduleActivity{thread_id: [{:p, 1}]},
  %Command.ScheduleActivity{thread_id: [{:p, 2}]}
] = commands
```

Run the same test repeatedly. It should never depend on mailbox timing.

Round-robin tests should also cover partial progress:

- initial fan-out schedules each runnable branch's first pausing command
- if only branch `A` resolves, branch `A` may continue without waiting for branch `B`
- if branches `A` and `B` resolve in the same activation, their next commands are emitted in stable branch order
- a unit that becomes runnable during a scheduler round is deferred to the next round

## Phase And Update Tests

Phase tests should read as message transcripts:

```elixir
{:ok, exec} = start_workflow(CounterWorkflow, %{})

assert {:waiting, info} = next(exec)
assert "increment" in info.signals
assert "done" in info.signals

assert {:waiting, _} = send_signal(exec, "increment", nil)
assert {:complete, {:ok, 1}} = send_signal(exec, "done", nil)
```

Update tests should cover acceptance, rejection, replies, and completion:

```elixir
assert {:update_reply, :ok, {:waiting, _}} =
  send_update(exec, "add_item", [%{sku: "A"}])

assert {:update_rejected, "invalid SKU"} =
  send_update(exec, "add_item", [%{sku: ""}])
```

Async handler tests should verify:

- accepted update response is emitted before handler completion
- accepted update response is emitted before any commands produced by the update handler
- handler return value becomes update completion result
- handler failures fail the update, not the whole workflow
- `API.update_state/1` transformations are serialized in executor order
- `API.update_state/1` closures cannot call workflow APIs or block on workflow operations
- phase does not return until bound async handlers finish
- phase timeout emits a durable timer, returns `{:timeout, state}` when it fires, and cancels the timer if the phase exits first

## Relationship To Backend Tests

Core tests use only core structs. Server/backend tests can later use `Temporalex.Backend.Test` to deliver the same structs through the server boundary.

The real Temporal backend should then have separate contract tests:

- Temporal activation bytes decode to expected `%Temporalex.Core.Activation{}`
- `%Temporalex.Core.Completion{}` encodes to expected Temporal completion bytes
- ETF payload conversion uses `term_to_binary/1` and `binary_to_term/1`

Core tests should not change when the real backend is added.
