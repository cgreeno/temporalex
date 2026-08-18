defmodule Temporalex.History do
  @moduledoc """
  A workflow's event history, parsed.

  Returned by `Temporalex.Client.fetch_workflow_history/2`. Events carry
  Temporal's full record of one execution: every start, schedule, completion,
  failure, signal, and timer, in order.

      {:ok, history} = Temporalex.Client.fetch_workflow_history(handle)

      history.events
      #=> [%Temporalex.History.Event{id: 1, type: :workflow_execution_started, ...}, ...]

      Temporalex.History.stuck_reason(history)
      #=> %{message: "replay command mismatch...", cause: ..., event_id: 17}

  `stuck_reason/1` answers the operational question directly: a workflow
  sitting Running with a retrying workflow task records each failed attempt
  as a `:workflow_task_failed` event — nondeterminism after a bad deploy
  being the classic cause — and this surfaces the latest one without the
  `temporal` CLI or the Web UI.

  Event `attributes` are the transport-shaped maps of the corresponding
  Temporal event-attributes message (payload fields stay encoded); the
  `type` is the event's kind as a readable atom, e.g.
  `:activity_task_scheduled`.
  """

  defstruct [:workflow_id, :run_id, events: []]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          run_id: String.t() | nil,
          events: [__MODULE__.Event.t()]
        }

  defmodule Event do
    @moduledoc "One history event: id, server timestamp, kind, and attributes."

    defstruct [:id, :time, :type, :attributes]

    @type t :: %__MODULE__{
            id: non_neg_integer(),
            time: DateTime.t() | nil,
            type: atom(),
            attributes: map() | nil
          }
  end

  @doc "All events of one type, in order."
  @spec events(t(), atom()) :: [Event.t()]
  def events(%__MODULE__{events: events}, type) when is_atom(type),
    do: Enum.filter(events, &(&1.type == type))

  @doc "The last event of one type, or nil."
  @spec last(t(), atom()) :: Event.t() | nil
  def last(%__MODULE__{events: events}, type) when is_atom(type),
    do: events |> Enum.reverse() |> Enum.find(&(&1.type == type))

  @doc """
  Why the workflow is stuck — the latest failed workflow task's failure.

  Returns nil when no workflow task has failed. A non-nil reason on a
  Running workflow means the server is retrying a task the worker cannot
  complete: nondeterminism after a code change is the classic cause, and
  `message` carries the worker's own report of it.
  """
  @spec stuck_reason(t()) :: %{message: String.t() | nil, cause: term(), event_id: term()} | nil
  def stuck_reason(%__MODULE__{} = history) do
    case last(history, :workflow_task_failed) do
      nil ->
        nil

      %Event{id: id, attributes: attributes} ->
        %{
          message: get_in(attributes, [:failure, :message]),
          cause: Map.get(attributes || %{}, :cause),
          event_id: id
        }
    end
  end
end
