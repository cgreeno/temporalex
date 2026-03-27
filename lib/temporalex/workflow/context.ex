defmodule Temporalex.Workflow.Context do
  @moduledoc """
  Context stored in the process dictionary of a workflow process.

  Holds workflow metadata, replay results map, and accumulated commands.
  """
  require Logger

  defstruct [
    :workflow_id,
    :run_id,
    :workflow_type,
    :task_queue,
    :namespace,
    :attempt,
    :parent_workflow_id,
    :parent_run_id,
    :worker_pid,
    :workflow_module,
    :randomness_seed,
    # Internal: monotonically increasing sequence for commands
    seq: 0,
    # Internal: commands accumulated during this activation (prepend, reverse on flush)
    commands: [],
    # Internal: pre-loaded replay results keyed by seq => result
    replay_results: %{},
    # Internal: pending activity types keyed by seq (for tracking)
    pending_activities: %{},
    # Internal: pending timer durations keyed by seq
    pending_timers: %{},
    # Internal: whether this activation is a replay
    is_replaying: false,
    # Internal: the current "workflow time" from the activation
    current_time: nil
  ]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          run_id: String.t(),
          workflow_type: String.t(),
          task_queue: String.t(),
          namespace: String.t(),
          attempt: non_neg_integer(),
          parent_workflow_id: String.t() | nil,
          parent_run_id: String.t() | nil,
          worker_pid: pid() | nil,
          workflow_module: module() | nil,
          randomness_seed: integer() | nil,
          seq: non_neg_integer(),
          commands: [term()],
          replay_results: map(),
          pending_activities: map(),
          pending_timers: map(),
          is_replaying: boolean(),
          current_time: DateTime.t() | nil
        }

  @doc """
  Build a context from an InitializeWorkflow job and activation metadata.

  Note: task_queue and namespace are NOT in the InitializeWorkflow proto --
  they must be set by the Worker from its own config after calling this.
  """
  @spec from_init(map(), map()) :: t()
  def from_init(init_job, activation) do
    %__MODULE__{
      workflow_id: init_job.workflow_id || "",
      run_id: activation.run_id || "",
      workflow_type: init_job.workflow_type || "",
      task_queue: "",
      namespace: "",
      attempt: init_job.attempt || 1,
      parent_workflow_id: safe_get(init_job, :parent_workflow_info, :workflow_id),
      parent_run_id: safe_get(init_job, :parent_workflow_info, :run_id),
      is_replaying: activation.is_replaying || false,
      current_time: parse_timestamp(activation.timestamp)
    }
  end

  @doc "Allocate the next sequence number and return {seq, updated_ctx}."
  @spec next_seq(t()) :: {non_neg_integer(), t()}
  def next_seq(%__MODULE__{seq: seq} = ctx) do
    {seq, %{ctx | seq: seq + 1}}
  end

  @doc "Prepend a command to the context. Reverse when flushing."
  @spec add_command(t(), term()) :: t()
  def add_command(%__MODULE__{commands: cmds} = ctx, command) do
    %{ctx | commands: [command | cmds]}
  end

  @doc "Return commands in correct order (reverses the prepend list)."
  @spec flush_commands(t()) :: {[term()], t()}
  def flush_commands(%__MODULE__{commands: cmds} = ctx) do
    {Enum.reverse(cmds), %{ctx | commands: []}}
  end

  @doc "Deterministic current time from the activation, NOT system clock."
  @spec now(t()) :: DateTime.t() | nil
  def now(%__MODULE__{current_time: time}), do: time

  @doc "Deterministic random float derived from run_id + seq."
  @spec random(t()) :: {float(), t()}
  def random(%__MODULE__{} = ctx) do
    hash = :erlang.phash2({ctx.run_id, ctx.seq}, 1_000_000)
    value = hash / 1_000_000
    {value, ctx}
  end

  @doc "Deterministic UUID v4 derived from run_id + seq."
  @spec uuid4(t()) :: {String.t(), t()}
  def uuid4(%__MODULE__{} = ctx) do
    hash = :erlang.phash2({ctx.run_id, "uuid", ctx.seq}, 4_294_967_296)
    hex = String.pad_leading(Integer.to_string(hash, 16), 8, "0")

    uuid =
      "#{String.slice(hex, 0, 8)}-0000-4000-8000-#{String.pad_leading(Integer.to_string(ctx.seq, 16), 12, "0")}"

    {uuid, ctx}
  end

  @doc "Whether this activation is replaying history."
  @spec replaying?(t()) :: boolean()
  def replaying?(%__MODULE__{is_replaying: r}), do: r

  # Parse a google.protobuf.Timestamp into DateTime
  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(%{seconds: seconds, nanos: nanos}) do
    case DateTime.from_unix(seconds, :second) do
      {:ok, dt} -> DateTime.add(dt, nanos, :nanosecond)
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  # Safely access nested struct fields
  defp safe_get(struct, field1, field2) do
    case Map.get(struct, field1) do
      nil -> nil
      nested -> Map.get(nested, field2)
    end
  end
end
