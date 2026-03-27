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

### 1. Define an activity

```elixir
defmodule MyApp.Activities.Greet do
  use Temporalex.Activity, start_to_close_timeout: 5_000

  @impl true
  def perform(%{name: name}) do
    {:ok, "Hello, #{name}!"}
  end
end
```

### 2. Define a workflow

```elixir
defmodule MyApp.Workflows.GreetUser do
  use Temporalex.Workflow

  def run(%{"name" => name}) do
    {:ok, greeting} = execute_activity(MyApp.Activities.Greet, %{name: name})
    {:ok, greeting}
  end
end
```

### 3. Start the worker

```elixir
children = [
  {Temporalex,
    name: MyApp.Temporal,
    task_queue: "greetings",
    workflows: [MyApp.Workflows.GreetUser],
    activities: [MyApp.Activities.Greet]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### 4. Run a workflow

```elixir
conn = Temporalex.connection_name(MyApp.Temporal)
{:ok, handle} = Temporalex.Client.start_workflow(conn, MyApp.Workflows.GreetUser, %{name: "Alice"})
{:ok, "Hello, Alice!"} = Temporalex.Client.get_result(handle)
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
