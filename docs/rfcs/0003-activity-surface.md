# RFC 0003 — The activity surface: testable bodies, honest options, one result shape

Status: accepted (implemented alongside this document)
Builds on: [RFC 0002 — the client surface](0002-client-surface.md)

## 1. Where activities already are

Activities are the healthiest area of the SDK. They arrived at RFC 0002's
destination before RFC 0002 existed:

```elixir
defmodule Bookings.Activities do
  use Temporalex.Activity

  defactivity charge(amount), start_to_close_timeout: 30_000 do
    {:ok, PaymentGateway.charge(amount)}
  end
end

# workflow-side — a plain function call, options invisible:
receipt = Activities.charge!(amount)
```

The definition owns identity (type derived from module + name) and policy
(timeouts, retry, locality). The call site names nothing but data. A `ctx`
first argument opts into runtime context without the caller ever seeing it.
An unregistered activity fails loudly and non-retryably instead of hanging.
None of that changes.

This RFC fixes what a P1–P6 audit found around those bones. One deliberate
non-change is recorded in §8.

## 2. What is necessary and what is not

At the call site, exactly one thing is necessary: **the input.**

```elixir
amount |> Activities.charge!()
```

Everything else has a home away from the call site:

| Fact             | Home                                  |
| ---------------- | ------------------------------------- |
| type             | derived from module + name (`name:` to override, §5) |
| task queue       | inherited from the workflow's own queue |
| timeout / retry  | declared on `defactivity` or the module (§6) |
| `local:`         | declared on `defactivity`             |
| headers          | interceptors                          |
| activity id      | executor sequence number              |

Call-site *overrides* exist, but as keyword options on the dispatch call —
not as a builder chain:

```elixir
Activities.charge!(amount, timeout: 10_000, retry_policy: [maximum_attempts: 1])
```

**Why no chain.** The Start chain earned its keep: starts are client-side,
reusable, assertable data with a dozen dimensions. An activity override
happens inside one workflow function, has five knobs, and — because
`charge/1` is already the dispatch — a builder would force a second name per
activity, breaking one-operation-one-name (P5). The chain vocabulary
(`timeout`, `retry`, `queue` as polymorphic steps over an
`%Activity.Call{}`) is *reserved*: if call-site overrides turn out to be
common in practice, it can be added without breaking the keyword spelling.
Until then: if a call site needs three overrides, the usual right fix is a
second `defactivity`, not a longer call.

## 3. Findings

1. **Activity bodies are hostile to unit tests.** The implementation
   compiles to `__charge__/1`; the honest-looking `Activities.charge(100)`
   is the dispatch and raises outside workflow execution. The most-tested
   code in a Temporal app hides behind a dunder convention.
2. **Dispatch accepts no call-site options.** Policy declared at definition
   is right as the default, but a one-off override today means a second
   activity definition or editing the shared one.
3. **`{:cancelled, error}` is a third result shape.** Everything else in the
   SDK returns `{:ok, _} | {:error, _}`. Activity dispatch alone is
   triple-headed, so `with` chains need a special clause and generic
   unwrapping cannot be written.
4. **The wire type is welded to the module name.** Renaming
   `Bookings.Activities` strands every in-flight workflow that scheduled
   `"Bookings.Activities.charge"`. Workflows got `name:` in RFC 0002 for
   exactly this.
5. **No module-level defaults.** Every `defactivity` in a module repeats the
   same `start_to_close_timeout:`/`retry_policy:`.
6. **Local-activity options are not validated.** Regular activities check an
   allowlist; `local: true` dispatch passes options through raw
   (`executor.ex`, `ExecuteLocalActivity`). A misspelled or unsupported
   option — including `heartbeat_timeout:`, which local activities cannot
   honour — silently does nothing. The silent-drop class, again.
7. **Context verbs are a long walk.**
   `Temporalex.Activity.Context.heartbeat(ctx)` for the second-most-common
   activity call.

## 4. Testable bodies (finding 1)

Decision: the dispatch keeps the name — the call site users read a hundred
times a day stays `Activities.charge!(amount)` — and tests get one blessed,
explicit entry point:

```elixir
# runs the real implementation, no Temporal anywhere:
assert {:ok, receipt} = Temporalex.Testing.run_activity(Activities, :charge, [100])

# context-taking activities get a fabricated ctx, overridable per test:
assert {:ok, _} =
         Temporalex.Testing.run_activity(Activities, :heartbeat_once, [5],
           context: [attempt: 3, headers: %{"traceparent" => "00-…"}]
         )
```

`run_activity/4`:

- resolves the activity by name via `__temporal_activities__/0` and raises
  instructively when the name doesn't exist (listing what does);
- fabricates a `%Temporalex.Activity.Context{}` for `ctx`-taking activities
  — `context:` merges over honest defaults (`attempt: 1`,
  `activity_type` set to the real wire type, no worker, so `heartbeat/2`
  is a no-op exactly as documented for worker-less contexts;
  `cancelled: :atomics` seeded so `cancelled?/1` works);
- passes `context:` to a context-less activity only as an error — a test
  fabricating context for an activity that never sees it is a test bug;
- returns whatever the body returns, unwrapped and untouched. Assertion
  stays the caller's job.

Rejected alternatives, for the record: exposing `__charge__/1` as the
blessed path (keeps the dunder in every test file); making the same name
dispatch-or-run depending on where it's called (the invisible-magic pattern
rejected for signal-with-start in RFC 0002 — the same expression must not
mean two things).

The existing `Temporalex.Testing.assert_next_activity/complete_activity`
kit is the complement, not a competitor: it tests *the workflow* by mocking
the activity; `run_activity` tests *the activity* by running it.

## 5. Call-site keyword options (finding 2)

The generated dispatch and bang heads gain a trailing `opts \\ []`:

```elixir
Activities.charge!(amount, timeout: 10_000)
Activities.charge(amount, retry_policy: [maximum_attempts: 1], task_queue: "payments-external")
```

- Call-site options merge **over** the definition's options — the
  definition is the default, the call site is the exception.
- Unknown keys raise `ArgumentError` at the call, listing what is allowed
  (the same allowlist the command builder enforces, stated once).
- Existing arities keep working; the new head only adds an optional
  argument.

## 6. `name:`, module defaults, and honest locality (findings 4, 5, 6)

```elixir
defmodule Bookings.Activities do
  # module-level defaults — every activity below inherits these:
  use Temporalex.Activity, start_to_close_timeout: 30_000

  # wire type decoupled from the module name — rename-safe:
  defactivity charge(amount), name: "bookings.charge" do
    {:ok, PaymentGateway.charge(amount)}
  end

  # per-activity options override module defaults:
  defactivity reconcile(day), start_to_close_timeout: 300_000, heartbeat_timeout: 30_000 do
    …
  end
end
```

- `use Temporalex.Activity, opts` accepts the same dispatch options
  `defactivity` does; per-activity options win key-by-key.
- `name:` sets the wire type verbatim. The naming ledger entry mirrors
  RFC 0002's: the default (module + function) is right until the first
  rename; `name:` is the escape hatch you set *before* you need it.
- `local: true` definitions validate their options at **compile time**
  against what local activities support; `heartbeat_timeout:` on a local
  activity is a definition error, not a silently ignored key. Local
  dispatch gains the same unknown-option validation regular dispatch has.

## 7. One result shape, shorter context verbs (findings 3, 7)

**Cancellation folds into the error channel.** Dispatch returns
`{:ok, value} | {:error, error}`; a cancelled activity returns
`{:error, %Temporalex.Failure.CancelledError{}}` — still pattern-matchable,
no longer a third shape. The bang raises it. **Breaking** for code matching
`{:cancelled, _}`; the changelog carries the one-line rewrite
(`{:cancelled, e}` → `{:error, %Temporalex.Failure.CancelledError{} = e}`).

**Context verbs move up one level.** `Temporalex.Activity.heartbeat(ctx)`
and `Temporalex.Activity.cancelled?(ctx)` delegate to `Context`; the long
spellings keep working. `heartbeat/2` keeps its cancellation-aware return
(`:ok | {:cancelled, reason}`) — that duality is the *point* of
heartbeating and is the one place the tuple is information, not noise.

## 8. The deliberate non-change: the 60-second default timeout

Temporal requires a timeout on every activity; when none is stated, this
SDK silently supplies `start_to_close: 60_000`. The audit called this a P2
violation — the default is consequential (it kills work and triggers a
retry), and other Temporal SDKs refuse to default it at all.

Decision: **left as-is for now**, revisit before 1.0. The options on the
table when it reopens: require a timeout at definition (compile-time raise,
module defaults making it one line per module), or keep a default and make
it loud. Recording the disagreement so it isn't re-litigated from scratch:
a shorter default (e.g. 2s) was considered and rejected — it converts
"forgot an option" into "duplicate side effects under production load,"
which is a worse failure than refusing to compile.

## Appendix — naming ledger additions

| chosen | over | because |
| --- | --- | --- |
| `run_activity` | exposing `__name__/N` | tests should read as intent, not as knowledge of a dunder convention |
| `name:` (defactivity) | `type:` | same word as the workflow escape hatch; one concept, one name |
| keyword opts on dispatch | an activity builder chain | a chain would force a second name per activity; P5 outranks pipe symmetry |
| `{:error, %CancelledError{}}` | `{:cancelled, error}` | one result algebra across the SDK; the struct keeps the information |
