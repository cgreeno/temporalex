defmodule Temporalex.Worker do
  @moduledoc """
  Supervisor for one Temporalex worker instance.

  A worker is a poller + executor bound to one task queue — the deployment
  topology written down: *this node serves these workflows*. The minimal
  spec is just that statement:

      {Temporalex.Worker, workflows: [Booking, Waitlist], activities: [Bookings.Activities]}

  Everything else is derived:

    * the task queue has exactly **one source**: derived from the workflow
      modules' `use ..., queue:` declarations (boot error if they disagree).
      Passing `task_queue:` alongside declaring modules is a boot error —
      redundant or contradictory, either way the modules own it. Only a
      worker whose modules declare nothing (activity-only workers, or
      workflow modules without `queue:`) takes — and then **requires** —
      an explicit `task_queue:`.
    * `client:` — defaults to the app's default client.
    * `name:` — derived from the queue, overridable.

  ## Capacity

  Pollers fetch work. Slots hold it while it runs. They are different numbers,
  and mixing them up is the usual reason a task queue backs up while the
  pollers, the CPU and the database all look idle.

    * `:max_workflow_pollers` / `:max_activity_pollers` — how many polls the
      worker keeps open. Five each by default.
    * `:max_workflow_task_slots` / `:max_activity_task_slots` — how much work
      the worker holds at once. Leave them unset and core decides, which means
      200 each. `:max_concurrent_workflow_task_executions` and
      `:max_concurrent_activity_task_executions` work too, matching what the
      other Temporal SDKs call them.
    * `:max_cached_workflows` — **off unless you ask for it.** Set it and
      workflows become sticky: the worker keeps each instance suspended in
      memory and applies new history to it as history arrives. Leave it off
      and every workflow task replays the whole history from the start to
      rebuild the state it needs. Once the cache is full, the least recently
      used instance is dropped to make room. You pay in memory, and you save
      more the longer a workflow's history gets.

  Setting a cache brings two rules from core with it. The workflow task slots
  and the workflow task pollers must both be at least 2. Break either one and
  the worker refuses to start, with a message naming the option you set.

      {Temporalex.Worker,
       workflows: [Booking],
       max_workflow_task_slots: 500,
       max_activity_task_slots: 500,
       max_cached_workflows: 200}

  ## Telemetry

  Counters and latencies come from core's own metrics exporter, which you
  configure on the client. See the Metrics section of the README.

  The one thing that exporter cannot tell you is which workflow left the
  cache, so the worker emits an Erlang telemetry event per eviction:

      :telemetry.attach("evictions", [:temporalex, :workflow, :evicted], &handler/4, nil)

  Measurements are `%{count: 1}`. Metadata carries `:reason`, `:message`,
  `:run_id`, `:workflow_type`, `:worker`, `:task_queue` and `:namespace`.

  Group on `:reason`, because evictions are not all the same thing:

    * `:cache_full` — the cache was full, so this instance was dropped to make
      room. The next workflow task for that run replays its whole history, so
      a rising count is the signal to raise `:max_cached_workflows` or add
      workers.
    * `:cache_miss` — a workflow task arrived for a run this worker had no
      instance for, so it replayed the history to rebuild the state.
    * `:workflow_execution_ending`, `:lang_requested` — routine, and free.
    * `:nondeterminism`, `:fatal` — a bug, not a tuning problem. These two are
      logged as warnings as well, because nothing else here reports them.
    * `:unhandled_command` — the server refused the workflow task. Not logged,
      because it also happens when a worker is shut down with a task still in
      flight.
    * `:lang_fail`, `:task_not_found`, `:pagination_or_history_fetch` — the
      rest of what core can send.
  """

  use Supervisor

  def start_link(opts) do
    opts = resolve!(opts)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl Supervisor
  def init(opts) do
    worker_name = Keyword.fetch!(opts, :name)

    server_name = server_name(worker_name)
    executor_supervisor_name = executor_supervisor_name(worker_name)
    activity_supervisor_name = activity_supervisor_name(worker_name)

    server_opts =
      opts
      |> Keyword.put(:server_name, server_name)
      |> Keyword.put(:executor_supervisor, executor_supervisor_name)
      |> Keyword.put(:activity_supervisor, activity_supervisor_name)

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: executor_supervisor_name},
      {Task.Supervisor, name: activity_supervisor_name},
      {Temporalex.Server, server_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc false
  # Fills task_queue, client, and name from what the workflow modules already
  # declare. Public (hidden) so the derivation is unit-testable.
  #
  # The queue has exactly one source. The pre-RFC-0002 fallback (silently
  # inheriting the client's queue) is dead: a worker with no queue from
  # either source refuses to boot.
  def resolve!(opts) do
    task_queue =
      agree_queue!(
        Keyword.get(opts, :task_queue),
        derive_queue!(Keyword.get(opts, :workflows, []))
      )
      |> validate_queue!()

    opts
    |> Keyword.put(:task_queue, task_queue)
    |> Keyword.put_new(:client, Temporalex.default_client())
    |> put_name(task_queue)
  end

  # Exactly one queue source. task_queue: alongside declaring modules is
  # refused whether it agrees or not: an agreeing copy is drift waiting to
  # happen, and a contradicting one is broken by construction — the worker
  # would poll one queue while the modules' generated starts target the
  # other, and those workflows would sit Running forever, unclaimed.
  defp agree_queue!(nil, nil) do
    raise ArgumentError,
          "a worker needs a task queue: declare `use Temporalex.Workflow, " <>
            "queue: ...` on the workflow modules, or pass task_queue: on a " <>
            "worker whose modules declare none (activity-only workers). " <>
            "Inheriting the client's queue is no longer supported"
  end

  defp agree_queue!(nil, declared), do: declared
  defp agree_queue!(explicit, nil), do: explicit

  defp agree_queue!(explicit, declared) do
    consequence =
      if explicit == declared do
        "It is redundant today and drift waiting to happen — the modules " <>
          "own the queue."
      else
        "The worker would poll #{inspect(explicit)} while the modules' " <>
          "generated starts target #{inspect(declared)} — those workflows " <>
          "would sit Running forever, unclaimed."
      end

    raise ArgumentError,
          "task_queue: #{inspect(explicit)} is specified alongside the " <>
            "workflow modules' declared queue: #{inspect(declared)}. " <>
            consequence <>
            " Drop task_queue: — it is derived from the modules"
  end

  # By here agree_queue! has raised on absence, so the only bad shapes left
  # are non-binary or empty values.
  defp validate_queue!(queue) when is_binary(queue) and queue != "", do: queue

  defp validate_queue!(other) do
    raise ArgumentError,
          "the task queue must be a non-empty string, got: #{inspect(other)}"
  end

  # validate_queue!/1 has already guaranteed a non-empty binary.
  defp put_name(opts, task_queue) do
    if Keyword.has_key?(opts, :name) do
      opts
    else
      Keyword.put(opts, :name, Module.concat(Temporalex.Worker, task_queue))
    end
  end

  # nil when nothing declares a queue; raises only on disagreement — the
  # misrouting bug this derivation exists to catch.
  defp derive_queue!(workflows) do
    declared =
      workflows
      |> Enum.map(fn module ->
        # ensure_loaded?: in dev the modules in a children list are lazily
        # loaded, and an unloaded module fails function_exported?/3 — which
        # would silently fall through to the legacy queue fallback and
        # resurrect the misrouting hang this derivation exists to catch.
        loaded? = Code.ensure_loaded?(module)
        {module, loaded? and function_exported?(module, :__queue__, 0) and module.__queue__()}
      end)
      |> Map.new()

    case declared |> Map.values() |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      # Exactly one declared queue: modules without a declaration ride along.
      [queue] -> queue
      [] -> nil
      _many -> raise_queue_mismatch(declared)
    end
  end

  defp raise_queue_mismatch(declared) do
    listing = Enum.map_join(declared, "\n", fn {m, q} -> "  #{inspect(m)} → #{inspect(q)}" end)

    raise ArgumentError,
          "one worker polls one task queue, but the listed workflows disagree:\n#{listing}\n" <>
            "Split them across workers, or align their `use Temporalex.Workflow, queue:` " <>
            "declarations"
  end

  def server_name(worker_name), do: Module.concat(worker_name, Server)
  def executor_supervisor_name(worker_name), do: Module.concat(worker_name, ExecutorSupervisor)
  def activity_supervisor_name(worker_name), do: Module.concat(worker_name, ActivitySupervisor)

  def server_pid(worker_name) when is_atom(worker_name) do
    worker_name
    |> server_name()
    |> Process.whereis()
  end

  def server_pid(pid) when is_pid(pid), do: pid
end
