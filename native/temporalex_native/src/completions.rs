use prost::Message;
use rustler::{Atom, Binary, Encoder, LocalPid, ResourceArc, Term};
use std::collections::HashMap;
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
/// `details` is a payload map `%{metadata: %{...}, data: bytes}` or `nil`.
#[rustler::nif]
fn record_activity_heartbeat<'a>(
    worker: ResourceArc<WorkerResource>,
    task_token: Binary,
    details: Term<'a>,
) -> Atom {
    use temporalio_common::protos::coresdk::ActivityHeartbeat;
    use temporalio_common::protos::temporal::api::common::v1::Payload;

    // nil → no details. Map → build a Payload with metadata + data.
    let details_vec: Vec<Payload> = if details.is_atom() {
        vec![]
    } else {
        match payload_from_map(details) {
            Some(p) => vec![p],
            None => {
                error!("record_activity_heartbeat: invalid details shape — dropping");
                vec![]
            }
        }
    };

    let heartbeat = ActivityHeartbeat {
        task_token: task_token.as_slice().to_vec(),
        details: details_vec,
    };

    worker.worker.record_activity_heartbeat(heartbeat);
    atoms::ok()
}

// Extract a Payload from an Elixir `%{metadata: %{...}, data: <<bytes>>}` map.
fn payload_from_map(
    term: Term,
) -> Option<temporalio_common::protos::temporal::api::common::v1::Payload> {
    use temporalio_common::protos::temporal::api::common::v1::Payload;

    let env = term.get_env();
    let data_term = term.map_get(atoms::data().encode(env)).ok()?;
    let data_bin: Binary = data_term.decode().ok()?;
    let data: Vec<u8> = data_bin.as_slice().to_vec();

    let mut metadata = HashMap::new();
    if let Ok(meta_term) = term.map_get(atoms::metadata().encode(env)) {
        if let Some(iter) = rustler::MapIterator::new(meta_term) {
            for (k, v) in iter {
                if let Ok(key) = k.decode::<String>() {
                    let val: Vec<u8> =
                        if let Ok(val_bin) = v.decode::<Binary>() {
                            val_bin.as_slice().to_vec()
                        } else if let Ok(val_str) = v.decode::<String>() {
                            val_str.into_bytes()
                        } else {
                            continue;
                        };
                    metadata.insert(key, val);
                }
            }
        }
    }

    Some(Payload {
        metadata,
        data,
        ..Default::default()
    })
}
