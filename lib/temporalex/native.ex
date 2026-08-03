defmodule Temporalex.Native do
  @moduledoc false

  # crate/path defaults live HERE (not only in config/config.exs) because a
  # dependency's config files are never evaluated by consumers — without
  # these options the Hex package fails to compile with
  # "Could not cd to native/temporalex". App-env config still overrides
  # (config/config.exs sets :mode per env for this repo's own builds).
  use Rustler, otp_app: :temporalex, crate: :temporalex_nif, path: "native/temporalex_nif"

  def create_runtime(_telemetry_opts), do: :erlang.nif_error(:nif_not_loaded)

  def connect(_runtime, _url, _api_key, _headers, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def start_worker(
        _runtime,
        _client,
        _task_queue,
        _namespace,
        _build_id,
        _max_wf,
        _max_act,
        _pid,
        _poll_pid
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def complete_workflow_activation(_worker, _bytes, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def complete_activity_task(_worker, _bytes, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def record_activity_heartbeat(_worker, _bytes),
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
