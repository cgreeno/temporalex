defmodule Temporalex.Native do
  @moduledoc false
  use Rustler, otp_app: :temporalex, crate: "temporalex_native"

  # --- Sync NIFs ---

  # Returns {:ok, runtime} or {:error, reason}
  def create_runtime, do: :erlang.nif_error(:nif_not_loaded)

  # Returns {:ok, worker} or {:error, reason}
  def start_worker(_runtime, _client, _task_queue, _namespace, _max_cached_workflows, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  # Fire-and-forget heartbeat
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

  # --- Client operations ---
  # Deferred to Phase 3 (start_workflow, signal_workflow, query_workflow, etc.)
  # These use the higher-level Client API, not the Worker-level SDK.
end
