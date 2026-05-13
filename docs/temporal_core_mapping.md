# Temporal Core Mapping

This document maps the Temporal Core worker-facing API to Temporalex core structs. It is based on Temporal Core's local protobuf surface under `temporal/sdk/core`:

- `workflow_activation/workflow_activation.proto`
- `workflow_completion/workflow_completion.proto`
- `workflow_commands/workflow_commands.proto`
- `activity_task/activity_task.proto`
- `activity_result/activity_result.proto`
- `core_interface.proto`

The purpose is alignment. Temporalex does not expose protobuf structs to the core or server, but the internal structs should preserve the same semantics so the real backend can be a translation layer rather than a semantic adapter.

## Worker Boundary

Temporal Core exposes the worker loop as:

1. poll workflow activation
2. run language workflow code for that activation
3. complete workflow activation
4. poll activity task
5. run activity code
6. complete activity task
7. record activity heartbeat when needed

Temporalex maps this to:

```elixir
{:workflow_activation, %Temporalex.Core.Activation{}}
{:workflow_activation_completion, run_id, %Temporalex.Core.Completion{}}
{:activity_task, %Temporalex.Core.ActivityTask{}}
%Temporalex.Core.ActivityCompletion{}
```

The server owns the worker handle and completion submission. The executor owns only deterministic workflow behavior.

## Workflow Activation

Temporal Core's `WorkflowActivation` top-level identity is `run_id`. Workflow id, workflow type, arguments, headers, and start metadata live in the `InitializeWorkflow` job.

Temporalex should follow that shape:

| Temporal Core | Temporalex |
|---|---|
| `WorkflowActivation.run_id` | `%Core.Activation{run_id: run_id}` |
| `timestamp` | `timestamp` |
| `is_replaying` | `is_replaying` |
| `history_length` | `history_length` |
| `history_size_bytes` | `history_size_bytes` |
| `continue_as_new_suggested` | `continue_as_new_suggested` |
| `available_internal_flags` | `available_internal_flags` |
| `deployment_version_for_current_task` | `deployment_version` |
| `jobs` | `jobs` |

There is only one outstanding activation per run. The server can key pending activations by `run_id`; a separate activation id is not part of Temporal Core's contract.

## Activation Jobs

| Temporal Core job | Temporalex job | Notes |
|---|---|---|
| `InitializeWorkflow` | `Job.InitializeWorkflow` | Contains workflow type, workflow id, decoded arguments, headers, workflow info, and randomness seed. |
| `FireTimer` | `Job.TimerFired` | Resolved by `seq`. |
| `ResolveActivity` | `Job.ActivityResolved` | Resolved by `seq`; result is completed, failed, cancelled, or local-activity backoff. |
| `UpdateRandomSeed` | `Job.UpdateRandomSeed` | Updates deterministic random source. |
| `QueryWorkflow` | `Job.QueryReceived` | Query activations do not advance workflow threads. |
| `CancelWorkflow` | `Job.CancelWorkflow` | Sets cooperative cancellation state unless the workflow chooses to return a cancel command. |
| `SignalWorkflow` | `Job.SignalReceived` | Decoded args, headers, and sender identity. |
| `NotifyHasPatch` | `Job.NotifyPatch` | Preemptively tells lang that a patch marker exists. |
| `DoUpdate` | `Job.UpdateReceived` | Must carry both user update `id` and `protocol_instance_id`. |
| `RemoveFromCache` | `Job.RemoveFromCache` | Eviction-only activation; do not invoke workflow code. |

Child workflow, external signal/cancel, local activity, and Nexus jobs map cleanly to additional core jobs later. They do not need to be part of the first core slice.

## Job Ordering

Temporal Core documents this activation job ordering:

1. initialize workflow
2. patches
3. random seed updates
4. signals and updates
5. all other jobs
6. local activity resolutions
7. queries
8. evictions

Temporalex should not depend on mailbox order or BEAM scheduling. The executor should apply all activation jobs to deterministic state first, then drive runnable workflow units using the scheduler rounds defined in [scheduler_and_replay.md](scheduler_and_replay.md).

Signal and update jobs may enqueue handler units, but runnable unit order is still executor-owned and deterministic. Query-only activations should answer queries without advancing workflow threads. Eviction-only activations should complete with no commands and stop cached workflow state.

## Workflow Completion

Temporal Core's `WorkflowActivationCompletion` is status-bearing:

```text
WorkflowActivationCompletion {
  run_id,
  status:
    successful { commands, used_internal_flags, versioning_behavior }
    failed { failure, force_cause }
}
```

Temporalex should preserve that distinction:

```elixir
%Temporalex.Core.Completion{
  run_id: run_id,
  status: {:ok, commands}
}

%Temporalex.Core.Completion{
  run_id: run_id,
  status: {:failed, reason, force_cause: :non_deterministic_error}
}
```

Activation failure is not the same as workflow failure. Workflow failure is a successful activation containing `%Core.Command.FailWorkflow{}`.

## Workflow Commands

Core command mappings:

| Temporal Core command | Temporalex command | Notes |
|---|---|---|
| `StartTimer` | `Command.StartTimer` | Uses zero-based `seq`. |
| `CancelTimer` | `Command.CancelTimer` | Uses the `seq` from the matching `StartTimer`. |
| `ScheduleActivity` | `Command.ScheduleActivity` | Uses zero-based `seq` and explicit `activity_id`. If the user does not provide an id, the executor generates one deterministically from command state. |
| `QueryResult` | `Command.RespondToQuery` | Uses `query_id`. |
| `CompleteWorkflowExecution` | `Command.CompleteWorkflow` | Terminal workflow command. |
| `FailWorkflowExecution` | `Command.FailWorkflow` | Terminal workflow command. |
| `ContinueAsNewWorkflowExecution` | `Command.ContinueAsNew` | Terminal workflow command. |
| `CancelWorkflowExecution` | `Command.CancelWorkflow` | Terminal workflow command. |
| `SetPatchMarker` | `Command.SetPatchMarker` or patch-specific command | Needed for `API.patched?/1` and `API.deprecate_patch/1`. |
| `UpsertWorkflowSearchAttributes` | `Command.UpsertSearchAttributes` | No `seq`. |
| `UpdateResponse` | `Command.RespondToUpdate` | Uses `protocol_instance_id`, not user update id. |

`API.now/0` should use the activation timestamp. `API.random/0` and `API.uuid4/0` should use the deterministic random seed from `InitializeWorkflow` and `UpdateRandomSeed`. These convenience primitives do not need workflow commands.

Later mappings:

- child workflow start/cancel/resolution
- external workflow signal/cancel
- local activities
- Nexus operations
- workflow memo/property modification

## Updates

Temporal Core `DoUpdate` carries:

- `id`: user-facing workflow-unique update id
- `protocol_instance_id`: protocol message instance id
- `name`
- `input`
- `headers`
- `meta`
- `run_validator`

Temporal Core requires an immediate `UpdateResponse` in the same activation:

- `accepted` if the validator passed or validation is skipped
- `rejected` if validation failed or no handler exists

After the update handler finishes, the language SDK sends another response:

- `completed` on success
- `rejected` on handler failure

During replay, `run_validator` is false. Validators must not be re-run from history. The executor should still send the accepted response so command ordering stays identical.

## Queries

Temporal Core says queries always come last and effectively in their own activation. Query-only activations must not advance workflow routines. A query response is a command in the successful activation completion.

The special query id `legacy` means the backend is handling an older query path. Temporalex can preserve it as a normal `query_id`; the backend can apply any special encoding rules.

## Replay

Temporal Core expects language SDKs to emit command decisions during replay. Core matches those commands against history and detects nondeterminism.

Temporalex tests should mirror that behavior:

- first execution records activation commands and resolution jobs
- replay feeds the same activation transcript
- the executor emits the same command decisions in the same order
- mismatched command type, sequence, id, input, or semantic options fails with nondeterminism

Do not model replay as "return recorded results without emitting commands." That would diverge from Temporal Core's worker contract.

## Activity Tasks

Temporal Core activity tasks are either `Start` or `Cancel` under one `ActivityTask` with a `task_token`.

Temporalex maps this to:

```elixir
%Temporalex.Core.ActivityTask{
  task_token: binary(),
  variant: :start | :cancel,
  ...
}
```

Activity completion maps to:

```elixir
%Temporalex.Core.ActivityCompletion{
  task_token: binary(),
  result: {:ok, term()} | {:error, term()} | {:cancelled, term()}
}
```

Heartbeats map to Temporal Core `ActivityHeartbeat`. Core does not return cancellation from heartbeat directly; cancellation is delivered as a separate activity cancel task. The server should set local cancellation state when that task arrives.

## Convenience API Boundary

Convenience workflow APIs should be grounded in Temporal Core activation data, jobs, or commands:

- workflow time comes from activation timestamps
- random values come from workflow random seed jobs
- UUIDs are derived from the deterministic random source
- patch/version APIs map to patch marker jobs and commands
- external reads, writes, ID services, configuration lookups, and network calls belong in activities

The first implementation slice should not include an unmodeled history-recording escape hatch.
