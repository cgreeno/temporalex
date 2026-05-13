defmodule Temporalex.Core.Activation do
  @moduledoc """
  Core workflow activation delivered to an executor.
  """

  defstruct run_id: nil,
            timestamp: nil,
            is_replaying: false,
            history_length: 0,
            history_size_bytes: nil,
            continue_as_new_suggested: false,
            available_internal_flags: [],
            deployment_version: nil,
            jobs: []
end

defmodule Temporalex.Core.Completion do
  @moduledoc """
  Status-bearing completion for one workflow activation.
  """

  defstruct run_id: nil, status: {:ok, []}
end

defmodule Temporalex.Core.Nondeterminism do
  @moduledoc """
  Activation failure raised when emitted command decisions diverge from replay history.
  """

  defexception [:message, :expected, :actual]

  @impl Exception
  def exception(opts) do
    expected = Keyword.get(opts, :expected)
    actual = Keyword.get(opts, :actual)

    reason =
      Keyword.get(opts, :message, "workflow command decisions diverged from replay history")

    %__MODULE__{message: reason, expected: expected, actual: actual}
  end
end

defmodule Temporalex.Core.SchedulerViolation do
  @moduledoc """
  Activation failure raised when a workflow process calls the executor outside its turn.
  """

  defexception [:message, :thread_id, :running]

  @impl Exception
  def exception(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    running = Keyword.get(opts, :running)

    %__MODULE__{
      message:
        "workflow thread #{inspect(thread_id)} called executor while #{inspect(running)} was running",
      thread_id: thread_id,
      running: running
    }
  end
end

defmodule Temporalex.Core.Context do
  @moduledoc false
  defstruct [:executor, :thread_id, :phase_id, :handler_mode]
end

defmodule Temporalex.Core.Thread do
  @moduledoc false

  defstruct id: [],
            pid: nil,
            status: :ready,
            kind: :root,
            parent_scope: nil,
            index: nil,
            result: nil,
            error: nil,
            resume: nil,
            phase_id: nil,
            update_protocol_instance_id: nil,
            signal?: false,
            started?: false
end

defmodule Temporalex.Core.Pending do
  @moduledoc false

  defstruct [:seq, :thread_id, :from, :op]
end

defmodule Temporalex.Core.ParallelScope do
  @moduledoc false

  defstruct [:id, :parent_thread_id, :from, :size, results: %{}, remaining: 0]
end

defmodule Temporalex.Core.Phase do
  @moduledoc false

  defstruct [
    :id,
    :owner_thread_id,
    :from,
    :timeout_ms,
    :timeout_seq,
    state: nil,
    signal_handlers: %{},
    update_handlers: %{},
    queue: :queue.new(),
    active_dispatch: nil,
    async_threads: MapSet.new(),
    dispatch_counter: 0,
    stopping?: false,
    result: nil,
    timeout_fired?: false,
    timer_cancelled?: false
  ]
end

defmodule Temporalex.Core.Job.InitializeWorkflow do
  @moduledoc false
  defstruct workflow_type: nil,
            workflow_id: nil,
            arguments: [],
            headers: %{},
            workflow_info: %{},
            randomness_seed: 0
end

defmodule Temporalex.Core.Job.UpdateRandomSeed do
  @moduledoc false
  defstruct randomness_seed: 0
end

defmodule Temporalex.Core.Job.ActivityResolved do
  @moduledoc false
  defstruct [:seq, :result]
end

defmodule Temporalex.Core.Job.TimerFired do
  @moduledoc false
  defstruct [:seq]
end

defmodule Temporalex.Core.Job.SignalReceived do
  @moduledoc false
  defstruct name: nil, args: [], headers: %{}, identity: nil
end

defmodule Temporalex.Core.Job.UpdateReceived do
  @moduledoc false
  defstruct id: nil,
            protocol_instance_id: nil,
            name: nil,
            args: [],
            headers: %{},
            meta: nil,
            run_validator: true
end

defmodule Temporalex.Core.Job.QueryReceived do
  @moduledoc false
  defstruct query_id: nil, query_type: nil, args: [], headers: %{}
end

defmodule Temporalex.Core.Job.CancelWorkflow do
  @moduledoc false
  defstruct [:reason]
end

defmodule Temporalex.Core.Job.NotifyPatch do
  @moduledoc false
  defstruct [:id]
end

defmodule Temporalex.Core.Job.RemoveFromCache do
  @moduledoc false
  defstruct reason: nil, message: nil
end

defmodule Temporalex.Core.Command.ScheduleActivity do
  @moduledoc false
  defstruct [:seq, :thread_id, :activity_id, :type, input: [], opts: []]
end

defmodule Temporalex.Core.Command.StartTimer do
  @moduledoc false
  defstruct [:seq, :thread_id, :duration_ms]
end

defmodule Temporalex.Core.Command.CancelTimer do
  @moduledoc false
  defstruct [:seq]
end

defmodule Temporalex.Core.Command.SetPatchMarker do
  @moduledoc false
  defstruct [:id, deprecated: false]
end

defmodule Temporalex.Core.Command.CompleteWorkflow do
  @moduledoc false
  defstruct [:result]
end

defmodule Temporalex.Core.Command.FailWorkflow do
  @moduledoc false
  defstruct [:reason]
end

defmodule Temporalex.Core.Command.ContinueAsNew do
  @moduledoc false
  defstruct [:args, :workflow_type, :task_queue]
end

defmodule Temporalex.Core.Command.CancelWorkflow do
  @moduledoc false
  defstruct []
end

defmodule Temporalex.Core.Command.RespondToUpdate do
  @moduledoc false
  defstruct [:protocol_instance_id, :response]
end

defmodule Temporalex.Core.Command.RespondToQuery do
  @moduledoc false
  defstruct [:query_id, :result]
end

defmodule Temporalex.Core.Command.UpsertSearchAttributes do
  @moduledoc false
  defstruct attrs: %{}
end

defmodule Temporalex.Core.ActivityTask do
  @moduledoc """
  Server-facing activity task decoded by a backend.
  """

  defstruct task_token: nil,
            activity_id: nil,
            activity_type: nil,
            workflow_id: nil,
            run_id: nil,
            workflow_type: nil,
            namespace: nil,
            task_queue: nil,
            input: [],
            attempt: 1,
            heartbeat_timeout: nil,
            is_local: false,
            headers: %{},
            variant: :start,
            cancel_reason: nil
end

defmodule Temporalex.Core.ActivityCompletion do
  @moduledoc """
  Server-facing activity completion submitted through a backend.
  """

  defstruct task_token: nil, result: nil
end

defmodule Temporalex.Core.Op.ExecuteActivity do
  @moduledoc false
  defstruct [:type, input: [], opts: []]
end

defmodule Temporalex.Core.Op.Sleep do
  @moduledoc false
  defstruct [:duration_ms]
end

defmodule Temporalex.Core.Op.WaitForSignal do
  @moduledoc false
  defstruct [:name]
end

defmodule Temporalex.Core.Op.PublishState do
  @moduledoc false
  defstruct [:state]
end

defmodule Temporalex.Core.Op.WorkflowInfo do
  @moduledoc false
  defstruct []
end

defmodule Temporalex.Core.Op.Cancelled do
  @moduledoc false
  defstruct []
end

defmodule Temporalex.Core.Op.Now do
  @moduledoc false
  defstruct []
end

defmodule Temporalex.Core.Op.Random do
  @moduledoc false
  defstruct []
end

defmodule Temporalex.Core.Op.UUID4 do
  @moduledoc false
  defstruct []
end

defmodule Temporalex.Core.Op.Patched do
  @moduledoc false
  defstruct [:id]
end

defmodule Temporalex.Core.Op.DeprecatePatch do
  @moduledoc false
  defstruct [:id]
end

defmodule Temporalex.Core.Op.UpsertSearchAttributes do
  @moduledoc false
  defstruct attrs: %{}
end

defmodule Temporalex.Core.Op.Parallel do
  @moduledoc false
  defstruct funs: []
end

defmodule Temporalex.Core.Op.Phase do
  @moduledoc false
  defstruct [:initial_state, opts: []]
end

defmodule Temporalex.Core.Op.UpdateState do
  @moduledoc false
  defstruct [:fun]
end
