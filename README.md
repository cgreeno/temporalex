# Temporalex

Workflow orchestration for Elixir, built on the [Temporal](https://temporal.io/)
Core SDK (Rust) over Rustler NIFs.

Temporalex workflows read top-to-bottom as sequential code. Concurrency is
explicit and structured — there is no implicit event loop. The runtime uses a
**deterministic cooperative scheduler** that owns thread ordering, so command
sequences are reproducible from the same activation transcript regardless of
BEAM scheduling or mailbox timing.

> **Status: alpha** — in alpha testing on production non-critical flows.
>
> Core design and scheduler authored by [@hansihe](https://github.com/hansihe).

---

## Install

```elixir
# mix.exs
defp deps do
  [{:temporalex, "~> 0.5"}]
end
```

Requirements: Elixir `~> 1.17`. The NIF ships precompiled for common targets
(macOS arm64/x86_64, Linux gnu/musl arm64/x86_64) — no Rust toolchain needed.

On any other platform (Windows, BSDs), or to compile from source by choice:
set `TEMPORALEX_BUILD=1` **and** add `{:rustler, ">= 0.0.0", optional: true}`
to your own deps (it is an optional dependency here, so it is not in your
tree by default). Source builds require Rust and protoc; the crate builds
against `temporalio/sdk-rust` v0.4.0. Checkouts of this repository always
build from source.

## Run a Temporal dev server

```bash
brew install temporal
temporal server start-dev
```

The Web UI lands at <http://localhost:8233>; the gRPC endpoint at
`localhost:7233`.

---

## Define and call a workflow

A workflow module declares what it is — behaviour, identity, address — and
`use` generates the call-side surface:

```elixir
defmodule Greet do
  use Temporalex.Workflow, queue: "greetings"

  @impl true
  def id(name), do: "greet-\#{name}"

  @impl true
  def run(name), do: {:ok, "Hello, \#{name}!"}
end
```

```elixir
greeting = Greet.execute!("Fresha")          # start, wait, get the answer
handle   = Greet.start!("Fresha")            # start and move on
greeting = Temporalex.await!(handle)         # collect later

booking_id                                    # policy, when a call carries it
|> Booking.new()
|> Temporalex.retry(max_attempts: 3)
|> Temporalex.fairness(salon_id)
|> Temporalex.execute!()
```

`id/1` derives the workflow id — Temporal's idempotency key — so a duplicate
start attaches to the running execution and a webhook can signal it knowing
only the business key: `Booking.signal!(booking_id, "confirmed")`. Design and
rationale: `docs/rfcs/0002-client-surface.md`.

## Define an activity

```elixir
defmodule MyApp.Activities.Payment do
  # options on `use` are module-wide defaults; per-activity options override
  use Temporalex.Activity, start_to_close_timeout: 30_000

  # name: pins the wire type, so renaming the module can't strand
  # in-flight workflows
  defactivity charge(amount), name: "payment.charge" do
    {:ok, "charge-#{amount}"}
  end

  # Local activity: runs in-process on the same worker, durable via a
  # history marker. Use for short, deterministic work where the network
  # round-trip to schedule a regular activity isn't worth it.
  defactivity stamp(prefix), local: true, start_to_close_timeout: 5_000 do
    {:ok, "#{prefix}-#{System.unique_integer([:positive])}"}
  end
end
```

Workflow code calls `Payment.charge!(amount)` — policy lives at the
definition, the call site names only data. One-off overrides are keyword
options, validated against what the backend honours:

```elixir
Payment.charge!(amount, timeout: 10_000)
```

Unit-test the implementation directly — no Temporal anywhere:

```elixir
assert {:ok, receipt} = Temporalex.Testing.run_activity(Payment, :charge, [100])
```

## Structured errors

Activities fail with `Temporalex.fail!/2`, or by returning `{:error, reason}`.
The workflow receives Temporal's failure tree, which preserves the business
error as the cause:

```elixir
defactivity charge(amount) do
  if amount > 10_000 do
    Temporalex.fail!("amount exceeds limit", type: "AmountTooLarge", retry: false)
  else
    {:ok, amount}
  end
end

# In the workflow:
case Activities.charge(amount) do
  {:ok, charge}                                 -> ...
  {:error, %{cause: %{type: "AmountTooLarge"}}} -> ...
end
```

The outer layer is the `%Temporalex.Failure.ActivityError{}` that Temporal
wraps a failed task-queue activity in. It is kept rather than folded away
because it records which activity failed and how it ended: `retry_state`
(`:non_retryable_failure` or `:maximum_attempts_reached`), `activity_type` and
`activity_id`. Activities declared `local: true` are the exception. Their
failures arrive unwrapped, as the raised error itself.

`retry: false` makes the failure final. Otherwise Temporal retries the
activity under its retry policy. `type:` is the string that a retry policy's
`non_retryable_error_types` matches on.

To match on the type without reaching through the wrapper by hand — and
without caring which of the two shapes arrived — use the guard, which works
in `case`, `with`, and function heads:

```elixir
import Temporalex.Failure, only: [is_failure: 2]

case Activities.charge(amount) do
  {:ok, charge}                                    -> ...
  {:error, e} when is_failure(e, "AmountTooLarge") -> ...  # e.retry_state still available
end
```

`Temporalex.Failure.type/1`, `retry_state/1` and `activity_type/1` read the
same fields for logging paths. An unstructured `raise` in an activity has no
`type` to match — those arrive as the exception itself, so match them by
struct.

## Define a workflow

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
      API.phase(false,
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

## Clients and workers

The worker is not the connection — that's the client. They are different
processes with different jobs:

|           | Client                            | Worker                                      |
| --------- | --------------------------------- | ------------------------------------------- |
| Is        | the gRPC connection to the server | a poller + executor bound to one task queue |
| Knows     | target, namespace, codec          | which workflows/activities it can run       |
| Needed by | anyone who starts/signals/queries | only nodes that run workflow code           |

One client can back many workers. And a node that only *starts* workflows —
a Phoenix deployment creating bookings, say — needs just a client and no
worker at all: it never polls.

The worker entry in your supervision tree is the deployment topology written
down: "this node serves these workflows." The *list of modules* is that
statement — a property of the deployable — and the task queue derives from
the modules' `queue:` declarations, so it is never stated twice.

## Task queues

A task queue is a rendezvous string — nothing more. Starting a workflow
writes its tasks under a name; workers long-poll a name; whoever polls the
name you wrote to gets the work. There is no server-side registry of which
worker runs which workflow type, so every start names its queue.

| The queue is the unit of… | |
| --- | --- |
| decoupling | callers name a queue, never a host, pod, or process — whoever polls that name picks the work up |
| scaling | more capacity = more workers polling the same name |
| deployment | one queue ≈ one deployable, with its own release cadence and blast radius |
| fairness & versioning | fairness keys and worker deployment versions attach per queue |

Queues are not provisioned; a queue springs into existence the first time
anyone uses its name. Which is what makes a typo dangerous: it does not
error, it creates a new empty queue — and a workflow started there sits
"Running" forever, because nothing polls it.

## Start a client and a worker

```elixir
children = [
  {Temporalex.Client,
   name: MyApp.Temporal,
   backend: Temporalex.Backend.TemporalCore,
   target: "http://127.0.0.1:7233",
   namespace: "default",
   # Starts that pass no :task_queue inherit this one. Without it they go to
   # "default" — which nothing here polls (see "Task queues" above).
   task_queue: "checkout",
   # :etf (default) preserves full Elixir term fidelity.
   # :json makes payloads renderable by `temporal` CLI and non-Elixir
   # clients, at the cost of lossy term encoding (atoms → strings,
   # tuples → unsupported).
   payload_codec: :etf},
  {Temporalex.Worker,
   name: MyApp.Worker,
   client: MyApp.Temporal,
   # The queue derives from the workflow modules' queue: declarations —
   # stating task_queue: here too is a boot error (one queue, one source).
   workflows: [MyApp.Workflows.Checkout],
   activities: [MyApp.Activities.Payment]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Metrics

Temporal's core records worker-side metrics — poller counts, slot usage, and
`schedule_to_start` latency, which is the signal you autoscale workers on.
They are off by default. The exporter belongs to the runtime, so it is
configured on the client:

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

For OTLP instead — to an OpenTelemetry Collector, or any agent with an OTLP
intake:

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

`:prometheus` and `:otlp` are mutually exclusive on one runtime. Other keys:
`metric_prefix` (default `"temporal_"`), `attach_service_name`, and
`durations_as_seconds`.

## Build id

Workers report a build id, which lands on every `WorkflowTaskCompleted` event
and so answers "which release executed this task?" from history or the Web UI:

```elixir
{Temporalex.Worker,
 name: MyApp.Worker,
 client: MyApp.Temporal,
 build_id: System.get_env("BUILD_ID", "dev"),
 workflows: [MyApp.Workflows.Checkout]}
```

Without a `:versioning` option the strategy is `None`, so the build id
identifies but does not affect task routing. Defaults to
`"temporalex-<version>"`. Pass `versioning: [deployment_name: ...,
use_versioning: true, default_behavior: :pinned | :auto_upgrade]` to opt a
worker into deployment-based routing.

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

The full client surface: `start_workflow`, `get_result`, `signal_workflow`,
`query_workflow`, `update_workflow`, `cancel_workflow`, `terminate_workflow`,
`describe_workflow`.

---

## Programming model

Workflows are a single `run/1` function. Concurrency enters only through
`phase` and `parallel`, which act as **structured concurrency scopes** — every
async handler spawned within a scope must complete before the scope returns.

| Primitive | Purpose |
| --- | --- |
| `Activities.Module.fun(args)` | Execute an activity. Blocks until resolved. |
| `API.sleep(ms)` | Durable timer. |
| `API.wait_for_signal(name)` | Pop one signal from the buffer. |
| `API.publish_state(state)` | Update the snapshot that queries see. |
| `API.now/0` `API.random/0` `API.uuid4/0` | Deterministic time/random. |
| `API.patched?(id)` | Workflow versioning, replay-safe. |
| `API.phase(state, opts)` | Message-processing scope with signal/update handlers and an optional `:timeout`. |
| `API.parallel(fns)` | Cooperatively scheduled fan-out. Results in input order. |
| `API.update_state(fn)` | Atomically transform the enclosing phase's state from inside an `{:async, fn, _}` handler. |
| `API.execute_child_workflow(mod, input, opts)` | Start a child workflow, block until it completes. |
| `API.start_child_workflow(mod, input, opts)` | Start a child non-blocking; returns a `ChildHandle`. |
| `API.await_child_workflow(handle)` | Block until a started child completes. |
| `API.signal_child_workflow(handle_or_id, name, args)` | Send a durable signal to a child workflow. |
| `API.cancel_child_workflow(handle_or_id)` | Request cancellation of a child workflow. |

Full details, return-value contracts, and the determinism rationale:

- [`docs/programming_model.md`](docs/programming_model.md) — public workflow programming model
- [`docs/scheduler_and_replay.md`](docs/scheduler_and_replay.md) — scheduler rounds, pause points, replay matching
- [`docs/implementation_principles.md`](docs/implementation_principles.md) — internal invariants and admission rules
- [`docs/sdk_overview.md`](docs/sdk_overview.md) — architecture map

---

## Testing

`Temporalex.Backend.Test` is an in-memory backend that lets you drive a worker
with core activation structs directly — no Temporal server required. The same
`Temporalex.Server` and `Temporalex.Core.Executor` that handle real traffic
also handle the test backend, so workflow code under test runs the production
codepath.

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

See `test/temporalex/server_integration_test.exs` for full activation and
activity-task transcripts.

---

## Project layout

```
lib/temporalex/
  workflow.ex                use Temporalex.Workflow
  workflow/api.ex            sequential primitives, phase, parallel
  activity.ex                defactivity macro
  activity/context.ex        heartbeat, cancelled? for activity bodies
  client.ex                  start / get_result / signal / query / update / cancel / terminate / describe
  worker.ex                  Supervisor — what users add to their tree
  server.ex                  Worker server: backend state, executor registry, activation routing
  core/executor.ex           deterministic workflow executor (scheduler + replay)
  core/structs.ex            internal protocol: Activation, Job, Command, Completion, Op
  core/test_harness.ex       in-process harness for testing the core directly
  backend.ex                 Backend behaviour
  backend/test.ex            in-memory backend for tests
  backend/temporal_core.ex   Rustler-backed Temporal Core backend
  native.ex                  Rustler NIF surface (do not call directly)
native/temporalex_nif/
  src/                       Rust NIF crate
```

---

## Contributing

The architecture is documented in [`docs/`](docs/). Start with
[`docs/sdk_overview.md`](docs/sdk_overview.md). The `docs/implementation_principles.md`
admission rule applies to any new workflow API: a primitive only enters the
public surface if it has a precise replay contract and can be tested without
the real Temporal backend.

Run the quality gates before committing — CI enforces all four:

```bash
mix format
mix test
mix credo --strict
mix dialyzer
```

Credo is configured in [`.credo.exs`](.credo.exs). The few relaxations
(Temporal-style exception names, NIF stub arities) are commented in the
config; individually exempted functions carry
`credo:disable-for-next-line` comments at the site explaining why.

## License

MIT — see [LICENSE](LICENSE).
