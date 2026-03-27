# Configuration

## All Options

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | *required* | Instance name (e.g., `MyApp.Temporal`) |
| `:task_queue` | *required* | Temporal task queue to poll |
| `:workflows` | `[]` | Workflow modules or `{"Type", &fun/1}` tuples |
| `:activities` | `[]` | Activity modules |
| `:address` | `"http://localhost:7233"` | Temporal server address |
| `:namespace` | `"default"` | Temporal namespace |
| `:api_key` | — | API key for Temporal Cloud |
| `:headers` | `[]` | Custom gRPC headers as `[{"key", "value"}]` |
| `:connection` | — | Shared `Temporalex.Connection` name |
| `:max_concurrent_workflow_tasks` | 5 | Max parallel workflow activations |
| `:max_concurrent_activity_tasks` | 5 | Max parallel activity executions |
| `:codec` | — | Payload codec module or list (encryption, compression) |
| `:interceptors` | `[]` | Interceptor modules for middleware |

## Temporal Cloud

```elixir
{Temporalex,
  name: MyApp.Temporal,
  address: "https://my-namespace.tmprl.cloud:7233",
  namespace: "my-namespace",
  api_key: System.fetch_env!("TEMPORAL_API_KEY"),
  task_queue: "orders",
  workflows: [MyApp.Workflows.ProcessOrder],
  activities: [MyApp.Activities]}
```

## Multiple Task Queues

Run separate workers for different task queues:

```elixir
children = [
  {Temporalex,
    name: MyApp.Orders,
    task_queue: "orders",
    workflows: [MyApp.Workflows.ProcessOrder],
    activities: [MyApp.OrderActivities]},
  {Temporalex,
    name: MyApp.Emails,
    task_queue: "emails",
    workflows: [MyApp.Workflows.SendDigest],
    activities: [MyApp.EmailActivities]}
]
```

Each Temporalex instance has its own connection and worker. They're fully independent.

## Shared Connection

If multiple servers share the same Temporal cluster, share a connection to reduce gRPC connections:

```elixir
children = [
  {Temporalex.Connection,
    name: MyApp.TemporalConn,
    address: "http://localhost:7233",
    namespace: "default"},
  {Temporalex.Server,
    connection: MyApp.TemporalConn,
    task_queue: "orders",
    workflows: [...], activities: [...]},
  {Temporalex.Server,
    connection: MyApp.TemporalConn,
    task_queue: "emails",
    workflows: [...], activities: [...]}
]
```

## Environment-Based Config

```elixir
config :my_app, :temporal,
  address: System.get_env("TEMPORAL_ADDRESS", "http://localhost:7233"),
  namespace: System.get_env("TEMPORAL_NAMESPACE", "default"),
  api_key: System.get_env("TEMPORAL_API_KEY")

# In application.ex
temporal_config = Application.fetch_env!(:my_app, :temporal)

children = [
  {Temporalex,
    name: MyApp.Temporal,
    address: temporal_config[:address],
    namespace: temporal_config[:namespace],
    api_key: temporal_config[:api_key],
    task_queue: "default",
    workflows: [...],
    activities: [...]}
]
```

## What's Next

Ready for production? Check the [production guide](../advanced/production.md).
