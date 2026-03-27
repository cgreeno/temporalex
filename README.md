# Temporalex

[![CI](https://github.com/cgreeno/temporalex/actions/workflows/ci.yml/badge.svg)](https://github.com/cgreeno/temporalex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/temporalex.svg)](https://hex.pm/packages/temporalex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/temporalex)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Durable workflow orchestration for Elixir, built on the [Temporal](https://temporal.io) Rust Core SDK.

Retries, timers, signals, queries, versioning, and child workflows — all backed by Temporal's battle-tested infrastructure, all feeling like native Elixir.

## Features

**Durable Execution** -- Workflows survive crashes, restarts, and deployments. Pick up exactly where you left off.

**Activity Orchestration** -- Schedule side-effectful work (HTTP calls, DB writes, APIs) with automatic retries and timeouts.

**Signals and Queries** -- Send data into running workflows and read their state without stopping them.

**Child Workflows** -- Compose complex business processes from smaller, reusable workflows.

**Timers** -- Durable sleeps from seconds to months. Works with `:timer.hours(24)`.

**Versioning** -- Safely deploy new workflow logic while old executions finish on the previous version.

**DSL Mode** -- Define activities as plain functions with `defactivity`. They auto-detect their execution context.

**Testing Without a Server** -- Stub activities, simulate signals, and test workflows in pure Elixir.

**Temporal Cloud Ready** -- API key auth, custom headers, and TLS out of the box.

## Requirements

- Elixir ~> 1.17
- Rust toolchain ([rustup.rs](https://rustup.rs))
- Temporal server (local: `temporal server start-dev`)

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [{:temporalex, "~> 0.1.0"}]
end
```

Then follow the [Installation Guide](guides/introduction/installation.md).

## Quick Start

Build a checkout flow: charge the card, send a receipt, wait for shipping confirmation.

### 1. Define activities

Activities are where side effects live — API calls, database writes, emails.

```elixir
defmodule MyApp.Activities.Payments do
  use Temporalex.Activity, start_to_close_timeout: 10_000

  @impl true
  def perform(%{order_id: order_id, amount: amount}) do
    case PaymentService.charge(order_id, amount) do
      {:ok, charge_id} -> {:ok, charge_id}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule MyApp.Activities.Notifications do
  use Temporalex.Activity, start_to_close_timeout: 5_000

  @impl true
  def perform(%{email: email, charge_id: charge_id}) do
    Mailer.send_receipt(email, charge_id)
    {:ok, "sent"}
  end
end
```

### 2. Define a workflow

Workflows orchestrate activities. They're durable — if the server crashes after charging the card, it picks up at the receipt step, not the beginning.

```elixir
defmodule MyApp.Workflows.Checkout do
  use Temporalex.Workflow

  def run(%{"order_id" => order_id, "amount" => amount, "email" => email}) do
    # Charge the card (retries automatically on transient failures)
    {:ok, charge_id} = execute_activity(MyApp.Activities.Payments, %{
      order_id: order_id, amount: amount
    })

    # Send receipt
    {:ok, _} = execute_activity(MyApp.Activities.Notifications, %{
      email: email, charge_id: charge_id
    })

    # Wait for warehouse to confirm shipping (could be hours or days)
    set_state(%{status: "awaiting_shipment", charge_id: charge_id})
    {:ok, tracking} = wait_for_signal("shipment_confirmed")

    {:ok, %{charge_id: charge_id, tracking: tracking}}
  end

  @impl Temporalex.Workflow
  def handle_query("status", _args, state), do: {:reply, state}
end
```

### 3. Start the worker

```elixir
children = [
  {Temporalex,
    name: MyApp.Temporal,
    task_queue: "checkout",
    workflows: [MyApp.Workflows.Checkout],
    activities: [MyApp.Activities.Payments, MyApp.Activities.Notifications]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### 4. Run it

```elixir
conn = Temporalex.connection_name(MyApp.Temporal)

# Start the checkout
{:ok, handle} = Temporalex.Client.start_workflow(conn,
  MyApp.Workflows.Checkout,
  %{order_id: "ORD-42", amount: 99_00, email: "alice@example.com"},
  id: "checkout-ORD-42", task_queue: "checkout"
)

# Check status while it's waiting for shipping
{:ok, status} = Temporalex.Client.query_workflow(conn, "checkout-ORD-42", "status")
# => %{status: "awaiting_shipment", charge_id: "ch_abc123"}

# Warehouse confirms shipping (could be from another service, webhook, admin panel)
Temporalex.Client.signal_workflow(conn, "checkout-ORD-42", "shipment_confirmed", "TRACK-789")

# Get the final result
{:ok, result} = Temporalex.Client.get_result(handle)
# => %{charge_id: "ch_abc123", tracking: "TRACK-789"}
```

## Guides

Learn Temporalex step by step. Each guide is self-contained with working code.

### Getting Started
- [Installation](guides/introduction/installation.md) -- Dependencies, Rust toolchain, first connection
- [Workflows](guides/learning/workflows.md) -- Your first workflow, the `run/1` callback, determinism rules
- [Activities](guides/learning/activities.md) -- Side effects, `perform/1` vs `perform/2`, heartbeats, retries

### Building Blocks
- [Signals and Queries](guides/learning/signals_and_queries.md) -- Async communication with running workflows
- [Timers and Scheduling](guides/learning/timers_and_scheduling.md) -- Durable sleeps, continue-as-new
- [Child Workflows](guides/learning/child_workflows.md) -- Composing workflows, parent close policies
- [Error Handling](guides/learning/error_handling.md) -- Error types, cancellation, retry policies
- [The DSL](guides/learning/the_dsl.md) -- `defactivity`, auto-detection, inline activities

### Production
- [Testing](guides/learning/testing.md) -- Stubs, signals, assertions, no server needed
- [Observability](guides/learning/observability.md) -- Telemetry events, OpenTelemetry spans, trace propagation
- [Configuration](guides/learning/configuration.md) -- All options, Temporal Cloud, multiple queues
- [Going to Production](guides/advanced/production.md) -- Checklist, graceful shutdown, monitoring

### Recipes
- [Saga Pattern](guides/recipes/saga_pattern.md) -- Compensating transactions on failure
- [Fan-Out / Fan-In](guides/recipes/fan_out_fan_in.md) -- Parallel activities, collect results
- [Long-Running with Signals](guides/recipes/long_running_with_signals.md) -- Approval flows, human-in-the-loop
- [Safe Deployments](guides/recipes/safe_deployments.md) -- Versioning with `patched?/1`

## Coming from Other SDKs

| Concept | Go | Python | TypeScript | Temporalex |
|---------|-----|--------|------------|------------|
| Start workflow | `ExecuteWorkflow` | `execute_workflow` | `client.start` | `Client.start_workflow` |
| Activity call | `ExecuteActivity` | `execute_activity` | `proxyActivities` | `execute_activity` |
| Sleep | `workflow.Sleep` | `workflow.sleep` | `sleep` | `sleep` |
| Signal handler | channel recv | `@workflow.signal` | `wf.signal` | `handle_signal/3` |
| Query handler | function | `@workflow.query` | `wf.query` | `handle_query/3` |

## License

MIT
