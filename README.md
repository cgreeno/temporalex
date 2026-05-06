# Temporalex

Workflow orchestration for Elixir, powered by the [Temporal](https://temporal.io/)
Core SDK (Rust) over Rustler NIFs.

Temporalex workflows read top-to-bottom as sequential code. Concurrency is
explicit, scoped, and structured — there is no implicit event loop. Activities,
timers, signals, queries, updates, child workflows, and continue-as-new all
work the same way they do in the official SDKs, but the programming surface is
designed for Elixir, not transliterated from another language.

> **Status: 0.2.0 on Hex.** From this release forward, upgrades aim to be
> backwards-compatible within the `0.x` line — no more clean-slate rewrites.
> Breaking changes will be flagged in the CHANGELOG and accompanied by a
> deprecation period whenever practical. 303 unit tests plus end-to-end
> integration tests against a live Temporal dev server.

---

## Install

```elixir
# mix.exs
defp deps do
  [{:temporalex, "~> 0.2.0"}]
end
```

Requirements: Elixir ~> 1.15, Rust ~> 1.94 (the NIF crate compiles on first
build).

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

  defactivity charge(amount) do
    {:ok, "charge-#{amount}"}
  end

  # Local activities run in-process, are recorded in workflow history,
  # and survive worker crashes — the durable replacement for `side_effect/1`.
  defactivity tag_id(prefix), local: true do
    {:ok, "#{prefix}-#{System.unique_integer([:positive])}"}
  end
end
```

## Define a workflow

```elixir
defmodule MyApp.Workflows.Checkout do
  use Temporalex.Workflow

  def handle_query("status", _args, state), do: {:reply, state}

  def run(args) do
    API.publish_state(:charging)
    {:ok, charge} = MyApp.Activities.Payment.charge(args["amount"])

    API.publish_state(:awaiting_confirmation)
    confirmed =
      API.receive(false,
        signal: %{
          "confirm" => fn _payload, _ -> {:stop, true} end,
          "cancel"  => fn _payload, _ -> {:stop, false} end
        },
        timeout: :timer.minutes(5)
      )

    if confirmed do
      {:ok, %{charge: charge, confirmed: true}}
    else
      {:error, :user_cancelled}
    end
  end
end
```

## Start a worker

```elixir
children = [
  {Temporalex.Worker,
   url: "http://localhost:7233",
   namespace: "default",
   task_queue: "checkout",
   workflows: [MyApp.Workflows.Checkout],
   activities: [MyApp.Activities.Payment]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Drive workflows from a client

```elixir
{:ok, client} = Temporalex.Client.connect("http://localhost:7233")

{:ok, _run_id} =
  Temporalex.Client.start_workflow(client, "default",
    workflow_id: "checkout-#{order_id}",
    workflow_type: "MyApp.Workflows.Checkout",
    task_queue: "checkout",
    input: %{"amount" => 100},
    execution_timeout_ms: :timer.hours(1)
  )

:ok = Temporalex.Client.signal_workflow(client, "default",
        workflow_id: "checkout-#{order_id}", signal_name: "confirm")

{:ok, status} = Temporalex.Client.query_workflow(client, "default",
                  workflow_id: "checkout-#{order_id}", query_type: "status")
```

---

## Programming model

Workflows are a single function. Concurrency enters only through `receive` and
`parallel`, which scope all spawned work — every async handler must complete
before the scope returns.

| Primitive | Where | Purpose |
| --- | --- | --- |
| `defactivity` calls | anywhere | Schedule an activity, block until it resolves. |
| `API.execute_local_activity/3` | anywhere | Same, but in-process and durable. |
| `API.sleep(ms)` | anywhere | Durable timer. |
| `API.wait_for_signal(name)` | anywhere | Pop one signal from the buffer. |
| `API.publish_state(state)` | anywhere | Update the snapshot queries see. |
| `API.patched?(id)` | anywhere | Workflow versioning, replay-safe. |
| `API.receive(state, opts)` | anywhere | Message-processing scope with signal/update handlers. |
| `API.parallel(fns)` | anywhere | Concurrent fan-out, results in input order. |
| `API.update_state(fn)` | inside an async handler | Atomically transform the receive's reducer state. |

Full details, return-value contracts, and design rationale: see
[`docs/architecture.md`](docs/architecture.md).

---

## Testing

`Temporalex.Testing` runs workflows step-by-step without a Temporal server.
Each blocking primitive surfaces as a descriptor you resolve in the test:

```elixir
test "checkout charges then waits for confirmation" do
  {:ok, exec} = Temporalex.Testing.start_workflow(MyApp.Workflows.Checkout, %{"amount" => 50})

  assert {:activity, call} = Temporalex.Testing.next(exec)
  assert call.type == "MyApp.Activities.Payment.charge"

  assert {:receive, info} = Temporalex.Testing.resolve(exec, {:ok, "charge-50"})
  assert "confirm" in info.signals

  Temporalex.Testing.send_signal(exec, "confirm")
  Process.sleep(20)

  assert {:ok, %{confirmed: true}} = Temporalex.Testing.next(exec)
end
```

Replay-state hooks are available too — see
`Temporalex.Testing.start_workflow/3` `:is_replaying` and `:seen_patches`
options.

---

## Project layout

```
lib/temporalex/
  workflow.ex          use Temporalex.Workflow + the API module
  workflow/api.ex      sequential primitives, receive, parallel
  activity.ex          defactivity macro
  activity/context.ex  heartbeat, cancelled? for activity bodies
  worker.ex            Supervisor — what users add to their tree
  worker/server.ex     poll-loop owner + dispatcher
  worker/executor.ex   per-workflow-task GenServer (production)
  worker/replay.ex     pure replay-log construction & consumption
  testing.ex           step-by-step test driver
  testing/executor.ex  per-workflow-task GenServer (testing)
  client.ex            start/signal/query/cancel from outside workflows
  converter.ex         ETF / JSON / binary payload conversion
  native.ex            Rustler NIF surface (do not call directly)
  runtime.ex           per-app Tokio runtime singleton
native/temporalex_native/
  src/                 Rust NIF crate — proto bridge, client ops, worker
```

---

## Contributing

The project is in active development. [`docs/architecture.md`](docs/architecture.md)
is the source of truth for the workflow programming model — read it before
proposing changes to the public API.

## License

MIT — see [LICENSE](LICENSE).
