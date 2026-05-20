defmodule Temporalex.Backend.TemporalCore.Codec do
  @moduledoc false

  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.Completion
  alias Temporalex.Native

  def workflow_completion_to_bytes(%Completion{} = completion, opts) do
    task_queue = Keyword.fetch!(opts, :task_queue)
    codec = Keyword.get(opts, :payload_codec, :etf)
    Native.encode_workflow_completion(completion, task_queue, codec)
  end

  def activity_completion_to_bytes(%ActivityCompletion{} = completion, opts \\ []) do
    codec = Keyword.get(opts, :payload_codec, :etf)
    Native.encode_activity_completion(completion, codec)
  end
end
