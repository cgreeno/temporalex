# Temporalex Workflow Programming Model

## Overview

A Temporalex workflow is a **single function** that reads top-to-bottom as sequential code. Concurrency is introduced through two explicit constructs — `phase` and `parallel` — which act as structured concurrency scopes. All async work is bound to the scope that spawned it and must complete before the scope returns.

The design principles:

1. **Workflows are functions.** A workflow is a module with a `run/1` function. It calls activities, sleeps, waits for signals, and returns a result. There is no implicit event loop or background message processing.

2. **Concurrency is scoped and explicit.** The only way to introduce concurrent execution is by entering an `API.phase/2` or `API.parallel/1` scope. The keyword `{:async, fn, state}` must be explicitly returned to spawn concurrent work. Nothing is concurrent by default.

3. **State is what you make it.** There is no framework-managed "workflow state" that handlers implicitly share. A phase has reducer state (an accumulator). Queries see only what you explicitly publish. These are separate concerns.

4. **Structure determines validity.** Which updates and signals a workflow accepts is determined by which phase it is currently in. An update that arrives when the workflow is not in a phase expecting it is rejected. The code structure declares what's valid when.

---

## The Primitive Set

### Sequential Primitives

These calls are available anywhere in workflow code (in `run/1`, inside handlers, inside parallel branches):

**`Activities.Module.function(args)`** — Execute an activity. Blocks until the activity completes, fails, or is cancelled. Returns `{:ok, value}`, `{:error, reason}`, or `{:cancelled, error}`. The generated `function!/N` variant unwraps `{:ok, value}` and raises failures or cancellation.

**`API.sleep(duration_ms)` / `API.sleep!(duration_ms)`** — Durable timer. Blocks for the specified duration. Survives process restarts. The executor schedules a `StartTimer` command and the runner resumes when the timer fires. The non-bang form returns `:ok` or `{:cancelled, error}`; the bang form raises on cancellation.

**`API.wait_for_signal(name)` / `API.wait_for_signal!(name)`** — Blocks until a signal with the given name arrives. Consumes one signal from the buffer. If a matching signal is already buffered, returns immediately. Signals are a queue — multiple signals with the same name accumulate and are consumed one at a time. The non-bang form returns `{:ok, args}` or `{:cancelled, error}`; the bang form returns `args` or raises on cancellation.

**`API.publish_state(state)`** — Publishes a state snapshot that queries can read. Non-blocking. Can be called from anywhere. This is the only way to make state visible to queries. Calling it replaces the previously published state entirely.

**`API.now()`** — Returns the workflow time from the current activation timestamp. Use this instead of wall-clock time inside workflow code.

**`API.random()` / `API.uuid4()`** — Deterministic random values derived from the workflow's replayed random seed. Use these instead of BEAM or library random sources inside workflow code.

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

These are blocking calls that can host durable concurrent work within their scope:

**`API.phase(state, handlers)` / `API.phase!(state, handlers)`** — Enters a message-driven workflow phase. Blocks the caller. Dispatches incoming updates and signals to the provided handlers. Returns when a handler signals completion via `{:stop, ...}` or the timeout expires. All async handlers spawned within this scope must complete before the phase returns. The non-bang form returns `{:ok, state}`, `{:timeout, state}`, or `{:cancelled, error}`; the bang form returns `state`, `{:timeout, state}`, or raises on cancellation.

**`API.parallel(fns)` / `API.parallel!(fns)`** — Executes a list of functions as cooperatively scheduled workflow branches. Each branch has its own workflow process and can call activities, sleep, or use other sequential primitives. Blocks until all branches complete. The non-bang form returns `{:ok, results}` or `{:cancelled, error}`; the bang form returns `results` or raises on cancellation.

### Async-Only Primitives

These are only available inside async handler processes (spawned by `{:async, fn, state}` within a phase):

**`API.update_state(fn)`** — Atomically transforms the enclosing phase's reducer state. The function receives the current state and returns `{result, new_state}`. The transformation runs inside the executor and is serialized — concurrent async handlers calling `update_state` are never interleaved. This is the only way for async handlers to interact with the phase state.

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

Any other return shape is invalid and fails the workflow with a clear error.

`handle_query/3` receives the query name, arguments, and the last published state. It returns `{:reply, value}`. Query handlers are always available and are read-only — they cannot modify state or issue workflow commands.

---

## Message Types

### Signals

Signals are asynchronous, fire-and-forget messages. They are buffered by the executor and never lost. A signal has a name and a payload.

**Inside a phase:** When a signal with a matching handler arrives, the handler is called. Multiple signals with the same name each invoke the handler separately.

**Outside a phase:** Signals accumulate in the executor's buffer. They can be consumed with `API.wait_for_signal!/1`, which pops one signal from the buffer and returns its payload. The non-bang `API.wait_for_signal/1` returns `{:ok, payload}` instead. If no matching signal exists, either form blocks until one arrives.

Signals arriving during linear execution (while the workflow is calling an activity, sleeping, etc.) are always buffered. They are never rejected or lost.

### Updates

Updates are synchronous, tracked messages. The caller sends an update and waits for a response. An update has a name, arguments, and returns a result to the caller.

**Inside a phase:** When an update with a matching handler arrives, the validator runs first (if defined). If the validator rejects, the caller gets an error and nothing is written to history. If accepted, the handler runs and its return value is sent back to the caller.

For accepted updates, the executor emits the accepted response in the same activation before any commands produced by the update handler. The completed response is emitted after the handler finishes, in the same or a later activation.

**Outside a phase:** Updates are rejected. The caller receives an error indicating the workflow is not accepting that update at this time. This is intentional — the code structure declares when updates are valid.

### Queries

Queries are synchronous, read-only requests. They operate on the last state published via `API.publish_state` and are handled by the module-level `handle_query/3` callback. Queries are always available, regardless of whether the workflow is in a phase.

---

## `API.phase`

`API.phase/2` is the central construct for message-driven workflow phases. It blocks the workflow function, processes messages, and returns when a handler signals completion.

### Signature

```elixir
result = API.phase!(initial_state, opts)
```

- `initial_state` — The starting value for the reducer. Can be any term: a map, integer, list, etc.
- `opts` — Keyword list with `:update`, `:signal`, and optionally `:timeout` keys.

### Handler Definitions

Handlers run in their own process. They may perform blocking operations (activities, `API.parallel`, `API.sleep`) before returning. While a sync handler is running, the phase waits for it to complete before dispatching the next message — this guarantees sequential message processing by default. See [Async Handlers](#async-handlers) for concurrent message processing.

**Signal handlers** receive the signal arguments and current state:

```elixir
signal: %{
  "name" => fn args, state -> {:noreply, new_state} end,
  "done" => fn _args, state -> {:stop, state} end,
}
```

Return values:
- `{:noreply, new_state}` — Update state, continue processing.
- `{:stop, state}` — Exit the phase.
- `{:async, fn, state}` — Spawn an async handler (see below). The function's return value is ignored (signals have no caller).

**Update handlers** receive the arguments and current state:

```elixir
update: %{
  "add_item" => fn args, state -> {:reply, response, new_state} end,
  "remove_item" => {&handler/2, validator: &validator/2},
}
```

Return values:
- `{:reply, response, new_state}` — Reply to the caller, update state, continue processing.
- `{:stop, response, new_state}` — Reply to the caller and exit the phase.
- `{:async, fn, state}` — Accept the update, spawn an async handler (see below). The function's return value becomes the update reply.

**Update validators** receive the arguments and current state. They accept or reject:

```elixir
validator: fn args, state ->
  :ok | {:error, reason}
end
```

Validators are always synchronous and always run inline in the executor process on first execution. They run before the update is accepted into history. If they return `{:error, reason}`, the update is rejected and no history event is written. During replay, validators are not re-run; acceptance or rejection is replayed from history.

### Timeout

```elixir
case API.phase!(state, signal: %{...}, timeout: :timer.hours(24)) do
  {:timeout, state} -> # timed out
  state -> # a handler returned {:stop, state}
end
```

If no handler returns `{:stop, ...}` within the timeout, the phase exits with `{:timeout, state}`, allowing the caller to distinguish between handler-driven completion and timeout. Useful for entity workflows that need periodic continue-as-new.

A phase timeout is a durable timer. If the phase exits before the timeout fires, the executor cancels the timer. If the timeout fires first, the phase stops dispatching new messages, waits for bound async handlers to finish, and then returns `{:timeout, state}`.

### Completion Semantics

When a handler returns `{:stop, ...}`:

1. The phase stops dispatching new messages to handlers.
2. All in-flight async handlers are allowed to complete (structured concurrency).
3. The final state (after all async handlers' `update_state` calls have applied) is returned to the caller.
4. The workflow function resumes at the line after the `phase` call.

---

## Async Handlers

By default, all handlers inside a phase are synchronous. Sync handlers run in their own process and may call activities, `API.parallel`, or other blocking operations — but the phase waits for each sync handler to complete before dispatching the next message.

To process messages concurrently, return the `{:async, fn, state}` tuple explicitly. This spawns a background process and allows the phase to continue dispatching:

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
5. The spawned process is bound to the enclosing `phase` — it must complete before `phase` returns.

When `{:async, fn, state}` is returned from a **signal handler**:

1. A new process is spawned for the function with the same capabilities as async update handlers.
2. The function's return value is ignored (signals have no caller to reply to).
3. If the function raises, the error is logged. The workflow continues.
4. The spawned process is bound to the enclosing `phase` — it must complete before `phase` returns.

The key difference between sync and async handlers is **concurrency, not capability**. Both can call activities and do blocking work. Sync handlers serialize message processing (one at a time). Async handlers allow the phase to dispatch further messages while they run in the background.

### `API.update_state`

Async handlers do not have direct access to the phase state (they run in a separate process). Instead, they use `API.update_state` to atomically read-modify-write the state:

```elixir
result = API.update_state(fn state ->
  {return_value, new_state}
end)
```

The closure runs inside the executor, serialized with all other state operations. It must be deterministic, synchronous, and non-blocking. It must not call activities, `API.sleep`, `API.publish_state`, or any workflow API that would call back into the executor.

This means:
- No stale reads. The closure always sees the current state.
- No races. Concurrent async handlers' `update_state` calls are applied one at a time.
- No locks needed. The executor's mailbox serializes everything.

If you need to read state without modifying it, return the state unchanged:

```elixir
count = API.update_state(fn state -> {length(state.items), state} end)
```

### Constraints

- `{:async, fn, state}` can only be returned from handlers inside a `phase`.
- Async handlers cannot spawn further async handlers (no `{:async, ...}` from within an async process).
- Async handlers cannot enter their own phases.
- Async handlers can call `API.parallel` for fan-out within the handler.

---

## `API.parallel`

`parallel` executes multiple functions as durable concurrent branches and waits for all of them to complete.

### Signature

```elixir
results = API.parallel!([fn1, fn2, fn3])
```

Each function has its own workflow process with access to the executor. Branches are cooperatively scheduled in deterministic rounds, so activity and timer waits can overlap without BEAM process timing affecting command order. Functions can call activities, sleep, use `API.publish_state`, and nest further `API.parallel` calls.

Returns a list of results in the same order as the input functions.

### Error Semantics

If a branch raises an exception, the other branches continue running until they reach a terminal state (completion or failure). Every branch runs to completion. The result list contains each branch's return value on success, or `{:error, reason}` if the branch raised:

```elixir
results = API.parallel!([
  fn -> Activities.StepA.run(x) end,   # returns {:ok, "a"}
  fn -> Activities.StepB.run(y) end,   # raises RuntimeError
  fn -> Activities.StepC.run(z) end,   # returns {:ok, "c"}
])
# results == [{:ok, "a"}, {:error, %RuntimeError{...}}, {:ok, "c"}]
```

### Example

```elixir
def run(args) do
  [{:ok, user}, {:ok, config}] = API.parallel!([
    fn -> Activities.Users.fetch(args.user_id) end,
    fn -> Activities.Config.load(args.tenant) end,
  ])

  # Both activity waits overlapped, both are done
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

### 2. Phase State (Reducer Accumulator)

The state managed by a `phase` block. Passed to handlers, updated by handler return values and `API.update_state` calls. Scoped to the lifetime of one `phase` call. Returned to the caller when `phase` exits:

```elixir
result = API.phase!(%{items: [], count: 0}, ...)
# result is the final accumulator value
```

### 3. Published State (Query State)

The state visible to query handlers. Set explicitly via `API.publish_state`. Persists across message phases and linear workflow sections. Replaced entirely on each publish:

```elixir
API.publish_state(%{phase: :open, item_count: 0})
# ... later ...
API.publish_state(%{phase: :charging, item_count: 5})
```

These three are independent. The phase accumulator is not automatically published. Local variables are not visible to handlers. Published state is not the phase accumulator. The developer controls the boundaries between them.

---

## Nesting Rules

```
run/1 (sequential, not a concurrency host)
├── Activities              ✓
├── API.sleep               ✓
├── API.wait_for_signal     ✓
├── API.now / random / uuid4 ✓
├── API.publish_state       ✓
├── API.patched? / deprecate_patch ✓
├── API.phase               ✓  (structured concurrency host)
│   ├── sync handlers       ✓  (default, runs in own process)
│   │   ├── Activities          ✓
│   │   ├── API.sleep           ✓
│   │   ├── API.parallel        ✓
│   │   ├── API.now / random / uuid4 ✓
│   │   └── API.publish_state   ✓
│   └── {:async, fn, state} ✓  (explicit, concurrent with phase message dispatch)
│       ├── Activities          ✓
│       ├── API.sleep           ✓
│       ├── API.parallel        ✓
│       ├── API.now / random / uuid4 ✓
│       ├── API.update_state    ✓
│       ├── API.publish_state   ✓
│       ├── {:async, ...}       ✗  (cannot nest async)
│       └── API.phase             ✗  (cannot nest phases)
├── API.parallel            ✓  (structured concurrency host)
│   ├── Activities          ✓
│   ├── API.sleep           ✓
│   ├── API.parallel        ✓  (nested fan-out)
│   ├── API.now / random / uuid4 ✓
│   ├── API.publish_state   ✓
│   ├── {:async, ...}       ✗  (parallel branches are not phase scopes)
│   └── API.phase             ✗  (not in v1)
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

    result = API.phase!(0,
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
    cart = API.phase!(%{items: []},
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

    outcome = API.phase!(%{confirmed: nil},
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
    # Process all items with concurrent durable activity waits
    results = API.parallel!(Enum.map(items, fn item ->
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

    result = API.phase!(%{stock: %{}},
      update: %{
        "restock" => fn [item], state ->
          # Async: needs to call an activity to get the price
          {:async, fn ->
            {:ok, price} = Activities.Pricing.current_price(item.sku)

            new_stock = API.update_state(fn s ->
              new_qty = Map.get(s.stock, item.sku, 0) + item.quantity
              entry = %{quantity: new_qty, price: price}
              new_stock = Map.put(s.stock, item.sku, entry)
              {new_stock, %{s | stock: new_stock}}
            end)

            API.publish_state(new_stock)
            Map.fetch!(new_stock, item.sku)
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

### Continue-As-New Entity

```elixir
defmodule MyApp.Workflows.EventCollector do
  use Temporalex.Workflow

  def handle_query("count", _args, state), do: {:reply, state}

  def run(args) do
    state = args[:state] || %{events: [], generation: 0}
    API.publish_state(length(state.events))

    case API.phase!(state,
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
- Workflow time: taken from activation timestamps.
- `API.random` and `API.uuid4`: derived from replayed workflow random seed updates.
- `API.update_state` closures: re-executed with the same state (because activity results are the same).
- `API.parallel` ordering: branches are scheduled in deterministic rounds, produce commands with unique sequence numbers, and return results in input order.

### What Is Not Deterministic

| Don't | Do |
|---|---|
| `DateTime.utc_now()` | `API.now()` |
| `:rand.uniform()` | `API.random()` |
| `UUID.uuid4()` | `API.uuid4()` |
| `System.get_env("FOO")` | Pass as workflow input or use an activity |
| `HTTPClient.get(url)` | Use an activity |
| `File.read(path)` | Use an activity |

---

## Cancellation

Workflow cancellation is delivered as a deterministic activation job. It does not kill BEAM
processes. The executor records a `%Temporalex.Failure.CancelledError{}` and interrupts
cancellable blocking primitives by resuming their workflow process with that exception.

The cancellation primitives are:

```elixir
API.cancelled?()
API.cancellation()
API.non_cancellable(fn -> ... end)
```

`API.cancelled?/0` returns a boolean. `API.cancellation/0` returns the current
`%Temporalex.Failure.CancelledError{}` or `nil`.

After cancellation, new cancellable blocking work returns `{:cancelled, error}` immediately, or
raises from the corresponding bang variant, unless it is inside `API.non_cancellable/1`. This makes
cleanup explicit:

```elixir
try do
  API.sleep!(60_000)
rescue
  error in Temporalex.Failure.CancelledError ->
    API.non_cancellable(fn ->
      {:ok, _} = MyApp.Activities.cleanup()
    end)

    {:cancelled, error}
end
```

State needed for cleanup should be carried as ordinary workflow state. Temporalex does not
recover local variables from an interrupted stack frame.

Cancellation effects:

| Primitive | Cancellation behavior |
|---|---|
| `API.sleep/1` / `API.sleep!/1` | Emits `CancelTimer`; non-bang returns `{:cancelled, error}`, bang raises |
| `API.wait_for_signal/1` / `API.wait_for_signal!/1` | Removes the waiter; non-bang returns `{:cancelled, error}`, bang raises |
| Activity dispatch / bang dispatch | Emits `RequestCancelActivity` unless `cancellation_type: :abandon`; `:wait_cancellation_completed` waits for the activity cancellation resolution, `:try_cancel` resolves immediately |
| `API.parallel/1` / `API.parallel!/1` | Cancels cancellable branches in deterministic branch order; non-bang returns `{:cancelled, error}`, bang raises |
| `API.phase/2` / `API.phase!/2` | Stops accepting messages, rejects queued/new updates as cancelled, cancels the phase timer, cancels cancellable handlers, then returns/raises cancellation to the owner |

---

## Mapping to Temporal Core SDK

The programming model maps to the Temporal Core SDK's activation/command protocol:

| Temporalex Construct | Core SDK Commands |
|---|---|
| `Activities.Foo.bar()` | `ScheduleActivity` → `ResolveActivity` |
| cancelled activity | `RequestCancelActivity` → `ResolveActivity(cancelled)` |
| `API.sleep(ms)` / `API.sleep!(ms)` | `StartTimer` → `FireTimer` |
| cancelled sleep | `CancelTimer` |
| `API.wait_for_signal(name)` / `API.wait_for_signal!(name)` | No command (executor buffers `SignalWorkflow` jobs) |
| `API.now` | No command; workflow time is provided by activation timestamp |
| `API.random` / `API.uuid4` | No command; deterministic random seed is provided by activation jobs |
| `API.phase` | No command unless a timeout is configured; executor dispatches `SignalWorkflow` and `DoUpdate` jobs to handlers |
| `API.phase(..., timeout: ms)` / `API.phase!(..., timeout: ms)` | `StartTimer`; `CancelTimer` if the phase exits before timeout |
| sync update handler | `UpdateResponse{accepted}` immediately, then handler's commands, then `UpdateResponse{completed}` |
| `{:async, fn, state}` (update) | `UpdateResponse{accepted}` immediately, then handler's commands, then `UpdateResponse{completed}` |
| `{:async, fn, state}` (signal) | No protocol-level tracking — handler's commands are regular commands |
| `API.parallel(fns)` / `API.parallel!(fns)` | Multiple commands in one activation (e.g. multiple `ScheduleActivity`) |
| `API.publish_state` | No command (executor state for query serving) |
| `API.update_state` | No command (executor-internal state transformation) |
| `{:continue_as_new, args}` | `ContinueAsNewWorkflowExecution` |
| `API.patched?(id)` | `SetPatchMarker` (or reads `NotifyHasPatch` from activation) |
| `API.deprecate_patch(id)` | `SetPatchMarker` with deprecated flag |

The executor allocates unique sequence numbers across all workflow units (runner, handlers, parallel branches) and routes `Resolve*` jobs back to the correct process. Temporal Core sees a flat stream of commands and has no knowledge of the Elixir scheduling model.
