# Temporalex

Workflow orchestration for Elixir, built on the [Temporal](https://temporal.io/)
Core SDK (Rust) over Rustler NIFs.

Temporalex workflows read top-to-bottom as sequential code. Concurrency is
explicit and structured — there is no implicit event loop. The runtime uses a
**deterministic cooperative scheduler** that owns thread ordering, so command
sequences are reproducible from the same activation transcript regardless of
BEAM scheduling or mailbox timing.

> **Status: 0.3.0.** This release is an architectural rewrite around a
> deterministic core, a `Temporalex.Backend` boundary that isolates Temporal
> Core / Rust details, and structured concurrency primitives `phase` and
> `parallel`. The 0.x line is not backwards-compatible with 0.2.0. See
> [CHANGELOG.md](CHANGELOG.md) for the migration notes.
>
> Core design and scheduler authored by [@hansihe](https://github.com/hansihe);
> see [`docs/scheduler_and_replay.md`](docs/scheduler_and_replay.md) and
> [`docs/implementation_principles.md`](docs/implementation_principles.md).

---

## Install

```elixir
# mix.exs
defp deps do
  [{:temporalex, "~> 0.3.0"}]
end
```

Requirements: Elixir `~> 1.17`, Rust toolchain (the NIF crate compiles on first
build against `temporalio/sdk-rust` v0.4.0).

## Run a Temporal dev server

```bash
brew install temporal
temporal server start-dev
```

The Web UI lands at <http://localhost:8233>; the gRPC endpoint at
`localhost:7233`.

---

## Define an activity

```elixir
defmodule MyApp.Activities.Payment do
  use Temporalex.Activity

  defactivity charge(amount), start_to_close_timeout: 30_000 do
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

## Structured errors

Activities can raise `Temporalex.ApplicationError` (or return `{:error,
reason}`); the workflow sees a typed exception with the cause preserved:

```elixir
defactivity charge(amount) do
  if amount > 10_000 do
    raise %Temporalex.ApplicationError{
      message: "amount exceeds limit",
      type: "AmountTooLarge",
      non_retryable: true
    }
  else
    {:ok, amount}
  end
end

# In the workflow:
case Activities.charge(amount) do
  {:ok, charge}                                                    -> ...
  {:error, %Temporalex.ActivityFailure{cause: %{type: "AmountTooLarge"}}} -> ...
end
```

## Define a workflow

```elixir
defmodule MyApp.Workflows.Checkout do
  use Temporalex.Workflow

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

## Start a worker

```elixir
children = [
  {Temporalex.Worker,
   name: MyApp.Temporal,
   backend: Temporalex.Backend.TemporalCore,
   target: "http://127.0.0.1:7233",
   namespace: "default",
   task_queue: "checkout",
   workflows: [MyApp.Workflows.Checkout],
   activities: [MyApp.Activities.Payment],
   # :etf (default) preserves full Elixir term fidelity.
   # :json makes payloads renderable by `temporal` CLI and non-Elixir
   # clients, at the cost of lossy term encoding (atoms → strings,
   # tuples → unsupported).
   payload_codec: :etf}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

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
  {Temporalex.Worker,
   name: MyApp.Temporal,
   backend: Temporalex.Backend.Test,
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

## License

MIT — see [LICENSE](LICENSE).
