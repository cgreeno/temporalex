# Temporalex Workflow Programming Model

## Overview

A Temporalex workflow is a **single function** that reads top-to-bottom as sequential code. Concurrency is introduced through two explicit constructs — `receive` and `parallel` — which act as structured concurrency scopes. All async work is bound to the scope that spawned it and must complete before the scope returns.

The design principles:

1. **Workflows are functions.** A workflow is a module with a `run/1` function. It calls activities, sleeps, waits for signals, and returns a result. There is no implicit event loop or background message processing.

2. **Concurrency is scoped and explicit.** The only way to introduce concurrent execution is by entering a `receive` or `parallel` block. The keyword `{:async, fn, state}` must be explicitly returned to spawn concurrent work. Nothing is concurrent by default.

3. **State is what you make it.** There is no framework-managed "workflow state" that handlers implicitly share. `receive` has reducer state (an accumulator). Queries see only what you explicitly publish. These are separate concerns.

4. **Structure determines validity.** Which updates and signals a workflow accepts is determined by which `receive` block it's currently in. An update that arrives when the workflow isn't in a `receive` expecting it is rejected. The code structure declares what's valid when.

---

## The Primitive Set

### Sequential Primitives

These are blocking calls available anywhere in workflow code (in `run/1`, inside handlers, inside parallel branches):

**`Activities.Module.function(args)`** — Execute an activity. Blocks until the activity completes or fails. This is the primary way workflows interact with the outside world.

**`API.sleep(duration_ms)`** — Durable timer. Blocks for the specified duration. Survives process restarts. The executor schedules a `StartTimer` command and the runner resumes when the timer fires.

**`API.wait_for_signal(name)`** — Blocks until a signal with the given name arrives. Consumes one signal from the buffer. If a matching signal is already buffered, returns immediately. Signals are a queue — multiple signals with the same name accumulate and are consumed one at a time.

**`API.side_effect(fn)`** — Executes a non-deterministic function **once** and records its return value in history. On replay, the function is not re-executed — the recorded value is returned. Use for things like reading a config value, generating an external ID, or capturing a timestamp for business logic. The function must not fail and must not have side effects beyond computing a value. If you need side effects (network calls, mutations), use an activity instead.

```elixir
order_number = API.side_effect(fn -> MyApp.Sequences.next("orders") end)
correlation_id = API.side_effect(fn -> UUID.uuid4() end)
```

**`API.publish_state(state)`** — Publishes a state snapshot that queries can read. Non-blocking. Can be called from anywhere. This is the only way to make state visible to queries. Calling it replaces the previously published state entirely.

### Versioning

**`API.patched?(patch_id)`** — Workflow versioning. Returns `true` on new executions (emits a `SetPatchMarker` command). On replay, returns `true` only if the patch was recorded in history. Use to branch between old and new code paths when changing workflow logic while executions are in-flight.

**`API.deprecate_patch(patch_id)`** — Marks a patch as deprecated. Call after all pre-patch executions have completed. Emits a marker but doesn't cause replay failure if missing.

```elixir
if API.patched?("use-new-pricing") do
  Activities.Pricing.v2(item)
else
  Activities.Pricing.v1(item)
end
```

### Structured Concurrency Hosts

These are blocking calls that can host concurrent work within their scope:

**`API.receive(state, handlers)`** — Enters a message-processing loop. Blocks the caller. Dispatches incoming updates and signals to the provided handlers. Returns when a handler signals completion via `{:stop, ...}` or the timeout expires. All async handlers spawned within this scope must complete before `receive` returns.

**`API.parallel(fns)`** — Executes a list of functions concurrently. Each function runs in its own process and can call activities, sleep, or use other sequential primitives. Blocks until all functions complete. Returns a list of results in the same order as the input functions.

### Async-Only Primitives

These are only available inside async handler processes (spawned by `{:async, fn, state}` within a `receive`):

**`API.update_state(fn)`** — Atomically transforms the enclosing `receive` block's reducer state. The function receives the current state and returns `{result, new_state}`. The transformation runs inside the executor and is serialized — concurrent async handlers calling `update_state` are never interleaved. This is the only way for async handlers to interact with the receive state.

---

## Workflow Structure

A workflow is a module that uses `Temporalex.Workflow` and defines `run/1` and optionally `handle_query/3`:

```elixir
defmodule MyApp.Workflows.Checkout do
  use Temporalex.Workflow

  # Queries — always available, operate on last published state
  def handle_query("status", _args, state), do: {:reply, state.phase}
  def handle_query("items", _args, state), do: {:reply, state[:items]}

  def run(args) do
    # Sequential workflow code...
  end
end
```

`run/1` receives the decoded workflow input and returns:
- `{:ok, result}` — Workflow completes successfully.
- `{:error, reason}` — Workflow fails.
- `{:continue_as_new, args}` — Workflow restarts with fresh history and the provided arguments.

`handle_query/3` receives the query name, arguments, and the last published state. It returns `{:reply, value}`. Query handlers are always available and are read-only — they cannot modify state or perform side effects.

---

## Message Types

### Signals

Signals are asynchronous, fire-and-forget messages. They are buffered by the executor and never lost. A signal has a name and a payload.

**Inside `receive`:** When a signal with a matching handler arrives, the handler is called. Multiple signals with the same name each invoke the handler separately.

**Outside `receive`:** Signals accumulate in the executor's buffer. They can be consumed with `API.wait_for_signal(name)`, which pops one signal from the buffer and returns its payload. If no matching signal exists, it blocks until one arrives.

Signals arriving during linear execution (while the workflow is calling an activity, sleeping, etc.) are always buffered. They are never rejected or lost.

### Updates

Updates are synchronous, tracked messages. The caller sends an update and waits for a response. An update has a name, arguments, and returns a result to the caller.

**Inside `receive`:** When an update with a matching handler arrives, the validator runs first (if defined). If the validator rejects, the caller gets an error and nothing is written to history. If accepted, the handler runs and its return value is sent back to the caller.

**Outside `receive`:** Updates are rejected. The caller receives an error indicating the workflow is not accepting that update at this time. This is intentional — the code structure declares when updates are valid.

### Queries

Queries are synchronous, read-only requests. They operate on the last state published via `API.publish_state` and are handled by the module-level `handle_query/3` callback. Queries are always available, regardless of whether the workflow is in a `receive` block.

---

## `API.receive`

`receive` is the central construct for message-driven workflow phases. It blocks the workflow function, processes messages, and returns when a handler signals completion.

### Signature

```elixir
result = API.receive(initial_state, opts)
```

- `initial_state` — The starting value for the reducer. Can be any term: a map, integer, list, etc.
- `opts` — Keyword list with `:update`, `:signal`, and optionally `:timeout` keys.

### Handler Definitions

Handlers run in their own process. They may perform blocking operations (activities, `API.parallel`, `API.sleep`) before returning. While a sync handler is running, the receive loop waits for it to complete before dispatching the next message — this guarantees sequential message processing by default. See [Async Handlers](#async-handlers) for concurrent message processing.

**Signal handlers** receive the signal arguments and current state:

```elixir
signal: %{
  "name" => fn args, state -> {:noreply, new_state} end,
  "done" => fn _args, state -> {:stop, state} end,
}
```

Return values:
- `{:noreply, new_state}` — Update state, continue processing.
- `{:stop, state}` — Exit the receive loop.
- `{:async, fn, state}` — Spawn an async handler (see below). The function's return value is ignored (signals have no caller).

**Update handlers** receive the arguments and current state:

```elixir
update: %{
  "name" => fn args, state -> {:reply, response, new_state} end,
  "name" => {&handler/2, validator: &validator/2},
}
```

Return values:
- `{:reply, response, new_state}` — Reply to the caller, update state, continue processing.
- `{:stop, response, new_state}` — Reply to the caller and exit the receive loop.
- `{:async, fn, state}` — Accept the update, spawn an async handler (see below). The function's return value becomes the update reply.

**Update validators** receive the arguments and current state. They accept or reject:

```elixir
validator: fn args, state ->
  :ok | {:error, reason}
end
```

Validators are always synchronous and always run inline in the executor process. They run before the update is accepted into history. If they return `{:error, reason}`, the update is rejected and no history event is written.

### Timeout

```elixir
case API.receive(state, signal: %{...}, timeout: :timer.hours(24)) do
  {:timeout, state} -> # timed out
  state -> # a handler returned {:stop, state}
end
```

If no handler returns `{:stop, ...}` within the timeout, the receive exits with `{:timeout, state}`, allowing the caller to distinguish between handler-driven completion and timeout. Useful for entity workflows that need periodic continue-as-new.

### Completion Semantics

When a handler returns `{:stop, ...}`:

1. The receive stops dispatching new messages to handlers.
2. All in-flight async handlers are allowed to complete (structured concurrency).
3. The final state (after all async handlers' `update_state` calls have applied) is returned to the caller.
4. The workflow function resumes at the line after the `receive` call.

---

## Async Handlers

By default, all handlers inside `receive` are synchronous. Sync handlers run in their own process and may call activities, `API.parallel`, or other blocking operations — but the receive loop waits for each sync handler to complete before dispatching the next message.

To process messages concurrently, return the `{:async, fn, state}` tuple explicitly. This spawns a background process and allows the receive loop to continue dispatching:

```elixir
update: %{
  "add_item" => fn [item], state ->
    {:async, fn ->
      {:ok, price} = Activities.Pricing.lookup(item.sku)

      API.update_state(fn s ->
        new_items = [%{sku: item.sku, price: price} | s.items]
        {price, %{s | items: new_items}}
      end)
    end, state}
  end,
}
```

### Semantics

When `{:async, fn, state}` is returned from an **update handler**:

1. The update is immediately accepted (the `UpdateAccepted` event is written to history).
2. A new process is spawned for the function. This process can call activities, use `API.parallel`, call `API.update_state`, and call `API.publish_state`.
3. **The return value of the function becomes the update reply** sent to the caller. No explicit reply mechanism is needed.
4. If the function raises, the update fails and the caller receives an error. The workflow continues.
5. The spawned process is bound to the enclosing `receive` — it must complete before `receive` returns.

When `{:async, fn, state}` is returned from a **signal handler**:

1. A new process is spawned for the function with the same capabilities as async update handlers.
2. The function's return value is ignored (signals have no caller to reply to).
3. If the function raises, the error is logged. The workflow continues.
4. The spawned process is bound to the enclosing `receive` — it must complete before `receive` returns.

The key difference between sync and async handlers is **concurrency, not capability**. Both can call activities and do blocking work. Sync handlers serialize message processing (one at a time). Async handlers allow the receive loop to dispatch further messages while they run in the background.

### `API.update_state`

Async handlers do not have direct access to the receive state (they run in a separate process). Instead, they use `API.update_state` to atomically read-modify-write the state:

```elixir
result = API.update_state(fn state ->
  {return_value, new_state}
end)
```

The closure runs inside the executor, serialized with all other state operations. This means:
- No stale reads. The closure always sees the current state.
- No races. Concurrent async handlers' `update_state` calls are applied one at a time.
- No locks needed. The executor's mailbox serializes everything.

If you need to read state without modifying it, return the state unchanged:

```elixir
count = API.update_state(fn state -> {length(state.items), state} end)
```

### Constraints

- `{:async, fn, state}` can only be returned from handlers inside a `receive`.
- Async handlers cannot spawn further async handlers (no `{:async, ...}` from within an async process).
- Async handlers cannot enter their own `receive` loops.
- Async handlers can call `API.parallel` for fan-out within the handler.

---

## `API.parallel`

`parallel` executes multiple functions concurrently and waits for all of them to complete.

### Signature

```elixir
results = API.parallel([fn1, fn2, fn3])
```

Each function runs in its own process with access to the executor. Functions can call activities, sleep, use `API.publish_state`, and nest further `API.parallel` calls.

Returns a list of results in the same order as the input functions.

### Error Semantics

If a branch raises an exception, the other branches continue running until they reach a terminal state (completion or failure). Every branch runs to completion. The result list contains each branch's return value on success, or `{:error, reason}` if the branch raised:

```elixir
results = API.parallel([
  fn -> Activities.StepA.run(x) end,   # returns {:ok, "a"}
  fn -> Activities.StepB.run(y) end,   # raises RuntimeError
  fn -> Activities.StepC.run(z) end,   # returns {:ok, "c"}
])
# results == [{:ok, "a"}, {:error, %RuntimeError{...}}, {:ok, "c"}]
```

### Example

```elixir
def run(args) do
  [{:ok, user}, {:ok, config}] = API.parallel([
    fn -> Activities.Users.fetch(args.user_id) end,
    fn -> Activities.Config.load(args.tenant) end,
  ])

  # Both activities ran concurrently, both are done
  {:ok, %{user: user, config: config}}
end
```

### Where It Works

`API.parallel` is a blocking call and works anywhere sequential primitives work:
- In `run/1`
- Inside sync and async handlers
- Inside parallel branches (nested fan-out)
- Anywhere you'd call an activity

---

## State Model

There are three distinct kinds of "state" in a Temporalex workflow:

### 1. Local Variables

The function's local variables. Private to the `run/1` execution. Not visible to handlers, queries, or anything else. This is the natural state of a sequential function:

```elixir
def run(args) do
  charge_id = do_charge(args)  # local variable
  # ...
end
```

### 2. Receive State (Reducer Accumulator)

The state managed by a `receive` block. Passed to handlers, updated by handler return values and `API.update_state` calls. Scoped to the lifetime of one `receive` call. Returned to the caller when `receive` exits:

```elixir
result = API.receive(%{items: [], count: 0}, ...)
# result is the final accumulator value
```

### 3. Published State (Query State)

The state visible to query handlers. Set explicitly via `API.publish_state`. Persists across receive blocks and linear phases. Replaced entirely on each publish:

```elixir
API.publish_state(%{phase: :open, item_count: 0})
# ... later ...
API.publish_state(%{phase: :charging, item_count: 5})
```

These three are independent. The receive accumulator is not automatically published. Local variables are not visible to handlers. Published state is not the receive accumulator. The developer controls the boundaries between them.

---

## Nesting Rules

```
run/1 (sequential, not a concurrency host)
├── Activities              ✓
├── API.sleep               ✓
├── API.wait_for_signal     ✓
├── API.side_effect         ✓
├── API.publish_state       ✓
├── API.patched? / deprecate_patch ✓
├── API.receive             ✓  (structured concurrency host)
│   ├── sync handlers       ✓  (default, runs in own process)
│   │   ├── Activities          ✓
│   │   ├── API.sleep           ✓
│   │   ├── API.parallel        ✓
│   │   ├── API.side_effect     ✓
│   │   └── API.publish_state   ✓
│   └── {:async, fn, state} ✓  (explicit, concurrent with receive loop)
│       ├── Activities          ✓
│       ├── API.sleep           ✓
│       ├── API.parallel        ✓
│       ├── API.side_effect     ✓
│       ├── API.update_state    ✓
│       ├── API.publish_state   ✓
│       ├── {:async, ...}       ✗  (cannot nest async)
│       └── API.receive         ✗  (cannot nest receive)
├── API.parallel            ✓  (structured concurrency host)
│   ├── Activities          ✓
│   ├── API.sleep           ✓
│   ├── API.parallel        ✓  (nested fan-out)
│   ├── API.side_effect     ✓
│   ├── API.publish_state   ✓
│   ├── {:async, ...}       ✗  (parallel branches are not receive)
│   └── API.receive         ✗  (not in v1)
└── {:async, ...}           ✗  (run/1 is not a host)

Return values from run/1:
  {:ok, result}             → CompleteWorkflowExecution
  {:error, reason}          → FailWorkflowExecution
  {:continue_as_new, args}  → ContinueAsNewWorkflowExecution
```

---

## Examples

### Sequential Workflow

A simple three-step workflow with no message processing:

```elixir
defmodule MyApp.Workflows.Onboarding do
  use Temporalex.Workflow

  def handle_query("status", _args, state), do: {:reply, state}

  def run(%{"user_id" => user_id}) do
    API.publish_state(%{step: :creating_account})
    {:ok, account} = Activities.Accounts.create(user_id)

    API.publish_state(%{step: :sending_welcome})
    {:ok, _} = Activities.Email.send_welcome(account)

    API.publish_state(%{step: :done})
    {:ok, %{account_id: account.id}}
  end
end
```

### Entity Workflow

A long-lived entity that processes messages until told to stop:

```elixir
defmodule MyApp.Workflows.Counter do
  use Temporalex.Workflow

  def handle_query("value", _args, state), do: {:reply, state}

  def run(_args) do
    API.publish_state(0)

    result = API.receive(0,
      signal: %{
        "increment" => fn _args, count -> {:noreply, count + 1} end,
        "decrement" => fn _args, count -> {:noreply, count - 1} end,
        "done"      => fn _args, count -> {:stop, count} end,
      }
    )

    API.publish_state(result)
    {:ok, result}
  end
end
```

### Multi-Phase Workflow

A shopping cart that transitions between collection, checkout, and confirmation:

```elixir
defmodule MyApp.Workflows.ShoppingCart do
  use Temporalex.Workflow

  def handle_query("status", _args, state), do: {:reply, state}

  def run(_args) do
    API.publish_state(%{phase: :open, item_count: 0})

    # Phase 1: Collect items
    cart = API.receive(%{items: []},
      update: %{
        "add_item"    => {&do_add_item/2, validator: &validate_sku/2},
        "remove_item" => &do_remove_item/2,
      },
      signal: %{
        "checkout" => fn _args, state -> {:stop, state} end,
      }
    )

    # Phase 2: Charge
    API.publish_state(%{phase: :charging, item_count: length(cart.items)})
    {:ok, total} = Activities.Payment.charge(cart.items)

    # Phase 3: Confirm or cancel
    API.publish_state(%{phase: :confirming, total: total})

    outcome = API.receive(%{confirmed: nil},
      update: %{
        "confirm" => fn _args, state -> {:stop, :ok, %{state | confirmed: true}} end,
        "cancel"  => fn _args, state -> {:stop, :ok, %{state | confirmed: false}} end,
      }
    )

    # Phase 4: Finalize
    if outcome.confirmed do
      API.publish_state(%{phase: :done, total: total})
      {:ok, _} = Activities.Email.send_receipt(total)
      {:ok, %{total: total}}
    else
      API.publish_state(%{phase: :refunded})
      {:ok, _} = Activities.Payment.refund(total)
      {:ok, :cancelled}
    end
  end

  defp do_add_item([item], state) do
    new_items = [item | state.items]
    API.publish_state(%{phase: :open, item_count: length(new_items)})
    {:reply, :ok, %{state | items: new_items}}
  end

  defp validate_sku([item], _state) do
    if valid_sku?(item.sku), do: :ok, else: {:error, "invalid SKU"}
  end

  defp do_remove_item([sku], state) do
    {:reply, :ok, %{state | items: Enum.reject(state.items, &(&1.sku == sku))}}
  end
end
```

### Fan-Out with Parallel

```elixir
defmodule MyApp.Workflows.BatchProcess do
  use Temporalex.Workflow

  def run(%{"items" => items}) do
    # Process all items concurrently
    results = API.parallel(Enum.map(items, fn item ->
      fn -> Activities.Processor.run(item) end
    end))

    failures = Enum.filter(results, &match?({:error, _}, &1))

    if failures == [] do
      {:ok, %{processed: length(results)}}
    else
      {:error, %{failures: length(failures)}}
    end
  end
end
```

### Async Update Handlers

```elixir
defmodule MyApp.Workflows.Inventory do
  use Temporalex.Workflow

  def handle_query("stock", _args, state), do: {:reply, state}

  def run(_args) do
    API.publish_state(%{})

    result = API.receive(%{stock: %{}},
      update: %{
        "restock" => fn [item], state ->
          # Async: needs to call an activity to get the price
          {:async, fn ->
            {:ok, price} = Activities.Pricing.current_price(item.sku)

            API.update_state(fn s ->
              new_qty = Map.get(s.stock, item.sku, 0) + item.quantity
              entry = %{quantity: new_qty, price: price}
              new_stock = Map.put(s.stock, item.sku, entry)
              API.publish_state(new_stock)
              {entry, %{s | stock: new_stock}}
            end)
          end, state}
        end,
      },
      signal: %{
        "close" => fn _args, state -> {:stop, state} end,
      }
    )

    {:ok, result.stock}
  end
end
```

### Side Effects

```elixir
defmodule MyApp.Workflows.OrderProcessing do
  use Temporalex.Workflow

  def run(%{"customer_id" => customer_id}) do
    # These run once and are recorded in history.
    # On replay, the recorded values are returned without re-executing.
    order_number = API.side_effect(fn -> MyApp.Sequences.next("orders") end)
    started_at = API.side_effect(fn -> DateTime.utc_now() end)

    API.publish_state(%{order_number: order_number, status: :processing})

    {:ok, _} = Activities.Orders.process(customer_id, order_number)
    {:ok, %{order_number: order_number, started_at: started_at}}
  end
end
```

### Continue-As-New Entity

```elixir
defmodule MyApp.Workflows.EventCollector do
  use Temporalex.Workflow

  def handle_query("count", _args, state), do: {:reply, state}

  def run(args) do
    state = args[:state] || %{events: [], generation: 0}
    API.publish_state(length(state.events))

    case API.receive(state,
      signal: %{
        "event" => fn [event], state ->
          {:noreply, %{state | events: [event | state.events]}}
        end,
        "flush" => fn _args, state -> {:stop, state} end,
      },
      timeout: :timer.hours(24)
    ) do
      {:timeout, state} -> state
      state -> state
    end
    |> then(fn state ->
      # Process accumulated events
      {:ok, _} = Activities.EventStore.batch_insert(state.events)

      # Continue with fresh state
      {:continue_as_new, %{state: %{events: [], generation: state.generation + 1}}}
    end)
  end
end
```

---

## Determinism and Replay

All workflow code must be deterministic. The same inputs (activity results, signal payloads, timer fires) must produce the same sequence of commands. This is enforced by the executor during replay.

### What Is Deterministic

- Activity calls: the executor replays recorded results.
- Timer fires: replayed from history.
- Signal arrival order: replayed from history.
- Update arrival order: replayed from history.
- `API.side_effect` return values: recorded in history, returned without re-execution on replay.
- `API.update_state` closures: re-executed with the same state (because activity results are the same).
- `API.parallel` ordering: branches produce commands with unique sequence numbers, results are collected in deterministic order.

### What Is Not Deterministic (Use Side Effects or Activities)

| Don't | Do |
|---|---|
| `DateTime.utc_now()` | `API.side_effect(fn -> DateTime.utc_now() end)` |
| `:rand.uniform()` | `API.side_effect(fn -> :rand.uniform() end)` |
| `UUID.uuid4()` | `API.side_effect(fn -> UUID.uuid4() end)` |
| `System.get_env("FOO")` | `API.side_effect(fn -> System.get_env("FOO") end)` |
| `HTTPClient.get(url)` | Use an activity |
| `File.read(path)` | Use an activity |

---

## Mapping to Temporal Core SDK

The programming model maps to the Temporal Core SDK's activation/command protocol:

| Temporalex Construct | Core SDK Commands |
|---|---|
| `Activities.Foo.bar()` | `ScheduleActivity` → `ResolveActivity` |
| `API.sleep(ms)` | `StartTimer` → `FireTimer` |
| `API.wait_for_signal(name)` | No command (executor buffers `SignalWorkflow` jobs) |
| `API.side_effect(fn)` | Records result as a `SideEffect` marker event |
| `API.receive` | No command (executor dispatches `SignalWorkflow` and `DoUpdate` jobs to handlers) |
| `{:async, fn, state}` (update) | `UpdateResponse{accepted}` immediately, then handler's commands, then `UpdateResponse{completed}` |
| `{:async, fn, state}` (signal) | No protocol-level tracking — handler's commands are regular commands |
| `API.parallel(fns)` | Multiple commands in one activation (e.g. multiple `ScheduleActivity`) |
| `API.publish_state` | No command (executor state for query serving) |
| `API.update_state` | No command (executor-internal state transformation) |
| `{:continue_as_new, args}` | `ContinueAsNewWorkflowExecution` |
| `API.patched?(id)` | `SetPatchMarker` (or reads `NotifyHasPatch` from activation) |
| `API.deprecate_patch(id)` | `SetPatchMarker` with deprecated flag |

The executor allocates unique sequence numbers across all concurrent processes (runner, async handlers, parallel branches) and routes `Resolve*` jobs back to the correct process. The Core SDK sees a flat stream of commands and has no knowledge of the concurrency model.
