use anyhow::anyhow;
use prost::Message;
use rustler::types::elixir_struct::make_ex_struct;
use rustler::types::list::ListIterator;
use rustler::{Atom, Binary, Env, LocalPid, MapIterator, Monitor, NewBinary, OwnedEnv};
use rustler::{Decoder, Encoder, Resource, ResourceArc, Term};
use serde_json::{Number as JsonNumber, Value as JsonValue};
use std::collections::HashMap;
use std::sync::Arc;
use temporalio_client::{
    Client, ClientOptions, Connection, ConnectionOptions, TlsOptions, UntypedQuery, UntypedSignal,
    UntypedUpdate, UntypedWorkflow, WorkflowCancelOptions, WorkflowDescribeOptions,
    WorkflowExecuteUpdateOptions, WorkflowExecutionDescription, WorkflowExecutionInfo,
    WorkflowGetResultOptions, WorkflowHandle, WorkflowQueryOptions, WorkflowSignalOptions,
    WorkflowStartOptions, WorkflowTerminateOptions,
    errors::{
        WorkflowGetResultError, WorkflowInteractionError, WorkflowQueryError, WorkflowStartError,
        WorkflowUpdateError,
    },
};
use temporalio_common::data_converters::RawValue;
use temporalio_common::protos::coresdk::workflow_completion::WorkflowActivationCompletion;
use temporalio_common::protos::coresdk::{ActivityHeartbeat, ActivityTaskCompletion};
use temporalio_common::protos::temporal::api::common::v1::{
    Header, Payload, Payloads, RetryPolicy,
};
use temporalio_common::protos::temporal::api::enums::v1::{
    QueryRejectCondition, RetryState, TimeoutType, WorkflowExecutionStatus,
    WorkflowIdConflictPolicy, WorkflowIdReusePolicy,
};
use temporalio_common::protos::temporal::api::failure::v1::{Failure, failure};
use temporalio_common::worker::WorkerTaskTypes;
use temporalio_sdk_core::{
    CoreRuntime, PollError, PollerBehavior, RuntimeOptions, TokioRuntimeBuilder, Worker,
    WorkerConfig, WorkerVersioningStrategy, init_worker,
};
use url::Url;

rustler::atoms! {
    ok,
    error,
    nil,
    connected,
    connect_error,
    worker_started,
    worker_error,
    workflow_activation,
    activity_task,
    backend_error,
    poll_loop_exited,
    workflow,
    activity,
    shutdown,
    crashed,
    workflow_completion,
    activity_completion,
    shutdown_complete,
    workflow_started,
    workflow_result,
    completed,
    failed,
    cancelled,
    rejected,
    unspecified,
    run_id,
    history_length,
    workflow_type,
    workflow_id,
    headers,
    identity,
    message,
    id,
    activity_id,
    activity_type,
    namespace,
    task_queue,
    source,
    stack_trace,
    cause,
    details,
    type_atom = "type",
    value,
    retryable_question = "retryable?",
    timeout_type,
    last_heartbeat_details,
    retry_state,
    failure_type,
    timeout,
    status_atom = "status",
    workflow_signalled,
    workflow_queried,
    workflow_updated,
    workflow_cancelled,
    workflow_terminated,
    workflow_described,
    terminated,
    timed_out,
    continued_as_new,
    running,
    paused,
    in_progress,
    non_retryable_failure,
    maximum_attempts_reached,
    retry_policy_not_set,
    internal_server_error,
    cancel_requested,
    start_to_close,
    schedule_to_start,
    schedule_to_close,
    heartbeat,
    activity_failure,
    child_workflow_failure,
    timeout_failure,
    cancelled_failure,
    terminated_failure,
    server_failure,
    reset_workflow_failure,
    nexus_operation_failure,
    nexus_handler_failure,
    unknown_failure,
    already_started,
    not_found,
    payload_conversion,
    invalid_options,
    rpc,
    execution_timeout,
    workflow_execution_timeout,
    run_timeout,
    workflow_run_timeout,
    task_timeout,
    workflow_task_timeout,
    cron_schedule,
    search_attributes,
    retry_policy,
    id_reuse_policy,
    workflow_id_reuse_policy,
    id_conflict_policy,
    workflow_id_conflict_policy,
    query_reject_condition,
    reject_condition,
    request_id,
    update_id,
    initial_interval,
    maximum_interval,
    maximum_attempts,
    backoff_coefficient,
    non_retryable_error_types,
    bool_atom = "bool",
    datetime,
    double,
    int,
    keyword,
    keyword_list,
    text,
    allow_duplicate,
    allow_duplicate_failed_only,
    reject_duplicate,
    terminate_if_running,
    fail,
    use_existing,
    terminate_existing,
    none,
    not_open,
    not_completed_cleanly,
    static_summary,
    static_details,
    start_time_ms,
    execution_time_ms,
    close_time_ms,
}

const ETF_ENCODING: &[u8] = b"binary/erlang-eterm";
const JSON_ENCODING: &[u8] = b"json/plain";

pub struct RuntimeResource {
    core: CoreRuntime,
}

impl Resource for RuntimeResource {}

pub struct ClientResource {
    connection: Connection,
    _runtime_handle: tokio::runtime::Handle,
    _runtime: ResourceArc<RuntimeResource>,
}

impl Resource for ClientResource {}

pub struct WorkerResource {
    worker: Arc<Worker>,
    runtime_handle: tokio::runtime::Handle,
    _runtime: ResourceArc<RuntimeResource>,
}

impl Resource for WorkerResource {
    const IMPLEMENTS_DOWN: bool = true;

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        schedule_worker_shutdown(self.worker.clone(), self.runtime_handle.clone());
    }
}

impl Drop for WorkerResource {
    fn drop(&mut self) {
        schedule_worker_shutdown(self.worker.clone(), self.runtime_handle.clone());
    }
}

struct TaskGuard {
    pid: LocalPid,
    failure: GuardFailure,
    completed: bool,
}

enum GuardFailure {
    Connect,
    WorkerStart,
    WorkflowCompletion,
    ActivityCompletion,
    Shutdown,
}

impl TaskGuard {
    fn new(pid: LocalPid, failure: GuardFailure) -> Self {
        Self {
            pid,
            failure,
            completed: false,
        }
    }

    fn complete(mut self) {
        self.completed = true;
    }
}

impl Drop for TaskGuard {
    fn drop(&mut self) {
        if self.completed {
            return;
        }

        let message = "native task dropped before sending a result";
        match self.failure {
            GuardFailure::Connect => send_simple(&self.pid, |env| {
                (connect_error(), message.to_string()).encode(env)
            }),
            GuardFailure::WorkerStart => send_simple(&self.pid, |env| {
                (worker_error(), message.to_string()).encode(env)
            }),
            GuardFailure::WorkflowCompletion => send_simple(&self.pid, |env| {
                (workflow_completion(), (error(), message.to_string())).encode(env)
            }),
            GuardFailure::ActivityCompletion => send_simple(&self.pid, |env| {
                (activity_completion(), (error(), message.to_string())).encode(env)
            }),
            GuardFailure::Shutdown => send_simple(&self.pid, |env| {
                (shutdown_complete(), (error(), message.to_string())).encode(env)
            }),
        }
    }
}

struct PollLoopGuard {
    pid: LocalPid,
    kind: Atom,
    completed: bool,
}

impl PollLoopGuard {
    fn new(pid: LocalPid, kind: Atom) -> Self {
        Self {
            pid,
            kind,
            completed: false,
        }
    }

    fn exit(mut self, reason: Atom) {
        send_simple(&self.pid, |env| {
            (poll_loop_exited(), self.kind, reason).encode(env)
        });
        self.completed = true;
    }
}

impl Drop for PollLoopGuard {
    fn drop(&mut self) {
        if self.completed {
            return;
        }

        send_simple(&self.pid, |env| {
            (poll_loop_exited(), self.kind, crashed()).encode(env)
        });
    }
}

fn send_simple<F>(pid: &LocalPid, build: F)
where
    F: for<'a> FnOnce(Env<'a>) -> Term<'a>,
{
    let mut env = OwnedEnv::new();
    let _ = env.send_and_clear(pid, build);
}

fn send_error(pid: &LocalPid, reason: impl Into<String>) {
    let reason = reason.into();
    send_simple(pid, |env| (backend_error(), reason).encode(env));
}

fn binary_term<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.copy_from_slice(bytes);
    Term::from(binary)
}

fn string_term<'a>(env: Env<'a>, value: impl Into<String>) -> Term<'a> {
    let value = value.into();
    rustler::Encoder::encode(&value, env)
}

fn i64_term<'a>(env: Env<'a>, value: i64) -> Term<'a> {
    rustler::Encoder::encode(&value, env)
}

fn nif_error(err: rustler::Error) -> anyhow::Error {
    anyhow!("rustler term error: {err:?}")
}

fn map_put<'a, K, V>(map: Term<'a>, key: K, value: V) -> anyhow::Result<Term<'a>>
where
    K: Encoder,
    V: Encoder,
{
    map.map_put(key, value).map_err(nif_error)
}

fn map_get<'a, K>(map: Term<'a>, key: K) -> anyhow::Result<Term<'a>>
where
    K: Encoder,
{
    map.map_get(key).map_err(nif_error)
}

fn decode_term<'a, T>(term: Term<'a>) -> anyhow::Result<T>
where
    T: Decoder<'a>,
{
    term.decode().map_err(nif_error)
}

macro_rules! put_fields {
    ($map:expr $(, $key:expr => $value:expr)+ $(,)?) => {{
        let mut map = $map;
        $(
            map = map_put(map, $key, $value)?;
        )+
        Ok::<_, anyhow::Error>(map)
    }};
}

#[rustler::nif]
fn create_runtime<'a>(env: Env<'a>) -> Term<'a> {
    match CoreRuntime::new(RuntimeOptions::default(), TokioRuntimeBuilder::default()) {
        Ok(runtime) => (ok(), ResourceArc::new(RuntimeResource { core: runtime })).encode(env),
        Err(err) => (error(), format!("{err:#}")).encode(env),
    }
}

#[rustler::nif]
fn connect(
    runtime: ResourceArc<RuntimeResource>,
    target: String,
    api_key: Option<String>,
    headers: HashMap<String, String>,
    pid: LocalPid,
) -> Atom {
    let handle = runtime.core.tokio_handle();
    let runtime_for_resource = runtime.clone();
    let headers = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    handle.clone().spawn(async move {
        let guard = TaskGuard::new(pid, GuardFailure::Connect);
        let result = async {
            let url = parse_target_url(&target)?;
            let tls = if url.scheme() == "https" {
                Some(TlsOptions::default())
            } else {
                None
            };

            let connection_options = ConnectionOptions::new(url)
                .identity(format!("temporalex-{}", std::process::id()))
                .maybe_api_key(api_key)
                .maybe_headers(headers)
                .maybe_tls_options(tls)
                .client_name("temporalex".to_string())
                .client_version(env!("CARGO_PKG_VERSION").to_string())
                .build();

            let connection = Connection::connect(connection_options).await?;
            Ok::<_, anyhow::Error>(connection)
        }
        .await;

        match result {
            Ok(connection) => {
                let client = ResourceArc::new(ClientResource {
                    connection,
                    _runtime_handle: handle.clone(),
                    _runtime: runtime_for_resource,
                });

                send_simple(&pid, |env| (connected(), client).encode(env));
            }
            Err(err) => {
                send_simple(&pid, |env| {
                    (connect_error(), format!("{err:#}")).encode(env)
                });
            }
        }

        guard.complete();
    });

    ok()
}

#[rustler::nif]
fn start_worker(
    runtime: ResourceArc<RuntimeResource>,
    client: ResourceArc<ClientResource>,
    task_queue: String,
    namespace: String,
    max_wf: usize,
    max_act: usize,
    pid: LocalPid,
    poll_pid: LocalPid,
) -> Atom {
    let handle = runtime.core.tokio_handle();
    let runtime_for_worker = runtime.clone();
    let client_connection = client.connection.clone();

    handle.clone().spawn(async move {
        let guard = TaskGuard::new(pid, GuardFailure::WorkerStart);
        let result = async {
            let config = WorkerConfig::builder()
                .namespace(namespace)
                .task_queue(task_queue)
                .versioning_strategy(WorkerVersioningStrategy::None {
                    build_id: format!("temporalex-{}", env!("CARGO_PKG_VERSION")),
                })
                .ignore_evicts_on_shutdown(true)
                .task_types(WorkerTaskTypes::all())
                .workflow_task_poller_behavior(PollerBehavior::SimpleMaximum(max_wf.max(1)))
                .activity_task_poller_behavior(PollerBehavior::SimpleMaximum(max_act.max(1)))
                .build()
                .map_err(|err| anyhow!(err))?;

            let worker = init_worker(&runtime.core, config, client_connection)?;
            worker.validate().await?;
            Ok::<_, anyhow::Error>(worker)
        }
        .await;

        match result {
            Ok(worker) => {
                let worker = Arc::new(worker);
                let resource = ResourceArc::new(WorkerResource {
                    worker: worker.clone(),
                    runtime_handle: handle.clone(),
                    _runtime: runtime_for_worker,
                });

                let _ = resource.monitor(None, &pid);
                start_poll_loops(resource.clone(), poll_pid);
                send_simple(&pid, |env| (worker_started(), resource).encode(env));
            }
            Err(err) => {
                send_simple(&pid, |env| (worker_error(), format!("{err:#}")).encode(env));
            }
        }

        guard.complete();
    });

    ok()
}

#[rustler::nif]
fn complete_workflow_activation(
    worker: ResourceArc<WorkerResource>,
    bytes: Binary,
    pid: LocalPid,
) -> Atom {
    let bytes = bytes.as_slice().to_vec();
    let handle = worker.runtime_handle.clone();
    let worker_ref = worker.worker.clone();

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, GuardFailure::WorkflowCompletion);
        let result = async {
            let completion = WorkflowActivationCompletion::decode(bytes.as_slice())?;
            worker_ref.complete_workflow_activation(completion).await?;
            Ok::<_, anyhow::Error>(())
        }
        .await;

        send_simple(&pid, |env| match result {
            Ok(()) => (workflow_completion(), ok()).encode(env),
            Err(err) => (workflow_completion(), (error(), format!("{err:#}"))).encode(env),
        });

        guard.complete();
    });

    ok()
}

#[rustler::nif]
fn complete_activity_task(
    worker: ResourceArc<WorkerResource>,
    bytes: Binary,
    pid: LocalPid,
) -> Atom {
    let bytes = bytes.as_slice().to_vec();
    let handle = worker.runtime_handle.clone();
    let worker_ref = worker.worker.clone();

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, GuardFailure::ActivityCompletion);
        let result = async {
            let completion = ActivityTaskCompletion::decode(bytes.as_slice())?;
            worker_ref.complete_activity_task(completion).await?;
            Ok::<_, anyhow::Error>(())
        }
        .await;

        send_simple(&pid, |env| match result {
            Ok(()) => (activity_completion(), ok()).encode(env),
            Err(err) => (activity_completion(), (error(), format!("{err:#}"))).encode(env),
        });

        guard.complete();
    });

    ok()
}

#[rustler::nif]
fn record_activity_heartbeat<'a>(
    env: Env<'a>,
    worker: ResourceArc<WorkerResource>,
    bytes: Binary,
) -> Term<'a> {
    match ActivityHeartbeat::decode(bytes.as_slice()) {
        Ok(heartbeat) => {
            worker.worker.record_activity_heartbeat(heartbeat);
            ok().encode(env)
        }
        Err(err) => (error(), format!("{err:#}")).encode(env),
    }
}

#[rustler::nif]
fn initiate_shutdown(worker: ResourceArc<WorkerResource>) -> Atom {
    schedule_worker_shutdown(worker.worker.clone(), worker.runtime_handle.clone());
    ok()
}

#[rustler::nif]
fn shutdown_worker(worker: ResourceArc<WorkerResource>, pid: LocalPid) -> Atom {
    let handle = worker.runtime_handle.clone();
    let worker_ref = worker.worker.clone();

    handle.spawn(async move {
        let guard = TaskGuard::new(pid, GuardFailure::Shutdown);
        worker_ref.initiate_shutdown();
        worker_ref.shutdown().await;
        send_simple(&pid, |env| (shutdown_complete(), ok()).encode(env));
        guard.complete();
    });

    ok()
}

#[rustler::nif]
fn start_workflow<'a>(
    env: Env<'a>,
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    workflow_type: String,
    task_queue: String,
    input: Term<'a>,
    opts: Term<'a>,
    pid: LocalPid,
    reference: Term<'a>,
) -> Atom {
    let input_payload = payload_from_term(input);
    let start_options = match workflow_start_options(task_queue, workflow_id.clone(), opts) {
        Ok(options) => options,
        Err(err) => {
            send_immediate_ref_error(
                env,
                reference,
                &pid,
                workflow_started(),
                error_reason(env, invalid_options(), format!("{err:#}")),
            );
            return ok();
        }
    };
    let connection = client.connection.clone();
    let handle = client._runtime_handle.clone();
    let saved_env = OwnedEnv::new();
    let saved_ref = saved_env.save(reference);

    handle.spawn(async move {
        let result = async {
            let client = Client::new(connection, ClientOptions::new(namespace.clone()).build())
                .map_err(|err| StartWorkflowResult::Other(format!("{err:#}")))?;
            let workflow = UntypedWorkflow::new(workflow_type.clone());
            let handle = client
                .start_workflow(workflow, RawValue::new(vec![input_payload]), start_options)
                .await
                .map_err(StartWorkflowResult::Start)?;
            let run_id = handle.info().run_id.clone().unwrap_or_default();
            Ok::<_, StartWorkflowResult>((workflow_id, workflow_type, run_id))
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_started(),
            |env| match result {
                Ok((workflow_id, workflow_type, run_id)) => {
                    let map = Term::map_new(env)
                        .map_put(crate::workflow_id(), workflow_id)
                        .unwrap()
                        .map_put(crate::workflow_type(), workflow_type)
                        .unwrap()
                        .map_put(crate::run_id(), run_id)
                        .unwrap();
                    (ok(), map).encode(env)
                }
                Err(err) => (error(), workflow_start_error_to_term(env, err)).encode(env),
            },
        );
    });

    ok()
}

#[rustler::nif]
fn get_workflow_result(
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: Option<String>,
    pid: LocalPid,
    reference: Term,
) -> Atom {
    let connection = client.connection.clone();
    let handle = client._runtime_handle.clone();
    let saved_env = OwnedEnv::new();
    let saved_ref = saved_env.save(reference);

    handle.spawn(async move {
        let result = async {
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)
                .map_err(GetWorkflowResult::Other)?;
            let raw = wf
                .get_result(WorkflowGetResultOptions::default())
                .await
                .map_err(GetWorkflowResult::Get)?;
            Ok::<_, GetWorkflowResult>(raw.payloads)
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_result(),
            |env| match result {
                Ok(payloads) => match payloads.into_iter().next() {
                    Some(payload) => match payload_to_term(env, &payload) {
                        Ok(term) => (ok(), term).encode(env),
                        Err(err) => (
                            error(),
                            error_reason(env, payload_conversion(), format!("{err:#}")),
                        )
                            .encode(env),
                    },
                    None => (ok(), nil()).encode(env),
                },
                Err(err) => (error(), get_workflow_result_error_to_term(env, err)).encode(env),
            },
        );
    });

    ok()
}

#[rustler::nif]
fn signal_workflow<'a>(
    env: Env<'a>,
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: Option<String>,
    signal_name: String,
    args_term: Term<'a>,
    opts: Term<'a>,
    pid: LocalPid,
    reference: Term<'a>,
) -> Atom {
    let payloads = match terms_list_to_payloads(args_term) {
        Ok(payloads) => payloads,
        Err(err) => {
            send_immediate_ref_error(
                env,
                reference,
                &pid,
                workflow_signalled(),
                error_reason(env, payload_conversion(), format!("{err:#}")),
            );
            return ok();
        }
    };
    let options = match signal_options(opts) {
        Ok(options) => options,
        Err(err) => {
            send_immediate_ref_error(
                env,
                reference,
                &pid,
                workflow_signalled(),
                error_reason(env, invalid_options(), format!("{err:#}")),
            );
            return ok();
        }
    };
    let connection = client.connection.clone();
    let handle = client._runtime_handle.clone();
    let saved_env = OwnedEnv::new();
    let saved_ref = saved_env.save(reference);

    handle.spawn(async move {
        let result = async {
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)
                .map_err(WorkflowInteractionResult::Other)?;
            wf.signal(
                UntypedSignal::<UntypedWorkflow>::new(signal_name),
                RawValue::new(payloads),
                options,
            )
            .await
            .map_err(WorkflowInteractionResult::Interaction)?;
            Ok::<_, WorkflowInteractionResult>(())
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_signalled(),
            |env| match result {
                Ok(()) => (ok(), ok()).encode(env),
                Err(err) => (error(), workflow_interaction_error_to_term(env, err)).encode(env),
            },
        );
    });

    ok()
}

#[rustler::nif]
fn query_workflow<'a>(
    env: Env<'a>,
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: Option<String>,
    query_name: String,
    args_term: Term<'a>,
    opts: Term<'a>,
    pid: LocalPid,
    reference: Term<'a>,
) -> Atom {
    let payloads = match terms_list_to_payloads(args_term) {
        Ok(payloads) => payloads,
        Err(err) => {
            send_immediate_ref_error(
                env,
                reference,
                &pid,
                workflow_queried(),
                error_reason(env, payload_conversion(), format!("{err:#}")),
            );
            return ok();
        }
    };
    let options = match query_options(opts) {
        Ok(options) => options,
        Err(err) => {
            send_immediate_ref_error(
                env,
                reference,
                &pid,
                workflow_queried(),
                error_reason(env, invalid_options(), format!("{err:#}")),
            );
            return ok();
        }
    };
    let connection = client.connection.clone();
    let handle = client._runtime_handle.clone();
    let saved_env = OwnedEnv::new();
    let saved_ref = saved_env.save(reference);

    handle.spawn(async move {
        let result = async {
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)
                .map_err(QueryWorkflowResult::Other)?;
            let raw = wf
                .query(
                    UntypedQuery::<UntypedWorkflow>::new(query_name),
                    RawValue::new(payloads),
                    options,
                )
                .await
                .map_err(QueryWorkflowResult::Query)?;
            Ok::<_, QueryWorkflowResult>(raw.payloads)
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_queried(),
            |env| match result {
                Ok(payloads) => payload_result_to_term(env, payloads),
                Err(err) => (error(), query_workflow_error_to_term(env, err)).encode(env),
            },
        );
    });

    ok()
}

#[rustler::nif]
fn update_workflow<'a>(
    env: Env<'a>,
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: Option<String>,
    update_name: String,
    args_term: Term<'a>,
    opts: Term<'a>,
    pid: LocalPid,
    reference: Term<'a>,
) -> Atom {
    let payloads = match terms_list_to_payloads(args_term) {
        Ok(payloads) => payloads,
        Err(err) => {
            send_immediate_ref_error(
                env,
                reference,
                &pid,
                workflow_updated(),
                error_reason(env, payload_conversion(), format!("{err:#}")),
            );
            return ok();
        }
    };
    let options = match update_options(opts) {
        Ok(options) => options,
        Err(err) => {
            send_immediate_ref_error(
                env,
                reference,
                &pid,
                workflow_updated(),
                error_reason(env, invalid_options(), format!("{err:#}")),
            );
            return ok();
        }
    };
    let connection = client.connection.clone();
    let handle = client._runtime_handle.clone();
    let saved_env = OwnedEnv::new();
    let saved_ref = saved_env.save(reference);

    handle.spawn(async move {
        let result = async {
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)
                .map_err(UpdateWorkflowResult::Other)?;
            let raw = wf
                .execute_update(
                    UntypedUpdate::<UntypedWorkflow>::new(update_name),
                    RawValue::new(payloads),
                    options,
                )
                .await
                .map_err(UpdateWorkflowResult::Update)?;
            Ok::<_, UpdateWorkflowResult>(raw.payloads)
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_updated(),
            |env| match result {
                Ok(payloads) => payload_result_to_term(env, payloads),
                Err(err) => (error(), update_workflow_error_to_term(env, err)).encode(env),
            },
        );
    });

    ok()
}

#[rustler::nif]
fn cancel_workflow(
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: Option<String>,
    reason_text: String,
    request_id_text: Option<String>,
    pid: LocalPid,
    reference: Term,
) -> Atom {
    let connection = client.connection.clone();
    let handle = client._runtime_handle.clone();
    let saved_env = OwnedEnv::new();
    let saved_ref = saved_env.save(reference);

    handle.spawn(async move {
        let result = async {
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)
                .map_err(WorkflowInteractionResult::Other)?;
            let mut options = WorkflowCancelOptions::default();
            options.reason = reason_text;
            options.request_id = request_id_text;
            wf.cancel(options)
                .await
                .map_err(WorkflowInteractionResult::Interaction)?;
            Ok::<_, WorkflowInteractionResult>(())
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_cancelled(),
            |env| match result {
                Ok(()) => (ok(), ok()).encode(env),
                Err(err) => (error(), workflow_interaction_error_to_term(env, err)).encode(env),
            },
        );
    });

    ok()
}

#[rustler::nif]
fn terminate_workflow(
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: Option<String>,
    reason_text: String,
    details_term: Term,
    pid: LocalPid,
    reference: Term,
) -> Atom {
    let details = if details_term.decode::<Atom>().ok() == Some(nil()) {
        None
    } else {
        Some(Payloads {
            payloads: vec![payload_from_term(details_term)],
        })
    };
    let connection = client.connection.clone();
    let handle = client._runtime_handle.clone();
    let saved_env = OwnedEnv::new();
    let saved_ref = saved_env.save(reference);

    handle.spawn(async move {
        let result = async {
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)
                .map_err(WorkflowInteractionResult::Other)?;
            let mut options = WorkflowTerminateOptions::default();
            options.reason = reason_text;
            options.details = details;
            wf.terminate(options)
                .await
                .map_err(WorkflowInteractionResult::Interaction)?;
            Ok::<_, WorkflowInteractionResult>(())
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_terminated(),
            |env| match result {
                Ok(()) => (ok(), ok()).encode(env),
                Err(err) => (error(), workflow_interaction_error_to_term(env, err)).encode(env),
            },
        );
    });

    ok()
}

#[rustler::nif]
fn describe_workflow(
    client: ResourceArc<ClientResource>,
    namespace: String,
    workflow_id: String,
    run_id: Option<String>,
    pid: LocalPid,
    reference: Term,
) -> Atom {
    let connection = client.connection.clone();
    let handle = client._runtime_handle.clone();
    let saved_env = OwnedEnv::new();
    let saved_ref = saved_env.save(reference);

    handle.spawn(async move {
        let result = async {
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)
                .map_err(WorkflowInteractionResult::Other)?;
            let description = wf
                .describe(WorkflowDescribeOptions::default())
                .await
                .map_err(WorkflowInteractionResult::Interaction)?;
            Ok::<_, WorkflowInteractionResult>(description)
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_described(),
            |env| match result {
                Ok(description) => match workflow_description_to_term(env, &description) {
                    Ok(term) => (ok(), term).encode(env),
                    Err(err) => (
                        error(),
                        error_reason(env, payload_conversion(), format!("{err:#}")),
                    )
                        .encode(env),
                },
                Err(err) => (error(), workflow_interaction_error_to_term(env, err)).encode(env),
            },
        );
    });

    ok()
}

fn parse_target_url(target: &str) -> anyhow::Result<Url> {
    if target.contains("://") {
        Ok(Url::parse(target)?)
    } else {
        Ok(Url::parse(&format!("http://{target}"))?)
    }
}

fn schedule_worker_shutdown(worker: Arc<Worker>, handle: tokio::runtime::Handle) {
    handle.spawn(async move {
        worker.initiate_shutdown();
    });
}

fn start_poll_loops(worker: ResourceArc<WorkerResource>, pid: LocalPid) {
    let workflow_worker = worker.clone();
    let workflow_pid = pid;
    worker.runtime_handle.spawn(async move {
        let guard = PollLoopGuard::new(workflow_pid, workflow());
        loop {
            match workflow_worker.worker.poll_workflow_activation().await {
                Ok(activation) => {
                    let bytes = activation.encode_to_vec();
                    send_simple(&workflow_pid, |env| {
                        (workflow_activation(), binary_term(env, &bytes)).encode(env)
                    });
                }
                Err(PollError::ShutDown) => {
                    guard.exit(shutdown());
                    break;
                }
                Err(err) => {
                    send_error(&workflow_pid, format!("workflow poll loop failed: {err:?}"));
                    guard.exit(crashed());
                    break;
                }
            }
        }
    });

    let activity_worker = worker.clone();
    let activity_pid = pid;
    worker.runtime_handle.spawn(async move {
        let guard = PollLoopGuard::new(activity_pid, activity());
        loop {
            match activity_worker.worker.poll_activity_task().await {
                Ok(task) => {
                    let bytes = task.encode_to_vec();
                    send_simple(&activity_pid, |env| {
                        (activity_task(), binary_term(env, &bytes)).encode(env)
                    });
                }
                Err(PollError::ShutDown) => {
                    guard.exit(shutdown());
                    break;
                }
                Err(err) => {
                    send_error(&activity_pid, format!("activity poll loop failed: {err:?}"));
                    guard.exit(crashed());
                    break;
                }
            }
        }
    });
}

fn send_ref_result<F>(
    saved_env: OwnedEnv,
    saved_ref: rustler::env::SavedTerm,
    pid: &LocalPid,
    tag: Atom,
    build_result: F,
) where
    F: for<'a> FnOnce(Env<'a>) -> Term<'a>,
{
    let mut saved_env = saved_env;
    let _ = saved_env.send_and_clear(pid, |env| {
        let reference = saved_ref.load(env);
        (tag, reference, build_result(env)).encode(env)
    });
}

fn send_immediate_ref_error<'a>(
    env: Env<'a>,
    reference: Term<'a>,
    pid: &LocalPid,
    tag: Atom,
    reason: Term<'a>,
) {
    let _ = env.send(pid, (tag, reference, (error(), reason)));
}

enum StartWorkflowResult {
    Start(WorkflowStartError),
    Other(String),
}

enum GetWorkflowResult {
    Get(WorkflowGetResultError),
    Other(anyhow::Error),
}

enum QueryWorkflowResult {
    Query(WorkflowQueryError),
    Other(anyhow::Error),
}

enum UpdateWorkflowResult {
    Update(WorkflowUpdateError),
    Other(anyhow::Error),
}

enum WorkflowInteractionResult {
    Interaction(WorkflowInteractionError),
    Other(anyhow::Error),
}

fn untyped_handle(
    connection: Connection,
    namespace: String,
    workflow_id: String,
    run_id: Option<String>,
) -> anyhow::Result<WorkflowHandle<Client, UntypedWorkflow>> {
    let client = Client::new(connection, ClientOptions::new(namespace.clone()).build())?;
    Ok(WorkflowHandle::<Client, UntypedWorkflow>::new(
        client,
        WorkflowExecutionInfo {
            namespace,
            workflow_id,
            run_id: run_id.clone(),
            first_execution_run_id: run_id,
        },
    ))
}

fn payload_result_to_term<'a>(env: Env<'a>, payloads: Vec<Payload>) -> Term<'a> {
    match payloads.into_iter().next() {
        Some(payload) => match payload_to_term(env, &payload) {
            Ok(term) => (ok(), term).encode(env),
            Err(err) => (
                error(),
                error_reason(env, payload_conversion(), format!("{err:#}")),
            )
                .encode(env),
        },
        None => (ok(), nil()).encode(env),
    }
}

fn error_reason<'a>(env: Env<'a>, tag: Atom, message: String) -> Term<'a> {
    (tag, string_term(env, message)).encode(env)
}

fn workflow_start_error_to_term<'a>(env: Env<'a>, err: StartWorkflowResult) -> Term<'a> {
    match err {
        StartWorkflowResult::Start(WorkflowStartError::AlreadyStarted { run_id, .. }) => {
            let run_id_term = run_id
                .map(|id| string_term(env, id))
                .unwrap_or_else(|| nil().encode(env));
            (already_started(), run_id_term).encode(env)
        }
        StartWorkflowResult::Start(WorkflowStartError::PayloadConversion(err)) => {
            error_reason(env, payload_conversion(), format!("{err:#}"))
        }
        StartWorkflowResult::Start(WorkflowStartError::Rpc(err)) => {
            error_reason(env, rpc(), format!("{err:#}"))
        }
        StartWorkflowResult::Start(err) => error_reason(env, rpc(), format!("{err:#}")),
        StartWorkflowResult::Other(reason) => error_reason(env, rpc(), reason),
    }
}

fn get_workflow_result_error_to_term<'a>(env: Env<'a>, err: GetWorkflowResult) -> Term<'a> {
    match err {
        GetWorkflowResult::Get(WorkflowGetResultError::Failed(failure)) => {
            match failure_to_term(env, Some(failure.as_ref())) {
                Ok(term) => (failed(), term).encode(env),
                Err(err) => error_reason(env, payload_conversion(), format!("{err:#}")),
            }
        }
        GetWorkflowResult::Get(WorkflowGetResultError::Cancelled { details }) => {
            match payloads_to_terms(env, &details) {
                Ok(terms) => (cancelled(), terms).encode(env),
                Err(err) => error_reason(env, payload_conversion(), format!("{err:#}")),
            }
        }
        GetWorkflowResult::Get(WorkflowGetResultError::Terminated { details }) => {
            match payloads_to_terms(env, &details) {
                Ok(terms) => (terminated(), terms).encode(env),
                Err(err) => error_reason(env, payload_conversion(), format!("{err:#}")),
            }
        }
        GetWorkflowResult::Get(WorkflowGetResultError::TimedOut) => timed_out().encode(env),
        GetWorkflowResult::Get(WorkflowGetResultError::ContinuedAsNew) => {
            continued_as_new().encode(env)
        }
        GetWorkflowResult::Get(WorkflowGetResultError::NotFound(_)) => not_found().encode(env),
        GetWorkflowResult::Get(WorkflowGetResultError::PayloadConversion(err)) => {
            error_reason(env, payload_conversion(), format!("{err:#}"))
        }
        GetWorkflowResult::Get(WorkflowGetResultError::Rpc(err)) => {
            error_reason(env, rpc(), format!("{err:#}"))
        }
        GetWorkflowResult::Get(err) => error_reason(env, rpc(), format!("{err:#}")),
        GetWorkflowResult::Other(err) => error_reason(env, rpc(), format!("{err:#}")),
    }
}

fn query_workflow_error_to_term<'a>(env: Env<'a>, err: QueryWorkflowResult) -> Term<'a> {
    match err {
        QueryWorkflowResult::Query(WorkflowQueryError::Rejected(query_rejected)) => {
            let status = WorkflowExecutionStatus::try_from(query_rejected.status)
                .unwrap_or(WorkflowExecutionStatus::Unspecified);
            (rejected(), workflow_status_atom(status)).encode(env)
        }
        QueryWorkflowResult::Query(WorkflowQueryError::NotFound(_)) => not_found().encode(env),
        QueryWorkflowResult::Query(WorkflowQueryError::PayloadConversion(err)) => {
            error_reason(env, payload_conversion(), format!("{err:#}"))
        }
        QueryWorkflowResult::Query(WorkflowQueryError::Rpc(err)) => {
            error_reason(env, rpc(), format!("{err:#}"))
        }
        QueryWorkflowResult::Query(err) => error_reason(env, rpc(), format!("{err:#}")),
        QueryWorkflowResult::Other(err) => error_reason(env, rpc(), format!("{err:#}")),
    }
}

fn update_workflow_error_to_term<'a>(env: Env<'a>, err: UpdateWorkflowResult) -> Term<'a> {
    match err {
        UpdateWorkflowResult::Update(WorkflowUpdateError::Failed(failure)) => {
            match failure_to_term(env, Some(failure.as_ref())) {
                Ok(term) => (failed(), term).encode(env),
                Err(err) => error_reason(env, payload_conversion(), format!("{err:#}")),
            }
        }
        UpdateWorkflowResult::Update(WorkflowUpdateError::NotFound(_)) => not_found().encode(env),
        UpdateWorkflowResult::Update(WorkflowUpdateError::PayloadConversion(err)) => {
            error_reason(env, payload_conversion(), format!("{err:#}"))
        }
        UpdateWorkflowResult::Update(WorkflowUpdateError::Rpc(err)) => {
            error_reason(env, rpc(), format!("{err:#}"))
        }
        UpdateWorkflowResult::Update(err) => error_reason(env, rpc(), format!("{err:#}")),
        UpdateWorkflowResult::Other(err) => error_reason(env, rpc(), format!("{err:#}")),
    }
}

fn workflow_interaction_error_to_term<'a>(
    env: Env<'a>,
    err: WorkflowInteractionResult,
) -> Term<'a> {
    match err {
        WorkflowInteractionResult::Interaction(WorkflowInteractionError::NotFound(_)) => {
            not_found().encode(env)
        }
        WorkflowInteractionResult::Interaction(WorkflowInteractionError::PayloadConversion(
            err,
        )) => error_reason(env, payload_conversion(), format!("{err:#}")),
        WorkflowInteractionResult::Interaction(WorkflowInteractionError::Rpc(err)) => {
            error_reason(env, rpc(), format!("{err:#}"))
        }
        WorkflowInteractionResult::Interaction(err) => error_reason(env, rpc(), format!("{err:#}")),
        WorkflowInteractionResult::Other(err) => error_reason(env, rpc(), format!("{err:#}")),
    }
}

fn workflow_description_to_term<'a>(
    env: Env<'a>,
    description: &WorkflowExecutionDescription,
) -> anyhow::Result<Term<'a>> {
    put_fields!(
        Term::map_new(env),
        workflow_id() => description.id().to_string(),
        run_id() => description.run_id().to_string(),
        workflow_type() => description.workflow_type().to_string(),
        status_atom() => workflow_status_atom(description.status()),
        task_queue() => description.task_queue().to_string(),
        history_length() => description.history_length() as i64,
        start_time_ms() => option_i64_term(env, description.start_time().and_then(system_time_to_millis)),
        execution_time_ms() => option_i64_term(env, description.execution_time().and_then(system_time_to_millis)),
        close_time_ms() => option_i64_term(env, description.close_time().and_then(system_time_to_millis)),
    )
}

fn option_i64_term<'a>(env: Env<'a>, value: Option<i64>) -> Term<'a> {
    match value {
        Some(value) => i64_term(env, value),
        None => nil().encode(env),
    }
}

fn system_time_to_millis(time: std::time::SystemTime) -> Option<i64> {
    time.duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_millis() as i64)
}

fn workflow_status_atom(status: WorkflowExecutionStatus) -> Atom {
    match status {
        WorkflowExecutionStatus::Running => running(),
        WorkflowExecutionStatus::Completed => completed(),
        WorkflowExecutionStatus::Failed => failed(),
        WorkflowExecutionStatus::Canceled => cancelled(),
        WorkflowExecutionStatus::Terminated => terminated(),
        WorkflowExecutionStatus::ContinuedAsNew => continued_as_new(),
        WorkflowExecutionStatus::TimedOut => timed_out(),
        WorkflowExecutionStatus::Paused => paused(),
        WorkflowExecutionStatus::Unspecified => unspecified(),
    }
}

fn payload_from_bytes(data: Vec<u8>) -> Payload {
    Payload {
        metadata: HashMap::from([("encoding".to_string(), ETF_ENCODING.to_vec())]),
        data,
        external_payloads: vec![],
    }
}

fn payload_from_term(term: Term) -> Payload {
    payload_from_bytes(term.to_binary().as_slice().to_vec())
}

fn json_payload_from_value(value: JsonValue) -> anyhow::Result<Payload> {
    Ok(Payload {
        metadata: HashMap::from([("encoding".to_string(), JSON_ENCODING.to_vec())]),
        data: serde_json::to_vec(&value)?,
        external_payloads: vec![],
    })
}

fn payload_to_term<'a>(env: Env<'a>, payload: &Payload) -> anyhow::Result<Term<'a>> {
    let data = payload.data.as_slice();
    if data.is_empty() {
        return Ok(nil().encode(env));
    }

    let (term, _read) = env
        .binary_to_term(data)
        .ok_or_else(|| anyhow!("payload is not ETF encoded"))?;
    Ok(term)
}

fn payloads_to_terms<'a>(env: Env<'a>, payloads: &[Payload]) -> anyhow::Result<Vec<Term<'a>>> {
    payloads
        .iter()
        .map(|payload| payload_to_term(env, payload))
        .collect()
}

fn failure_to_term<'a>(env: Env<'a>, failure: Option<&Failure>) -> anyhow::Result<Term<'a>> {
    let Some(failure) = failure else {
        return Ok(nil().encode(env));
    };

    let cause_term = failure_to_term(env, failure.cause.as_deref())?;

    match &failure.failure_info {
        Some(failure::FailureInfo::ApplicationFailureInfo(info)) => put_fields!(
            make_struct(env, "Elixir.Temporalex.Failure.ApplicationError")?,
            message() => failure.message.clone(),
            source() => failure.source.clone(),
            stack_trace() => failure.stack_trace.clone(),
            type_atom() => info.r#type.clone(),
            details() => payloads_to_terms_option(env, info.details.as_ref())?,
            retryable_question() => !info.non_retryable,
            cause() => cause_term,
        ),
        Some(failure::FailureInfo::CanceledFailureInfo(info)) => put_fields!(
            make_struct(env, "Elixir.Temporalex.Failure.CancelledError")?,
            message() => failure.message.clone(),
            source() => failure.source.clone(),
            stack_trace() => failure.stack_trace.clone(),
            identity() => info.identity.clone(),
            details() => payloads_to_terms_option(env, info.details.as_ref())?,
            cause() => cause_term,
        ),
        Some(failure::FailureInfo::TimeoutFailureInfo(info)) => put_fields!(
            make_struct(env, "Elixir.Temporalex.Failure.TimeoutError")?,
            message() => failure.message.clone(),
            source() => failure.source.clone(),
            stack_trace() => failure.stack_trace.clone(),
            timeout_type() => timeout_type_atom(info.timeout_type()),
            last_heartbeat_details() => payloads_to_terms_option(env, info.last_heartbeat_details.as_ref())?,
            cause() => cause_term,
        ),
        Some(failure::FailureInfo::ActivityFailureInfo(info)) => put_fields!(
            make_struct(env, "Elixir.Temporalex.Failure.ActivityError")?,
            message() => failure.message.clone(),
            source() => failure.source.clone(),
            stack_trace() => failure.stack_trace.clone(),
            identity() => info.identity.clone(),
            activity_id() => info.activity_id.clone(),
            activity_type() => info.activity_type.as_ref().map(|activity_type| activity_type.name.clone()).unwrap_or_default(),
            retry_state() => retry_state_atom(info.retry_state()),
            cause() => cause_term,
        ),
        Some(failure::FailureInfo::ChildWorkflowExecutionFailureInfo(info)) => {
            let execution = info.workflow_execution.as_ref();
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Failure.WorkflowExecutionError")?,
                message() => failure.message.clone(),
                source() => failure.source.clone(),
                stack_trace() => failure.stack_trace.clone(),
                namespace() => info.namespace.clone(),
                workflow_id() => execution.map(|execution| execution.workflow_id.clone()).unwrap_or_default(),
                run_id() => execution.map(|execution| execution.run_id.clone()).unwrap_or_default(),
                workflow_type() => info.workflow_type.as_ref().map(|workflow_type| workflow_type.name.clone()).unwrap_or_default(),
                retry_state() => retry_state_atom(info.retry_state()),
                cause() => cause_term,
            )
        }
        other => put_fields!(
            make_struct(env, "Elixir.Temporalex.Failure.UnknownError")?,
            message() => failure.message.clone(),
            source() => failure.source.clone(),
            stack_trace() => failure.stack_trace.clone(),
            failure_type() => failure_info_type_atom(other),
            cause() => cause_term,
        ),
    }
}

fn payloads_to_terms_option<'a>(
    env: Env<'a>,
    payloads: Option<&Payloads>,
) -> anyhow::Result<Vec<Term<'a>>> {
    payloads
        .map(|payloads| payloads_to_terms(env, &payloads.payloads))
        .transpose()
        .map(|terms| terms.unwrap_or_default())
}

fn retry_state_atom(retry_state: RetryState) -> Atom {
    match retry_state {
        RetryState::InProgress => in_progress(),
        RetryState::NonRetryableFailure => non_retryable_failure(),
        RetryState::Timeout => timeout(),
        RetryState::MaximumAttemptsReached => maximum_attempts_reached(),
        RetryState::RetryPolicyNotSet => retry_policy_not_set(),
        RetryState::InternalServerError => internal_server_error(),
        RetryState::CancelRequested => cancel_requested(),
        RetryState::Unspecified => unspecified(),
    }
}

fn timeout_type_atom(timeout_type: TimeoutType) -> Atom {
    match timeout_type {
        TimeoutType::StartToClose => start_to_close(),
        TimeoutType::ScheduleToStart => schedule_to_start(),
        TimeoutType::ScheduleToClose => schedule_to_close(),
        TimeoutType::Heartbeat => heartbeat(),
        TimeoutType::Unspecified => unspecified(),
    }
}

fn failure_info_type_atom(info: &Option<failure::FailureInfo>) -> Atom {
    match info {
        Some(failure::FailureInfo::TimeoutFailureInfo(_)) => timeout_failure(),
        Some(failure::FailureInfo::CanceledFailureInfo(_)) => cancelled_failure(),
        Some(failure::FailureInfo::TerminatedFailureInfo(_)) => terminated_failure(),
        Some(failure::FailureInfo::ServerFailureInfo(_)) => server_failure(),
        Some(failure::FailureInfo::ResetWorkflowFailureInfo(_)) => reset_workflow_failure(),
        Some(failure::FailureInfo::ActivityFailureInfo(_)) => activity_failure(),
        Some(failure::FailureInfo::ChildWorkflowExecutionFailureInfo(_)) => {
            child_workflow_failure()
        }
        Some(failure::FailureInfo::NexusOperationExecutionFailureInfo(_)) => {
            nexus_operation_failure()
        }
        Some(failure::FailureInfo::NexusHandlerFailureInfo(_)) => nexus_handler_failure(),
        Some(failure::FailureInfo::ApplicationFailureInfo(_)) => failed(),
        None => unknown_failure(),
    }
}

fn terms_list_to_payloads(list: Term) -> anyhow::Result<Vec<Payload>> {
    let iter: ListIterator = decode_term(list)?;
    Ok(iter.map(payload_from_term).collect())
}

fn keyword_get_i64(opts: Term, key: Atom) -> anyhow::Result<Option<i64>> {
    let Some(term) = keyword_get(opts, key)? else {
        return Ok(None);
    };

    if term.decode::<Atom>().ok() == Some(nil()) {
        Ok(None)
    } else {
        decode_term(term).map(Some)
    }
}

fn keyword_get_millis(opts: Term, key: Atom, option_name: &str) -> anyhow::Result<Option<u64>> {
    keyword_get_i64(opts, key)?
        .map(|ms| non_negative_millis(ms, option_name))
        .transpose()
}

fn keyword_get_f64(opts: Term, key: Atom) -> anyhow::Result<Option<f64>> {
    let Some(term) = keyword_get(opts, key)? else {
        return Ok(None);
    };

    if term.decode::<Atom>().ok() == Some(nil()) {
        return Ok(None);
    }

    if let Ok(value) = term.decode::<f64>() {
        Ok(Some(value))
    } else {
        decode_term::<i64>(term).map(|value| Some(value as f64))
    }
}

fn keyword_get_string(opts: Term, key: Atom) -> anyhow::Result<Option<String>> {
    let Some(term) = keyword_get(opts, key)? else {
        return Ok(None);
    };

    if term.decode::<Atom>().ok() == Some(nil()) {
        Ok(None)
    } else {
        decode_term(term).map(Some)
    }
}

fn keyword_get_string_list(opts: Term, key: Atom) -> anyhow::Result<Option<Vec<String>>> {
    let Some(term) = keyword_get(opts, key)? else {
        return Ok(None);
    };

    let iter: ListIterator = decode_term(term)?;
    iter.map(decode_term::<String>)
        .collect::<anyhow::Result<Vec<_>>>()
        .map(Some)
}

fn keyword_get_payload_map(opts: Term, key: Atom) -> anyhow::Result<HashMap<String, Payload>> {
    let Some(term) = keyword_get(opts, key)? else {
        return Ok(HashMap::new());
    };

    if term.decode::<Atom>().ok() == Some(nil()) {
        return Ok(HashMap::new());
    }

    term_to_payload_map(term)
}

fn term_to_payload_map(term: Term) -> anyhow::Result<HashMap<String, Payload>> {
    let iterator = MapIterator::new(term).ok_or_else(|| anyhow!("headers option must be a map"))?;
    let mut headers = HashMap::new();

    for (key, value) in iterator {
        headers.insert(decode_term::<String>(key)?, payload_from_term(value));
    }

    Ok(headers)
}

fn term_to_search_attributes_map(term: Term) -> anyhow::Result<HashMap<String, Payload>> {
    let iterator =
        MapIterator::new(term).ok_or_else(|| anyhow!("search_attributes option must be a map"))?;
    let mut attrs = HashMap::new();

    for (key, value) in iterator {
        attrs.insert(
            decode_term::<String>(key)?,
            search_attribute_payload_from_term(value)?,
        );
    }

    Ok(attrs)
}

fn search_attribute_payload_from_term(term: Term) -> anyhow::Result<Payload> {
    json_payload_from_value(search_attribute_json_from_term(term)?)
}

fn search_attribute_json_from_term(term: Term) -> anyhow::Result<JsonValue> {
    if term.is_map() {
        if let Ok(type_term) = map_get(term, type_atom()) {
            let value_term = map_get(term, value())
                .map_err(|_| anyhow!("typed Search Attribute values must include :value"))?;
            return typed_search_attribute_json(type_term, value_term);
        }
    }

    if let Ok(value) = term.decode::<bool>() {
        return Ok(JsonValue::Bool(value));
    }

    if let Ok(value) = term.decode::<i64>() {
        return Ok(JsonValue::Number(JsonNumber::from(value)));
    }

    if let Ok(value) = term.decode::<f64>() {
        return json_number_from_f64(value);
    }

    if let Ok(value) = term.decode::<String>() {
        return Ok(JsonValue::String(value));
    }

    if let Ok(iter) = term.decode::<ListIterator>() {
        let values = iter
            .map(decode_term::<String>)
            .collect::<anyhow::Result<Vec<_>>>()?;
        return Ok(JsonValue::Array(
            values.into_iter().map(JsonValue::String).collect(),
        ));
    }

    Err(anyhow!(
        "search attribute values must be typed values or JSON-compatible bool, integer, float, string, or string list"
    ))
}

fn typed_search_attribute_json(type_term: Term, value_term: Term) -> anyhow::Result<JsonValue> {
    let type_atom_value: Atom = decode_term(type_term)?;

    if type_atom_value == bool_atom() {
        Ok(JsonValue::Bool(decode_term(value_term)?))
    } else if type_atom_value == datetime() {
        Ok(JsonValue::String(decode_term(value_term)?))
    } else if type_atom_value == double() {
        if let Ok(value) = value_term.decode::<f64>() {
            json_number_from_f64(value)
        } else {
            let value: i64 = decode_term(value_term)?;
            json_number_from_f64(value as f64)
        }
    } else if type_atom_value == int() {
        let value: i64 = decode_term(value_term)?;
        Ok(JsonValue::Number(JsonNumber::from(value)))
    } else if type_atom_value == keyword() || type_atom_value == text() {
        Ok(JsonValue::String(decode_term(value_term)?))
    } else if type_atom_value == keyword_list() {
        let iter: ListIterator = decode_term(value_term)?;
        let values = iter
            .map(decode_term::<String>)
            .collect::<anyhow::Result<Vec<_>>>()?;
        Ok(JsonValue::Array(
            values.into_iter().map(JsonValue::String).collect(),
        ))
    } else {
        Err(anyhow!("unsupported Search Attribute type"))
    }
}

fn json_number_from_f64(value: f64) -> anyhow::Result<JsonValue> {
    JsonNumber::from_f64(value)
        .map(JsonValue::Number)
        .ok_or_else(|| anyhow!("search attribute double values must be finite"))
}

fn workflow_start_options(
    task_queue: String,
    workflow_id: String,
    opts: Term,
) -> anyhow::Result<WorkflowStartOptions> {
    let mut options = WorkflowStartOptions::new(task_queue, workflow_id).build();
    options.id_reuse_policy = workflow_id_reuse_policy_from_opts(opts)?;
    options.id_conflict_policy = workflow_id_conflict_policy_from_opts(opts)?;
    options.execution_timeout =
        duration_option_from_opts(opts, &[execution_timeout(), workflow_execution_timeout()])?;
    options.run_timeout =
        duration_option_from_opts(opts, &[run_timeout(), workflow_run_timeout()])?;
    options.task_timeout =
        duration_option_from_opts(opts, &[task_timeout(), workflow_task_timeout()])?;
    options.cron_schedule = keyword_get_string(opts, cron_schedule())?;
    options.search_attributes = search_attributes_option_from_opts(opts)?;
    options.retry_policy = retry_policy_from_opts(opts)?;
    options.header = header_from_opts(opts)?;
    options.static_summary = keyword_get_string(opts, static_summary())?;
    options.static_details = keyword_get_string(opts, static_details())?;
    Ok(options)
}

fn signal_options(opts: Term) -> anyhow::Result<WorkflowSignalOptions> {
    let mut options = WorkflowSignalOptions::default();
    options.request_id = keyword_get_string(opts, request_id())?;
    options.header = header_from_opts(opts)?;
    Ok(options)
}

fn query_options(opts: Term) -> anyhow::Result<WorkflowQueryOptions> {
    let mut options = WorkflowQueryOptions::default();
    options.reject_condition = query_reject_condition_from_opts(opts)?;
    options.header = header_from_opts(opts)?;
    Ok(options)
}

fn update_options(opts: Term) -> anyhow::Result<WorkflowExecuteUpdateOptions> {
    let mut options = WorkflowExecuteUpdateOptions::default();
    options.update_id = keyword_get_string(opts, update_id())?;
    options.header = header_from_opts(opts)?;
    Ok(options)
}

fn header_from_opts(opts: Term) -> anyhow::Result<Option<Header>> {
    let fields = keyword_get_payload_map(opts, headers())?;
    if fields.is_empty() {
        Ok(None)
    } else {
        Ok(Some(Header { fields }))
    }
}

fn search_attributes_option_from_opts(
    opts: Term,
) -> anyhow::Result<Option<HashMap<String, Payload>>> {
    let Some(term) = keyword_get(opts, search_attributes())? else {
        return Ok(None);
    };

    if term.decode::<Atom>().ok() == Some(nil()) {
        Ok(None)
    } else {
        Ok(Some(term_to_search_attributes_map(term)?))
    }
}

fn retry_policy_from_opts(opts: Term) -> anyhow::Result<Option<RetryPolicy>> {
    let Some(term) = keyword_get(opts, retry_policy())? else {
        return Ok(None);
    };

    if term.decode::<Atom>().ok() == Some(nil()) {
        Ok(None)
    } else {
        Ok(Some(retry_policy_from_term(term)?))
    }
}

fn retry_policy_from_term(term: Term) -> anyhow::Result<RetryPolicy> {
    let backoff_coefficient = keyword_get_f64(term, backoff_coefficient())?;
    if let Some(value) = backoff_coefficient
        && value < 1.0
    {
        return Err(anyhow!(
            "retry_policy.backoff_coefficient must be 1.0 or larger"
        ));
    }
    let backoff_coefficient = backoff_coefficient.unwrap_or(0.0);

    let maximum_attempts = keyword_get_i64(term, maximum_attempts())?.unwrap_or(0);
    if maximum_attempts < 0 || maximum_attempts > i32::MAX as i64 {
        return Err(anyhow!(
            "retry_policy.maximum_attempts must fit in a non-negative i32"
        ));
    }

    Ok(RetryPolicy {
        initial_interval: keyword_get_millis(
            term,
            initial_interval(),
            "retry_policy.initial_interval",
        )?
        .map(duration_from_ms),
        backoff_coefficient,
        maximum_interval: keyword_get_millis(
            term,
            maximum_interval(),
            "retry_policy.maximum_interval",
        )?
        .map(duration_from_ms),
        maximum_attempts: maximum_attempts as i32,
        non_retryable_error_types: keyword_get_string_list(term, non_retryable_error_types())?
            .unwrap_or_default(),
    })
}

#[allow(deprecated)]
fn workflow_id_reuse_policy_from_opts(opts: Term) -> anyhow::Result<WorkflowIdReusePolicy> {
    let Some(term) =
        keyword_get(opts, workflow_id_reuse_policy())?.or(keyword_get(opts, id_reuse_policy())?)
    else {
        return Ok(WorkflowIdReusePolicy::Unspecified);
    };

    let atom: Atom = decode_term(term)?;
    if atom == allow_duplicate() {
        Ok(WorkflowIdReusePolicy::AllowDuplicate)
    } else if atom == allow_duplicate_failed_only() {
        Ok(WorkflowIdReusePolicy::AllowDuplicateFailedOnly)
    } else if atom == reject_duplicate() {
        Ok(WorkflowIdReusePolicy::RejectDuplicate)
    } else if atom == terminate_if_running() {
        Ok(WorkflowIdReusePolicy::TerminateIfRunning)
    } else if atom == unspecified() {
        Ok(WorkflowIdReusePolicy::Unspecified)
    } else {
        Err(anyhow!("unsupported workflow id reuse policy"))
    }
}

fn workflow_id_conflict_policy_from_opts(opts: Term) -> anyhow::Result<WorkflowIdConflictPolicy> {
    let Some(term) = keyword_get(opts, workflow_id_conflict_policy())?
        .or(keyword_get(opts, id_conflict_policy())?)
    else {
        return Ok(WorkflowIdConflictPolicy::Unspecified);
    };

    let atom: Atom = decode_term(term)?;
    if atom == fail() {
        Ok(WorkflowIdConflictPolicy::Fail)
    } else if atom == use_existing() {
        Ok(WorkflowIdConflictPolicy::UseExisting)
    } else if atom == terminate_existing() {
        Ok(WorkflowIdConflictPolicy::TerminateExisting)
    } else if atom == unspecified() {
        Ok(WorkflowIdConflictPolicy::Unspecified)
    } else {
        Err(anyhow!("unsupported workflow id conflict policy"))
    }
}

fn query_reject_condition_from_opts(opts: Term) -> anyhow::Result<Option<QueryRejectCondition>> {
    let Some(term) =
        keyword_get(opts, query_reject_condition())?.or(keyword_get(opts, reject_condition())?)
    else {
        return Ok(None);
    };

    let atom: Atom = decode_term(term)?;
    if atom == none() {
        Ok(Some(QueryRejectCondition::None))
    } else if atom == not_open() {
        Ok(Some(QueryRejectCondition::NotOpen))
    } else if atom == not_completed_cleanly() {
        Ok(Some(QueryRejectCondition::NotCompletedCleanly))
    } else if atom == unspecified() {
        Ok(Some(QueryRejectCondition::Unspecified))
    } else {
        Err(anyhow!("unsupported query reject condition"))
    }
}

fn duration_option_from_opts(
    opts: Term,
    keys: &[Atom],
) -> anyhow::Result<Option<std::time::Duration>> {
    for key in keys {
        if let Some(ms) = keyword_get_i64(opts, *key)? {
            if ms < 0 {
                return Err(anyhow!("duration option must be non-negative"));
            }
            return Ok(Some(std::time::Duration::from_millis(ms as u64)));
        }
    }

    Ok(None)
}

fn non_negative_millis(ms: i64, option_name: &str) -> anyhow::Result<u64> {
    if ms < 0 {
        Err(anyhow!("{option_name} must be non-negative"))
    } else {
        Ok(ms as u64)
    }
}

fn keyword_get(opts: Term, key: Atom) -> anyhow::Result<Option<Term>> {
    if opts.is_map() {
        return Ok(opts.map_get(key).ok());
    }

    let iter: ListIterator = decode_term(opts)?;
    for item in iter {
        let (item_key, value): (Atom, Term) = decode_term(item)?;
        if item_key == key {
            return Ok(Some(value));
        }
    }

    Ok(None)
}

fn duration_from_ms(ms: u64) -> prost_types::Duration {
    prost_types::Duration {
        seconds: (ms / 1000) as i64,
        nanos: ((ms % 1000) * 1_000_000) as i32,
    }
}

fn make_struct<'a>(env: Env<'a>, module: &str) -> anyhow::Result<Term<'a>> {
    make_ex_struct(env, module).map_err(nif_error)
}

fn on_load(env: Env, _load_info: Term) -> bool {
    env.register::<RuntimeResource>().is_ok()
        && env.register::<ClientResource>().is_ok()
        && env.register::<WorkerResource>().is_ok()
}

rustler::init!("Elixir.Temporalex.Native", load = on_load);
