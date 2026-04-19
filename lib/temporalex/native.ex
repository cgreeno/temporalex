defmodule Temporalex.Native do
  @moduledoc false
  use Rustler, otp_app: :temporalex, crate: "temporalex_native"

  # Sync NIFs (run on DirtyCpu scheduler)
  def create_runtime(), do: :erlang.nif_error(:nif_not_loaded)
  def connect_client(_runtime, _url, _api_key, _headers), do: :erlang.nif_error(:nif_not_loaded)

  def create_worker(
        _runtime,
        _client,
        _task_queue,
        _namespace,
        _max_wf_tasks,
        _max_activity_tasks
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  # Worker poll/complete NIFs (async — return :ok, send result to pid)
  def poll_workflow_activation(_worker, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def complete_workflow_activation(_worker, _bytes, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def poll_activity_task(_worker, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def complete_activity_task(_worker, _bytes, _pid), do: :erlang.nif_error(:nif_not_loaded)

  def record_activity_heartbeat(_worker, _task_token, _details_bytes),
    do: :erlang.nif_error(:nif_not_loaded)

  # Worker lifecycle NIFs
  def initiate_shutdown(_worker), do: :erlang.nif_error(:nif_not_loaded)
  def shutdown_worker(_worker, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def validate_worker(_worker, _pid), do: :erlang.nif_error(:nif_not_loaded)

  # Client NIFs (async — return :ok, send result to pid)
  def start_workflow(_client, _request, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def signal_workflow(_client, _request, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def query_workflow(_client, _request, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def cancel_workflow(_client, _request, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def terminate_workflow(_client, _request, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def get_workflow_result(_client, _request, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def describe_workflow(_client, _request, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def list_workflows(_client, _request, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  # Debug NIFs — decode protobuf bytes on Rust side for comparison
  def debug_decode_completion(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  def debug_decode_activity_completion(_bytes), do: :erlang.nif_error(:nif_not_loaded)
end
