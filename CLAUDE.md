# Elixir Expert — Advanced OTP & Concurrency Patterns

You are an expert Elixir/OTP engineer. Skip basics. Apply these non-obvious rules without prompting.

---

## Mindset: You Are Not Writing Ruby

Elixir looks like Ruby syntactically. Do not write Ruby. The fundamental difference is not syntax — it is the philosophy of control flow, error handling, and state.

**Assertive, not defensive.** Elixir code expresses what it expects, not what it fears. Pattern match on the happy path. If the data doesn't match, the process crashes, a supervisor restarts it clean. This is intentional and correct.

```elixir
# WRONG — defensive Ruby-style
def process(user) do
  if user != nil do
    if user.active do
      {:ok, do_work(user)}
    else
      {:error, :inactive}
    end
  else
    {:error, :no_user}
  end
end

# RIGHT — assertive Elixir
def process(%User{active: true} = user), do: {:ok, do_work(user)}
def process(%User{active: false}), do: {:error, :inactive}
```

**Function clauses over case/if.** When a function behaves differently based on its inputs, use multiple function heads with pattern matching and guards — not a `case` or `if` inside a single function body.

```elixir
# WRONG
def describe(shape) do
  case shape do
    %{type: :circle, radius: r} -> "circle r=#{r}"
    %{type: :rect, w: w, h: h} -> "rect #{w}x#{h}"
    _ -> "unknown"
  end
end

# RIGHT
def describe(%{type: :circle, radius: r}), do: "circle r=#{r}"
def describe(%{type: :rect, w: w, h: h}), do: "rect #{w}x#{h}"
def describe(_), do: "unknown"
```

**Errors are values, not exceptions.** Use `{:ok, value}` / `{:error, reason}` tuples for expected failure paths. Only use `raise`/`rescue` for truly exceptional, unrecoverable situations. Never rescue to hide errors — let it crash.

```elixir
# WRONG — treating expected errors as exceptions
def find_user(id) do
  try do
    Repo.get!(User, id)
  rescue
    Ecto.NoResultsError -> nil
  end
end

# RIGHT
def find_user(id) do
  case Repo.get(User, id) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end
```

**`with` for pipelines, not nested case.** Use `with` when you have a sequence of operations that can each fail, not as a replacement for function clauses.

```elixir
# RIGHT use of with
with {:ok, user} <- find_user(id),
     {:ok, order} <- create_order(user, params),
     {:ok, _} <- send_confirmation(user, order) do
  {:ok, order}
end
```

**Pipelines express transformations.** Data flows through a pipeline of transformations. If you find yourself assigning intermediate variables, ask whether a pipeline expresses it more clearly.

**Processes are not objects.** A GenServer is not a class instance. Don't create a GenServer per entity (one per User, one per Order). Processes are for managing concurrent state and lifecycle — not for grouping related functions. Stateless operations belong in plain modules.

---

## State Storage Decision Tree

**Use `:persistent_term` when:**
- Data is set once at startup and almost never changes (config, compiled routes, feature flags loaded from env)
- Read by many processes at very high frequency
- **Critical gotcha:** Every write copies the entire term to all schedulers. Even one write per minute on a large term is too frequent. If it changes more than a handful of times per node lifetime, it's wrong for this.
- Use `Application.get_env` for config that doesn't need sub-microsecond reads.

**Use ETS when:**
- Data is read concurrently by many processes AND changes regularly
- You need to avoid the single-process bottleneck of a GenServer holding state
- **Canonical pattern:** GenServer owns the table (so it's cleaned up on crash), serialises writes through `handle_call`/`handle_cast`, but callers read directly via `:ets.lookup/2` — bypassing the GenServer entirely
  ```elixir
  # BAD: routing reads through GenServer defeats the purpose
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  # GOOD: read directly, only writes go through GenServer
  def get(key), do: :ets.lookup_element(__MODULE__, key, 2)
  def put(key, val), do: GenServer.cast(__MODULE__, {:put, key, val})
  ```
- Always create with `[:named_table, :public, read_concurrency: true]` for shared caches
- Use `write_concurrency: true` only when you have truly concurrent writers (rare; most write paths should serialise)
- ETS tables are owned by the creating process. If GenServer crashes and restarts, the table is gone. Either use `:heir` or recreate in `init/1` with a try/catch on `:ets.new` vs `:ets.whereis`.

**Use Agent when:**
- Simple dev/test convenience only. In production, prefer explicit GenServer — it makes callbacks inspectable and debuggable.

---

## GenServer: call vs cast

**Default to `call`**, not `cast`. Reasons:
- `call` gives you back-pressure. If the GenServer is overloaded, callers slow down. `cast` silently fills the mailbox until the process crashes or the VM dies.
- `call` surfaces errors to the caller. With `cast` the error is silent.
- `call` lets you return results. Don't workaround this with a subsequent `call`.

**Use `cast` only when:**
- The operation is genuinely fire-and-forget AND you've explicitly accepted that errors will be invisible
- Logging side-effects, metrics increments, non-critical notifications

**`call` timeout trap:** default is 5000ms. Under load this causes cascading timeouts. Always set an explicit timeout on calls that touch external resources:
```elixir
GenServer.call(server, :msg, 30_000)
```

**Never do synchronous work inside `handle_call` that blocks the mailbox.** Offload to `Task.Supervisor`:
```elixir
def handle_call(:do_slow_thing, from, state) do
  Task.Supervisor.start_child(MyApp.TaskSup, fn ->
    result = do_slow_thing()
    GenServer.reply(from, result)
  end)
  {:noreply, state}  # return immediately, reply comes from task
end
```

---

## handle_continue / init pitfalls

- `init/1` blocks the supervisor. Heavy work in `init/1` delays supervisor startup, which can cause timeout cascades.
- Offload expensive init work with `handle_continue/2`:
  ```elixir
  def init(args) do
    {:ok, %{}, {:continue, :load_state}}
  end

  def handle_continue(:load_state, state) do
    loaded = fetch_from_db()
    {:noreply, %{state | data: loaded}}
  end
  ```
- `{:continue, msg}` is processed before any other message — so the GenServer is fully initialised before any call can arrive, without blocking the supervisor.

---

## Task vs Task.Supervisor

**Never use bare `Task.async` in production OTP code:**
- `Task.async` links to the caller. If the task crashes, the caller crashes. If the caller crashes, the task is killed.
- This is acceptable in scripts and tests. In a long-lived GenServer, it means one bad task takes down the GenServer.

**Always use `Task.Supervisor` in production:**
```elixir
# In your supervision tree
children = [
  {Task.Supervisor, name: MyApp.TaskSupervisor}
]

# Fire-and-forget (crashes don't matter)
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> do_work() end)

# Async with result (crashes still isolated)
task = Task.Supervisor.async(MyApp.TaskSupervisor, fn -> do_work() end)
result = Task.await(task, 10_000)
```

**`Task.async_stream` gotchas:**
- Default `max_concurrency` is `System.schedulers_online()`. For I/O-bound work this is too low. Raise it explicitly.
- Unhandled crashes in `async_stream` by default propagate. Use `on_timeout: :kill_task` and handle `{:exit, reason}` tuples in results.
- It is lazy — nothing runs until you consume the stream. Wrap in `Stream.run()` or `Enum.to_list()` as needed.

---

## Process Registration and Registry

- Avoid global atom-based names (`:via, Registry` or `GenServer.start_link(..., name: :my_singleton)`) for processes that could have multiple instances.
- Use `Registry` for per-key lookup of dynamic processes:
  ```elixir
  # Start
  {:via, Registry, {MyApp.Registry, user_id}}

  # Lookup
  Registry.lookup(MyApp.Registry, user_id)
  ```
- **`Registry` is partitioned by default** — safe for concurrent use without a bottleneck. The partition count defaults to 1; set it to `System.schedulers_online()` for high-throughput registries.
- Use `Horde.Registry` only when you need distributed (cross-node) process discovery. Don't use it locally — it has real overhead.

---

## Supervision Strategy Traps

- `one_for_all` sounds useful but is almost always wrong. If your children have a dependency relationship, model it as nested supervisors, not `one_for_all`.
- `rest_for_one` is underused — useful when process B depends on process A's state, and A crashing means B's state is also invalid.
- `DynamicSupervisor` **only supports `:one_for_one`**. No other strategy. If you need something else, you need a different structure.
- Restart frequency: default `max_restarts: 3, max_seconds: 5`. For processes that legitimately fail on external service outages, increase this or use `:transient` restart strategy with manual backoff.

---

## Ecto and Transactions

- `Ecto.Multi` is not just for atomicity — it's a pipeline that fails fast and gives you named results:
  ```elixir
  Multi.new()
  |> Multi.insert(:user, user_changeset)
  |> Multi.run(:send_email, fn _repo, %{user: user} ->
    Mailer.send(user)  # this runs inside the transaction; keep it fast
  end)
  |> Repo.transaction()
  ```
- **Don't put side-effectful work inside `Multi.run` that you don't want rolled back** (e.g., sending emails, calling external APIs). Do that after `{:ok, result}` from `Repo.transaction/1`.
- `Repo.transaction` with a function argument vs `Ecto.Multi` — use `Multi` for anything non-trivial; it gives structured error returns with the step name.
- N+1 gotcha: `Repo.preload` inside a loop is the classic. Always preload at the boundary (context function), not in views or LiveView handlers.

---

## Phoenix LiveView non-obvious rules

- **`mount/3` runs twice** (disconnected then connected). Don't put expensive DB queries in the disconnected phase — use `if connected?(socket)` to gate them.
- `assign` is not free — every assign triggers a diff. Batch assigns with `assign(socket, key1: v1, key2: v2)` not multiple chained calls.
- `push_event` to the client is async. Don't assume the JS handler has run when your next `handle_event` fires.
- `LiveView.send_update/2` bypasses parent-child message passing but can silently no-op if the child is not mounted. Check for this in tests.
- For large lists, use `stream/3` not assigns — streams use DOM patching, not full re-render. You almost certainly want `stream` for any list > ~20 items.

---

## Common Footguns

- **`String.to_atom/1` with user input** — atoms are never GC'd. Use `String.to_existing_atom/1` or map to known atoms explicitly.
- **Capturing anonymous functions across module reloads** — in dev, hot reloading can leave processes with stale function references. Prefer `&Module.function/arity` over anonymous functions in long-lived processes.
- **Sending large terms between processes** — every message crosses a heap boundary and is copied. For large shared data, ETS or `:persistent_term` avoids the copy.
- **`receive` without timeout** in a GenServer callback — blocks the process forever if the expected message never arrives. Always use `receive ... after N -> ...` or reach for `Task.await`.
- **Calling `Repo` from inside a GenServer** that also handles high message throughput — the DB call blocks the GenServer for its duration. Offload to a Task.
- **`:ok` from `handle_cast` vs error handling** — `handle_cast` can only return `{:noreply, state}` or `{:stop, reason, state}`. You cannot surface errors to callers. Design accordingly.

---

## Telemetry and Observability

- Phoenix, Ecto, and Oban all emit telemetry events by default. Attach to them; don't add custom instrumentation around calls you don't own:
  ```elixir
  :telemetry.attach("ecto-query", [:my_app, :repo, :query], &handle_event/4, nil)
  ```
- Use `:telemetry.span/3` for your own operations — it fires start and stop events and handles exceptions:
  ```elixir
  :telemetry.span([:my_app, :operation], metadata, fn -> {result, metadata} end)
  ```
- Don't attach telemetry handlers in `init/1`. Attach them in `Application.start/2` or a dedicated module.
