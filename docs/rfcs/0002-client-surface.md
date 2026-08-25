# RFC 0002 — The client surface: module-owned workflows and the start chain

**Status: proposed.**
**Scope: the public client API, plus one new backend operation.** The
deterministic core, the scheduler and replay contract, and the workflow-side
`API.*` surface are untouched. Everything here compiles down to the existing
`Temporalex.Client` primitives with a single exception: signal-with-start is
an atomic server operation that cannot be composed from `start_workflow` +
`signal_workflow` without reintroducing the race it exists to kill, so it
requires one new backend callback and NIF op (`signal_with_start`).

---

## 1. The problem, by autopsy

This is a real call from the example repository, reduced to its parts:

```elixir
def greet(name) do
  Client.start_workflow(
    TemporalEval.client(),                                     # ①
    Greet,
    %{"name" => name},                                         # ②
    workflow_id: TemporalEval.demo_id("greet-#{name}"),        # ③
    task_queue: TemporalEval.Application.task_queue!(@worker)  # ④
  )
end
```

Four arguments; one of them (`Greet`) is a decision. The rest:

| | Defect | Evidence |
| --- | --- | --- |
| ① | The connection is threaded through every call | callers invent a `client()` helper |
| ② | The client's codec dictates the payload's key type | `%{"name" => ...}` because the worker runs `:json` |
| ③ | Identity is invented at the call site, and *optional* | omit it and a random id is generated silently (`backend/temporal_core.ex:224`) — which quietly turns an at-most-once start into at-least-once |
| ④ | The caller reconstructs routing the SDK already has | the user wrote `task_queue!/1` and a `@worker` attribute to look up what the worker was configured with |

Two more defects are invisible in the snippet:

- Omitting `:task_queue` silently falls back to the client's default queue
  (`"default"`, `backend/temporal_core.ex:57,86`). Nothing polls it, so the
  workflow sits "Running" forever — the classic first-hour Temporal bug,
  shipped as a default.
- The SDK already generates a hook for exactly this information —
  `__workflow_defaults__/0` (`workflow.ex:11`, `public_api.md:26`) — and
  nothing in the codebase reads it. The right shape was designed and never
  wired up.

Meanwhile the *workflow-side* API already solved this problem once:
`defactivity double(n)` generates a dispatch function
(`activity.ex:85`), so workflow code calls `Activities.double(n)` instead of
`API.execute_activity("Activities.double", [n], ...)`. Activities got
ergonomics; workflows calling in from outside did not. This RFC extends the
same idea to the client surface.

---

## 2. Principles

Each of these decided at least one argument during the design review. They
are the tiebreakers for every future surface question.

**P1 — The SDK never asks for something it already knows.**
Client, task queue, workflow type, codec: all derivable. A call site states
decisions, not plumbing.

**P2 — Defaults may be convenient, never consequential.**
A 60-second await timeout is convenience: expiring is recoverable. A random
workflow id is consequence: it silently changes idempotency semantics.
Convenient facts get defaults; consequential facts are stated or raise.

**P3 — Anything consequential is syntactically visible at the call site.**
Creation spells `new`. Execution spells `!`. Data never hides in an options
list. A reader must be able to see what a call can do without opening docs.

**P4 — Three kinds of argument, three shapes.**

| Kind | Shape | Why |
| --- | --- | --- |
| address | whatever `id/1` accepts — a struct, a bare pk | never serialized; just resolved |
| payload | a map or explicit term, positional | it is *data*: codec-encoded, recorded in history forever |
| options | trailing keyword list | control knobs — timeouts, overrides; never serialized |

**P5 — One name per operation.**
No aliases. The current `:workflow_id`/`:id` pair (`client.ex:629-631`) is
the cautionary example: two spellings mean the API cannot even guide users to
one.

**P6 — Builders are inert; terminal verbs run; a bang raises.**
Constructors and chain steps only produce data — they touch nothing and have
no failure *effects*. They may still raise `ArgumentError` on programmer
misuse (an unknown option, a missing `id/1`): that is the loud-and-early
guidance P2 demands, same as `MapSet.new(:not_enumerable)` raising.
Terminal verbs perform the operation, in two spellings — `start!` raises on
failure (for pipelines), `start` returns tagged tuples (for `with`). Docs
lead with the bang forms and the shortest honest call.

---

## 3. The workflow module contract

Everything a workflow *is* — its behaviour, identity, and address — is
declared once, on the module. Both sides of the task queue compile this
module (the caller to start it, the worker to run it), which is what makes it
the only location where routing and identity cannot drift apart.

```elixir
defmodule Booking do
  use Temporalex.Workflow, queue: "bookings"

  # The workflow id — Temporal's idempotency key. One clause per shape
  # callers naturally hold.
  @impl true
  def id(%Fresha.Booking{id: pk}), do: "booking-#{pk}"
  def id(pk) when is_integer(pk), do: "booking-#{pk}"

  # Optional: what goes into history. The address source is often richer
  # than the durable input should be — an Ecto struct starts a workflow,
  # but only the pk belongs in history.
  @impl true
  def input(%Fresha.Booking{id: pk}), do: pk
  def input(pk), do: pk

  @impl true
  def run(booking_id) do
    # ...
  end
end
```

### `use` options

| Option | Required | Meaning |
| --- | --- | --- |
| `queue:` | yes | the task queue — the rendezvous string where this workflow's work and workers meet |
| `name:` | no | the wire type; defaults to `inspect(__MODULE__)`. Set it when the type must outlive the module name |
| `client:` | no | which client this workflow's generated functions use; defaults to the app's default client |

`queue:` is required rather than defaulted because the failure mode of a
silently wrong queue is a hang, not an error (P2). It is a property of the
workflow *type* — as intrinsic as its name — not of any call, client, or
deployment.

### Callbacks

```elixir
@callback id(input :: term()) :: String.t() | :generate
@callback input(term()) :: term()                # optional; defaults to identity
@callback run(input :: term()) :: {:ok, term()} | {:error, term()}
```

`id/1` is **required**. The workflow id is the single field that decides
what a duplicate start means — and deriving it from the business key is what
lets any other system (a webhook handler, a Broadway consumer) address the
workflow knowing only that key.

Deriving the id is necessary but not sufficient for idempotent starts:
Temporal's *default* id-conflict policy **fails** a start against a running
execution rather than attaching to it. So the generated `start!`/`execute!`
default to `id_conflict_policy: :use_existing` — a duplicate start returns a
handle to the running execution, which is the semantics every example in
this document reads as. Callers that want duplicate starts to be loud errors
say so: `Booking.start!(id, id_conflict_policy: :fail)`. This default is
consequential and therefore stated here, in the specs, and in the generated
docs (P2 applies to us too: the decision is made visibly, once, not
silently). A workflow that
genuinely wants server-generated ids opts out in one deliberate line:

```elixir
def id(_), do: :generate
```

The friction of writing that line is the guidance. There is no silent path
to a random id (P2, P3).

Mechanically, `id/1` is declared in `@optional_callbacks` and enforced at
runtime by the generated functions — a hard `@callback` would make every
existing `use Temporalex.Workflow` module emit an undefined-callback warning
and break `--warnings-as-errors` CI. "Required" here means *required to use
the generated surface*, raised with instructions, not required to compile.
For the same reason the surface is generated only when `use` is given
`queue:`, and every generated function is `defoverridable` — an existing
module that already defines `start!/2` keeps its own.

---

## 4. The generated surface

`use Temporalex.Workflow` generates a call-side API, the same way
`defactivity` already does for activities:

```elixir
# fire and move on — the entity-workflow case
handle = Booking.start!(booking_id)

# fire, wait, get the answer — the checkout case
receipt = Deposit.execute!(booking_id)

# address the running workflow, knowing only the business key
:ok = Booking.signal!(booking_id, "capture_completed", %{status: "ok"})
answer = Booking.query!(booking_id, "status")
```

Every generated function has a tuple-returning twin without the bang:

```elixir
with {:ok, handle} <- Booking.start(booking_id),
     {:ok, receipt} <- Temporalex.await(handle) do
  ...
end
```

| Generated | Returns | Is exactly |
| --- | --- | --- |
| `new(input, opts \\ [])` | `%Temporalex.Start{}` | pure data — nothing happens |
| `start!(input, opts \\ [])` | `%Temporalex.Handle{}` | `new(input, opts) \|> Temporalex.start!()` |
| `execute!(input, opts \\ [])` | the result | `new(input, opts) \|> Temporalex.execute!()` |
| `signal!(address, name, payload \\ nil, opts \\ [])` | `:ok` | resolve `id/1`, deliver; error if absent |
| `query!(address, name, args \\ [], opts \\ [])` | the reply | resolve `id/1`, query |
| plus `start/2`, `execute/2`, `signal/4`, `query/4` | tagged tuples | same operations, `with`-friendly |

Specs follow P4 — one positional data argument, everything else named and
typed:

```elixir
@spec execute!(input :: term(), opts) :: term()
      when opts: [
             id: String.t() | :generate,
             queue: String.t(),
             client: atom(),
             timeout: pos_integer() | :infinity
           ]
```

The first argument is always the data being acted on — input for `start`,
address for `signal` — so every function pipes naturally.

**The generated surface is client-side only, enforced.** Calling
`Booking.start!` or `signal!` from *inside* workflow code is a live client
call during replay — nondeterminism, precisely what
`implementation_principles.md` forbids. Because the generated functions make
that mistake one token away from the legal child-workflow API, they check
for workflow context (`:__temporal_context__`) and **raise**, pointing at
`API.execute_child_workflow` / `API.signal_child_workflow` instead.

### The common case, complete

```elixir
greeting = Greet.execute!("Fresha")
```

One argument, which is data. The 60-second default wait comes from the
client (`workflow_result_timeout`, today's default at
`backend/temporal_core.ex:67`); an await timing out is the *caller* giving
up — the workflow is untouched and the handle can be awaited again.

---

## 5. The start chain

Underneath the sugar, every start is data plus one verb. `new/2` builds a
`%Temporalex.Start{}` — inspectable, testable with no server anywhere — and
the chain sets properties on it:

```elixir
booking_id
|> Booking.new()
|> Temporalex.retry(max_attempts: 3)
|> Temporalex.fairness(salon_id)
|> Temporalex.index(salon_id: salon_id)
|> Temporalex.memo(channel: "marketplace")
|> Temporalex.execute!()
```

The chain is the exception, not the norm: docs lead with
`Booking.execute!(id)`, and the chain appears when a call genuinely carries
policy. Every chain step also has a keyword-option spelling
(`execute!(id, retry: ...)`) — same struct underneath, one machinery.

### Chain vocabulary

| Step | Sets | Notes |
| --- | --- | --- |
| `id("…")` / `id(:generate)` | workflow id override | escape hatch; `id/1` normally did this in `new` |
| `queue("…")` | task queue override | for starting on *someone else's* queue — the cross-service seam |
| `client(Other)` | which connection | multi-namespace apps |
| `input(term)` | durable input override | rare: when address and input genuinely diverge |
| `timeout(ms)` | the **caller's** wait | expiring never touches the workflow |
| `run_timeout(ms)` | one run's lifetime | *consequential*: expiry destroys the run without compensation — never defaulted |
| `execution_timeout(ms)` | the whole chain's lifetime, retries and continue-as-new included | same, and the distinction from `run_timeout` matters for RFC 0001's fallback budgets |
| `retry(opts)` | workflow retry policy | |
| `priority(n)` | queue priority band | smaller is higher |
| `fairness(key, weight \\ 1.0)` | fair dispatch key | typically a tenant id — noisy-neighbour protection |
| `index(kv)` | indexed search attributes | machine-findable: `temporal workflow list --query` |
| `memo(kv)` | unindexed memo | human-readable context in the UI; on *start* this is blocked upstream (sdk-rust #1443, draft PR #17) |
| `headers(kv)` | header payloads | usually an interceptor's job, not the call site's |
| `cron("0 9 * * *")` | cron schedule | |
| `with_signal(name, payload)` | signal-with-start | see below |

`index`, not `search`: chain steps are verbs describing what happens to
*this request*, and searching is what someone does later. The pair is
self-teaching — `index` is machine-findable, `memo` is human-readable — and
Ecto migrations already made "index" native Elixir vocabulary for
*make-this-indexed*. The docs still say "search attributes" so Temporal's
own term stays discoverable. No `search` alias exists (P5).

### Terminal verbs

A chain ends with exactly one running verb — `start!`/`execute!` (or the
tuple twins). Everything before it is inert data; the last call is the only
one that touches Temporal.

```elixir
# same request, different last word
... |> Temporalex.start!()      # → %Handle{}, nobody waits
... |> Temporalex.execute!()    # → result
```

`... |> Temporalex.start!() |> Temporalex.await!()` is legal and is
`execute!` spelled long; docs steer to `execute!`.

**Timeout on a `start!`-ended chain** is carried on the returned
`%Handle{}` and becomes the default for a later `await!(handle)`. The
timeout means the same thing in every chain — *how long a waiter waits* —
it just activates whenever the waiting happens. Nothing is silently
ignored, nothing raises, and one built request works with either ending.

### Signal-with-start

Temporal's `SignalWithStartWorkflowExecution` is one atomic server
operation: *if the workflow exists, deliver the signal; if not, create it
and write the signal into history before its first task.* It exists to kill
the check-then-act race — a payment webhook and the booking's creation can
arrive in either order, and both must work.

Because this chain **can create an execution**, it must begin with `new`
(P3). A *signal* never creates implicitly — only `new`-chains (and their
fused `start!`/`execute!` shortcuts) create:

```elixir
booking_id
|> Booking.new()
|> Temporalex.with_signal("capture_completed", %{status: "ok"})
|> Temporalex.start!()
```

`with_signal` — not `signal` — because mid-chain steps are properties, and
`signal!` is already the standalone *sending* verb. One word, one meaning
(P5). The standalone send is unchanged and errors if the target is absent:

```elixir
Booking.signal!(booking_id, "capture_completed", %{status: "ok"})
```

A consequence worth stating: on the generated surface, **every code path
that can create an execution contains `.new(` or a fused
`start!`/`execute!`** — creation is greppable. (The low-level
`Client.start_workflow` remains public, so the guarantee is per-surface, not
global.)

Upstream caveat: sdk-rust's signal-with-start request path omits
`priority`, `links`, `completion_callbacks` and `request_eager_execution`.
It does set `retry_policy` (v0.7.0; an earlier revision of this list said
otherwise). Of those, only `priority` is reachable from this surface. A
request carrying `with_signal` *and* one of them must **raise** — silently
dropping options is exactly the defect class this RFC exists to remove.
Temporal also rejects `id_conflict_policy: :fail` for this operation, which
the same check refuses locally rather than leaving to the server. The check runs in the terminal verb, not
in the chain steps: steps are inert and order-independent
(`with_signal |> retry(...)` must be caught the same as the reverse), so the
terminal verb validates the completed struct before sending.

---

## 6. Handles and awaiting

```elixir
handle = Booking.start!(booking_id)

# later — possibly a different process
{:ok, result} = Temporalex.await(handle, timeout: :timer.seconds(30))
```

`%Temporalex.Handle{}` carries `workflow_id`, `run_id`, `workflow_type`,
`client`, and the chain-supplied default `await_timeout`. `await!/2` and
`await/2` replace today's `get_result/2`, which reads like a peek but
blocks. An await timeout returns `{:error, :timeout}` (or raises, with
bang); the workflow keeps running and the handle stays valid.

Tuple twins return the SDK's existing normalized error structs (the
`Temporalex.Error` taxonomy — `ClientUnavailableError`, `TransportError`,
`WorkflowFailedError`, ...); bang twins raise the same structs. A per-function
table of exact struct per failure lands with the implementation, but the
contract is fixed now: **no bare atoms, no strings — every error is one of
the normalized structs**, so `Exception.message/1` always works.

`timeout: :infinity` is legal and undocumented-by-example: a six-week
workflow being awaited is a design smell — `start!` plus a signal is the
right shape, and the 60-second default failing loudly is what says so.

---

## 7. Resolution and precedence

Every fact resolves through the same ladder: **call site → workflow module
→ client → SDK default or loud error.**

| Fact | Call site | Module | Client | Otherwise |
| --- | --- | --- | --- | --- |
| workflow id | `id:` option / `id(...)` step | `id/1` | — | **raise**, naming the callback to write |
| task queue | `queue:` | `use ..., queue:` (required) | — | — |
| client | `client:` | `use ..., client:` | — | the default client |
| await timeout | `timeout:` | — | `workflow_result_timeout` | 60 s |
| durable input | `input(...)` step | `input/1` | — | identity |
| id conflict | `id_conflict_policy:` | — | — | `:use_existing` on the generated surface |
| payload codec | — | — | `payload_codec` | `:etf` |
| wire type | — | `use ..., name:` | — | `inspect(module)` |

One naming note (P5): on the generated surface `timeout:` always means the
*caller's wait*. The low-level start RPC's own deadline (today also called
`:timeout` on `Client.start_workflow`) is not exposed here; internally it is
never conflated with the await timeout.

The default client is the `Temporalex.Client` started without a `name:`
(it takes `Temporalex.Client` as its registered name). Apps with one
connection configure nothing; multi-namespace apps name their clients and
say `client:` per workflow module — which is where a bookings/payments
namespace split lands.

**Loud, instructive errors** (never silent fallbacks):

- start with no `id:` and no `id/1` → raise: *"define `id/1` on `Booking`
  or pass `id:` — the workflow id is Temporal's idempotency key; return
  `:generate` to opt out"*
- generated function used on a module whose `use` lacks `queue:` → raise
  at the call, naming the option
- no client running under the resolved name → raise with the child spec to
  add
- `with_signal` combined with an option the upstream path drops → raise at
  build time

---

## 8. Worker wiring

Workflows now carry their queue, so the worker stops asking for what it can
read:

```elixir
# a caller-only node (Phoenix) — starts bookings, never runs them
children = [
  {Temporalex.Client, target: temporal_target(), namespace: "default"}
]

# the bookings-worker deployable
children = [
  {Temporalex.Client, target: temporal_target(), namespace: "default"},
  {Temporalex.Worker, workflows: [Booking, Waitlist], activities: [Bookings.Activities]}
]
```

- `queue:` on the worker is gone: derived from the workflow modules, with a
  **boot error if the listed modules declare different queues** — the
  misrouting bug caught at startup instead of as a silent hang.
- `name:` is gone: derived from the queue, overridable.
- `client:` defaults to the default client.
- The worker entry itself stays, deliberately: it is the deployment
  topology written down — *this node serves these workflows* — a property
  of the deployable that cannot live on the module, because every node
  compiles the module and only some may poll.

---

## 9. The serialization boundary

`input/1`'s return value is the durable input: it is what the codec
encodes, what history records, and what `run/1` receives *after* the codec
round-trip. The contract is:

> `run/1` is written against the post-codec shape of `input/1`'s return.

With `:etf` the round-trip is the identity — atoms, tuples, structs all
survive. With `:json` it is lossy: atom keys become strings, tuples are
unsupported. A workflow on a `:json` client that takes
`input(%Booking{id: pk}), do: %{booking_id: pk}` must pattern-match
`%{"booking_id" => pk}` in `run/1`.

This RFC does not add a canonicalization layer; it makes the boundary a
named, documented place instead of a surprise at every call site. (Noted in
passing: `implementation_principles.md`'s Serialization section still calls
the converter fixed-ETF, which predates the `:json` codec — it needs its own
update, independent of this RFC.) A
round-trip check in `Temporalex.Testing` — assert `input/1`'s output
survives the configured codec — is listed as an open question.

---

## 10. Architecture: sugar over one choke point

Every generated function compiles to a call into the existing
`Temporalex.Client` primitives, through `with_client_connection/4`. Nothing
bypasses it, which means:

- **interceptors wrap the new surface for free** — trace-context injection
  from RFC-adjacent work (#16) applies identically to `Booking.execute!`
  and to raw `Client.start_workflow`;
- the low-level API remains public and unchanged, for the cases with no
  module to call — starting a workflow by *string* type across a namespace
  boundary (the booking→payments seam), and everything existing code does
  today;
- there is exactly one place where an operation becomes a backend call, so
  error normalization, client-down detection, and future middleware stay
  single-pathed.

One implementation note from hard-won experience: the backend's
`native_start_opts/1` is an allowlist, and options omitted from it are
**silently dropped** before reaching the NIF — this bit both `:priority`
and `:memo` during development. Every option this RFC introduces must be
added there, and the round-trip covered by a test that fails when the
allowlist is stale.

---

## 11. Compatibility and migration

Phase 1 — additive (target 0.5):

- `use Temporalex.Workflow` accepts `queue:`/`name:`/`client:` (it ignores
  all options today, `workflow.ex:6`, so this breaks nothing).
- The generated surface appears; existing modules without `queue:` compile
  unchanged, and only raise if the *generated* functions are called.
- `Temporalex.await!/await` land as the primary collection API, with
  `get_result/2` soft-deprecated in docs (`@doc deprecated:`). A hard
  `@deprecated` would emit compile warnings in every existing caller and
  break `--warnings-as-errors` CI — the same reasoning as `id/1`'s
  optional-callback mechanics.
- The low-level random-id fallback logs a deprecation pointing at `id/1` /
  `:generate`.
- `__workflow_defaults__/0` — generated, documented, read by nothing — is
  removed.
- `Temporalex.Client.Handle` is extended in place with `await_timeout`
  rather than moved: renaming the struct would break every existing pattern
  match, which is Phase-2-grade breakage. The rename question is deferred.
- an unnamed `{Temporalex.Client, ...}` today runs *unregistered*; giving it
  the default registered name is a behaviour change. Two unnamed clients in
  one app — legal today — will collide at boot with an error telling them to
  name one. Called out in the changelog.

Phase 2 — the consequential defaults die (target 0.6):

- silent random workflow ids raise (`:generate` remains).
- the client-level `task_queue:` fallback on *starts* is removed — the
  second consequential silent default from §1 (the "sits Running forever"
  queue). The client keeps its queue for the low-level API's worker wiring;
  starts must resolve a queue from the module or the call site. The README's
  "Clients and workers" section (which currently documents the fallback)
  is rewritten when this lands.
- `get_result/2` is removed.
- `:workflow_id`/`:id` collapses to `:id` on the new surface; the
  low-level API keeps both for compatibility, documented as one.

---

## 12. Interaction with RFC 0001

RFC 0001 versions behaviour by workflow *type* (`Booking.V1`, `Booking.V2`)
and requires that only `route/2` names a type at Fresha call sites, and that
ids and signal contracts stay stable across a version family. The generated
surface composes with that — `route(:booking, salon).execute!(id)` — but two
rules keep them compatible:

- **a version family shares one `id/1`**: `V2` delegates to (or hoists) the
  family's id derivation, so `Booking.V1.id(x) == Booking.V2.id(x)` always.
  Ids drifting between versions would break fallback re-attachment.
- direct `Booking.V1.execute!` remains what 0001 says it is — forbidden at
  application call sites by 0001's own compile checks, not by this RFC. The
  generated surface is the mechanism; 0001 governs who may invoke it.

## 13. Out of scope

- The executor, scheduler, replay matching, and the backend behaviour —
  nothing here touches `docs/implementation_principles.md`'s territory.
- The workflow-side `API.*` surface (activities, timers, child workflows).
- Update handlers on the generated surface (`update!` should follow the
  same grammar; it needs its own pass).
- Worker versioning and the deployment story (RFC 0001, PR #14).
- Nexus, schedules, reset.

## 14. Open questions

1. **Multi-queue worker spec.** `{Temporalex.Worker, workflows: [...]}`
   spanning two queues: boot error (recommended — keeps *one worker = one
   queue = one deployable* visible) or silently fan out one worker per
   queue?
2. **Deriving `activities:`.** The workflow modules know which activity
   modules they call; a later pass could derive the worker's activity list
   the way the queue is derived.
3. **Codec round-trip check.** A `Temporalex.Testing` assertion that
   `input/1` output survives the client's codec — cheap insurance for the
   §9 contract.
4. **`with_signal` versus the upstream gap.** Raise on the dropped-option
   combinations (recommended), or block the feature on an sdk-rust fix.

---

## Appendix A — the full integration, before and after

Before: a per-worker block of eight options in `application.ex`, plus a
facade module carrying `client()`, `demo_id/1`, `task_queue!/1`, and a
`@worker` attribute.

After — every file a user touches:

```elixir
# mix.exs
{:temporalex, "~> 0.5"}
```

```elixir
# application.ex
children = [
  {Temporalex.Client,
   target: System.get_env("TEMPORAL_TARGET", "http://127.0.0.1:7233"),
   namespace: "default"},
  {Temporalex.Worker, workflows: [Greet]}
]
```

```elixir
# greet.ex
defmodule Greet do
  use Temporalex.Workflow, queue: "greetings"

  @impl true
  def id(name), do: "greet-#{name}"

  @impl true
  def run(name), do: {:ok, "Hello, #{name}!"}
end
```

```elixir
# the call
greeting = Greet.execute!("Fresha")
```

And the composed forms, when composition is real:

```elixir
# start now, collect later
handle = Greet.start!("Fresha")
{:ok, greeting} = Temporalex.await(handle)

# policy on one call
booking_id
|> Booking.new()
|> Temporalex.fairness(salon_id)
|> Temporalex.index(salon_id: salon_id)
|> Temporalex.execute!()

# the webhook race, atomically
booking_id
|> Booking.new()
|> Temporalex.with_signal("capture_completed", %{status: "ok"})
|> Temporalex.start!()
```

## Appendix B — naming ledger

Decisions made against alternatives, so they are not relitigated by
accident:

| Chosen | Rejected | Why |
| --- | --- | --- |
| `id` / `id/1` | `runkey` | "run" means one incarnation in Temporal; inventing a word for the workflow id makes users learn a mapping the UI and CLI will contradict |
| `queue:` | `task_queue:` | shorter; unambiguous in context |
| `new` | — | the community constructor convention (`MapSet.new`, `Req.new`, `Ecto.Multi.new`): pure data, born valid, no effects. Raises `ArgumentError` on misuse; if construction ever validates against *external* state, convention says `{:ok, t}` + `new!` |
| `index` | `search` | chain verbs describe what happens to the request now; searching happens later, done by someone else |
| `with_signal` | `signal` (mid-chain) | `signal!` is the standalone sending verb; the same word must not mean *attach* in one position and *send* in another |
| `await` | `get_result` | `get_result` reads like a peek but blocks; `await` says what it does |
| `execute!`/`start!` pair | one merged call | the verb at the call site documents whether the caller expects the answer here; a `wait:` option hides that in the place meaning goes to be skimmed |
| start-chain `with_signal` | a `%Signal{}` builder ending in `send!`/`start!` | the signal-side chain let a terminal verb create an execution whose input never appeared in the chain — hidden creation; `new` is the visible creation marker, and deleting the second noun shrank the surface |
| bare-value input | required map input | `id/1` and `run/1` receive what you passed; wrapping a pk in a map to satisfy the SDK was ceremony |
