defmodule Temporalex.Worker.Replay do
  @moduledoc false

  # Pure functions for the workflow replay log.
  #
  # The log is a list of `{type, seq, result}` tuples sorted by seq. Each
  # entry describes a resolution that Temporal provided in an activation —
  # an activity completion, a timer fire, or a child workflow result. The
  # executor consumes the log head each time the workflow makes a matching
  # blocking call, handing back the cached result without emitting a new
  # command.

  alias Temporalex.Converter

  @type entry :: {:activity | :timer | :child_workflow, non_neg_integer(), term()}
  @type log :: [entry]

  @doc """
  Build the ordered replay log from a list of activation jobs.
  """
  @spec build_log([tuple]) :: log
  def build_log(jobs) do
    jobs
    |> Enum.filter(&resolvable?/1)
    |> Enum.map(&to_entry/1)
    |> Enum.sort_by(fn {_, seq, _} -> seq end)
  end

  @doc """
  Consume the next entry from the log.

  - `{:replay, result, remaining}` — head matched `type` and `seq`.
  - `{:new, log}` — log is empty; caller should treat this as a fresh call.
  - raises — head present but does not match (nondeterminism).
  """
  @spec consume(log, atom, non_neg_integer) ::
          {:replay, term, log} | {:new, log}
  def consume([{type, seq, result} | rest], type, seq), do: {:replay, result, rest}
  def consume([], _type, _seq), do: {:new, []}

  def consume([{other_type, other_seq, _} | _], type, seq) do
    raise Temporalex.NondeterminismError,
      message:
        "Nondeterminism detected: expected #{type} seq=#{seq}, got #{other_type} seq=#{other_seq}"
  end

  # --- private ---

  # Backoff is an intermediate signal for local-activity retries — not a final
  # resolution, so it must not enter the replay log.
  defp resolvable?({:resolve_activity, %{result: {:backoff, _}}}), do: false
  defp resolvable?({:resolve_activity, _}), do: true
  defp resolvable?({:fire_timer, _}), do: true
  defp resolvable?({:resolve_child_workflow_execution, _}), do: true
  defp resolvable?(_), do: false

  defp to_entry({:resolve_activity, %{seq: seq, result: {:completed, payload}}}),
    do: {:activity, seq, Converter.decode(payload)}

  defp to_entry({:resolve_activity, %{seq: seq, result: {:failed, failure}}}),
    do: {:activity, seq, {:error, failure}}

  defp to_entry({:resolve_activity, %{seq: seq, result: {:cancelled, failure}}}),
    do: {:activity, seq, {:error, {:cancelled, failure}}}

  defp to_entry({:fire_timer, %{seq: seq}}),
    do: {:timer, seq, :ok}

  defp to_entry({:resolve_child_workflow_execution, %{seq: seq, result: {:completed, payload}}}),
    do: {:child_workflow, seq, Converter.decode(payload)}

  defp to_entry({:resolve_child_workflow_execution, %{seq: seq, result: {:failed, failure}}}),
    do: {:child_workflow, seq, {:error, failure}}

  defp to_entry({:resolve_child_workflow_execution, %{seq: seq, result: {:cancelled, failure}}}),
    do: {:child_workflow, seq, {:error, {:cancelled, failure}}}
end
