# Temporalex

Workflow orchestration for Elixir, built on the [Temporal](https://temporal.io/)
Core SDK (Rust) over Rustler NIFs.

A Temporalex workflow reads top to bottom as ordinary sequential code. Nothing
runs concurrently unless you ask for it. When you do ask, you ask through a
named scope, so the concurrency is visible in the source.

The runtime uses a deterministic cooperative scheduler. The scheduler owns
thread ordering, so the same activation transcript always produces the same
command sequence. BEAM scheduling and mailbox timing do not change the result.

> **Status: alpha.** In alpha testing on production non-critical flows.
>
> Core design and scheduler authored by [@hansihe](https://github.com/hansihe).

## Requirements

| | |
| --- | --- |
| Elixir | `~> 1.17` |
| Rust toolchain | not needed on common platforms, see [Install](#install) |
| Temporal server | a dev server is enough, see [Run a Temporal dev server](#run-a-temporal-dev-server) |

## Install

```elixir
# mix.exs
defp deps do
  [{:temporalex, "~> 0.5"}]
end
```

The NIF ships precompiled for six targets:

```
aarch64-apple-darwin          x86_64-apple-darwin
aarch64-unknown-linux-gnu     x86_64-unknown-linux-gnu
aarch64-unknown-linux-musl    x86_64-unknown-linux-musl
```

On those targets you need no Rust toolchain.

### Building from source

You must build from source on any other platform, such as Windows or a BSD. You
can also choose to build from source anywhere. Two steps are required:

1. Set `TEMPORALEX_BUILD=1`.
2. Add `{:rustler, ">= 0.0.0", optional: true}` to your own deps. Rustler is an
   optional dependency here, so it is not in your tree by default.

A source build needs Rust and `protoc`. The crate builds against
[`temporalio/sdk-rust`](https://github.com/temporalio/sdk-rust) tag `v0.7.0`.

A checkout of this repository always builds from source.

## Run a Temporal dev server

```bash
brew install temporal
temporal server start-dev
```

The Web UI serves at <http://localhost:8233>. The gRPC endpoint listens on
`localhost:7233`.

## Your first workflow

A workflow module declares three things: its behaviour, its identity, and its
address. `use Temporalex.Workflow` reads those declarations and generates the
functions that callers use.

```elixir
defmodule Greet do
  use Temporalex.Workflow, queue: "greetings"

  @impl true
  def id(name), do: "greet-#{name}"

  @impl true
  def run(name), do: {:ok, "Hello, #{name}!"}
end
```

`queue:` is the task queue the workflow is served on. `id/1` derives the
workflow id. `run/1` is the workflow body.

Three ways to call it:

```elixir
greeting = Greet.execute!("Fresha")     # start, wait, return the answer
handle   = Greet.start!("Fresha")       # start and move on
greeting = Temporalex.await!(handle)    # collect the answer later
```

When a call needs a policy, build it up with a pipeline. Each function takes the
struct and returns it, so the options compose:

```elixir
booking_id
|> Booking.new()
|> Temporalex.retry(max_attempts: 3)
|> Temporalex.fairness(salon_id)
|> Temporalex.execute!()
```

The pipeline functions are `id`, `queue`, `client`, `input`, `timeout`, `retry`,
`priority`, `fairness`, `index`, `headers`, `cron`, `run_timeout` and
`execution_timeout`. Finish with `start`, `start!`, `execute` or `execute!`.

### Why the workflow id matters

The workflow id is Temporal's idempotency key. Two consequences follow.

First, a duplicate start attaches to the execution that is already running
instead of creating a second one.

Second, any caller that knows the business key can reach the workflow without
storing a handle:

```elixir
Booking.signal!(booking_id, "confirmed")
```

Design and rationale: [`docs/rfcs/0002-client-surface.md`](docs/rfcs/0002-client-surface.md).

## Activities

An activity is a step that talks to the outside world. Workflows decide;
activities do.

```elixir
defmodule MyApp.Activities.Payment do
  use Temporalex.Activity, start_to_close_timeout: 30_000

  defactivity charge(amount), name: "payment.charge" do
    {:ok, "charge-#{amount}"}
  end

  defactivity stamp(prefix), local: true, start_to_close_timeout: 5_000 do
    {:ok, "#{prefix}-#{System.unique_integer([:positive])}"}
  end
end
```

Options on `use` are module-wide defaults. Options on `defactivity` override
them for that one activity.

| Option | Meaning |
| --- | --- |
| `name:` | Pins the wire type. Renaming the module then cannot strand in-flight workflows. |
| `local:` | Runs the activity in-process on the same worker, made durable by a history marker. Use it for short deterministic work where scheduling a regular activity is not worth the network round-trip. |
| `start_to_close_timeout:` | How long one attempt may take. `timeout:` is an accepted spelling of the same option. |

Workflow code calls the generated bang function:

```elixir
Payment.charge!(amount)
```

Policy lives at the definition. The call site names only data. A one-off
override is a keyword option, validated against what the backend honours:

```elixir
Payment.charge!(amount, timeout: 10_000)
```

### Testing an activity

Call the implementation directly. No Temporal server is involved:

```elixir
assert {:ok, receipt} = Temporalex.Testing.run_activity(Payment, :charge, [100])
```

## Errors

An activity fails in one of two ways: it calls `Temporalex.fail!/2`, or it
returns `{:error, reason}`.

```elixir
defactivity charge(amount) do
  if amount > 10_000 do
    Temporalex.fail!("amount exceeds limit", type: "AmountTooLarge", retry: false)
  else
    {:ok, amount}
  end
end
```

`retry: false` makes the failure final. Without it, Temporal retries the
activity under its retry policy. `type:` is the string a retry policy's
`non_retryable_error_types` matches on.

The workflow receives Temporal's failure tree. The business error is preserved
as the cause:

```elixir
case Activities.charge(amount) do
  {:ok, charge}                                 -> ...
  {:error, %{cause: %{type: "AmountTooLarge"}}} -> ...
end
```

### The wrapper

The outer layer is a `%Temporalex.Failure.ActivityError{}`. Temporal adds it
around any task-queue activity that fails. Temporalex keeps the wrapper rather
than folding it away, because it records which activity failed and how it
ended:

| Field | Value |
| --- | --- |
| `retry_state` | `:non_retryable_failure` or `:maximum_attempts_reached` |
| `activity_type` | the activity's wire type |
| `activity_id` | the activity's id |

Activities declared `local: true` are the exception. Their failures arrive
unwrapped, as the raised error itself.

### Matching on the type

Two shapes can therefore arrive for the same business error. The `is_failure/2`
guard matches either one, so you never reach through the wrapper by hand. It
works in `case`, in `with`, and in function heads:

```elixir
import Temporalex.Failure, only: [is_failure: 2]

case Activities.charge(amount) do
  {:ok, charge}                                    -> ...
  {:error, e} when is_failure(e, "AmountTooLarge") -> ...
end
```

`e.retry_state` is still available inside that clause.

Temporal nests failures, and a guard cannot recurse, so `is_failure/2` checks
three levels: the error, its cause, and its cause's cause. Those three cover a
bare local failure, a remote activity's `ActivityError` wrapper, and a child
workflow wrapping one. For deeper nesting use
`Temporalex.Failure.failure?/2`, which walks the whole chain.

For logging paths, `Temporalex.Failure.type/1`, `retry_state/1` and
`activity_type/1` read those fields at whatever depth they sit.

An unstructured `raise` in an activity carries no `type` to match on. Those
arrive as the exception itself, so match them by struct.

## Writing a workflow

A workflow is a single `run/1` function.

```elixir
defmodule MyApp.Workflows.Checkout do
  use Temporalex.Workflow, queue: "checkout"

  alias Temporalex.Workflow.API

  def handle_query("status", _args, state), do: {:reply, state}

  def run(args) do
    API.publish_state(:charging)
    {:ok, charge} = MyApp.Activities.Payment.charge(args["amount"])

    API.publish_state(:awaiting_confirmation)

    confirmed =
      API.phase!(false,
        signal: %{
          "confirm" => fn _args, _state -> {:stop, true} end,
          "cancel"  => fn _args, _state -> {:stop, false} end
        },
        timeout: :timer.minutes(5)
      )

    case confirmed do
      {:timeout, _state} -> {:error, :timed_out}
      true               -> {:ok, %{charge: charge, confirmed: true}}
      false              -> {:error, :user_cancelled}
    end
  end
end
```

Read that in four steps.

1. `publish_state/1` sets the snapshot that `handle_query/3` serves, so a
   caller can ask what the workflow is doing right now.
2. The activity call blocks until Temporal resolves it. If the worker dies
   here, the workflow resumes at this line on another worker.
3. `phase!/2` waits for a signal. The two handlers each return `{:stop, value}`,
   which ends the phase and makes `value` the phase's result.
4. If neither signal arrives within five minutes, `phase!/2` returns
   `{:timeout, state}` instead, where `state` is the `false` it started with.

`phase/2` and `phase!/2` differ in what they return. `phase!/2` returns the
state itself, which is why the `case` above matches a bare `true`. `phase/2`
returns `{:ok, state}` and would need a different `case`.

## Clients and workers

The worker is not the connection. The client is. They are different processes
with different jobs.

| | Client | Worker |
| --- | --- | --- |
| Is | the gRPC connection to the server | a poller and an executor bound to one task queue |
| Knows | target, namespace, codec | which workflows and activities it can run |
| Needed by | anyone who starts, signals or queries | only nodes that run workflow code |

One client can back many workers.

A node that only starts workflows needs a client and no worker at all. A Phoenix
deployment that creates bookings is the common case. It never polls.

The worker entry in your supervision tree is your deployment topology written
down. It says "this node serves these workflows." The list of modules is that
statement, and it is a property of the deployable. The task queue is derived
from the modules' own `queue:` declarations, so it is never stated twice.

## Task queues

A task queue is a rendezvous string. Starting a workflow writes its tasks under
a name. Workers long-poll a name. Whoever polls the name you wrote to gets the
work. The server keeps no registry of which worker runs which workflow type, so
every start names its queue.

| The queue is the unit of | |
| --- | --- |
| decoupling | callers name a queue, never a host, pod or process |
| scaling | more capacity means more workers polling the same name |
| deployment | one queue is roughly one deployable, with its own release cadence and blast radius |
| fairness and versioning | fairness keys and worker deployment versions attach per queue |

Queues are not provisioned. A queue springs into existence the first time anyone
uses its name.

That is why a typo is dangerous. It does not raise an error. It creates a new
empty queue, and a workflow started there sits in Running forever, because
nothing polls it.

## Start a client and a worker

```elixir
children = [
  {Temporalex.Client,
   name: MyApp.Temporal,
   backend: Temporalex.Backend.TemporalCore,
   target: "http://127.0.0.1:7233",
   namespace: "default",
   task_queue: "checkout",
   payload_codec: :etf},
  {Temporalex.Worker,
   name: MyApp.Worker,
   client: MyApp.Temporal,
   workflows: [MyApp.Workflows.Checkout],
   activities: [MyApp.Activities.Payment]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Two options above are easy to get wrong.

**`task_queue:` on the client** is the fallback for starts that pass no
`:task_queue` of their own. Without it those starts go to `"default"`, which
nothing here polls. See [Task queues](#task-queues).

**`task_queue:` on the worker** is a boot error when the worker also declares
workflow modules. The queue comes from the modules' `queue:` declarations. One
queue, one source.

### Payload codecs

| Codec | Behaviour |
| --- | --- |
| `:etf` (default) | Preserves full Elixir term fidelity. |
| `:json` | Payloads are renderable by the `temporal` CLI and by non-Elixir clients. Term encoding is lossy: atoms become strings, and tuples are unsupported. |

## Drive workflows from a client

```elixir
{:ok, handle} =
  Temporalex.Client.start_workflow(
    MyApp.Temporal,
    MyApp.Workflows.Checkout,
    %{"amount" => 100},
    workflow_id: "checkout-#{order_id}"
  )

:ok = Temporalex.Client.signal_workflow(handle, "confirm")
{:ok, status} = Temporalex.Client.query_workflow(handle, "status")
{:ok, result} = Temporalex.Client.get_result(handle)
```

The full client surface is `start_workflow`, `get_result`, `signal_workflow`,
`query_workflow`, `update_workflow`, `cancel_workflow`, `terminate_workflow`,
`describe_workflow` and `fetch_workflow_history`.

Each of `signal_workflow`, `query_workflow`, `update_workflow`,
`cancel_workflow`, `terminate_workflow`, `describe_workflow` and
`fetch_workflow_history` accepts either a `%Handle{}` or a client plus a
workflow id.

## Programming model

Concurrency enters a workflow through exactly two primitives, `phase` and
`parallel`. Both are structured-concurrency scopes. Every async handler spawned
inside a scope must finish before the scope returns.

All of the following live in `Temporalex.Workflow.API`. Most have a `!` variant
that unwraps the result and raises on error.

**Activities**

| Primitive | Purpose |
| --- | --- |
| `Activities.Module.fun(args)` | Execute an activity. Blocks until it resolves. |
| `execute_activity(type, input, opts)` | Execute an activity by wire type. |
| `execute_local_activity(type, input, opts)` | Execute a local activity by wire type. |

**Time and randomness**

| Primitive | Purpose |
| --- | --- |
| `sleep(ms)` | Durable timer. |
| `now/0`, `random/0`, `uuid4/0` | Deterministic time and randomness. |

**Signals, queries and state**

| Primitive | Purpose |
| --- | --- |
| `wait_for_signal(name)` | Pop one signal from the buffer. |
| `publish_state(state)` | Update the snapshot that queries read. |
| `update_state(fun)` | Atomically transform the enclosing phase's state from inside an `{:async, fn, _}` handler. |

**Concurrency scopes**

| Primitive | Purpose |
| --- | --- |
| `phase(state, opts)` | Message-processing scope with signal and update handlers and an optional `:timeout`. Returns the accumulated `state`, `{:timeout, state}` or `{:cancelled, error, partial}`, where `partial` is the state as it stood when the cancel arrived. `phase!/2` returns the state itself and raises on cancellation. |
| `parallel(funs)` | Cooperatively scheduled fan out. Results come back in input order. Returns `{:ok, results}` or `{:cancelled, error, partial}`, where `partial` holds every branch's outcome in input order. `parallel!/1` returns the results and raises on cancellation. |

**Child workflows**

| Primitive | Purpose |
| --- | --- |
| `execute_child_workflow(mod, input, opts)` | Start a child and block until it completes. |
| `start_child_workflow(mod, input, opts)` | Start a child without blocking. Returns a `ChildHandle`. |
| `await_child_workflow(handle)` | Block until a started child completes. |
| `signal_child_workflow(handle_or_id, name, args)` | Send a durable signal to a child. |
| `cancel_child_workflow(handle_or_id)` | Request cancellation of a child. |

**Versioning, metadata and lifetime**

| Primitive | Purpose |
| --- | --- |
| `patched?(id)` | Workflow versioning, replay-safe. |
| `deprecate_patch(id)` | Retire a patch once no in-flight run needs the old branch. |
| `upsert_search_attributes(attrs)` | Set search attributes, which `list --query` can find. |
| `upsert_memo(memo)` | Set memo fields, which `describe` reads back. |
| `headers/0` | Read headers injected by a client interceptor. |
| `workflow_info/0` | Read the current run's id, type, queue and attempt. |
| `continue_as_new!(input, opts)` | Restart the workflow with a fresh history and unbounded lifetime. |

**Cancellation**

| Primitive | Purpose |
| --- | --- |
| `cancelled?/0` | Has cancellation been requested? |
| `cancellation/0` | The cancellation reason. |
| `non_cancellable(fun)` | Run `fun` so that a pending cancellation cannot interrupt it. |

Return value contracts and the determinism rationale live in `docs/`:

| Document | Covers |
| --- | --- |
| [`docs/programming_model.md`](docs/programming_model.md) | the public workflow programming model |
| [`docs/scheduler_and_replay.md`](docs/scheduler_and_replay.md) | scheduler rounds, pause points, replay matching |
| [`docs/implementation_principles.md`](docs/implementation_principles.md) | internal invariants and admission rules |
| [`docs/sdk_overview.md`](docs/sdk_overview.md) | the architecture map |

## Testing

`Temporalex.Testing` runs a workflow in-process with no Temporal server. You
drive it one step at a time and assert on what it did.

```elixir
import Temporalex.Testing

assert {:ok, run} = start_workflow(MyApp.Workflows.Checkout, %{"amount" => 100})

activity = assert_next_activity(run, type: {MyApp.Activities.Payment, :charge})
complete_activity(run, activity, {:ok, "charge-100"})

signal(run, "confirm")

assert_completed(run, %{charge: "charge-100", confirmed: true})
assert_replay(run)
```

`run` is a handle to a runner process, so you never rebind it. The stepping
functions return `:ok`, and the `assert_*` functions either return the value you
asked for or fail the test.

`assert_next_activity/2` filters on the command it expects. The keys are `type`,
`input`, `activity_id`, `thread_id`, `task_queue`, `headers`, `retry_policy`,
`cancellation_type`, and the four timeout keys
(`schedule_to_close_timeout_ms`, `schedule_to_start_timeout_ms`,
`start_to_close_timeout_ms`, `heartbeat_timeout_ms`). Pass no keys to accept any
activity.

The functions group into five jobs:

| Job | Functions |
| --- | --- |
| Start | `start_workflow`, `run_activity`, `run_activity!` |
| Assert what the workflow asked for | `assert_next_activity`, `assert_next_timer`, `assert_next_command`, `assert_no_commands` |
| Answer those requests | `complete_activity`, `fail_activity`, `cancel_activity`, `fire_timer` |
| Send input | `signal`, `update`, `query`, `cancel_workflow` |
| Assert the outcome | `assert_completed`, `refute_completed`, `assert_failed`, `assert_cancelled`, `assert_continue_as_new`, `assert_query`, `assert_next_update_accepted`, `assert_next_update_completed`, `assert_next_update_rejected`, `assert_replay`, `snapshot` |

Two of those are worth calling out. `fire_timer` makes a durable timer expire
instantly, so a test of a five-day wait runs in microseconds. `assert_replay`
replays the recorded history against the current code and fails if the command
sequence differs, which is how you catch a nondeterministic change before it
ships.

### The test backend

Underneath, `Temporalex.Backend.Test` is an in-memory backend. You can drive a
worker with core activation structs directly:

```elixir
start_supervised!(
  {Temporalex.Client, name: MyApp.TestClient, backend: Temporalex.Backend.Test}
)

start_supervised!(
  {Temporalex.Worker,
   name: MyApp.TestWorker,
   client: MyApp.TestClient,
   workflows: [MyApp.Workflows.Checkout],
   activities: [MyApp.Activities.Payment]}
)
```

The same `Temporalex.Server` and `Temporalex.Core.Executor` that handle real
traffic also handle the test backend, so workflow code under test runs the
production codepath.

Full activation and activity-task transcripts:
[`test/temporalex/server_integration_test.exs`](test/temporalex/server_integration_test.exs).

## Metrics

Temporal's core records worker-side metrics: poller counts, slot usage, and
`schedule_to_start` latency, which is the signal you autoscale workers on. They
are off by default.

The exporter belongs to the runtime, so you configure it on the client:

```elixir
{Temporalex.Client,
 name: MyApp.Temporal,
 backend: Temporalex.Backend.TemporalCore,
 target: "http://127.0.0.1:7233",
 namespace: "default",
 telemetry: [
   prometheus: [bind_address: "0.0.0.0:9464"],
   global_tags: %{"service" => "checkout-worker", "env" => "prod"}
 ]}
```

`GET /metrics` on that address then serves, among others:

```
temporal_num_pollers
temporal_worker_task_slots_available
temporal_worker_task_slots_used
temporal_workflow_task_schedule_to_start_latency
temporal_workflow_task_execution_latency
temporal_workflow_endtoend_latency
temporal_workflow_completed
```

To send OTLP instead, to an OpenTelemetry Collector or any agent with an OTLP
intake, replace the `prometheus:` entry with an `otlp:` one:

```elixir
telemetry: [
  otlp: [
    url: "http://localhost:4317",
    protocol: :grpc,                  # or :http
    metric_temporality: :cumulative,  # or :delta
    metric_periodicity_ms: 1_000,
    headers: %{"authorization" => "Bearer ..."}
  ]
]
```

`:prometheus` and `:otlp` are mutually exclusive on one runtime. The other keys
are `metric_prefix` (default `"temporal_"`), `attach_service_name` and
`durations_as_seconds`.

## Build id

Every worker reports a build id. It lands on every `WorkflowTaskCompleted`
event, so history and the Web UI can answer "which release executed this task?"

```elixir
{Temporalex.Worker,
 name: MyApp.Worker,
 client: MyApp.Temporal,
 build_id: System.get_env("BUILD_ID", "dev"),
 workflows: [MyApp.Workflows.Checkout]}
```

The default is `"temporalex-<version>"`.

Without a `:versioning` option the strategy is `None`. The build id then
identifies the release but does not affect task routing.

To opt a worker into deployment-based routing, add a `:versioning` option to
the worker:

```elixir
versioning: [
  deployment_name: "checkout",
  use_versioning: true,
  default_behavior: :pinned      # or :auto_upgrade
]
```

`default_behavior` is required whenever `use_versioning: true`.

## Project layout

```
lib/temporalex.ex              pipeline API: id, retry, fairness, start, execute, await, fail!
lib/temporalex/
  workflow.ex                  use Temporalex.Workflow
  workflow/api.ex              sequential primitives, phase, parallel
  activity.ex                  defactivity macro
  activity/context.ex          heartbeat, cancelled? for activity bodies
  client.ex                    start, get_result, signal, query, update, cancel, terminate, describe
  worker.ex                    Supervisor, the module users add to their tree
  server.ex                    worker server: backend state, executor registry, activation routing
  failure.ex                   failure structs, is_failure guard, type and retry_state readers
  interceptor.ex               client interceptor behaviour
  start.ex                     the %Start{} struct the pipeline API builds
  search_attribute.ex          search attribute encoding
  history.ex                   history fetch and decode
  replay.ex                    replay a recorded history against current code
  child_handle.ex              handle returned by start_child_workflow
  testing.ex                   public in-process test API
  testing/                     Run, Activity, Timer, Update structs and the runner
  core/executor.ex             deterministic workflow executor: scheduler and replay
  core/command_builder.ex      builds core commands from API calls
  core/structs.ex              internal protocol: Activation, Job, Command, Completion, Op
  core/test_harness.ex         in-process harness for testing the core directly
  core/trace_guard.ex          determinism trace checks
  backend.ex                   Backend behaviour
  backend/test.ex              in-memory backend for tests
  backend/temporal_core.ex     Rustler-backed Temporal Core backend
  native.ex                    Rustler NIF surface, do not call directly
native/temporalex_nif/
  src/                         Rust NIF crate
```

## Contributing

The architecture is documented in [`docs/`](docs/). Start with
[`docs/sdk_overview.md`](docs/sdk_overview.md).

`docs/implementation_principles.md` states the admission rule for any new
workflow API. A primitive enters the public surface only if it has a precise
replay contract and can be tested without the real Temporal backend.

CI enforces four quality gates. Run them before committing:

```bash
mix format
mix test
mix credo --strict
mix dialyzer
```

Credo is configured in [`.credo.exs`](.credo.exs). The config comments explain
the few relaxations, which cover Temporal-style exception names and NIF stub
arities. Individually exempted functions carry a `credo:disable-for-next-line`
comment at the site saying why.

## License

MIT. See [LICENSE](LICENSE).
