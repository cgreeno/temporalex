defmodule Temporalex.Native do
  @moduledoc false

  # Consumers download a precompiled NIF from the GitHub release matching
  # this version — no Rust toolchain or protoc needed. Building from source
  # instead:
  #   * in this repo, always (Mix.env() is :dev/:test here and :prod when
  #     compiled as a dependency), or
  #   * anywhere, with TEMPORALEX_BUILD=1.
  # crate/path defaults live HERE (not only in config/config.exs) because a
  # dependency's config files are never evaluated by consumers.
  # force_build: is only PASSED when true — an always-present key (even
  # false) would defeat rustler_precompiled's Keyword.put_new fallback to
  # `config :rustler_precompiled, force_build: [temporalex: true]`, which is
  # the remedy its own download-failure message tells consumers to use.
  @force_build System.get_env("TEMPORALEX_BUILD") in ["1", "true"] or
                 Mix.env() in [:dev, :test]

  @precompiled_opts [
                      otp_app: :temporalex,
                      crate: "temporalex_nif",
                      path: "native/temporalex_nif",
                      base_url:
                        "https://github.com/cgreeno/temporalex/releases/download/v#{Mix.Project.config()[:version]}",
                      version: Mix.Project.config()[:version],
                      nif_versions: ["2.15"],
                      targets: ~w(
                        aarch64-apple-darwin
                        x86_64-apple-darwin
                        aarch64-unknown-linux-gnu
                        x86_64-unknown-linux-gnu
                        aarch64-unknown-linux-musl
                        x86_64-unknown-linux-musl
                      )
                    ] ++ if(@force_build, do: [force_build: true], else: [])

  use RustlerPrecompiled, @precompiled_opts

  def create_runtime(_telemetry_opts), do: :erlang.nif_error(:nif_not_loaded)

  def connect(_runtime, _url, _api_key, _headers, _pid),
    do: :erlang.nif_error(:nif_not_loaded)

  def start_worker(
        _runtime,
        _client,
        _task_queue,
        _namespace,
        _versioning,
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

  def monitor_worker(_worker), do: :erlang.nif_error(:nif_not_loaded)

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

  def fetch_workflow_history(_client, _namespace, _workflow_id, _run_id, _pid, _ref),
    do: :erlang.nif_error(:nif_not_loaded)
end
