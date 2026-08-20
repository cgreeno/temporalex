# Workflow Testing

`Temporalex.Testing` is the fast workflow test surface for application tests.
It runs workflow code through the real Temporalex executor without starting a
Temporal server.

Use this for the common test shape:

- start a workflow
- assert the Temporal-visible work it scheduled
- complete or fail that work explicitly
- send signals, updates, queries, or cancellation
- assert the terminal result
- replay the recorded activation transcript

This is different from Temporal dev-server integration tests. Dev-server tests
are still valuable for SDK/backend conformance, but most application workflow
tests should stay deterministic, local, and fast.

## Running the external suite

External tests (`@moduletag :external`) need a Temporal dev server at
`127.0.0.1:7233` and are excluded by default:

```
mix test                     # unit only
mix test --include external  # unit + live
```

**Each run gets its own Temporal namespace**, created by
`test_support/temporal_namespace.ex` and named `temporalex-test-<time>-<pid>`.
That is what makes concurrent runs safe, and the reason is worth knowing:
several tests declare a *fixed* task queue — `use Temporalex.Workflow,
queue: "surface-greet"` and friends — which cannot be made unique per run.
`use` options are evaluated at compile time, so two runs of one build share
the string, and a worker may not override a declared queue (RFC 0002's
one-source rule). Two runs in the *same* namespace would therefore poll the
same queue, and Temporal would deliver each task to whichever worker asked
first: one run executing the other's workflows, surfacing as a failure that
does not reproduce.

Task queues are namespace-scoped, so the isolation goes one level up instead.
Identical queue names in different namespaces never meet.

### The rule for new end-to-end tests

**Every E2E test runs in a namespace, never in `default` on a shared server.**
Two shapes satisfy that, and new tests must pick one deliberately:

1. **Shared dev server, per-run namespace** (the common case) — pass
   `namespace: Temporalex.TestSupport.Namespace.name()` wherever a client is
   started, and pass `--namespace` to any `temporal` CLI invocation so the CLI
   talks to the same namespace the workers poll. Task queues may then be fixed
   strings safely.
2. **Its own dev server** — `Temporalex.TestSupport.TemporalDevServer.start!/1`
   picks a free port, so such a test is already isolated by port and should
   stay on `namespace: "default"` (its private server has no per-run
   namespace).

Mixing them is the trap: a test that starts its own server but asks for the
run namespace will fail, because that namespace exists on the *shared* server.
`temporal_core_integration_test`, `temporal_worker_restart_test`,
`temporal_client_semantics_test` and `temporal_cli_smoke_test` are the
own-server tests today.

Race conditions between namespaces and queues are themselves tested — see
`test/temporalex/integration/queue_isolation_test.exs`, which pins that
identical queue names in different namespaces cannot reach each other, that
the same workflow id can run concurrently in two namespaces, and that
sdk-core refuses a second in-process worker on the same namespace + queue
(scale a single worker with `max_concurrent_*` instead).

Notes:

* A freshly registered namespace is not immediately usable — the server caches
  its namespace registry — so setup polls `operator namespace describe` until
  it succeeds rather than assuming.
* Without the `temporal` CLI on `PATH`, setup warns and falls back to
  `default`. A single run is unaffected; two concurrent runs would then
  interfere, so install the CLI if you run suites in parallel.
* Namespaces are left behind rather than deleted. A dev server is ephemeral,
  and keeping them makes a failed run's history inspectable
  (`temporal workflow list --namespace temporalex-test-...`).
* Namespaces do **not** fix two runs sharing one worktree's `_build` and
  compiled NIF. That fails loudly with compile errors rather than silently
  stealing tasks, so it is a caution rather than something to engineer
  around: when delegating to another agent, either it runs the suite or you
  do, not both in the same worktree.

## Basic Shape

Temporalex does not provide an ExUnit case-template macro. Import the helpers
directly or from your own case template:

```elixir
defmodule MyApp.CheckoutWorkflowTest do
  use ExUnit.Case, async: true

  import Temporalex.Testing

  test "checkout charges the card" do
    {:ok, run} =
      start_workflow(MyApp.Workflows.Checkout, %{order_id: "ord_123"})

    charge =
      assert_next_activity(run,
        type: {MyApp.Activities, :charge_card},
        input: [%{order_id: "ord_123"}]
      )

    complete_activity(run, charge, {:ok, %{charge_id: "ch_123"}})

    assert_completed(run, :complete)
    assert_replay(run)
  end
end
```

## Linear Command Consumption

Each activation may emit one or more commands. Tests consume those commands in
deterministic emission order:

```elixir
first = assert_next_activity(run, input: [:first])
second = assert_next_activity(run, input: [:second])
assert_no_commands(run)
```

After a command is consumed, the returned handle can be resolved later. This
allows out-of-order activity completion while preserving deterministic command
assertions:

```elixir
complete_activity(run, second, {:ok, :second_done})
complete_activity(run, first, {:ok, :first_done})
```

The runner rejects new activations while emitted commands are still unconsumed.
That keeps tests honest about the full set of Temporal-visible side effects from
each workflow activation.

## Operation Handles

Activity and timer assertions return handles with the runtime identity needed to
resolve the exact operation:

```elixir
%Temporalex.Testing.Activity{
  seq: 0,
  thread_id: [],
  activity_id: "activity-0",
  type: "MyApp.Activities.charge_card",
  input: [%{order_id: "ord_123"}],
  task_queue: nil,
  headers: %{},
  start_to_close_timeout_ms: 30_000,
  retry_policy: nil,
  cancellation_type: :wait_cancellation_completed
}
```

The `seq` is the executor's pending operation identity. `activity_id` remains
visible because it is part of the Temporal command.

## Inputs

Signals, updates, queries, and cancellation are explicit workflow inputs:

```elixir
signal(run, "approve", [%{by: "alice"}])

update = update(run, "add_item", [%{sku: "ABC"}], protocol_instance_id: "add-item")
assert_next_update_accepted(run, update)
assert_next_update_completed(run, update, :ok)

assert_query(run, "status", [], :approved)

cancel_workflow(run, "user requested")
```

Queries consume their query response internally and return `{:ok, value}` or
`{:error, reason}`. Updates expose their accepted/completed/rejected responses
as commands so tests can observe durable update behavior around blocking work.

## Replay

Every run records an activation transcript. Use `assert_replay/1` to verify that
the same workflow code emits the same commands when replaying that transcript:

```elixir
assert_replay(run)
```

Safe mode defaults to `:fail`, so common nondeterministic workflow mistakes are
caught during these local workflow tests.
