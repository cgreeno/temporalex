use prost::Message;
use rustler::{Atom, Binary, Encoder, LocalPid, ResourceArc};
use temporalio_common::protos::coresdk::{
    workflow_completion::WorkflowActivationCompletion, ActivityTaskCompletion,
};
use tracing::error;

use crate::atoms;
use crate::task_guard::TaskGuard;
use crate::worker::WorkerResource;

/// Async NIF — decodes protobuf completion and sends it to the Core SDK.
/// Sends `{:workflow_completion, :ok | {:error, reason}}` to `pid`.
#[rustler::nif]
fn complete_workflow_activation(
    worker: ResourceArc<WorkerResource>,
    bytes: Binary,
    pid: LocalPid,
) -> Atom {
    let data = bytes.as_slice().to_vec();
    let w = worker.worker.clone();
    let handle = worker.runtime_handle.clone();

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, atoms::workflow_completion());

        let completion = match WorkflowActivationCompletion::decode(&data[..]) {
            Ok(c) => c,
            Err(e) => {
                error!(error = %e, "Failed to decode workflow completion");
                guard.complete(|env| {
                    (atoms::workflow_completion(), (atoms::error(), format!("{e}"))).encode(env)
                });
                return;
            }
        };

        match w.complete_workflow_activation(completion).await {
            Ok(()) => {
                guard.complete(|env| (atoms::workflow_completion(), atoms::ok()).encode(env));
            }
            Err(e) => {
                error!(error = %e, "Workflow completion failed");
                guard.complete(|env| {
                    (atoms::workflow_completion(), (atoms::error(), format!("{e}"))).encode(env)
                });
            }
        }
    });

    atoms::ok()
}

/// Async NIF — decodes protobuf completion and sends it to the Core SDK.
/// Sends `{:activity_completion, :ok | {:error, reason}}` to `pid`.
#[rustler::nif]
fn complete_activity_task(
    worker: ResourceArc<WorkerResource>,
    bytes: Binary,
    pid: LocalPid,
) -> Atom {
    let data = bytes.as_slice().to_vec();
    let w = worker.worker.clone();
    let handle = worker.runtime_handle.clone();

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, atoms::activity_completion());

        let completion = match ActivityTaskCompletion::decode(&data[..]) {
            Ok(c) => c,
            Err(e) => {
                error!(error = %e, "Failed to decode activity completion");
                guard.complete(|env| {
                    (atoms::activity_completion(), (atoms::error(), format!("{e}"))).encode(env)
                });
                return;
            }
        };

        match w.complete_activity_task(completion).await {
            Ok(()) => {
                guard.complete(|env| (atoms::activity_completion(), atoms::ok()).encode(env));
            }
            Err(e) => {
                error!(error = %e, "Activity completion failed");
                guard.complete(|env| {
                    (atoms::activity_completion(), (atoms::error(), format!("{e}"))).encode(env)
                });
            }
        }
    });

    atoms::ok()
}

/// Sync NIF — fire-and-forget heartbeat. Core SDK throttles internally.
/// `details_bytes` is a single protobuf-encoded Payload.
#[rustler::nif]
fn record_activity_heartbeat(
    worker: ResourceArc<WorkerResource>,
    task_token: Binary,
    details_bytes: Binary,
) -> Atom {
    use temporalio_common::protos::coresdk::ActivityHeartbeat;
    use temporalio_common::protos::temporal::api::common::v1::Payload;

    let detail = match Payload::decode(details_bytes.as_slice()) {
        Ok(p) => p,
        Err(_) => {
            // If we can't decode, wrap raw bytes as a payload
            Payload {
                data: details_bytes.as_slice().to_vec(),
                ..Default::default()
            }
        }
    };

    let heartbeat = ActivityHeartbeat {
        task_token: task_token.as_slice().to_vec(),
        details: vec![detail],
    };

    worker.worker.record_activity_heartbeat(heartbeat);
    atoms::ok()
}
