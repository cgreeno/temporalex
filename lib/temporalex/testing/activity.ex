defmodule Temporalex.Testing.Activity do
  @moduledoc """
  Testing handle for a scheduled activity command.

  Activity handles are returned by `Temporalex.Testing.assert_next_activity/2`
  and must be used to complete or fail that exact scheduled activity.
  """

  defstruct [
    :run,
    :ref,
    :seq,
    :thread_id,
    :activity_id,
    :type,
    :task_queue,
    input: [],
    headers: %{},
    schedule_to_close_timeout_ms: nil,
    schedule_to_start_timeout_ms: nil,
    start_to_close_timeout_ms: nil,
    heartbeat_timeout_ms: nil,
    retry_policy: nil,
    cancellation_type: nil,
    do_not_eagerly_execute: false
  ]
end
