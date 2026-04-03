use prost::Message;
use rustler::{Encoder, Env, LocalPid, Monitor, Resource, ResourceArc};
use std::panic::{AssertUnwindSafe, RefUnwindSafe};
use std::sync::Arc;
use temporalio_client::Connection;
use temporalio_common::worker::WorkerTaskTypes;
use temporalio_sdk_core::{
    init_worker, PollError, Worker, WorkerConfig, WorkerVersioningStrategy,
};
use tracing::{error, info};

use crate::atoms;
use crate::client::ClientResource;
use crate::helpers;
use crate::runtime::RuntimeResource;
use crate::task_guard::PollLoopGuard;

/// Opaque handle to a Temporal Worker.
///
/// Uses `Arc<Worker>` so the worker can be shared between poll loops and
/// completion calls from multiple Elixir processes.
///
/// Implements resource monitoring via `down/3` — when the owning Elixir process
/// (Server) dies, the worker shuts down immediately. This is more reliable than
/// `terminate/2` which is skipped on `:kill` exits.
pub struct WorkerResource {
    pub worker: Arc<AssertUnwindSafe<Worker>>,
    pub runtime_handle: tokio::runtime::Handle,
    pub _runtime: ResourceArc<RuntimeResource>,
}

impl RefUnwindSafe for WorkerResource {}

#[rustler::resource_impl]
impl Resource for WorkerResource {
    /// Called by the BEAM when the monitored process (Server) dies.
    /// Triggers graceful worker shutdown so poll loops exit cleanly.
    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        info!("Monitored process died — initiating worker shutdown");
        self.worker.initiate_shutdown();
    }
}

/// Synchronous NIF (DirtyCpu) — creates a worker, sets up resource monitor,
/// spawns poll loops, returns `{:ok, worker}` or `{:error, reason}`.
///
/// Sync because `init_worker` is CPU-only and we need `Env` for `env.monitor()`.
#[rustler::nif(schedule = "DirtyCpu")]
fn start_worker(
    env: Env,
    runtime: ResourceArc<RuntimeResource>,
    client: ResourceArc<ClientResource>,
    task_queue: String,
    namespace: String,
    max_cached_workflows: usize,
    pid: LocalPid,
) -> Result<ResourceArc<WorkerResource>, String> {
    let config = WorkerConfig::builder()
        .namespace(&namespace)
        .task_queue(&task_queue)
        .max_cached_workflows(max_cached_workflows)
        .task_types(WorkerTaskTypes::all())
        .versioning_strategy(WorkerVersioningStrategy::None {
            build_id: String::new(),
        })
        .build()
        .map_err(|e| format!("worker config: {e}"))?;

    // Clone the connection — init_worker takes it by value
    let connection: Connection = (*client.connection).clone();

    // Enter Tokio runtime context — init_worker spawns internal tasks
    let _guard = runtime.core.tokio_handle().enter();

    let worker = init_worker(&runtime.core, config, connection)
        .map_err(|e| format!("init worker: {e}"))?;

    let worker_arc = Arc::new(AssertUnwindSafe(worker));
    let handle = runtime.core.tokio_handle().clone();

    let resource = ResourceArc::new(WorkerResource {
        worker: worker_arc.clone(),
        runtime_handle: handle.clone(),
        _runtime: runtime,
    });

    // Monitor the owning process — when it dies, down/3 fires
    env.monitor(&resource, &pid);

    // Spawn push-based poll loops
    spawn_workflow_poll_loop(worker_arc.clone(), pid, handle.clone());
    spawn_activity_poll_loop(worker_arc, pid, handle);

    info!(task_queue = %task_queue, "Worker started with poll loops");

    Ok(resource)
}

/// Long-lived Tokio task that continuously polls for workflow activations.
/// Sends `{:workflow_activation, bytes}` to the Server PID on each activation.
/// On shutdown: PollLoopGuard sends `{:poll_loop_exited, :workflow, :shutdown}`.
/// On crash: PollLoopGuard Drop sends `{:poll_loop_exited, :workflow, :crashed}`.
fn spawn_workflow_poll_loop(
    worker: Arc<AssertUnwindSafe<Worker>>,
    pid: LocalPid,
    handle: tokio::runtime::Handle,
) {
    handle.spawn(async move {
        let guard = PollLoopGuard::new(pid, atoms::workflow());

        loop {
            match worker.poll_workflow_activation().await {
                Ok(activation) => {
                    let bytes = Message::encode_to_vec(&activation);
                    let mut env = rustler::OwnedEnv::new();
                    let _ = env.send_and_clear(&pid, |env| {
                        let bin = helpers::make_binary(env, &bytes);
                        (atoms::workflow_activation(), bin).encode(env)
                    });
                }
                Err(PollError::ShutDown) => {
                    info!("Workflow poll loop shutting down");
                    guard.complete_shutdown();
                    return;
                }
                Err(e) => {
                    error!(error = %e, "Workflow poll loop error");
                    // Guard Drop fires, sending {:poll_loop_exited, :workflow, :crashed}
                    return;
                }
            }
        }
    });
}

/// Long-lived Tokio task that continuously polls for activity tasks.
/// Sends `{:activity_task, bytes}` to the Server PID on each task.
fn spawn_activity_poll_loop(
    worker: Arc<AssertUnwindSafe<Worker>>,
    pid: LocalPid,
    handle: tokio::runtime::Handle,
) {
    handle.spawn(async move {
        let guard = PollLoopGuard::new(pid, atoms::activity());

        loop {
            match worker.poll_activity_task().await {
                Ok(task) => {
                    let bytes = Message::encode_to_vec(&task);
                    let mut env = rustler::OwnedEnv::new();
                    let _ = env.send_and_clear(&pid, |env| {
                        let bin = helpers::make_binary(env, &bytes);
                        (atoms::activity_task(), bin).encode(env)
                    });
                }
                Err(PollError::ShutDown) => {
                    info!("Activity poll loop shutting down");
                    guard.complete_shutdown();
                    return;
                }
                Err(e) => {
                    error!(error = %e, "Activity poll loop error");
                    return;
                }
            }
        }
    });
}
