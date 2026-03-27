# Going to Production

A checklist for running Temporalex in production.

## Pre-Deploy Checklist

- [ ] All workflows are deterministic (no `DateTime.utc_now()`, no `:rand`, no I/O)
- [ ] Activities have explicit timeouts (`start_to_close_timeout` at minimum)
- [ ] Long-running activities heartbeat
- [ ] `max_concurrent_workflow_tasks` and `max_concurrent_activity_tasks` are tuned for your workload
- [ ] Telemetry handlers are attached for monitoring
- [ ] Error alerts are set up for `[:temporalex, :workflow, :exception]` events

## Graceful Shutdown

Temporalex handles shutdown automatically:

1. Stops accepting new work from Temporal
2. Cancels in-flight activities and sends completions
3. Stops executor processes
4. Drains the NIF worker (waits for Rust-side cleanup)

The default shutdown timeout is 30 seconds. Temporal will reschedule any incomplete work on another worker.

Make sure your deployment tool sends `SIGTERM` and waits before `SIGKILL`:

```yaml
# Kubernetes
terminationGracePeriodSeconds: 60
```

## Connection Resilience

Temporalex automatically retries connection failures with exponential backoff (up to 3 attempts). If the connection fails persistently, the supervisor restarts the entire tree.

Poll failures also use exponential backoff — a transient Temporal server outage won't hot-loop your worker.

## Scaling

### Horizontal Scaling

Run multiple instances of your app. Each connects to Temporal independently. Temporal distributes work across all connected workers via the task queue.

### Tuning Concurrency

```elixir
{Temporalex,
  max_concurrent_workflow_tasks: 20,   # How many workflows process simultaneously
  max_concurrent_activity_tasks: 50,   # How many activities run in parallel
  ...}
```

Higher values = more throughput but more memory and CPU usage. Start conservative and increase based on metrics.

### Multiple Task Queues

Separate workloads by queue to isolate resources:

```elixir
# CPU-intensive work gets its own queue and worker
{Temporalex, name: MyApp.HeavyWorker, task_queue: "heavy",
  max_concurrent_activity_tasks: 2, ...}

# Fast work gets high concurrency
{Temporalex, name: MyApp.FastWorker, task_queue: "fast",
  max_concurrent_activity_tasks: 100, ...}
```

## Monitoring

### Key Metrics to Watch

| Metric | What It Tells You |
|--------|-------------------|
| `temporalex.workflow.stop` count by result | Success vs failure rate |
| `temporalex.workflow.stop` duration | Workflow latency |
| `temporalex.activity.stop` duration | Activity latency |
| `temporalex.worker.activation` duration | Worker processing overhead |
| Temporal UI: schedule-to-start latency | Workers are overloaded (work is queuing) |

### Alerting

Alert on these conditions:
- `workflow.exception` count > 0 (workflow code is crashing)
- `activity.stop` with result=error rate increasing (downstream failures)
- Schedule-to-start latency > 5s (need more workers)

## Versioning Deployments

When deploying new workflow code:

1. Use `patched?/1` to gate new logic
2. Old running workflows take the old path
3. New workflows take the new path
4. When all old executions complete, remove the patch guard and call `deprecate_patch/1`

See the [Safe Deployments recipe](../recipes/safe_deployments.md) for a walkthrough.
