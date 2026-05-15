defmodule Temporalex.Backend.TemporalCore.Codec do
  @moduledoc false

  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.Completion
  alias Temporalex.Native

  def workflow_completion_to_bytes(%Completion{} = completion, opts) do
    task_queue = Keyword.fetch!(opts, :task_queue)
    Native.encode_workflow_completion(completion, task_queue)
  end

  def activity_completion_to_bytes(%ActivityCompletion{} = completion) do
    Native.encode_activity_completion(completion)
  end
end
