defmodule Temporalex.Native do
  @moduledoc false

  use Rustler, otp_app: :temporalex

  def create_runtime, do: :erlang.nif_error(:nif_not_loaded)

  def connect(_runtime, _url, _api_key, _headers, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def start_worker(_runtime, _client, _task_queue, _namespace, _max_wf, _max_act, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def encode_workflow_completion(_completion, _task_queue),
    do: :erlang.nif_error(:nif_not_loaded)

  def encode_activity_completion(_completion),
    do: :erlang.nif_error(:nif_not_loaded)

  def complete_workflow_activation(_worker, _bytes, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def complete_activity_task(_worker, _bytes, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def record_activity_heartbeat(_worker, _task_token, _details_bytes),
    do: :erlang.nif_error(:nif_not_loaded)

  def initiate_shutdown(_worker), do: :erlang.nif_error(:nif_not_loaded)

  def shutdown_worker(_worker, _pid), do: :erlang.nif_error(:nif_not_loaded)

  def start_workflow(
        _client,
        _namespace,
        _workflow_id,
        _workflow_type,
        _task_queue,
        _input,
        _opts,
        _pid,
        _ref
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def get_workflow_result(_client, _namespace, _workflow_id, _run_id, _pid, _ref),
    do: :erlang.nif_error(:nif_not_loaded)

  def signal_workflow(
        _client,
        _namespace,
        _workflow_id,
        _run_id,
        _signal_name,
        _args,
        _opts,
        _pid,
        _ref
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def query_workflow(
        _client,
        _namespace,
        _workflow_id,
        _run_id,
        _query_name,
        _args,
        _opts,
        _pid,
        _ref
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def update_workflow(
        _client,
        _namespace,
        _workflow_id,
        _run_id,
        _update_name,
        _args,
        _opts,
        _pid,
        _ref
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def cancel_workflow(
        _client,
        _namespace,
        _workflow_id,
        _run_id,
        _reason,
        _request_id,
        _pid,
        _ref
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def terminate_workflow(
        _client,
        _namespace,
        _workflow_id,
        _run_id,
        _reason,
        _details,
        _pid,
        _ref
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def describe_workflow(_client, _namespace, _workflow_id, _run_id, _pid, _ref),
    do: :erlang.nif_error(:nif_not_loaded)
end
