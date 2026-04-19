use prost::Message;
use rustler::{Atom, Encoder, Env, LocalPid, NewBinary, OwnedEnv, Resource, ResourceArc};
use std::panic::{AssertUnwindSafe, RefUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use temporalio_client::tonic::Request;
use temporalio_client::Connection;
use temporalio_client::ConnectionOptions;
use temporalio_common::protos::temporal::api::{
    common::v1::{Payloads, WorkflowExecution, WorkflowType},
    enums::v1::{EventType, HistoryEventFilterType},
    history::v1::{history_event::Attributes, HistoryEvent},
    query::v1::WorkflowQuery,
    taskqueue::v1::TaskQueue,
    workflowservice::v1::{
        DescribeWorkflowExecutionRequest, GetWorkflowExecutionHistoryRequest,
        ListWorkflowExecutionsRequest, QueryWorkflowRequest, RequestCancelWorkflowExecutionRequest,
        SignalWorkflowExecutionRequest, StartWorkflowExecutionRequest,
        TerminateWorkflowExecutionRequest,
    },
};
use temporalio_common::worker::WorkerTaskTypes;
use temporalio_sdk_core::{init_worker, CoreRuntime, Worker};
use tokio::time::{timeout, Duration};
use tracing::{debug, error, info, warn};
use url::Url;

// Timeout durations for async NIF operations
const COMPLETION_TIMEOUT: Duration = Duration::from_secs(60);
const CLIENT_OP_TIMEOUT: Duration = Duration::from_secs(30);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(30);
const VALIDATE_TIMEOUT: Duration = Duration::from_secs(10);

type StartWorkflowRequest<'a> = (
    String,
    String,
    String,
    String,
    rustler::Binary<'a>,
    String,
    i64,
);
type SignalWorkflowRequest<'a> = (
    String,
    String,
    String,
    String,
    rustler::Binary<'a>,
    String,
    i64,
);
type QueryWorkflowNifRequest<'a> = (String, String, String, String, rustler::Binary<'a>, i64);
type CancelWorkflowRequest = (String, String, String, String, String, i64);
type TerminateWorkflowRequest = (String, String, String, String, i64);
type WorkflowResultRequest = (String, String, String, i64);
type DescribeWorkflowRequest = (String, String, String, i64);
type ListWorkflowsRequest = (String, String, i32, i64);

// --- Atoms ---

mod atoms {
    rustler::atoms! {
        ok,
        error,
        workflow_activation,
        workflow_completion,
        activity_task,
        activity_completion,
        shutdown,
        // Worker lifecycle atoms
        shutdown_complete,
        validate_result,
        // Client operation result atoms
        start_workflow_result,
        signal_workflow_result,
        query_workflow_result,
        cancel_workflow_result,
        terminate_workflow_result,
        get_result_result,
        describe_workflow_result,
        list_workflows_result,
    }
}

// --- Resource types (opaque handles passed to/from Elixir) ---
// These contain Tokio/gRPC internals with UnsafeCell, which aren't UnwindSafe.
// This is safe because we don't rely on unwind safety for correctness — a panic
// in a NIF is already fatal to the BEAM.

struct RuntimeResource {
    core: AssertUnwindSafe<CoreRuntime>,
}
impl RefUnwindSafe for RuntimeResource {}

#[rustler::resource_impl]
impl Resource for RuntimeResource {}

struct ClientResource {
    connection: AssertUnwindSafe<Connection>,
    runtime_handle: tokio::runtime::Handle,
    // Hold a reference to the runtime so BEAM GC can't drop it while this client is alive
    _runtime: ResourceArc<RuntimeResource>,
}
impl RefUnwindSafe for ClientResource {}

#[rustler::resource_impl]
impl Resource for ClientResource {}

struct WorkerResource {
    worker: Arc<AssertUnwindSafe<Worker>>,
    runtime_handle: tokio::runtime::Handle,
    // Hold a reference to the runtime so BEAM GC can't drop it while this worker is alive
    _runtime: ResourceArc<RuntimeResource>,
}
impl RefUnwindSafe for WorkerResource {}

#[rustler::resource_impl]
impl Resource for WorkerResource {}

// --- Tracing initialization ---
// Uses TEMPORALEX_LOG env var (e.g. TEMPORALEX_LOG=debug or TEMPORALEX_LOG=temporalio=debug)
// Falls back to "info" if unset. This captures Core SDK internal logs too.

/// Helper: send a message to an Elixir process, logging if the send fails.
/// This prevents silent message loss when the target process is dead.
fn send_or_log<F>(env: &mut OwnedEnv, pid: &LocalPid, op: &str, builder: F)
where
    F: for<'a> FnOnce(Env<'a>) -> rustler::Term<'a>,
{
    if env.send_and_clear(pid, builder).is_err() {
        error!(
            operation = op,
            "send_and_clear failed — target process may be dead"
        );
    }
}

static TRACING_INITIALIZED: AtomicBool = AtomicBool::new(false);

fn init_tracing() {
    if TRACING_INITIALIZED.swap(true, Ordering::SeqCst) {
        return; // already initialized
    }

    use tracing_subscriber::EnvFilter;

    let filter = EnvFilter::try_from_env("TEMPORALEX_LOG")
        .unwrap_or_else(|_| EnvFilter::new("info,temporalio=info,temporalex_native=debug"));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        .with_thread_ids(true)
        .with_file(true)
        .with_line_number(true)
        .with_ansi(true)
        .init();

    info!("Temporalex NIF tracing initialized");
}

// --- Helper: encode bytes as an Erlang binary term ---

fn make_binary<'a>(env: Env<'a>, data: &[u8]) -> rustler::Term<'a> {
    let mut bin = NewBinary::new(env, data.len());
    bin.as_mut_slice().copy_from_slice(data);
    bin.into()
}

/// Log a hex preview of bytes (first 128 bytes) for debugging protobuf issues
fn hex_preview(data: &[u8]) -> String {
    let preview_len = data.len().min(128);
    format!(
        "{}{}",
        hex::encode(&data[..preview_len]),
        if data.len() > 128 { "..." } else { "" }
    )
}

fn close_event_result(event: &HistoryEvent) -> Option<Result<Vec<u8>, String>> {
    let event_type = EventType::try_from(event.event_type).unwrap_or(EventType::Unspecified);

    match event_type {
        EventType::WorkflowExecutionCompleted => Some(Ok(completed_event_result(event))),
        EventType::WorkflowExecutionFailed => Some(Err(failed_event_message(event))),
        EventType::WorkflowExecutionCanceled => Some(Err("workflow_cancelled".to_string())),
        EventType::WorkflowExecutionTerminated => Some(Err("workflow_terminated".to_string())),
        EventType::WorkflowExecutionTimedOut => Some(Err("workflow_timed_out".to_string())),
        _ => None,
    }
}

fn completed_event_result(event: &HistoryEvent) -> Vec<u8> {
    match &event.attributes {
        Some(Attributes::WorkflowExecutionCompletedEventAttributes(completed)) => {
            match &completed.result {
                Some(payloads) => payloads.encode_to_vec(),
                None => vec![],
            }
        }
        _ => vec![],
    }
}

fn failed_event_message(event: &HistoryEvent) -> String {
    match &event.attributes {
        Some(Attributes::WorkflowExecutionFailedEventAttributes(failed)) => {
            let msg = failed
                .failure
                .as_ref()
                .map(|f| f.message.clone())
                .unwrap_or_else(|| "workflow failed".to_string());

            format!("workflow_failed: {msg}")
        }
        _ => "workflow_failed: unknown".to_string(),
    }
}

// --- NIF functions ---

/// Create a CoreRuntime that owns a Tokio multi-thread runtime.
/// Also initializes tracing (controlled by TEMPORALEX_LOG env var).
#[rustler::nif(schedule = "DirtyCpu")]
fn create_runtime() -> Result<ResourceArc<RuntimeResource>, String> {
    init_tracing();
    info!("Creating CoreRuntime");

    let opts = temporalio_sdk_core::RuntimeOptions::builder()
        .build()
        .map_err(|e| {
            error!(error = %e, "Failed to build RuntimeOptions");
            format!("RuntimeOptions build error: {e}")
        })?;

    let core = CoreRuntime::new(opts, Default::default()).map_err(|e| {
        error!(error = %e, "Failed to create CoreRuntime");
        format!("CoreRuntime creation error: {e}")
    })?;

    info!("CoreRuntime created successfully");
    Ok(ResourceArc::new(RuntimeResource {
        core: AssertUnwindSafe(core),
    }))
}

/// Connect to a Temporal server. Returns a client resource.
/// Uses DirtyIo scheduler because this performs network I/O (DNS, TCP, TLS).
///
/// api_key: empty string means no API key; non-empty enables API key auth (auto-enables TLS).
/// headers: list of {key, value} string tuples for custom gRPC metadata on every call.
#[rustler::nif(schedule = "DirtyIo")]
fn connect_client(
    runtime: ResourceArc<RuntimeResource>,
    url_str: String,
    api_key: String,
    headers: Vec<(String, String)>,
) -> Result<ResourceArc<ClientResource>, String> {
    info!(url = %url_str, has_api_key = !api_key.is_empty(), header_count = headers.len(), "Connecting to Temporal server");

    let handle = runtime.core.tokio_handle();
    let connection = handle.block_on(async {
        let target = Url::parse(&url_str).map_err(|e| {
            error!(url = %url_str, error = %e, "Invalid server URL");
            format!("URL parse error: {e}")
        })?;

        let pid = std::process::id();
        let identity = format!("temporalex@{pid}");
        info!(identity = %identity, target = %target, "Building connection options");

        let api_key_opt = if api_key.is_empty() {
            None
        } else {
            info!("API key auth enabled");
            Some(api_key)
        };

        let headers_opt = if headers.is_empty() {
            None
        } else {
            let header_map: std::collections::HashMap<String, String> =
                headers.into_iter().collect();
            info!(header_count = header_map.len(), "Custom headers configured");
            Some(header_map)
        };

        let opts = ConnectionOptions::new(target)
            .identity(identity)
            .client_name("temporalex")
            .client_version("0.1.0")
            .maybe_api_key(api_key_opt)
            .maybe_headers(headers_opt)
            .build();

        Connection::connect(opts).await.map_err(|e| {
            error!(error = %e, "Failed to connect to Temporal server");
            format!("Connection error: {e}")
        })
    })?;

    info!(url = %url_str, "Connected to Temporal server");
    Ok(ResourceArc::new(ClientResource {
        connection: AssertUnwindSafe(connection),
        runtime_handle: handle.clone(),
        _runtime: runtime,
    }))
}

/// Create a Worker bound to a task queue. Returns a worker resource.
/// max_concurrent_wf_tasks and max_concurrent_activity_tasks control concurrency.
#[rustler::nif(schedule = "DirtyCpu")]
fn create_worker(
    runtime: ResourceArc<RuntimeResource>,
    client: ResourceArc<ClientResource>,
    task_queue: String,
    namespace: String,
    max_concurrent_wf_tasks: usize,
    max_concurrent_activity_tasks: usize,
) -> Result<ResourceArc<WorkerResource>, String> {
    info!(
        task_queue = %task_queue,
        namespace = %namespace,
        max_concurrent_wf_tasks = max_concurrent_wf_tasks,
        max_concurrent_activity_tasks = max_concurrent_activity_tasks,
        "Creating worker"
    );

    let config = temporalio_sdk_core::WorkerConfig::builder()
        .namespace(namespace.clone())
        .task_queue(task_queue.clone())
        .task_types(WorkerTaskTypes::all())
        .versioning_strategy(temporalio_sdk_core::WorkerVersioningStrategy::default())
        .max_outstanding_workflow_tasks(max_concurrent_wf_tasks)
        .max_outstanding_activities(max_concurrent_activity_tasks)
        .build()
        .map_err(|e| {
            error!(error = %e, task_queue = %task_queue, "Failed to build WorkerConfig");
            format!("WorkerConfig build error: {e}")
        })?;

    debug!(
        task_queue = %task_queue,
        namespace = %namespace,
        max_wf_tasks = max_concurrent_wf_tasks,
        max_activities = max_concurrent_activity_tasks,
        "WorkerConfig built"
    );

    let conn = (*client.connection).clone();
    let runtime_handle = runtime.core.tokio_handle().clone();

    let _guard = runtime_handle.enter();
    let worker = init_worker(&runtime.core, config, conn).map_err(|e| {
        error!(error = %e, task_queue = %task_queue, "Failed to init worker");
        format!("Worker init error: {e}")
    })?;

    info!(task_queue = %task_queue, namespace = %namespace, "Worker created successfully");
    Ok(ResourceArc::new(WorkerResource {
        worker: Arc::new(AssertUnwindSafe(worker)),
        runtime_handle,
        _runtime: runtime,
    }))
}

/// Poll for workflow activations. Returns :ok immediately, then sends
/// {:workflow_activation, bytes} or {:error, reason} to the caller pid.
#[rustler::nif]
fn poll_workflow_activation(worker: ResourceArc<WorkerResource>, pid: LocalPid) -> Atom {
    let w = worker.worker.clone();
    let handle = worker.runtime_handle.clone();

    debug!("Starting poll_workflow_activation");

    handle.spawn(async move {
        let result = w.poll_workflow_activation().await;

        let mut env = OwnedEnv::new();
        send_or_log(
            &mut env,
            &pid,
            "poll_workflow_activation",
            |env| match result {
                Ok(activation) => {
                    let job_types: Vec<String> = activation
                        .jobs
                        .iter()
                        .map(|j| match &j.variant {
                            Some(v) => format!("{:?}", std::mem::discriminant(v)),
                            None => "None".to_string(),
                        })
                        .collect();

                    info!(
                        run_id = %activation.run_id,
                        num_jobs = activation.jobs.len(),
                        job_types = ?job_types,
                        is_replaying = activation.is_replaying,
                        history_length = activation.history_length,
                        "Received workflow activation"
                    );

                    let bytes = activation.encode_to_vec();
                    debug!(
                        run_id = %activation.run_id,
                        byte_size = bytes.len(),
                        "Sending activation bytes to Elixir"
                    );

                    let bin_term = make_binary(env, &bytes);
                    (atoms::workflow_activation(), bin_term).encode(env)
                }
                Err(temporalio_sdk_core::PollError::ShutDown) => {
                    info!("Poll workflow: shutdown signal received");
                    (atoms::error(), atoms::shutdown()).encode(env)
                }
                Err(e) => {
                    error!(error = ?e, "Poll workflow activation failed");
                    (atoms::error(), format!("{e}")).encode(env)
                }
            },
        );
    });
    atoms::ok()
}

/// Complete a workflow activation. Returns :ok immediately, then sends
/// {:workflow_completion, :ok | {:error, msg}} to the caller pid.
#[rustler::nif]
fn complete_workflow_activation(
    worker: ResourceArc<WorkerResource>,
    bytes: rustler::Binary,
    pid: LocalPid,
) -> Atom {
    let w = worker.worker.clone();
    let data = bytes.as_slice().to_vec();
    let handle = worker.runtime_handle.clone();

    debug!(
        byte_size = data.len(),
        hex_preview = %hex_preview(&data),
        "Completing workflow activation (bytes from Elixir)"
    );

    handle.spawn(async move {
        let result: Result<(), String> = match timeout(COMPLETION_TIMEOUT, async {
            // Decode step — log what we got
            let completion = temporalio_common::protos::coresdk::workflow_completion::WorkflowActivationCompletion::decode(&data[..])
                .map_err(|e| {
                    error!(
                        error = %e,
                        byte_size = data.len(),
                        hex_preview = %hex_preview(&data),
                        "Failed to decode WorkflowActivationCompletion from Elixir bytes"
                    );
                    format!("decode error: {e}")
                })?;

            info!(
                run_id = %completion.run_id,
                has_status = completion.status.is_some(),
                "Decoded completion, sending to Core"
            );

            // Log the completion details
            match &completion.status {
                Some(temporalio_common::protos::coresdk::workflow_completion::workflow_activation_completion::Status::Successful(success)) => {
                    info!(
                        run_id = %completion.run_id,
                        num_commands = success.commands.len(),
                        "Completion status: Successful"
                    );
                    for (i, cmd) in success.commands.iter().enumerate() {
                        debug!(
                            run_id = %completion.run_id,
                            command_index = i,
                            command = ?cmd,
                            "Command detail"
                        );
                    }
                }
                Some(temporalio_common::protos::coresdk::workflow_completion::workflow_activation_completion::Status::Failed(failure)) => {
                    warn!(
                        run_id = %completion.run_id,
                        failure = ?failure,
                        "Completion status: Failed"
                    );
                }
                None => {
                    warn!(run_id = %completion.run_id, "Completion has no status set!");
                }
            }

            // Re-encode on Rust side to compare byte sizes
            let rust_bytes = completion.encode_to_vec();
            if rust_bytes.len() != data.len() {
                warn!(
                    run_id = %completion.run_id,
                    elixir_bytes = data.len(),
                    rust_bytes = rust_bytes.len(),
                    elixir_hex = %hex_preview(&data),
                    rust_hex = %hex_preview(&rust_bytes),
                    "PROTOBUF MISMATCH: Elixir and Rust encode differently!"
                );
            } else {
                debug!(
                    run_id = %completion.run_id,
                    byte_size = data.len(),
                    "Protobuf encoding matches between Elixir and Rust"
                );
            }

            // Send to Core
            w.complete_workflow_activation(completion).await.map_err(|e| {
                error!(
                    error = ?e,
                    "Core rejected workflow activation completion"
                );
                format!("Core completion error: {e}")
            })
        }).await {
            Ok(inner) => inner,
            Err(_) => {
                error!("complete_workflow_activation timed out after {}s", COMPLETION_TIMEOUT.as_secs());
                Err("completion timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "complete_workflow_activation", |env| match result {
            Ok(()) => {
                info!("Workflow activation completion accepted by Core");
                (atoms::workflow_completion(), atoms::ok()).encode(env)
            }
            Err(msg) => {
                error!(error = %msg, "Workflow activation completion FAILED");
                (atoms::workflow_completion(), (atoms::error(), msg)).encode(env)
            }
        });
    });
    atoms::ok()
}

/// Poll for activity tasks. Returns :ok immediately, then sends
/// {:activity_task, bytes} or {:error, reason} to the caller pid.
#[rustler::nif]
fn poll_activity_task(worker: ResourceArc<WorkerResource>, pid: LocalPid) -> Atom {
    let w = worker.worker.clone();
    let handle = worker.runtime_handle.clone();

    debug!("Starting poll_activity_task");

    handle.spawn(async move {
        let result = w.poll_activity_task().await;
        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "poll_activity_task", |env| match result {
            Ok(task) => {
                info!(
                    task_token_len = task.task_token.len(),
                    variant = ?std::mem::discriminant(&task.variant),
                    "Received activity task"
                );

                let bytes = task.encode_to_vec();
                debug!(
                    byte_size = bytes.len(),
                    "Sending activity task bytes to Elixir"
                );

                let bin_term = make_binary(env, &bytes);
                (atoms::activity_task(), bin_term).encode(env)
            }
            Err(temporalio_sdk_core::PollError::ShutDown) => {
                info!("Poll activity: shutdown signal received");
                (atoms::error(), atoms::shutdown()).encode(env)
            }
            Err(e) => {
                error!(error = ?e, "Poll activity task failed");
                (atoms::error(), format!("{e}")).encode(env)
            }
        });
    });
    atoms::ok()
}

/// Complete an activity task. Returns :ok immediately, then sends
/// {:activity_completion, :ok | {:error, msg}} to the caller pid.
#[rustler::nif]
fn complete_activity_task(
    worker: ResourceArc<WorkerResource>,
    bytes: rustler::Binary,
    pid: LocalPid,
) -> Atom {
    let w = worker.worker.clone();
    let data = bytes.as_slice().to_vec();
    let handle = worker.runtime_handle.clone();

    debug!(
        byte_size = data.len(),
        "Completing activity task (bytes from Elixir)"
    );

    handle.spawn(async move {
        let result: Result<(), String> = match timeout(COMPLETION_TIMEOUT, async {
            let completion =
                temporalio_common::protos::coresdk::ActivityTaskCompletion::decode(&data[..])
                    .map_err(|e| {
                        error!(
                            error = %e,
                            byte_size = data.len(),
                            hex_preview = %hex_preview(&data),
                            "Failed to decode ActivityTaskCompletion from Elixir bytes"
                        );
                        format!("decode error: {e}")
                    })?;

            info!(
                task_token_len = completion.task_token.len(),
                has_result = completion.result.is_some(),
                "Decoded activity completion, sending to Core"
            );

            if let Some(ref result) = completion.result {
                debug!(result = ?result, "Activity result detail");
            }

            w.complete_activity_task(completion).await.map_err(|e| {
                error!(error = ?e, "Core rejected activity completion");
                format!("Core activity completion error: {e}")
            })
        })
        .await
        {
            Ok(inner) => inner,
            Err(_) => {
                error!(
                    "complete_activity_task timed out after {}s",
                    COMPLETION_TIMEOUT.as_secs()
                );
                Err("activity completion timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(
            &mut env,
            &pid,
            "complete_activity_task",
            |env| match result {
                Ok(()) => {
                    info!("Activity completion accepted by Core");
                    (atoms::activity_completion(), atoms::ok()).encode(env)
                }
                Err(msg) => {
                    error!(error = %msg, "Activity completion FAILED");
                    (atoms::activity_completion(), (atoms::error(), msg)).encode(env)
                }
            },
        );
    });
    atoms::ok()
}

/// Record an activity heartbeat. Synchronous — the Core SDK handles
/// throttling internally. task_token identifies the activity.
/// details_bytes is protobuf-encoded Payloads (or empty).
#[rustler::nif]
fn record_activity_heartbeat(
    worker: ResourceArc<WorkerResource>,
    task_token: rustler::Binary,
    details_bytes: rustler::Binary,
) -> Atom {
    let token = task_token.as_slice().to_vec();
    let details_data = details_bytes.as_slice().to_vec();

    debug!(
        task_token_len = token.len(),
        details_len = details_data.len(),
        "Recording activity heartbeat"
    );

    let details = if details_data.is_empty() {
        vec![]
    } else {
        match Payloads::decode(&details_data[..]) {
            Ok(payloads) => payloads.payloads,
            Err(e) => {
                warn!(error = %e, "Failed to decode heartbeat details, sending empty");
                vec![]
            }
        }
    };

    let heartbeat = temporalio_common::protos::coresdk::ActivityHeartbeat {
        task_token: token,
        details,
    };

    worker.worker.record_activity_heartbeat(heartbeat);
    atoms::ok()
}

// --- Worker lifecycle NIF functions ---

/// Initiate worker shutdown. Non-blocking — starts the drain process.
/// Polling will return ShutDown errors after this.
#[rustler::nif]
fn initiate_shutdown(worker: ResourceArc<WorkerResource>) -> Atom {
    info!("Initiating worker shutdown");
    worker.worker.initiate_shutdown();
    info!("Worker shutdown initiated");
    atoms::ok()
}

/// Await full worker shutdown. Sends {:shutdown_complete, :ok} to pid when done.
/// Call initiate_shutdown first, then this to wait for in-flight tasks to drain.
#[rustler::nif]
fn shutdown_worker(worker: ResourceArc<WorkerResource>, pid: LocalPid) -> Atom {
    let w = worker.worker.clone();
    let handle = worker.runtime_handle.clone();

    info!("Awaiting worker shutdown completion");

    handle.spawn(async move {
        match timeout(SHUTDOWN_TIMEOUT, w.shutdown()).await {
            Ok(()) => info!("Worker shutdown complete"),
            Err(_) => warn!(
                "Worker shutdown timed out after {}s — proceeding anyway",
                SHUTDOWN_TIMEOUT.as_secs()
            ),
        }

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "shutdown_worker", |env| {
            (atoms::shutdown_complete(), atoms::ok()).encode(env)
        });
    });
    atoms::ok()
}

/// Validate worker against Temporal server (checks namespace exists).
/// Sends {:validate_result, :ok | {:error, reason}} to pid.
#[rustler::nif]
fn validate_worker(worker: ResourceArc<WorkerResource>, pid: LocalPid) -> Atom {
    let w = worker.worker.clone();
    let handle = worker.runtime_handle.clone();

    info!("Validating worker against server");

    handle.spawn(async move {
        let result: Result<(), String> = match timeout(VALIDATE_TIMEOUT, w.validate()).await {
            Ok(Ok(_namespace_info)) => Ok(()),
            Ok(Err(e)) => {
                error!(error = ?e, "Worker validation failed");
                Err(format!("{e}"))
            }
            Err(_) => {
                error!(
                    "validate_worker timed out after {}s",
                    VALIDATE_TIMEOUT.as_secs()
                );
                Err("validation timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "validate_worker", |env| match result {
            Ok(()) => {
                info!("Worker validation succeeded");
                (atoms::validate_result(), atoms::ok()).encode(env)
            }
            Err(msg) => (atoms::validate_result(), (atoms::error(), msg)).encode(env),
        });
    });
    atoms::ok()
}

// --- Client NIF functions ---
// These call Temporal gRPC service methods via the Connection's WorkflowService.
// Same async pattern: NIF returns :ok immediately, sends result to pid.

/// Start a workflow execution. Sends
/// {:start_workflow_result, request_ref, {:ok, run_id} | {:error, reason}}
/// to the caller pid.
#[rustler::nif]
fn start_workflow(
    client: ResourceArc<ClientResource>,
    request: StartWorkflowRequest,
    pid: LocalPid,
) -> Atom {
    let (namespace, workflow_id, workflow_type, task_queue, input_bytes, request_id, request_ref) =
        request;
    let conn = (*client.connection).clone();
    let handle = client.runtime_handle.clone();
    let input_data = input_bytes.as_slice().to_vec();

    info!(
        namespace = %namespace,
        workflow_id = %workflow_id,
        workflow_type = %workflow_type,
        task_queue = %task_queue,
        input_size = input_data.len(),
        "Starting workflow via gRPC"
    );

    handle.spawn(async move {
        let result: Result<String, String> = match timeout(CLIENT_OP_TIMEOUT, async {
            let mut svc = conn.workflow_service();

            // Decode input payloads from Elixir protobuf bytes (if non-empty)
            let input = if input_data.is_empty() {
                None
            } else {
                Some(Payloads::decode(&input_data[..]).map_err(|e| {
                    error!(error = %e, "Failed to decode input Payloads");
                    format!("input decode error: {e}")
                })?)
            };

            let identity = format!("temporalex@{}", std::process::id());

            let request = StartWorkflowExecutionRequest {
                namespace: namespace.clone(),
                workflow_id: workflow_id.clone(),
                workflow_type: Some(WorkflowType {
                    name: workflow_type.clone(),
                }),
                task_queue: Some(TaskQueue {
                    name: task_queue.clone(),
                    ..Default::default()
                }),
                input,
                identity,
                request_id,
                ..Default::default()
            };

            let response = svc
                .start_workflow_execution(Request::new(request))
                .await
                .map_err(|e| {
                    error!(
                        error = %e,
                        workflow_id = %workflow_id,
                        "StartWorkflowExecution gRPC failed"
                    );
                    format!("gRPC error: {e}")
                })?;

            let run_id = response.into_inner().run_id;
            info!(
                workflow_id = %workflow_id,
                run_id = %run_id,
                "Workflow started successfully"
            );
            Ok(run_id)
        })
        .await
        {
            Ok(inner) => inner,
            Err(_) => {
                error!(
                    "start_workflow timed out after {}s",
                    CLIENT_OP_TIMEOUT.as_secs()
                );
                Err("start_workflow timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "start_workflow", |env| match result {
            Ok(run_id) => (
                atoms::start_workflow_result(),
                request_ref,
                (atoms::ok(), run_id),
            )
                .encode(env),
            Err(msg) => (
                atoms::start_workflow_result(),
                request_ref,
                (atoms::error(), msg),
            )
                .encode(env),
        });
    });
    atoms::ok()
}

/// Signal a running workflow. Sends
/// {:signal_workflow_result, request_ref, :ok | {:error, reason}}.
#[rustler::nif]
fn signal_workflow(
    client: ResourceArc<ClientResource>,
    request: SignalWorkflowRequest,
    pid: LocalPid,
) -> Atom {
    let (namespace, workflow_id, run_id, signal_name, input_bytes, request_id, request_ref) =
        request;
    let conn = (*client.connection).clone();
    let handle = client.runtime_handle.clone();
    let input_data = input_bytes.as_slice().to_vec();

    info!(
        namespace = %namespace,
        workflow_id = %workflow_id,
        run_id = %run_id,
        signal_name = %signal_name,
        "Signaling workflow via gRPC"
    );

    handle.spawn(async move {
        let result: Result<(), String> = match timeout(CLIENT_OP_TIMEOUT, async {
            let mut svc = conn.workflow_service();

            let input = if input_data.is_empty() {
                None
            } else {
                Some(Payloads::decode(&input_data[..]).map_err(|e| {
                    error!(error = %e, "Failed to decode signal input Payloads");
                    format!("input decode error: {e}")
                })?)
            };

            let identity = format!("temporalex@{}", std::process::id());

            let request = SignalWorkflowExecutionRequest {
                namespace: namespace.clone(),
                workflow_execution: Some(WorkflowExecution {
                    workflow_id: workflow_id.clone(),
                    run_id: run_id.clone(),
                }),
                signal_name: signal_name.clone(),
                input,
                identity,
                request_id,
                ..Default::default()
            };

            svc.signal_workflow_execution(Request::new(request))
                .await
                .map_err(|e| {
                    error!(
                        error = %e,
                        workflow_id = %workflow_id,
                        signal_name = %signal_name,
                        "SignalWorkflowExecution gRPC failed"
                    );
                    format!("gRPC error: {e}")
                })?;

            info!(
                workflow_id = %workflow_id,
                signal_name = %signal_name,
                "Signal sent successfully"
            );
            Ok(())
        })
        .await
        {
            Ok(inner) => inner,
            Err(_) => {
                error!(
                    "signal_workflow timed out after {}s",
                    CLIENT_OP_TIMEOUT.as_secs()
                );
                Err("signal_workflow timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "signal_workflow", |env| match result {
            Ok(()) => (atoms::signal_workflow_result(), request_ref, atoms::ok()).encode(env),
            Err(msg) => (
                atoms::signal_workflow_result(),
                request_ref,
                (atoms::error(), msg),
            )
                .encode(env),
        });
    });
    atoms::ok()
}

/// Query a workflow. Sends
/// {:query_workflow_result, request_ref, {:ok, result_bytes} | {:error, reason}}.
/// result_bytes is protobuf-encoded Payloads.
#[rustler::nif]
fn query_workflow(
    client: ResourceArc<ClientResource>,
    request: QueryWorkflowNifRequest,
    pid: LocalPid,
) -> Atom {
    let (namespace, workflow_id, run_id, query_type, query_args_bytes, request_ref) = request;
    let conn = (*client.connection).clone();
    let handle = client.runtime_handle.clone();
    let args_data = query_args_bytes.as_slice().to_vec();

    info!(
        namespace = %namespace,
        workflow_id = %workflow_id,
        run_id = %run_id,
        query_type = %query_type,
        "Querying workflow via gRPC"
    );

    handle.spawn(async move {
        let result: Result<Vec<u8>, String> = match timeout(CLIENT_OP_TIMEOUT, async {
            let mut svc = conn.workflow_service();

            let query_args = if args_data.is_empty() {
                None
            } else {
                Some(Payloads::decode(&args_data[..]).map_err(|e| {
                    error!(error = %e, "Failed to decode query args Payloads");
                    format!("query args decode error: {e}")
                })?)
            };

            let request = QueryWorkflowRequest {
                namespace: namespace.clone(),
                execution: Some(WorkflowExecution {
                    workflow_id: workflow_id.clone(),
                    run_id: run_id.clone(),
                }),
                query: Some(WorkflowQuery {
                    query_type: query_type.clone(),
                    query_args,
                    ..Default::default()
                }),
                ..Default::default()
            };

            let response = svc
                .query_workflow(Request::new(request))
                .await
                .map_err(|e| {
                    error!(
                        error = %e,
                        workflow_id = %workflow_id,
                        query_type = %query_type,
                        "QueryWorkflow gRPC failed"
                    );
                    format!("gRPC error: {e}")
                })?;

            let inner = response.into_inner();

            // Check for rejection
            if let Some(rejected) = inner.query_rejected {
                warn!(
                    workflow_id = %workflow_id,
                    query_type = %query_type,
                    status = ?rejected.status,
                    "Query rejected"
                );
                return Err(format!("query rejected: status={:?}", rejected.status));
            }

            // Encode result payloads back to protobuf bytes for Elixir
            let result_bytes = match inner.query_result {
                Some(payloads) => payloads.encode_to_vec(),
                None => vec![],
            };

            info!(
                workflow_id = %workflow_id,
                query_type = %query_type,
                result_size = result_bytes.len(),
                "Query completed successfully"
            );
            Ok(result_bytes)
        })
        .await
        {
            Ok(inner) => inner,
            Err(_) => {
                error!(
                    "query_workflow timed out after {}s",
                    CLIENT_OP_TIMEOUT.as_secs()
                );
                Err("query_workflow timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "query_workflow", |env| match result {
            Ok(bytes) => {
                let bin_term = make_binary(env, &bytes);
                (
                    atoms::query_workflow_result(),
                    request_ref,
                    (atoms::ok(), bin_term),
                )
                    .encode(env)
            }
            Err(msg) => (
                atoms::query_workflow_result(),
                request_ref,
                (atoms::error(), msg),
            )
                .encode(env),
        });
    });
    atoms::ok()
}

/// Cancel a workflow. Sends
/// {:cancel_workflow_result, request_ref, :ok | {:error, reason}}.
#[rustler::nif]
fn cancel_workflow(
    client: ResourceArc<ClientResource>,
    request: CancelWorkflowRequest,
    pid: LocalPid,
) -> Atom {
    let (namespace, workflow_id, run_id, reason, request_id, request_ref) = request;
    let conn = (*client.connection).clone();
    let handle = client.runtime_handle.clone();

    info!(
        namespace = %namespace,
        workflow_id = %workflow_id,
        run_id = %run_id,
        reason = %reason,
        "Cancelling workflow via gRPC"
    );

    handle.spawn(async move {
        let result: Result<(), String> = match timeout(CLIENT_OP_TIMEOUT, async {
            let mut svc = conn.workflow_service();
            let identity = format!("temporalex@{}", std::process::id());

            let request = RequestCancelWorkflowExecutionRequest {
                namespace: namespace.clone(),
                workflow_execution: Some(WorkflowExecution {
                    workflow_id: workflow_id.clone(),
                    run_id: run_id.clone(),
                }),
                identity,
                request_id,
                reason: reason.clone(),
                ..Default::default()
            };

            svc.request_cancel_workflow_execution(Request::new(request))
                .await
                .map_err(|e| {
                    error!(
                        error = %e,
                        workflow_id = %workflow_id,
                        "RequestCancelWorkflowExecution gRPC failed"
                    );
                    format!("gRPC error: {e}")
                })?;

            info!(workflow_id = %workflow_id, "Cancel request sent successfully");
            Ok(())
        })
        .await
        {
            Ok(inner) => inner,
            Err(_) => {
                error!(
                    "cancel_workflow timed out after {}s",
                    CLIENT_OP_TIMEOUT.as_secs()
                );
                Err("cancel_workflow timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "cancel_workflow", |env| match result {
            Ok(()) => (atoms::cancel_workflow_result(), request_ref, atoms::ok()).encode(env),
            Err(msg) => (
                atoms::cancel_workflow_result(),
                request_ref,
                (atoms::error(), msg),
            )
                .encode(env),
        });
    });
    atoms::ok()
}

/// Terminate a workflow. Sends
/// {:terminate_workflow_result, request_ref, :ok | {:error, reason}}.
#[rustler::nif]
fn terminate_workflow(
    client: ResourceArc<ClientResource>,
    request: TerminateWorkflowRequest,
    pid: LocalPid,
) -> Atom {
    let (namespace, workflow_id, run_id, reason, request_ref) = request;
    let conn = (*client.connection).clone();
    let handle = client.runtime_handle.clone();

    info!(
        namespace = %namespace,
        workflow_id = %workflow_id,
        run_id = %run_id,
        reason = %reason,
        "Terminating workflow via gRPC"
    );

    handle.spawn(async move {
        let result: Result<(), String> = match timeout(CLIENT_OP_TIMEOUT, async {
            let mut svc = conn.workflow_service();
            let identity = format!("temporalex@{}", std::process::id());

            let request = TerminateWorkflowExecutionRequest {
                namespace: namespace.clone(),
                workflow_execution: Some(WorkflowExecution {
                    workflow_id: workflow_id.clone(),
                    run_id: run_id.clone(),
                }),
                reason: reason.clone(),
                identity,
                ..Default::default()
            };

            svc.terminate_workflow_execution(Request::new(request))
                .await
                .map_err(|e| {
                    error!(
                        error = %e,
                        workflow_id = %workflow_id,
                        "TerminateWorkflowExecution gRPC failed"
                    );
                    format!("gRPC error: {e}")
                })?;

            info!(workflow_id = %workflow_id, "Workflow terminated successfully");
            Ok(())
        })
        .await
        {
            Ok(inner) => inner,
            Err(_) => {
                error!(
                    "terminate_workflow timed out after {}s",
                    CLIENT_OP_TIMEOUT.as_secs()
                );
                Err("terminate_workflow timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "terminate_workflow", |env| match result {
            Ok(()) => (atoms::terminate_workflow_result(), request_ref, atoms::ok()).encode(env),
            Err(msg) => (
                atoms::terminate_workflow_result(),
                request_ref,
                (atoms::error(), msg),
            )
                .encode(env),
        });
    });
    atoms::ok()
}

/// Get the result of a completed workflow by polling its history.
/// Uses long-polling with wait_new_event to block until the workflow closes.
/// Sends {:get_result_result, request_ref, {:ok, result_bytes} | {:error, reason}} to pid.
/// result_bytes is protobuf-encoded Payloads from the completion event.
#[rustler::nif]
fn get_workflow_result(
    client: ResourceArc<ClientResource>,
    request: WorkflowResultRequest,
    pid: LocalPid,
) -> Atom {
    let (namespace, workflow_id, run_id, request_ref) = request;
    let conn = (*client.connection).clone();
    let handle = client.runtime_handle.clone();

    info!(
        namespace = %namespace,
        workflow_id = %workflow_id,
        run_id = %run_id,
        "Getting workflow result via gRPC history"
    );

    handle.spawn(async move {
        let result: Result<Vec<u8>, String> = match timeout(CLIENT_OP_TIMEOUT, async {
            let mut svc = conn.workflow_service();
            let mut next_page_token = vec![];

            // Long-poll for the close event
            let max_pages = 100;
            let mut page_count = 0;
            loop {
                page_count += 1;
                if page_count > max_pages {
                    return Err(format!("exceeded max page iterations ({max_pages}) waiting for workflow result"));
                }
                let request = GetWorkflowExecutionHistoryRequest {
                    namespace: namespace.clone(),
                    execution: Some(WorkflowExecution {
                        workflow_id: workflow_id.clone(),
                        run_id: run_id.clone(),
                    }),
                    // Only get close events — skip the full history
                    history_event_filter_type: HistoryEventFilterType::CloseEvent as i32,
                    wait_new_event: true,
                    next_page_token: next_page_token.clone(),
                    ..Default::default()
                };

                let response = svc
                    .get_workflow_execution_history(Request::new(request))
                    .await
                    .map_err(|e| {
                        error!(
                            error = %e,
                            workflow_id = %workflow_id,
                            "GetWorkflowExecutionHistory gRPC failed"
                        );
                        format!("gRPC error: {e}")
                    })?;

                let inner = response.into_inner();

                // Check if we got a close event
                if let Some(history) = &inner.history {
                    for event in &history.events {
                        if let Some(result) = close_event_result(event) {
                            if result.is_ok() {
                                info!(workflow_id = %workflow_id, "Workflow completed successfully");
                            }

                            return result;
                        }

                        let event_type =
                            EventType::try_from(event.event_type).unwrap_or(EventType::Unspecified);
                        debug!(event_type = ?event_type, "Skipping non-close event");
                    }
                }

                // If we got a next page token, keep polling
                if inner.next_page_token.is_empty() {
                    // No more pages and no close event — shouldn't happen with wait_new_event
                    return Err("no close event found".to_string());
                }
                next_page_token = inner.next_page_token;
            }
        }).await {
            Ok(inner) => inner,
            Err(_) => {
                error!("get_workflow_result timed out after {}s", CLIENT_OP_TIMEOUT.as_secs());
                Err("get_workflow_result timed out".to_string())
            }
        };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "get_workflow_result", |env| match result {
            Ok(bytes) => {
                let bin_term = make_binary(env, &bytes);
                (atoms::get_result_result(), request_ref, (atoms::ok(), bin_term)).encode(env)
            }
            Err(msg) => (
                atoms::get_result_result(),
                request_ref,
                (atoms::error(), msg),
            )
                .encode(env),
        });
    });
    atoms::ok()
}

// --- Debug NIF functions ---

/// Debug helper: decode workflow completion bytes on the Rust side and return
/// a human-readable string. Use this to verify Elixir protobuf encoding.
#[rustler::nif]
fn debug_decode_completion(bytes: rustler::Binary) -> Result<String, String> {
    let data = bytes.as_slice();
    debug!(byte_size = data.len(), hex = %hex_preview(data), "Debug decoding completion");

    match temporalio_common::protos::coresdk::workflow_completion::WorkflowActivationCompletion::decode(data) {
        Ok(completion) => {
            let debug_str = format!("{completion:#?}");
            debug!(decoded = %debug_str, "Successfully decoded completion");
            Ok(debug_str)
        }
        Err(e) => {
            error!(error = %e, hex = %hex_preview(data), "Failed to decode completion");
            Err(format!("decode error: {e}"))
        }
    }
}

/// Debug helper: decode activity completion bytes on the Rust side.
#[rustler::nif]
fn debug_decode_activity_completion(bytes: rustler::Binary) -> Result<String, String> {
    let data = bytes.as_slice();
    debug!(byte_size = data.len(), hex = %hex_preview(data), "Debug decoding activity completion");

    match temporalio_common::protos::coresdk::ActivityTaskCompletion::decode(data) {
        Ok(completion) => {
            let debug_str = format!("{completion:#?}");
            debug!(decoded = %debug_str, "Successfully decoded activity completion");
            Ok(debug_str)
        }
        Err(e) => {
            error!(error = %e, hex = %hex_preview(data), "Failed to decode activity completion");
            Err(format!("decode error: {e}"))
        }
    }
}

// --- Describe / List workflow NIFs ---

/// Describe a workflow execution. Sends
/// {:describe_workflow_result, request_ref, {:ok, info_map} | {:error, reason}}.
/// Returns key fields as an Erlang-friendly map.
#[rustler::nif]
fn describe_workflow(
    client: ResourceArc<ClientResource>,
    request: DescribeWorkflowRequest,
    pid: LocalPid,
) -> Atom {
    let (namespace, workflow_id, run_id, request_ref) = request;
    let conn = (*client.connection).clone();
    let handle = client.runtime_handle.clone();

    info!(namespace = %namespace, workflow_id = %workflow_id, "Describing workflow");

    handle.spawn(async move {
        let result: Result<Vec<(String, String)>, String> =
            match timeout(CLIENT_OP_TIMEOUT, async {
                let mut svc = conn.workflow_service();

                let request = DescribeWorkflowExecutionRequest {
                    namespace: namespace.clone(),
                    execution: Some(WorkflowExecution {
                        workflow_id: workflow_id.clone(),
                        run_id: run_id.clone(),
                    }),
                };

                let response = svc
                    .describe_workflow_execution(Request::new(request))
                    .await
                    .map_err(|e| format!("gRPC error: {e}"))?;

                let inner = response.into_inner();

                // Extract key fields into string pairs for Elixir
                let mut fields = Vec::new();

                if let Some(ref info) = inner.workflow_execution_info {
                    if let Some(ref exec) = info.execution {
                        fields.push(("workflow_id".to_string(), exec.workflow_id.clone()));
                        fields.push(("run_id".to_string(), exec.run_id.clone()));
                    }
                    if let Some(ref wf_type) = info.r#type {
                        fields.push(("workflow_type".to_string(), wf_type.name.clone()));
                    }
                    fields.push(("status".to_string(), format!("{:?}", info.status)));
                    fields.push((
                        "history_length".to_string(),
                        info.history_length.to_string(),
                    ));
                    if let Some(ref start_time) = info.start_time {
                        fields.push((
                            "start_time".to_string(),
                            format!("{}.{}", start_time.seconds, start_time.nanos),
                        ));
                    }
                    if let Some(ref close_time) = info.close_time {
                        fields.push((
                            "close_time".to_string(),
                            format!("{}.{}", close_time.seconds, close_time.nanos),
                        ));
                    }
                    if !info.task_queue.is_empty() {
                        fields.push(("task_queue".to_string(), info.task_queue.clone()));
                    }
                }

                fields.push((
                    "pending_activities".to_string(),
                    inner.pending_activities.len().to_string(),
                ));
                fields.push((
                    "pending_children".to_string(),
                    inner.pending_children.len().to_string(),
                ));

                Ok(fields)
            })
            .await
            {
                Ok(inner) => inner,
                Err(_) => {
                    error!(
                        "describe_workflow timed out after {}s",
                        CLIENT_OP_TIMEOUT.as_secs()
                    );
                    Err("describe_workflow timed out".to_string())
                }
            };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "describe_workflow", |env| match result {
            Ok(fields) => {
                let pairs = fields
                    .iter()
                    .map(|(k, v)| (k.as_str(), v.as_str()))
                    .collect::<Vec<_>>();

                match rustler::Term::map_from_pairs(env, &pairs) {
                    Ok(map) => (
                        atoms::describe_workflow_result(),
                        request_ref,
                        (atoms::ok(), map),
                    )
                        .encode(env),
                    Err(e) => (
                        atoms::describe_workflow_result(),
                        request_ref,
                        (atoms::error(), format!("map encode error: {e:?}")),
                    )
                        .encode(env),
                }
            }
            Err(msg) => (
                atoms::describe_workflow_result(),
                request_ref,
                (atoms::error(), msg),
            )
                .encode(env),
        });
    });
    atoms::ok()
}

/// List workflow executions. Sends
/// {:list_workflows_result, request_ref, {:ok, [info_map]} | {:error, reason}}.
#[rustler::nif]
fn list_workflows(
    client: ResourceArc<ClientResource>,
    request: ListWorkflowsRequest,
    pid: LocalPid,
) -> Atom {
    let (namespace, query, page_size, request_ref) = request;
    let conn = (*client.connection).clone();
    let handle = client.runtime_handle.clone();

    info!(namespace = %namespace, query = %query, page_size = page_size, "Listing workflows");

    handle.spawn(async move {
        let result: Result<Vec<Vec<(String, String)>>, String> =
            match timeout(CLIENT_OP_TIMEOUT, async {
                let mut svc = conn.workflow_service();

                let request = ListWorkflowExecutionsRequest {
                    namespace: namespace.clone(),
                    page_size,
                    query: query.clone(),
                    next_page_token: vec![],
                };

                let response = svc
                    .list_workflow_executions(Request::new(request))
                    .await
                    .map_err(|e| format!("gRPC error: {e}"))?;

                let inner = response.into_inner();

                let executions: Vec<Vec<(String, String)>> = inner
                    .executions
                    .iter()
                    .map(|info| {
                        let mut fields = Vec::new();
                        if let Some(ref exec) = info.execution {
                            fields.push(("workflow_id".to_string(), exec.workflow_id.clone()));
                            fields.push(("run_id".to_string(), exec.run_id.clone()));
                        }
                        if let Some(ref wf_type) = info.r#type {
                            fields.push(("workflow_type".to_string(), wf_type.name.clone()));
                        }
                        fields.push(("status".to_string(), format!("{:?}", info.status)));
                        if let Some(ref start_time) = info.start_time {
                            fields.push((
                                "start_time".to_string(),
                                format!("{}.{}", start_time.seconds, start_time.nanos),
                            ));
                        }
                        fields
                    })
                    .collect();

                info!(count = executions.len(), "Listed workflows");
                Ok(executions)
            })
            .await
            {
                Ok(inner) => inner,
                Err(_) => {
                    error!(
                        "list_workflows timed out after {}s",
                        CLIENT_OP_TIMEOUT.as_secs()
                    );
                    Err("list_workflows timed out".to_string())
                }
            };

        let mut env = OwnedEnv::new();
        send_or_log(&mut env, &pid, "list_workflows", |env| match result {
            Ok(executions) => {
                let maps = executions
                    .iter()
                    .map(|fields| {
                        let pairs = fields
                            .iter()
                            .map(|(k, v)| (k.as_str(), v.as_str()))
                            .collect::<Vec<_>>();

                        rustler::Term::map_from_pairs(env, &pairs)
                    })
                    .collect::<Result<Vec<_>, _>>();

                match maps {
                    Ok(maps) => {
                        let list = maps.encode(env);
                        (
                            atoms::list_workflows_result(),
                            request_ref,
                            (atoms::ok(), list),
                        )
                            .encode(env)
                    }
                    Err(e) => (
                        atoms::list_workflows_result(),
                        request_ref,
                        (atoms::error(), format!("map encode error: {e:?}")),
                    )
                        .encode(env),
                }
            }
            Err(msg) => (
                atoms::list_workflows_result(),
                request_ref,
                (atoms::error(), msg),
            )
                .encode(env),
        });
    });
    atoms::ok()
}

// --- Init ---

rustler::init!("Elixir.Temporalex.Native");

#[cfg(test)]
mod tests {
    use super::*;
    use temporalio_common::protos::temporal::api::{
        failure::v1::Failure,
        history::v1::{
            WorkflowExecutionCompletedEventAttributes, WorkflowExecutionFailedEventAttributes,
        },
    };

    fn event(event_type: EventType, attributes: Option<Attributes>) -> HistoryEvent {
        HistoryEvent {
            event_type: event_type as i32,
            attributes,
            ..Default::default()
        }
    }

    #[test]
    fn close_event_result_extracts_completed_payloads() {
        let payloads = Payloads { payloads: vec![] };
        let expected = payloads.encode_to_vec();
        let event = event(
            EventType::WorkflowExecutionCompleted,
            Some(Attributes::WorkflowExecutionCompletedEventAttributes(
                WorkflowExecutionCompletedEventAttributes {
                    result: Some(payloads),
                    ..Default::default()
                },
            )),
        );

        assert_eq!(close_event_result(&event), Some(Ok(expected)));
    }

    #[test]
    fn close_event_result_handles_failed_event_message() {
        let event = event(
            EventType::WorkflowExecutionFailed,
            Some(Attributes::WorkflowExecutionFailedEventAttributes(
                WorkflowExecutionFailedEventAttributes {
                    failure: Some(Failure {
                        message: "boom".to_string(),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            )),
        );

        assert_eq!(
            close_event_result(&event),
            Some(Err("workflow_failed: boom".to_string()))
        );
    }

    #[test]
    fn close_event_result_ignores_non_close_events() {
        let event = event(EventType::WorkflowTaskStarted, None);

        assert_eq!(close_event_result(&event), None);
    }
}
