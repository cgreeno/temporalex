defmodule Temporalex.Start do
  @moduledoc """
  A workflow start as data.

  Built by a workflow module's generated `new/2`, shaped by the chain steps on
  `Temporalex`, and performed by exactly one terminal verb
  (`Temporalex.start!/1` or `Temporalex.execute!/1`). Until the terminal verb
  runs, nothing has happened — the struct is inspectable, assertable in tests,
  and reusable.

      booking_id
      |> Booking.new()
      |> Temporalex.retry(max_attempts: 3)
      |> Temporalex.fairness(salon_id)
      |> Temporalex.execute!()

  See `docs/rfcs/0002-client-surface.md`.
  """

  @enforce_keys [:workflow, :input, :id, :queue]
  defstruct [:workflow, :input, :id, :queue, :client, :timeout, opts: []]

  @typedoc """
  One workflow start, fully resolved except for execution.

    * `:workflow` — the workflow module
    * `:input` — the durable input, after the module's `input/1`
    * `:id` — the workflow id from `id/1` or `id:`, or the `:generate`
      sentinel, resolved to a fresh id at the terminal verb
    * `:queue` — the task queue
    * `:client` — the client name, or `nil` for the default client
    * `:timeout` — how long a waiter waits; carried onto the handle by `start!`
    * `:opts` — remaining pass-through options (see `@passthrough_opts`)
  """
  @type t :: %__MODULE__{
          workflow: module(),
          input: term(),
          id: String.t() | :generate,
          queue: String.t(),
          client: atom() | nil,
          timeout: pos_integer() | :infinity | nil,
          opts: keyword()
        }

  # Keyword spellings accepted by new/3 and passed through to the low-level
  # start. Each also has a chain step on `Temporalex`. Anything else raises:
  # a misspelled option that silently does nothing is the defect class the
  # surface exists to remove.
  @passthrough_opts [
    :retry_policy,
    :priority,
    :search_attributes,
    :headers,
    :cron_schedule,
    :run_timeout,
    :execution_timeout,
    :id_conflict_policy,
    :id_reuse_policy,
    :start_signal
  ]

  @resolution_opts [:id, :queue, :client, :timeout]

  @doc false
  def __passthrough_opts__, do: @passthrough_opts

  @doc false
  # Called by the generated `new/2` — not intended to be called directly.
  def new(workflow, raw_input, opts) when is_atom(workflow) and is_list(opts) do
    validate_opts!(workflow, opts)

    %__MODULE__{
      workflow: workflow,
      input: durable_input(workflow, raw_input),
      id: resolve_id(workflow, raw_input, Keyword.get(opts, :id)),
      queue: Keyword.get(opts, :queue) || workflow.__queue__(),
      client: Keyword.get(opts, :client) || workflow.__client__(),
      timeout: Keyword.get(opts, :timeout),
      opts: Keyword.take(opts, @passthrough_opts)
    }
  end

  @doc false
  def generate_id do
    "temporalex-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  @doc false
  # The address must resolve through the module's id/1 so callers and
  # signalling systems can never drift apart.
  def resolve_address!(workflow, address) do
    if function_exported?(workflow, :id, 1) do
      resolved_address!(workflow, workflow.id(address))
    else
      raise ArgumentError, missing_id_message(workflow)
    end
  end

  defp resolved_address!(_workflow, id) when is_binary(id), do: id

  defp resolved_address!(workflow, :generate) do
    raise ArgumentError,
          "#{inspect(workflow)}.id/1 returned :generate — a workflow with " <>
            "generated ids cannot be addressed by business key; keep the " <>
            "%Handle{} from start instead"
  end

  # :generate stays a sentinel until the terminal verb, so a reused %Start{}
  # draws a fresh id per start instead of attaching to its first one.
  defp resolve_id(_workflow, _raw_input, id) when is_binary(id), do: id
  defp resolve_id(_workflow, _raw_input, :generate), do: :generate

  defp resolve_id(workflow, raw_input, nil) do
    if function_exported?(workflow, :id, 1) do
      validate_derived_id!(workflow, workflow.id(raw_input))
    else
      raise ArgumentError, missing_id_message(workflow)
    end
  end

  defp validate_derived_id!(_workflow, id) when is_binary(id), do: id
  defp validate_derived_id!(_workflow, :generate), do: :generate

  defp validate_derived_id!(workflow, other) do
    raise ArgumentError,
          "#{inspect(workflow)}.id/1 must return a String.t() or :generate, " <>
            "got: #{inspect(other)}"
  end

  defp durable_input(workflow, raw_input) do
    if function_exported?(workflow, :input, 1) do
      workflow.input(raw_input)
    else
      raw_input
    end
  end

  defp validate_opts!(workflow, opts) do
    case Keyword.keys(opts) -- (@resolution_opts ++ @passthrough_opts) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) #{inspect(unknown)} for #{inspect(workflow)}.new/2 — " <>
                "allowed: #{inspect(@resolution_opts ++ @passthrough_opts)}"
    end
  end

  defp missing_id_message(workflow) do
    "define id/1 on #{inspect(workflow)} or pass id: — the workflow id is " <>
      "Temporal's idempotency key. Derive it from the business primary key " <>
      "(e.g. \"booking-\#{pk}\") so retries attach to the existing execution; " <>
      "return :generate to opt out deliberately"
  end
end
