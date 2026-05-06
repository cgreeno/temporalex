defmodule Temporalex.Native do
  @moduledoc false
  use Rustler, otp_app: :temporalex, crate: "temporalex_native"

  # --- Sync NIFs ---

  # Returns {:ok, runtime} or {:error, reason}
  def create_runtime, do: :erlang.nif_error(:nif_not_loaded)

  # Returns {:ok, worker} or {:error, reason}
  def start_worker(_runtime, _client, _task_queue, _namespace, _max_cached_workflows, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  # Fire-and-forget heartbeat. `details` is a payload map
  # `%{metadata: ..., data: ...}` (from `Temporalex.Converter.encode/1`) or `nil`.
  def record_activity_heartbeat(_worker, _task_token, _details),
    do: :erlang.nif_error(:nif_not_loaded)

  # Non-blocking shutdown signal
  def initiate_shutdown(_worker), do: :erlang.nif_error(:nif_not_loaded)

  # --- Async NIFs (return :ok, send result to pid) ---

  # Sends {:connected, client} or {:connect_error, reason}
  def connect(_runtime, _url, _api_key, _headers, _pid), do: :erlang.nif_error(:nif_not_loaded)

  # Sends {:workflow_completion, :ok | {:error, msg}}
  def complete_workflow_activation(_worker, _bytes, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  # Sends {:activity_completion, :ok | {:error, msg}}
  def complete_activity_task(_worker, _bytes, _pid), do: :erlang.nif_error(:nif_not_loaded)

  # Sends {:shutdown_complete, :ok}
  def shutdown_worker(_worker, _pid), do: :erlang.nif_error(:nif_not_loaded)

  # --- Proto bridge (sync, DirtyCpu) ---

  # Decodes WorkflowActivation protobuf → {:ok, %{run_id, is_replaying, jobs}}
  def decode_workflow_activation(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  # Decodes ActivityTask protobuf → {:ok, %{task_token, variant}}
  def decode_activity_task(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  # Encodes workflow completion → {:ok, protobuf_bytes}
  def encode_workflow_completion(_run_id, _status), do: :erlang.nif_error(:nif_not_loaded)

  # Encodes activity result → {:ok, protobuf_bytes}
  def encode_activity_result(_task_token, _result), do: :erlang.nif_error(:nif_not_loaded)

  # --- Client operations (async, send result to pid) ---

  def start_workflow(
        _client,
        _ns,
        _wf_id,
        _wf_type,
        _tq,
        _input,
        _req_id,
        _execution_timeout_ms,
        _run_timeout_ms,
        _task_timeout_ms,
        _pid
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def signal_workflow(_client, _ns, _wf_id, _run_id, _signal, _input, _req_id, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def query_workflow(_client, _ns, _wf_id, _run_id, _query_type, _args, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def cancel_workflow(_client, _ns, _wf_id, _run_id, _reason, _req_id, _pid),
    do: :erlang.nif_error(:nif_not_loaded)
end
