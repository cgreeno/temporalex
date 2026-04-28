//! Client operations: start, signal, query, cancel workflows via gRPC.

use prost::Message;
use rustler::{Atom, Binary, Encoder, LocalPid, ResourceArc, Term};
use std::collections::HashMap;
use temporalio_common::protos::temporal::api::{
    common::v1::{Payload, Payloads, WorkflowExecution, WorkflowType},
    enums::v1::TaskQueueKind,
    query::v1::WorkflowQuery,
    taskqueue::v1::TaskQueue,
    workflowservice::v1::*,
};

use crate::atoms;
use crate::client::ClientResource;
use crate::helpers;
use crate::task_guard::TaskGuard;

use temporalio_client::tonic;

/// Disambiguate encode
fn enc<'a, T: Encoder>(val: &T, env: rustler::Env<'a>) -> Term<'a> {
    Encoder::encode(val, env)
}

#[rustler::nif]
fn start_workflow(
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    workflow_type: String,
    task_queue: String,
    input: Term,
    request_id: String,
    // Timeouts in milliseconds. Pass 0 (or negative) to omit a timeout.
    execution_timeout_ms: i64,
    run_timeout_ms: i64,
    task_timeout_ms: i64,
    pid: LocalPid,
) -> Atom {
    let handle = client.runtime_handle.clone();
    let connection = (*client.connection).clone();

    // Build input payloads from Elixir term
    let payloads = if input.is_atom() {
        // nil — no input
        None
    } else {
        // Expect a payload map %{metadata, data}
        let payload = encode_payload_from_nif_term(input);
        payload.map(|p| Payloads { payloads: vec![p] })
    };

    fn ms_to_duration(ms: i64) -> Option<::prost_wkt_types::Duration> {
        if ms <= 0 {
            None
        } else {
            Some(::prost_wkt_types::Duration {
                seconds: ms / 1000,
                nanos: ((ms % 1000) * 1_000_000) as i32,
            })
        }
    }

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, atoms::start_workflow_result());

        let req = StartWorkflowExecutionRequest {
            namespace,
            workflow_id: workflow_id.clone(),
            workflow_type: Some(WorkflowType {
                name: workflow_type,
            }),
            task_queue: Some(TaskQueue {
                name: task_queue,
                kind: TaskQueueKind::Normal as i32,
                normal_name: String::new(),
            }),
            input: payloads,
            request_id,
            identity: format!("temporalex@{}", std::process::id()),
            workflow_execution_timeout: ms_to_duration(execution_timeout_ms),
            workflow_run_timeout: ms_to_duration(run_timeout_ms),
            workflow_task_timeout: ms_to_duration(task_timeout_ms),
            ..Default::default()
        };

        let mut svc = connection.workflow_service();

        match svc.start_workflow_execution(tonic::Request::new(req)).await {
            Ok(resp) => {
                let run_id = resp.into_inner().run_id;
                guard.complete(|env| {
                    enc(&(atoms::start_workflow_result(), (atoms::ok(), run_id.as_str())), env)
                });
            }
            Err(e) => {
                guard.complete(|env| {
                    enc(
                        &(
                            atoms::start_workflow_result(),
                            (atoms::error(), format!("{e}")),
                        ),
                        env,
                    )
                });
            }
        }
    });

    atoms::ok()
}

#[rustler::nif]
fn signal_workflow(
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: String,
    signal_name: String,
    input: Term,
    request_id: String,
    pid: LocalPid,
) -> Atom {
    let handle = client.runtime_handle.clone();
    let connection = (*client.connection).clone();

    let payloads = if input.is_atom() {
        None
    } else {
        encode_payload_from_nif_term(input).map(|p| Payloads { payloads: vec![p] })
    };

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, atoms::signal_workflow_result());

        let req = SignalWorkflowExecutionRequest {
            namespace,
            workflow_execution: Some(WorkflowExecution {
                workflow_id,
                run_id,
            }),
            signal_name,
            input: payloads,
            request_id,
            identity: format!("temporalex@{}", std::process::id()),
            ..Default::default()
        };

        let mut svc = connection.workflow_service();

        match svc.signal_workflow_execution(tonic::Request::new(req)).await {
            Ok(_) => {
                guard.complete(|env| {
                    enc(&(atoms::signal_workflow_result(), atoms::ok()), env)
                });
            }
            Err(e) => {
                guard.complete(|env| {
                    enc(
                        &(
                            atoms::signal_workflow_result(),
                            (atoms::error(), format!("{e}")),
                        ),
                        env,
                    )
                });
            }
        }
    });

    atoms::ok()
}

#[rustler::nif]
fn query_workflow(
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: String,
    query_type: String,
    query_input: Term,
    pid: LocalPid,
) -> Atom {
    let handle = client.runtime_handle.clone();
    let connection = (*client.connection).clone();

    let query_args = if query_input.is_atom() {
        None
    } else {
        encode_payload_from_nif_term(query_input).map(|p| Payloads { payloads: vec![p] })
    };

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, atoms::query_workflow_result());

        let req = QueryWorkflowRequest {
            namespace,
            execution: Some(WorkflowExecution {
                workflow_id,
                run_id,
            }),
            query: Some(WorkflowQuery {
                query_type,
                query_args,
                ..Default::default()
            }),
            ..Default::default()
        };

        let mut svc = connection.workflow_service();

        match svc.query_workflow(tonic::Request::new(req)).await {
            Ok(resp) => {
                let inner = resp.into_inner();
                // Extract result from query_result payloads
                let result_bytes = inner
                    .query_result
                    .and_then(|payloads| payloads.payloads.into_iter().next())
                    .map(|p| p.data)
                    .unwrap_or_default();

                guard.complete(|env| {
                    let bin = helpers::make_binary(env, &result_bytes);
                    enc(&(atoms::query_workflow_result(), (atoms::ok(), bin)), env)
                });
            }
            Err(e) => {
                guard.complete(|env| {
                    enc(
                        &(
                            atoms::query_workflow_result(),
                            (atoms::error(), format!("{e}")),
                        ),
                        env,
                    )
                });
            }
        }
    });

    atoms::ok()
}

#[rustler::nif]
fn cancel_workflow(
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: String,
    reason: String,
    request_id: String,
    pid: LocalPid,
) -> Atom {
    let handle = client.runtime_handle.clone();
    let connection = (*client.connection).clone();

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, atoms::cancel_workflow_result());

        let req = RequestCancelWorkflowExecutionRequest {
            namespace,
            workflow_execution: Some(WorkflowExecution {
                workflow_id,
                run_id,
            }),
            reason,
            request_id,
            identity: format!("temporalex@{}", std::process::id()),
            ..Default::default()
        };

        let mut svc = connection.workflow_service();

        match svc.request_cancel_workflow_execution(tonic::Request::new(req)).await {
            Ok(_) => {
                guard.complete(|env| {
                    enc(&(atoms::cancel_workflow_result(), atoms::ok()), env)
                });
            }
            Err(e) => {
                guard.complete(|env| {
                    enc(
                        &(
                            atoms::cancel_workflow_result(),
                            (atoms::error(), format!("{e}")),
                        ),
                        env,
                    )
                });
            }
        }
    });

    atoms::ok()
}

// Helper: convert an Elixir payload map to a Payload proto.
// Uses atoms::data() and atoms::metadata() for map key lookup.
fn encode_payload_from_nif_term(term: Term) -> Option<Payload> {
    let env = term.get_env();

    let data = term
        .map_get(enc(&atoms::data(), env))
        .ok()?
        .decode::<Binary>()
        .ok()?
        .as_slice()
        .to_vec();

    let mut metadata = HashMap::new();

    if let Ok(meta_term) = term.map_get(enc(&atoms::metadata(), env)) {
        if let Some(iter) = rustler::MapIterator::new(meta_term) {
            for (k, v) in iter {
                if let (Ok(key), Ok(val)) = (k.decode::<String>(), v.decode::<String>()) {
                    metadata.insert(key, val.into_bytes());
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
