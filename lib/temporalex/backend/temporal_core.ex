defmodule Temporalex.Backend.TemporalCore do
  @moduledoc """
  Temporal Core backend implemented through the Rustler native bridge.

  The server-facing surface remains core structs. Runtime resources, Temporal
  clients, workers, protobuf bytes, and payload conversion stay inside this
  backend and `Temporalex.Native`.
  """

  @behaviour Temporalex.Backend

  alias Temporalex.Backend.TemporalCore.Codec
  alias Temporalex.Backend.TemporalCore.PollerBridge
  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.Completion
  alias Temporalex.Error
  alias Temporalex.Native

  defmodule ClientState do
    @moduledoc false

    defstruct [
      :runtime,
      :client,
      :owner_pid,
      :namespace,
      :task_queue,
      :target,
      :connect_timeout,
      :start_timeout,
      :completion_timeout,
      :shutdown_timeout,
      :workflow_result_timeout,
      payload_codec: :etf
    ]
  end

  defmodule WorkerState do
    @moduledoc false

    defstruct [
      :runtime,
      :client,
      :worker,
      :poller_bridge,
      :owner_pid,
      :namespace,
      :task_queue,
      :start_timeout,
      :shutdown_timeout,
      payload_codec: :etf
    ]
  end

  @default_target "http://127.0.0.1:7233"
  @default_namespace "default"
  @default_task_queue "default"
  # Reported to the server for identification only — worker versioning is not
  # enabled, so this does not affect task routing. It lands on every
  # WorkflowTaskCompleted event, which is what makes "which release ran this
  # task?" answerable from history. Override with `:build_id` to stamp a
  # release SHA instead.
  @default_build_id "temporalex-#{Mix.Project.config()[:version]}"
  @default_connect_timeout 10_000
  @default_start_timeout 10_000
  @default_completion_timeout 10_000
  @default_shutdown_timeout 10_000
  @default_workflow_result_timeout 60_000

  defp payload_codec_from_opts(opts) do
    case Keyword.get(opts, :payload_codec, :etf) do
      :etf ->
        :etf

      :json ->
        :json

      other ->
        raise ArgumentError, "invalid :payload_codec #{inspect(other)}; expected :etf or :json"
    end
  end

  @impl Temporalex.Backend
  def start_client(opts, owner_pid) when is_list(opts) and is_pid(owner_pid) do
    target = target(opts)
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    task_queue = Keyword.get(opts, :task_queue, @default_task_queue)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)

    with {:ok, runtime} <- Native.create_runtime(telemetry_opts(opts)),
         :ok <-
           Native.connect(runtime, target, Keyword.get(opts, :api_key), headers(opts), owner_pid),
         {:ok, client} <- await_connection(connect_timeout) do
      {:ok,
       %ClientState{
         runtime: runtime,
         client: client,
         owner_pid: owner_pid,
         namespace: namespace,
         task_queue: task_queue,
         target: target,
         connect_timeout: connect_timeout,
         start_timeout: Keyword.get(opts, :start_timeout, @default_start_timeout),
         completion_timeout: Keyword.get(opts, :completion_timeout, @default_completion_timeout),
         shutdown_timeout: Keyword.get(opts, :shutdown_timeout, @default_shutdown_timeout),
         workflow_result_timeout:
           Keyword.get(opts, :workflow_result_timeout, @default_workflow_result_timeout),
         payload_codec: payload_codec_from_opts(opts)
       }}
    else
      {:error, reason} ->
        {:error, Error.normalize_client_reason(reason, operation: :connect_client)}
    end
  end

  @impl Temporalex.Backend
  def shutdown_client(%ClientState{}), do: :ok

  @impl Temporalex.Backend
  def start_worker(%ClientState{} = client_state, opts, owner_pid)
      when is_list(opts) and is_pid(owner_pid) do
    task_queue = Keyword.get(opts, :task_queue, client_state.task_queue)
    start_timeout = Keyword.get(opts, :start_timeout, @default_start_timeout)

    {:ok, poller_bridge} = PollerBridge.start(owner_pid)

    result =
      with :ok <-
             Native.start_worker(
               client_state.runtime,
               client_state.client,
               task_queue,
               client_state.namespace,
               Keyword.get(opts, :build_id, @default_build_id),
               workflow_poller_count(opts),
               activity_poller_count(opts),
               owner_pid,
               poller_bridge
             ),
           {:ok, worker} <- await_worker(start_timeout) do
        {:ok,
         %WorkerState{
           runtime: client_state.runtime,
           client: client_state.client,
           worker: worker,
           poller_bridge: poller_bridge,
           owner_pid: owner_pid,
           namespace: client_state.namespace,
           task_queue: task_queue,
           start_timeout: start_timeout,
           shutdown_timeout: Keyword.get(opts, :shutdown_timeout, @default_shutdown_timeout),
           payload_codec: client_state.payload_codec
         }}
      else
        {:error, reason} ->
          {:error, Error.normalize_client_reason(reason, operation: :start_worker)}
      end

    if match?({:error, _reason}, result) do
      send(poller_bridge, :stop)
    end

    result
  end

  @impl Temporalex.Backend
  def complete_workflow_activation(%WorkerState{} = state, %Completion{} = completion) do
    with {:ok, bytes} <-
           Codec.workflow_completion_to_bytes(completion,
             task_queue: state.task_queue,
             payload_codec: state.payload_codec
           ) do
      Native.complete_workflow_activation(state.worker, bytes, state.owner_pid)
    end
  end

  @impl Temporalex.Backend
  def complete_activity_task(%WorkerState{} = state, %ActivityCompletion{} = completion) do
    with {:ok, bytes} <-
           Codec.activity_completion_to_bytes(completion, payload_codec: state.payload_codec) do
      Native.complete_activity_task(state.worker, bytes, state.owner_pid)
    end
  end

  @impl Temporalex.Backend
  def record_activity_heartbeat(%WorkerState{} = state, task_token, details)
      when is_binary(task_token) do
    with {:ok, bytes} <- Codec.activity_heartbeat_to_bytes(task_token, details) do
      Native.record_activity_heartbeat(state.worker, bytes)
    end
  end

  @impl Temporalex.Backend
  def shutdown_worker(%WorkerState{} = state) do
    Native.initiate_shutdown(state.worker)

    try do
      case Native.shutdown_worker(state.worker, self()) do
        :ok ->
          case await_shutdown(state.shutdown_timeout) do
            :ok ->
              :ok

            {:error, reason} ->
              {:error, Error.normalize_client_reason(reason, operation: :shutdown_worker)}
          end

        {:error, reason} ->
          {:error, Error.normalize_client_reason(reason, operation: :shutdown_worker)}
      end
    after
      if is_pid(state.poller_bridge) do
        send(state.poller_bridge, :stop)
      end
    end
  end

  @impl Temporalex.Backend
  def start_workflow(%ClientState{} = state, workflow_type, input, opts)
      when is_binary(workflow_type) and is_list(opts) do
    workflow_id = Keyword.get_lazy(opts, :workflow_id, fn -> Keyword.get(opts, :id) end)

    workflow_id =
      workflow_id ||
        "temporalex-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    task_queue = Keyword.get(opts, :task_queue, state.task_queue)
    timeout = Keyword.get(opts, :timeout, state.start_timeout)
    ref = make_ref()

    with :ok <-
           Native.start_workflow(
             state.client,
             state.namespace,
             workflow_id,
             workflow_type,
             task_queue,
             input,
             native_start_opts(opts),
             self(),
             ref
           ) do
      await_ref(:workflow_started, ref, timeout, client_monitor(opts))
    end
  end

  @impl Temporalex.Backend
  def get_workflow_result(%ClientState{} = state, workflow_id, run_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, state.workflow_result_timeout)
    ref = make_ref()

    with :ok <-
           Native.get_workflow_result(
             state.client,
             state.namespace,
             workflow_id,
             empty_to_nil(run_id),
             self(),
             ref
           ) do
      await_ref(:workflow_result, ref, timeout, client_monitor(opts))
    end
  end

  @impl Temporalex.Backend
  def signal_workflow(%ClientState{} = state, workflow_id, run_id, signal_name, args, opts)
      when is_binary(workflow_id) and is_binary(signal_name) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, state.completion_timeout)
    ref = make_ref()

    with :ok <-
           Native.signal_workflow(
             state.client,
             state.namespace,
             workflow_id,
             empty_to_nil(run_id),
             signal_name,
             List.wrap(args),
             native_headers_opts(opts),
             self(),
             ref
           ) do
      await_ok_ref(:workflow_signalled, ref, timeout, client_monitor(opts))
    end
  end

  @impl Temporalex.Backend
  def query_workflow(%ClientState{} = state, workflow_id, run_id, query_name, args, opts)
      when is_binary(workflow_id) and is_binary(query_name) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, state.completion_timeout)
    ref = make_ref()

    with :ok <-
           Native.query_workflow(
             state.client,
             state.namespace,
             workflow_id,
             empty_to_nil(run_id),
             query_name,
             List.wrap(args),
             native_headers_opts(opts),
             self(),
             ref
           ) do
      await_ref(:workflow_queried, ref, timeout, client_monitor(opts))
    end
  end

  @impl Temporalex.Backend
  def update_workflow(%ClientState{} = state, workflow_id, run_id, update_name, args, opts)
      when is_binary(workflow_id) and is_binary(update_name) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, state.workflow_result_timeout)
    ref = make_ref()

    with :ok <-
           Native.update_workflow(
             state.client,
             state.namespace,
             workflow_id,
             empty_to_nil(run_id),
             update_name,
             List.wrap(args),
             native_headers_opts(opts),
             self(),
             ref
           ) do
      await_ref(:workflow_updated, ref, timeout, client_monitor(opts))
    end
  end

  @impl Temporalex.Backend
  def cancel_workflow(%ClientState{} = state, workflow_id, run_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, state.completion_timeout)
    ref = make_ref()

    with :ok <-
           Native.cancel_workflow(
             state.client,
             state.namespace,
             workflow_id,
             empty_to_nil(run_id),
             to_string(Keyword.get(opts, :reason, "")),
             Keyword.get(opts, :request_id),
             self(),
             ref
           ) do
      await_ok_ref(:workflow_cancelled, ref, timeout, client_monitor(opts))
    end
  end

  @impl Temporalex.Backend
  def terminate_workflow(%ClientState{} = state, workflow_id, run_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, state.completion_timeout)
    ref = make_ref()

    with :ok <-
           Native.terminate_workflow(
             state.client,
             state.namespace,
             workflow_id,
             empty_to_nil(run_id),
             to_string(Keyword.get(opts, :reason, "")),
             Keyword.get(opts, :details),
             self(),
             ref
           ) do
      await_ok_ref(:workflow_terminated, ref, timeout, client_monitor(opts))
    end
  end

  @impl Temporalex.Backend
  def describe_workflow(%ClientState{} = state, workflow_id, run_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, state.completion_timeout)
    ref = make_ref()

    with :ok <-
           Native.describe_workflow(
             state.client,
             state.namespace,
             workflow_id,
             empty_to_nil(run_id),
             self(),
             ref
           ) do
      await_ref(:workflow_described, ref, timeout, client_monitor(opts))
    end
  end

  # Histories can be large and paginate server-side, so this borrows the
  # (longer) workflow-result timeout rather than the completion timeout.
  @impl Temporalex.Backend
  def fetch_workflow_history(%ClientState{} = state, workflow_id, run_id, opts)
      when is_binary(workflow_id) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, state.workflow_result_timeout)
    ref = make_ref()

    with :ok <-
           Native.fetch_workflow_history(
             state.client,
             state.namespace,
             workflow_id,
             empty_to_nil(run_id),
             self(),
             ref
           ) do
      await_ref(:workflow_history_fetched, ref, timeout, client_monitor(opts))
    end
  end

  defp target(opts) do
    Keyword.get(opts, :target) ||
      Keyword.get(opts, :url) ||
      Keyword.get(opts, :address) ||
      @default_target
  end

  # Metrics are opt-in: without `:prometheus` or `:otlp` the runtime starts with
  # telemetry off, exactly as before. Core decodes tags and headers as string
  # maps, so normalise them before they cross the NIF boundary.
  defp telemetry_opts(opts) do
    opts
    |> Keyword.get(:telemetry, [])
    |> Keyword.replace_lazy(:global_tags, &normalize_headers/1)
    |> Keyword.replace_lazy(:otlp, &normalize_otlp/1)
  end

  defp normalize_otlp(otlp), do: Keyword.replace_lazy(otlp, :headers, &normalize_headers/1)

  defp headers(opts) do
    opts
    |> Keyword.get(:headers, %{})
    |> normalize_headers()
  end

  defp normalize_headers(nil), do: %{}

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp native_start_opts(opts) do
    opts
    |> Keyword.take([
      :headers,
      :execution_timeout,
      :workflow_execution_timeout,
      :run_timeout,
      :workflow_run_timeout,
      :task_timeout,
      :workflow_task_timeout,
      :cron_schedule,
      :search_attributes,
      :retry_policy,
      :id_reuse_policy,
      :workflow_id_reuse_policy,
      :id_conflict_policy,
      :workflow_id_conflict_policy,
      :static_summary,
      :static_details
    ])
    |> normalize_native_opts()
  end

  defp native_headers_opts(opts) do
    opts
    |> Keyword.take([
      :headers,
      :request_id,
      :update_id,
      :query_reject_condition,
      :reject_condition
    ])
    |> normalize_native_opts()
  end

  defp client_monitor(opts) do
    Keyword.get(opts, :client_monitor)
  end

  defp normalize_native_opts(opts) do
    opts
    |> Keyword.update(:headers, %{}, &normalize_header_payload_keys/1)
    |> Keyword.update(:search_attributes, nil, &normalize_header_payload_keys/1)
  end

  defp normalize_header_payload_keys(nil), do: %{}

  defp normalize_header_payload_keys(headers) do
    Map.new(headers, fn {key, value} -> {to_string(key), value} end)
  end

  defp workflow_poller_count(opts) do
    Keyword.get(opts, :max_wf) ||
      Keyword.get(opts, :max_workflow_pollers) ||
      Keyword.get(opts, :max_concurrent_workflow_polls) ||
      5
  end

  defp activity_poller_count(opts) do
    Keyword.get(opts, :max_act) ||
      Keyword.get(opts, :max_activity_pollers) ||
      Keyword.get(opts, :max_concurrent_activity_polls) ||
      5
  end

  defp await_connection(timeout) do
    receive do
      {:connected, client} -> {:ok, client}
      {:connect_error, reason} -> {:error, {:connect_error, reason}}
    after
      timeout -> {:error, {:connect_timeout, timeout}}
    end
  end

  defp await_worker(timeout) do
    receive do
      {:worker_started, worker} ->
        # Bind the worker's lifetime to THIS process (the owning server):
        # the monitor must be attached from a real NIF call — the native
        # side cannot attach it from its own async task (see monitor_worker
        # in the NIF). Without this, a violently killed worker never
        # releases its task-queue registration.
        :ok = Native.monitor_worker(worker)
        {:ok, worker}

      {:worker_error, reason} ->
        {:error, {:worker_error, reason}}
    after
      timeout -> {:error, {:worker_start_timeout, timeout}}
    end
  end

  defp await_shutdown(timeout) do
    receive do
      {:shutdown_complete, :ok} -> :ok
      {:shutdown_complete, {:error, reason}} -> {:error, {:shutdown_error, reason}}
    after
      timeout -> {:error, {:shutdown_timeout, timeout}}
    end
  end

  defp await_ref(tag, ref, timeout, client_monitor)

  defp await_ref(tag, ref, timeout, nil) do
    receive do
      {^tag, ^ref, {:ok, result}} -> {:ok, result}
      {^tag, ^ref, {:error, reason}} -> {:error, reason}
    after
      timeout -> {:error, {tag, :timeout, timeout}}
    end
  end

  defp await_ref(tag, ref, timeout, {client_pid, client_ref}) do
    receive do
      {^tag, ^ref, {:ok, result}} -> {:ok, result}
      {^tag, ^ref, {:error, reason}} -> {:error, reason}
      {:DOWN, ^client_ref, :process, ^client_pid, reason} -> {:error, {:client_down, reason}}
    after
      timeout -> {:error, {tag, :timeout, timeout}}
    end
  end

  defp await_ok_ref(tag, ref, timeout, client_monitor) do
    case await_ref(tag, ref, timeout, client_monitor) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
