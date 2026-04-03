use rustler::{Atom, Encoder, LocalPid, ResourceArc};
use tracing::info;

use crate::atoms;
use crate::task_guard::TaskGuard;
use crate::worker::WorkerResource;

/// Sync NIF — signals the worker to shut down. Non-blocking.
/// Poll loops will exit with PollError::ShutDown.
#[rustler::nif]
fn initiate_shutdown(worker: ResourceArc<WorkerResource>) -> Atom {
    info!("Initiating worker shutdown");
    worker.worker.initiate_shutdown();
    atoms::ok()
}

/// Async NIF — waits for the worker to fully shut down.
/// Sends `{:shutdown_complete, :ok}` to `pid`.
#[rustler::nif]
fn shutdown_worker(worker: ResourceArc<WorkerResource>, pid: LocalPid) -> Atom {
    let w = worker.worker.clone();
    let handle = worker.runtime_handle.clone();

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, atoms::shutdown_complete());
        w.shutdown().await;
        info!("Worker shutdown complete");
        guard.complete(|env| (atoms::shutdown_complete(), atoms::ok()).encode(env));
    });

    atoms::ok()
}
