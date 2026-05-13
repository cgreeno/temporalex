use anyhow::{Context, anyhow};
use prost::Message;
use rustler::types::elixir_struct::{get_ex_struct_name, make_ex_struct};
use rustler::types::list::ListIterator;
use rustler::{Atom, Binary, Env, LocalPid, MapIterator, Monitor, NewBinary, OwnedEnv};
use rustler::{Decoder, Encoder, Resource, ResourceArc, Term};
use std::collections::HashMap;
use std::sync::Arc;
use temporalio_client::{
    Client, ClientOptions, Connection, ConnectionOptions, TlsOptions, UntypedQuery, UntypedSignal,
    UntypedUpdate, UntypedWorkflow, WorkflowCancelOptions, WorkflowDescribeOptions,
    WorkflowExecuteUpdateOptions, WorkflowExecutionDescription, WorkflowExecutionInfo,
    WorkflowGetResultOptions, WorkflowHandle, WorkflowQueryOptions, WorkflowSignalOptions,
    WorkflowStartOptions, WorkflowTerminateOptions,
    errors::{WorkflowGetResultError, WorkflowQueryError, WorkflowStartError, WorkflowUpdateError},
};
use temporalio_common::data_converters::RawValue;
use temporalio_common::protos::coresdk::activity_result::{
    ActivityExecutionResult, ActivityResolution, Cancellation, Failure as ActivityFailure,
    Success as ActivitySuccess, activity_execution_result, activity_resolution,
};
use temporalio_common::protos::coresdk::activity_task::{ActivityTask, activity_task};
use temporalio_common::protos::coresdk::workflow_activation::{
    WorkflowActivation, WorkflowActivationJob, remove_from_cache::EvictionReason,
    workflow_activation_job,
};
use temporalio_common::protos::coresdk::workflow_commands::{
    ActivityCancellationType, CancelTimer, CancelWorkflowExecution, CompleteWorkflowExecution,
    ContinueAsNewWorkflowExecution, FailWorkflowExecution, QueryResult, QuerySuccess,
    ScheduleActivity, SetPatchMarker, StartTimer, UpdateResponse, UpsertWorkflowSearchAttributes,
    WorkflowCommand, query_result, update_response, workflow_command,
};
use temporalio_common::protos::coresdk::workflow_completion::{
    Failure as WorkflowCompletionFailure, Success as WorkflowCompletionSuccess,
    WorkflowActivationCompletion, workflow_activation_completion,
};
use temporalio_common::protos::coresdk::{ActivityHeartbeat, ActivityTaskCompletion};
use temporalio_common::protos::temporal::api::common::v1::{
    Header, Payload, Payloads, RetryPolicy, SearchAttributes,
};
use temporalio_common::protos::temporal::api::enums::v1::{
    VersioningBehavior, WorkflowExecutionStatus, WorkflowIdConflictPolicy, WorkflowIdReusePolicy,
    WorkflowTaskFailedCause,
};
use temporalio_common::protos::temporal::api::failure::v1::{
    ApplicationFailureInfo, CanceledFailureInfo, Failure, failure,
};
use temporalio_common::worker::WorkerTaskTypes;
use temporalio_sdk_core::{
    CoreRuntime, PollError, PollerBehavior, RuntimeOptions, TokioRuntimeBuilder, Worker,
    WorkerConfig, WorkerVersioningStrategy, init_worker,
};
use time::OffsetDateTime;
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
    start,
    cancel,
    completed,
    failed,
    cancelled,
    accepted,
    rejected,
    backoff,
    cache_full,
    cache_miss,
    nondeterminism,
    lang_fail,
    lang_requested,
    task_not_found,
    unhandled_command,
    fatal,
    pagination_or_history_fetch,
    workflow_execution_ending,
    unspecified,
    run_id,
    timestamp,
    is_replaying,
    history_length,
    history_size_bytes,
    continue_as_new_suggested,
    available_internal_flags,
    deployment_version,
    jobs,
    workflow_type,
    workflow_id,
    arguments,
    headers,
    attrs,
    workflow_info,
    randomness_seed,
    seq,
    result,
    name,
    args,
    identity,
    query_id,
    query_type,
    reason,
    message,
    id,
    protocol_instance_id,
    meta,
    run_validator,
    task_token,
    activity_id,
    activity_type,
    namespace,
    task_queue,
    input,
    attempt,
    heartbeat_timeout,
    is_local,
    variant,
    cancel_reason,
    source,
    details,
    type_atom = "type",
    force_cause,
    timeout,
    start_to_close_timeout,
    schedule_to_close_timeout,
    schedule_to_start_timeout,
    status_atom = "status",
    duration_ms,
    opts_atom = "opts",
    response,
    deprecated,
    signal,
    query,
    update,
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
    already_started,
    not_found,
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
    request_id,
    update_id,
    initial_interval,
    maximum_interval,
    maximum_attempts,
    backoff_coefficient,
    non_retryable_error_types,
    cancellation_type,
    try_cancel,
    wait_cancellation_completed,
    abandon,
    allow_duplicate,
    allow_duplicate_failed_only,
    reject_duplicate,
    terminate_if_running,
    fail,
    use_existing,
    terminate_existing,
    static_summary,
    static_details,
    start_time_ms,
    execution_time_ms,
    close_time_ms,
    history_length_atom = "history_length",
    calendar_atom = "calendar",
    year_atom = "year",
    month_atom = "month",
    day_atom = "day",
    hour_atom = "hour",
    minute_atom = "minute",
    second_atom = "second",
    microsecond_atom = "microsecond",
    time_zone_atom = "time_zone",
    zone_abbr_atom = "zone_abbr",
    utc_offset_atom = "utc_offset",
    std_offset_atom = "std_offset",
}

const ETF_ENCODING: &[u8] = b"binary/erlang-eterm";
const DEFAULT_ACTIVITY_TIMEOUT_MS: u64 = 30_000;

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

fn ok_binary<'a>(env: Env<'a>, bytes: Vec<u8>) -> Term<'a> {
    (ok(), binary_term(env, &bytes)).encode(env)
}

fn binary_term<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.copy_from_slice(bytes);
    Term::from(binary)
}

fn error_term<'a>(env: Env<'a>, reason: impl Into<String>) -> Term<'a> {
    (error(), reason.into()).encode(env)
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
                start_poll_loops(resource.clone(), pid);
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
fn encode_workflow_completion<'a>(
    env: Env<'a>,
    completion: Term<'a>,
    task_queue: String,
) -> Term<'a> {
    match workflow_completion_from_term(completion, &task_queue) {
        Ok(completion) => ok_binary(env, completion.encode_to_vec()),
        Err(err) => error_term(env, format!("{err:#}")),
    }
}

#[rustler::nif]
fn encode_activity_completion<'a>(env: Env<'a>, completion: Term<'a>) -> Term<'a> {
    match activity_completion_from_term(completion) {
        Ok(completion) => ok_binary(env, completion.encode_to_vec()),
        Err(err) => error_term(env, format!("{err:#}")),
    }
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
fn record_activity_heartbeat(
    worker: ResourceArc<WorkerResource>,
    task_token: Binary,
    details_bytes: Option<Binary>,
) -> Atom {
    let details = details_bytes
        .map(|bytes| vec![payload_from_bytes(bytes.as_slice().to_vec())])
        .unwrap_or_default();

    worker.worker.record_activity_heartbeat(ActivityHeartbeat {
        task_token: task_token.as_slice().to_vec(),
        details,
    });

    ok()
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
            send_immediate_ref_error(env, reference, &pid, workflow_started(), format!("{err:#}"));
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
                        Err(err) => (error(), format!("{err:#}")).encode(env),
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
                format!("{err:#}"),
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
                format!("{err:#}"),
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
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)?;
            wf.signal(
                UntypedSignal::<UntypedWorkflow>::new(signal_name),
                RawValue::new(payloads),
                options,
            )
            .await?;
            Ok::<_, anyhow::Error>(())
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_signalled(),
            |env| match result {
                Ok(()) => (ok(), ok()).encode(env),
                Err(err) => (error(), format!("{err:#}")).encode(env),
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
            send_immediate_ref_error(env, reference, &pid, workflow_queried(), format!("{err:#}"));
            return ok();
        }
    };
    let options = match query_options(opts) {
        Ok(options) => options,
        Err(err) => {
            send_immediate_ref_error(env, reference, &pid, workflow_queried(), format!("{err:#}"));
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
            send_immediate_ref_error(env, reference, &pid, workflow_updated(), format!("{err:#}"));
            return ok();
        }
    };
    let options = match update_options(opts) {
        Ok(options) => options,
        Err(err) => {
            send_immediate_ref_error(env, reference, &pid, workflow_updated(), format!("{err:#}"));
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
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)?;
            let mut options = WorkflowCancelOptions::default();
            options.reason = reason_text;
            options.request_id = request_id_text;
            wf.cancel(options).await?;
            Ok::<_, anyhow::Error>(())
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_cancelled(),
            |env| match result {
                Ok(()) => (ok(), ok()).encode(env),
                Err(err) => (error(), format!("{err:#}")).encode(env),
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
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)?;
            let mut options = WorkflowTerminateOptions::default();
            options.reason = reason_text;
            options.details = details;
            wf.terminate(options).await?;
            Ok::<_, anyhow::Error>(())
        }
        .await;

        send_ref_result(
            saved_env,
            saved_ref,
            &pid,
            workflow_terminated(),
            |env| match result {
                Ok(()) => (ok(), ok()).encode(env),
                Err(err) => (error(), format!("{err:#}")).encode(env),
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
            let wf = untyped_handle(connection, namespace, workflow_id, run_id)?;
            let description = wf.describe(WorkflowDescribeOptions::default()).await?;
            Ok::<_, anyhow::Error>(description)
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
                    Err(err) => (error(), format!("{err:#}")).encode(env),
                },
                Err(err) => (error(), format!("{err:#}")).encode(env),
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
                    let sent = {
                        let mut ok = true;
                        send_simple(&workflow_pid, |env| {
                            match activation_to_term(env, &activation) {
                                Ok(term) => (workflow_activation(), term).encode(env),
                                Err(err) => {
                                    ok = false;
                                    (backend_error(), format!("{err:#}")).encode(env)
                                }
                            }
                        });
                        ok
                    };

                    if !sent {
                        guard.exit(crashed());
                        break;
                    }
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
                    let sent = {
                        let mut ok = true;
                        send_simple(&activity_pid, |env| {
                            match activity_task_to_term(env, &task) {
                                Ok(term) => (activity_task(), term).encode(env),
                                Err(err) => {
                                    ok = false;
                                    (backend_error(), format!("{err:#}")).encode(env)
                                }
                            }
                        });
                        ok
                    };

                    if !sent {
                        guard.exit(crashed());
                        break;
                    }
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
    reason: String,
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
            Err(err) => (error(), format!("{err:#}")).encode(env),
        },
        None => (ok(), nil()).encode(env),
    }
}

fn workflow_start_error_to_term<'a>(env: Env<'a>, err: StartWorkflowResult) -> Term<'a> {
    match err {
        StartWorkflowResult::Start(WorkflowStartError::AlreadyStarted { run_id, .. }) => {
            let run_id_term = run_id
                .map(|id| string_term(env, id))
                .unwrap_or_else(|| nil().encode(env));
            (already_started(), run_id_term).encode(env)
        }
        StartWorkflowResult::Start(err) => string_term(env, format!("{err:#}")),
        StartWorkflowResult::Other(reason) => string_term(env, reason),
    }
}

fn get_workflow_result_error_to_term<'a>(env: Env<'a>, err: GetWorkflowResult) -> Term<'a> {
    match err {
        GetWorkflowResult::Get(WorkflowGetResultError::Failed(failure)) => {
            match failure_to_term(env, Some(failure.as_ref())) {
                Ok(term) => (failed(), term).encode(env),
                Err(err) => string_term(env, format!("{err:#}")),
            }
        }
        GetWorkflowResult::Get(WorkflowGetResultError::Cancelled { details }) => {
            match payloads_to_terms(env, &details) {
                Ok(terms) => (cancelled(), terms).encode(env),
                Err(err) => string_term(env, format!("{err:#}")),
            }
        }
        GetWorkflowResult::Get(WorkflowGetResultError::Terminated { details }) => {
            match payloads_to_terms(env, &details) {
                Ok(terms) => (terminated(), terms).encode(env),
                Err(err) => string_term(env, format!("{err:#}")),
            }
        }
        GetWorkflowResult::Get(WorkflowGetResultError::TimedOut) => timed_out().encode(env),
        GetWorkflowResult::Get(WorkflowGetResultError::ContinuedAsNew) => {
            continued_as_new().encode(env)
        }
        GetWorkflowResult::Get(WorkflowGetResultError::NotFound(_)) => not_found().encode(env),
        GetWorkflowResult::Get(err) => string_term(env, format!("{err:#}")),
        GetWorkflowResult::Other(err) => string_term(env, format!("{err:#}")),
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
        QueryWorkflowResult::Query(err) => string_term(env, format!("{err:#}")),
        QueryWorkflowResult::Other(err) => string_term(env, format!("{err:#}")),
    }
}

fn update_workflow_error_to_term<'a>(env: Env<'a>, err: UpdateWorkflowResult) -> Term<'a> {
    match err {
        UpdateWorkflowResult::Update(WorkflowUpdateError::Failed(failure)) => {
            match failure_to_term(env, Some(failure.as_ref())) {
                Ok(term) => (failed(), term).encode(env),
                Err(err) => string_term(env, format!("{err:#}")),
            }
        }
        UpdateWorkflowResult::Update(WorkflowUpdateError::NotFound(_)) => not_found().encode(env),
        UpdateWorkflowResult::Update(err) => string_term(env, format!("{err:#}")),
        UpdateWorkflowResult::Other(err) => string_term(env, format!("{err:#}")),
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

fn payload_map_to_term<'a>(
    env: Env<'a>,
    payloads: &HashMap<String, Payload>,
) -> anyhow::Result<Term<'a>> {
    let mut map = Term::map_new(env);
    for (key, payload) in payloads {
        map = map_put(map, key, payload_to_term(env, payload)?)?;
    }
    Ok(map)
}

fn activation_to_term<'a>(
    env: Env<'a>,
    activation: &WorkflowActivation,
) -> anyhow::Result<Term<'a>> {
    let job_terms = activation
        .jobs
        .iter()
        .map(|job| activation_job_to_term(env, job))
        .collect::<anyhow::Result<Vec<_>>>()?;

    put_fields!(
        make_struct(env, "Elixir.Temporalex.Core.Activation")?,
        run_id() => activation.run_id.clone(),
        timestamp() => timestamp_to_datetime(env, activation.timestamp.as_ref())?,
        is_replaying() => activation.is_replaying,
        history_length() => activation.history_length as i64,
        history_size_bytes() => activation.history_size_bytes as i64,
        continue_as_new_suggested() => activation.continue_as_new_suggested,
        available_internal_flags() => activation
            .available_internal_flags
            .iter()
            .map(|flag| *flag as i64)
            .collect::<Vec<_>>(),
        deployment_version() => nil(),
        jobs() => job_terms,
    )
}

fn activation_job_to_term<'a>(
    env: Env<'a>,
    job: &WorkflowActivationJob,
) -> anyhow::Result<Term<'a>> {
    match job
        .variant
        .as_ref()
        .context("activation job had no variant")?
    {
        workflow_activation_job::Variant::InitializeWorkflow(init) => {
            let workflow_info_term = put_fields!(
                Term::map_new(env),
                workflow_id() => init.workflow_id.clone(),
                workflow_type() => init.workflow_type.clone(),
                attempt() => init.attempt as i64,
                identity() => init.identity.clone(),
                run_id() => init.first_execution_run_id.clone(),
            )?;

            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.InitializeWorkflow")?,
                workflow_type() => init.workflow_type.clone(),
                workflow_id() => init.workflow_id.clone(),
                arguments() => payloads_to_terms(env, &init.arguments)?,
                headers() => payload_map_to_term(env, &init.headers)?,
                workflow_info() => workflow_info_term,
                randomness_seed() => init.randomness_seed as i64,
            )
        }
        workflow_activation_job::Variant::FireTimer(timer) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.TimerFired")?,
                seq() => timer.seq as i64,
            )
        }
        workflow_activation_job::Variant::ResolveActivity(resolution) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.ActivityResolved")?,
                seq() => resolution.seq as i64,
                result() => activity_resolution_to_term(env, resolution.result.as_ref())?,
            )
        }
        workflow_activation_job::Variant::UpdateRandomSeed(seed) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.UpdateRandomSeed")?,
                randomness_seed() => seed.randomness_seed as i64,
            )
        }
        workflow_activation_job::Variant::QueryWorkflow(query) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.QueryReceived")?,
                query_id() => query.query_id.clone(),
                query_type() => query.query_type.clone(),
                args() => payloads_to_terms(env, &query.arguments)?,
                headers() => payload_map_to_term(env, &query.headers)?,
            )
        }
        workflow_activation_job::Variant::CancelWorkflow(cancel_job) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.CancelWorkflow")?,
                reason() => cancel_job.reason.clone(),
            )
        }
        workflow_activation_job::Variant::SignalWorkflow(signal_job) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.SignalReceived")?,
                name() => signal_job.signal_name.clone(),
                args() => payloads_to_terms(env, &signal_job.input)?,
                headers() => payload_map_to_term(env, &signal_job.headers)?,
                identity() => signal_job.identity.clone(),
            )
        }
        workflow_activation_job::Variant::NotifyHasPatch(patch) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.NotifyPatch")?,
                id() => patch.patch_id.clone(),
            )
        }
        workflow_activation_job::Variant::DoUpdate(update) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.UpdateReceived")?,
                id() => update.id.clone(),
                protocol_instance_id() => update.protocol_instance_id.clone(),
                name() => update.name.clone(),
                args() => payloads_to_terms(env, &update.input)?,
                headers() => payload_map_to_term(env, &update.headers)?,
                meta() => nil(),
                run_validator() => update.run_validator,
            )
        }
        workflow_activation_job::Variant::RemoveFromCache(eviction) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.Job.RemoveFromCache")?,
                reason() => eviction_reason_atom(eviction.reason()),
                message() => eviction.message.clone(),
            )
        }
        other => Err(anyhow!(
            "unsupported workflow activation job from Temporal Core: {other:?}"
        )),
    }
}

fn activity_resolution_to_term<'a>(
    env: Env<'a>,
    resolution: Option<&ActivityResolution>,
) -> anyhow::Result<Term<'a>> {
    let resolution = resolution.context("activity resolution missing result")?;
    match resolution
        .status
        .as_ref()
        .context("activity resolution empty")?
    {
        activity_resolution::Status::Completed(success) => {
            let payload = success
                .result
                .as_ref()
                .context("activity result missing payload")?;
            Ok((ok(), payload_to_term(env, payload)?).encode(env))
        }
        activity_resolution::Status::Failed(failure) => {
            Ok((error(), failure_to_term(env, failure.failure.as_ref())?).encode(env))
        }
        activity_resolution::Status::Cancelled(cancellation) => Ok((
            cancelled(),
            failure_to_term(env, cancellation.failure.as_ref())?,
        )
            .encode(env)),
        activity_resolution::Status::Backoff(backoff_job) => {
            let details = put_fields!(
                Term::map_new(env),
                attempt() => backoff_job.attempt as i64,
                timeout() => duration_to_millis(backoff_job.backoff_duration.as_ref()) as i64,
            )?;
            Ok((backoff(), details).encode(env))
        }
    }
}

fn activity_task_to_term<'a>(env: Env<'a>, task: &ActivityTask) -> anyhow::Result<Term<'a>> {
    match task
        .variant
        .as_ref()
        .context("activity task had no variant")?
    {
        activity_task::Variant::Start(start_task) => {
            let execution = start_task.workflow_execution.as_ref();
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.ActivityTask")?,
                task_token() => binary_term(env, &task.task_token),
                activity_id() => start_task.activity_id.clone(),
                activity_type() => start_task.activity_type.clone(),
                workflow_id() => execution
                    .map(|execution| execution.workflow_id.clone())
                    .unwrap_or_default(),
                run_id() => execution
                    .map(|execution| execution.run_id.clone())
                    .unwrap_or_default(),
                workflow_type() => start_task.workflow_type.clone(),
                namespace() => start_task.workflow_namespace.clone(),
                task_queue() => nil(),
                input() => payloads_to_terms(env, &start_task.input)?,
                attempt() => start_task.attempt as i64,
                heartbeat_timeout() => nullable_duration_millis(env, start_task.heartbeat_timeout.as_ref()),
                is_local() => start_task.is_local,
                headers() => payload_map_to_term(env, &start_task.header_fields)?,
                variant() => start(),
                cancel_reason() => nil(),
            )
        }
        activity_task::Variant::Cancel(cancel_task) => {
            put_fields!(
                make_struct(env, "Elixir.Temporalex.Core.ActivityTask")?,
                task_token() => binary_term(env, &task.task_token),
                variant() => cancel(),
                cancel_reason() => activity_cancel_reason(cancel_task.reason()),
            )
        }
    }
}

fn workflow_completion_from_term(
    completion: Term,
    default_task_queue: &str,
) -> anyhow::Result<WorkflowActivationCompletion> {
    let run_id: String = decode_term(map_get(completion, crate::run_id())?)?;
    let status = map_get(completion, crate::status_atom())?;

    if let Ok((tag, commands_term)) = status.decode::<(Atom, Term)>() {
        if tag == ok() {
            let commands = commands_from_term(commands_term, default_task_queue)?;
            return Ok(WorkflowActivationCompletion {
                run_id,
                status: Some(workflow_activation_completion::Status::Successful(
                    WorkflowCompletionSuccess {
                        commands,
                        used_internal_flags: vec![],
                        versioning_behavior: VersioningBehavior::Unspecified as i32,
                    },
                )),
            });
        }
    }

    if let Ok((tag, reason_term, opts_term)) = status.decode::<(Atom, Term, Term)>() {
        if tag == failed() {
            let force_cause = force_cause_from_opts(opts_term);
            return Ok(WorkflowActivationCompletion {
                run_id,
                status: Some(workflow_activation_completion::Status::Failed(
                    WorkflowCompletionFailure {
                        failure: Some(failure_from_term(
                            reason_term,
                            "Temporalex activation failure",
                        )),
                        force_cause: force_cause as i32,
                    },
                )),
            });
        }
    }

    Err(anyhow!("unsupported workflow completion status"))
}

fn commands_from_term(
    commands_term: Term,
    default_task_queue: &str,
) -> anyhow::Result<Vec<WorkflowCommand>> {
    let iter: ListIterator = decode_term(commands_term)?;
    iter.map(|command| command_from_term(command, default_task_queue))
        .collect()
}

fn command_from_term(command: Term, default_task_queue: &str) -> anyhow::Result<WorkflowCommand> {
    let module_atom = get_ex_struct_name(command).map_err(nif_error)?;
    let module = module_atom
        .to_term(command.get_env())
        .atom_to_string()
        .map_err(nif_error)?;
    let variant = match module.as_str() {
        "Elixir.Temporalex.Core.Command.StartTimer" => {
            let duration_ms = map_get_non_negative_i64(command, duration_ms(), "timer duration")?;

            workflow_command::Variant::StartTimer(StartTimer {
                seq: map_get_i64(command, seq())? as u32,
                start_to_fire_timeout: Some(duration_from_ms(duration_ms)),
            })
        }
        "Elixir.Temporalex.Core.Command.CancelTimer" => {
            workflow_command::Variant::CancelTimer(CancelTimer {
                seq: map_get_i64(command, seq())? as u32,
            })
        }
        "Elixir.Temporalex.Core.Command.ScheduleActivity" => {
            let opts = map_get(command, opts_atom())?;
            let task_queue = keyword_get_string(opts, task_queue())?
                .unwrap_or_else(|| default_task_queue.to_string());
            let timeout_ms = keyword_get_millis(opts, timeout(), "activity timeout")?
                .or(keyword_get_millis(
                    opts,
                    start_to_close_timeout(),
                    "activity start_to_close_timeout",
                )?)
                .unwrap_or(DEFAULT_ACTIVITY_TIMEOUT_MS);

            workflow_command::Variant::ScheduleActivity(ScheduleActivity {
                seq: map_get_i64(command, seq())? as u32,
                activity_id: map_get_string(command, activity_id())?,
                activity_type: map_get_string(command, type_atom())?,
                task_queue,
                headers: keyword_get_payload_map(opts, headers())?,
                arguments: terms_list_to_payloads(map_get(command, input())?)?,
                schedule_to_close_timeout: Some(duration_from_ms(
                    keyword_get_millis(
                        opts,
                        schedule_to_close_timeout(),
                        "activity schedule_to_close_timeout",
                    )?
                    .unwrap_or(timeout_ms),
                )),
                schedule_to_start_timeout: keyword_get_millis(
                    opts,
                    schedule_to_start_timeout(),
                    "activity schedule_to_start_timeout",
                )?
                .map(duration_from_ms),
                start_to_close_timeout: Some(duration_from_ms(timeout_ms)),
                heartbeat_timeout: keyword_get_millis(
                    opts,
                    heartbeat_timeout(),
                    "activity heartbeat_timeout",
                )?
                .map(duration_from_ms),
                retry_policy: retry_policy_from_opts(opts)?,
                cancellation_type: activity_cancellation_type_from_opts(opts)? as i32,
                do_not_eagerly_execute: false,
                ..Default::default()
            })
        }
        "Elixir.Temporalex.Core.Command.CompleteWorkflow" => {
            workflow_command::Variant::CompleteWorkflowExecution(CompleteWorkflowExecution {
                result: Some(payload_from_term(map_get(command, result())?)),
            })
        }
        "Elixir.Temporalex.Core.Command.FailWorkflow" => {
            workflow_command::Variant::FailWorkflowExecution(FailWorkflowExecution {
                failure: Some(failure_from_term(
                    map_get(command, reason())?,
                    "Temporalex workflow failure",
                )),
            })
        }
        "Elixir.Temporalex.Core.Command.ContinueAsNew" => {
            let opts_or_command = command.map_get(opts_atom()).unwrap_or(command);
            let workflow_type = keyword_get_string(opts_or_command, workflow_type())
                .ok()
                .flatten()
                .unwrap_or_default();
            let task_queue = keyword_get_string(opts_or_command, task_queue())
                .ok()
                .flatten()
                .unwrap_or_else(|| default_task_queue.to_string());

            workflow_command::Variant::ContinueAsNewWorkflowExecution(
                ContinueAsNewWorkflowExecution {
                    workflow_type,
                    task_queue,
                    arguments: vec![payload_from_term(map_get(command, args())?)],
                    ..Default::default()
                },
            )
        }
        "Elixir.Temporalex.Core.Command.CancelWorkflow" => {
            workflow_command::Variant::CancelWorkflowExecution(CancelWorkflowExecution {})
        }
        "Elixir.Temporalex.Core.Command.RespondToQuery" => {
            workflow_command::Variant::RespondToQuery(query_result_from_term(command)?)
        }
        "Elixir.Temporalex.Core.Command.RespondToUpdate" => {
            workflow_command::Variant::UpdateResponse(update_response_from_term(command)?)
        }
        "Elixir.Temporalex.Core.Command.SetPatchMarker" => {
            workflow_command::Variant::SetPatchMarker(SetPatchMarker {
                patch_id: map_get_string(command, id())?,
                deprecated: command
                    .map_get(deprecated())
                    .ok()
                    .and_then(|t| t.decode().ok())
                    .unwrap_or(false),
            })
        }
        "Elixir.Temporalex.Core.Command.UpsertSearchAttributes" => {
            workflow_command::Variant::UpsertWorkflowSearchAttributes(
                UpsertWorkflowSearchAttributes {
                    search_attributes: Some(SearchAttributes {
                        indexed_fields: term_to_payload_map(map_get(command, attrs())?)?,
                    }),
                },
            )
        }
        unsupported => return Err(anyhow!("unsupported workflow command {unsupported}")),
    };

    Ok(WorkflowCommand {
        variant: Some(variant),
        user_metadata: None,
    })
}

fn activity_completion_from_term(completion: Term) -> anyhow::Result<ActivityTaskCompletion> {
    let task_token_binary: Binary = decode_term(map_get(completion, task_token())?)?;
    let result_term = map_get(completion, result())?;
    let result = if let Ok((tag, value)) = result_term.decode::<(Atom, Term)>() {
        if tag == ok() {
            ActivityExecutionResult {
                status: Some(activity_execution_result::Status::Completed(
                    ActivitySuccess {
                        result: Some(payload_from_term(value)),
                    },
                )),
            }
        } else if tag == error() {
            ActivityExecutionResult {
                status: Some(activity_execution_result::Status::Failed(ActivityFailure {
                    failure: Some(failure_from_term(value, "Temporalex activity failure")),
                })),
            }
        } else if tag == cancelled() {
            ActivityExecutionResult {
                status: Some(activity_execution_result::Status::Cancelled(Cancellation {
                    failure: Some(cancelled_failure_from_term(value)),
                })),
            }
        } else {
            return Err(anyhow!("unsupported activity completion result tag"));
        }
    } else {
        return Err(anyhow!("activity completion result must be a tagged tuple"));
    };

    Ok(ActivityTaskCompletion {
        task_token: task_token_binary.as_slice().to_vec(),
        result: Some(result),
    })
}

fn query_result_from_term(command: Term) -> anyhow::Result<QueryResult> {
    let query_id = map_get_string(command, query_id())?;
    let result_term = map_get(command, result())?;

    if let Ok((tag, value)) = result_term.decode::<(Atom, Term)>() {
        if tag == ok() {
            return Ok(QueryResult {
                query_id,
                variant: Some(query_result::Variant::Succeeded(QuerySuccess {
                    response: Some(payload_from_term(value)),
                })),
            });
        }

        if tag == error() {
            return Ok(QueryResult {
                query_id,
                variant: Some(query_result::Variant::Failed(failure_from_term(
                    value,
                    "Temporalex query failure",
                ))),
            });
        }
    }

    Err(anyhow!(
        "query result must be {{:ok, value}} or {{:error, reason}}"
    ))
}

fn update_response_from_term(command: Term) -> anyhow::Result<UpdateResponse> {
    let protocol_instance_id = map_get_string(command, protocol_instance_id())?;
    let response_term = map_get(command, response())?;

    let response = if response_term.decode::<Atom>().ok() == Some(accepted()) {
        update_response::Response::Accepted(Default::default())
    } else if let Ok((tag, value)) = response_term.decode::<(Atom, Term)>() {
        if tag == completed() {
            update_response::Response::Completed(payload_from_term(value))
        } else if tag == rejected() {
            update_response::Response::Rejected(failure_from_term(
                value,
                "Temporalex update rejected",
            ))
        } else {
            return Err(anyhow!("unsupported update response tag"));
        }
    } else {
        return Err(anyhow!("unsupported update response"));
    };

    Ok(UpdateResponse {
        protocol_instance_id,
        response: Some(response),
    })
}

fn failure_from_term(term: Term, default_message: &str) -> Failure {
    let message = term
        .decode::<String>()
        .ok()
        .filter(|message| !message.is_empty())
        .unwrap_or_else(|| default_message.to_string());

    let details_payload = payload_from_term(term);
    Failure {
        message,
        source: "Temporalex".to_string(),
        failure_info: Some(failure::FailureInfo::ApplicationFailureInfo(
            ApplicationFailureInfo {
                r#type: "Temporalex.ApplicationError".to_string(),
                non_retryable: false,
                details: Some(Payloads {
                    payloads: vec![details_payload],
                }),
                ..Default::default()
            },
        )),
        ..Default::default()
    }
}

fn cancelled_failure_from_term(term: Term) -> Failure {
    Failure {
        message: "Temporalex activity cancelled".to_string(),
        source: "Temporalex".to_string(),
        failure_info: Some(failure::FailureInfo::CanceledFailureInfo(
            CanceledFailureInfo {
                details: Some(Payloads {
                    payloads: vec![payload_from_term(term)],
                }),
                ..Default::default()
            },
        )),
        ..Default::default()
    }
}

fn failure_to_term<'a>(env: Env<'a>, failure: Option<&Failure>) -> anyhow::Result<Term<'a>> {
    let Some(failure) = failure else {
        return Ok(nil().encode(env));
    };

    let mut map = put_fields!(
        Term::map_new(env),
        message() => failure.message.clone(),
        source() => failure.source.clone(),
    )?;

    if let Some(failure::FailureInfo::ApplicationFailureInfo(info)) = &failure.failure_info {
        map = put_fields!(
            map,
            type_atom() => info.r#type.clone(),
            details() => info
                .details
                .as_ref()
                .map(|payloads| payloads_to_terms(env, &payloads.payloads))
                .transpose()?
                .unwrap_or_default(),
        )?;
    }

    Ok(map)
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
    options.search_attributes = payload_map_option_from_opts(opts, search_attributes())?;
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

fn payload_map_option_from_opts(
    opts: Term,
    key: Atom,
) -> anyhow::Result<Option<HashMap<String, Payload>>> {
    let Some(term) = keyword_get(opts, key)? else {
        return Ok(None);
    };

    if term.decode::<Atom>().ok() == Some(nil()) {
        Ok(None)
    } else {
        Ok(Some(term_to_payload_map(term)?))
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
    let backoff_coefficient = keyword_get_f64(term, backoff_coefficient())?.unwrap_or(0.0);
    if backoff_coefficient < 0.0 {
        return Err(anyhow!(
            "retry_policy.backoff_coefficient must be non-negative"
        ));
    }

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

fn activity_cancellation_type_from_opts(opts: Term) -> anyhow::Result<ActivityCancellationType> {
    let Some(term) = keyword_get(opts, cancellation_type())? else {
        return Ok(ActivityCancellationType::WaitCancellationCompleted);
    };

    let atom: Atom = decode_term(term)?;
    if atom == try_cancel() {
        Ok(ActivityCancellationType::TryCancel)
    } else if atom == wait_cancellation_completed() {
        Ok(ActivityCancellationType::WaitCancellationCompleted)
    } else if atom == abandon() {
        Ok(ActivityCancellationType::Abandon)
    } else {
        Err(anyhow!("unsupported activity cancellation type"))
    }
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

fn map_get_non_negative_i64(map: Term, key: Atom, field_name: &str) -> anyhow::Result<u64> {
    non_negative_millis(map_get_i64(map, key)?, field_name)
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

fn map_get_string(map: Term, key: Atom) -> anyhow::Result<String> {
    decode_term(map_get(map, key)?)
}

fn map_get_i64(map: Term, key: Atom) -> anyhow::Result<i64> {
    decode_term(map_get(map, key)?)
}

fn force_cause_from_opts(opts: Term) -> WorkflowTaskFailedCause {
    let Some(cause) = keyword_get(opts, force_cause()).ok().flatten() else {
        return WorkflowTaskFailedCause::Unspecified;
    };

    match cause.decode::<Atom>().ok() {
        Some(atom) if atom == nondeterminism() => WorkflowTaskFailedCause::NonDeterministicError,
        _ => WorkflowTaskFailedCause::Unspecified,
    }
}

fn duration_from_ms(ms: u64) -> prost_types::Duration {
    prost_types::Duration {
        seconds: (ms / 1000) as i64,
        nanos: ((ms % 1000) * 1_000_000) as i32,
    }
}

fn duration_to_millis(duration: Option<&prost_types::Duration>) -> u64 {
    duration
        .map(|duration| {
            (duration.seconds.max(0) as u64 * 1000) + (duration.nanos.max(0) as u64 / 1_000_000)
        })
        .unwrap_or(0)
}

fn nullable_duration_millis<'a>(
    env: Env<'a>,
    duration: Option<&prost_types::Duration>,
) -> Term<'a> {
    match duration {
        Some(duration) => {
            rustler::Encoder::encode(&(duration_to_millis(Some(duration)) as i64), env)
        }
        None => nil().encode(env),
    }
}

fn timestamp_to_datetime<'a>(
    env: Env<'a>,
    timestamp: Option<&prost_types::Timestamp>,
) -> anyhow::Result<Term<'a>> {
    let Some(timestamp) = timestamp else {
        return Ok(nil().encode(env));
    };

    let dt = OffsetDateTime::from_unix_timestamp(timestamp.seconds)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH)
        .replace_nanosecond(timestamp.nanos.max(0) as u32)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH);

    put_fields!(
        make_struct(env, "Elixir.DateTime")?,
        calendar_atom() => module_atom(env, "Elixir.Calendar.ISO")?,
        year_atom() => dt.year() as i64,
        month_atom() => dt.month() as u8 as i64,
        day_atom() => dt.day() as i64,
        hour_atom() => dt.hour() as i64,
        minute_atom() => dt.minute() as i64,
        second_atom() => dt.second() as i64,
        microsecond_atom() => ((dt.nanosecond() / 1000) as i64, 6_i64),
        time_zone_atom() => "Etc/UTC",
        zone_abbr_atom() => "UTC",
        utc_offset_atom() => 0_i64,
        std_offset_atom() => 0_i64,
    )
}

fn eviction_reason_atom(reason: EvictionReason) -> Atom {
    match reason {
        EvictionReason::CacheFull => cache_full(),
        EvictionReason::CacheMiss => cache_miss(),
        EvictionReason::Nondeterminism => nondeterminism(),
        EvictionReason::LangFail => lang_fail(),
        EvictionReason::LangRequested => lang_requested(),
        EvictionReason::TaskNotFound => task_not_found(),
        EvictionReason::UnhandledCommand => unhandled_command(),
        EvictionReason::Fatal => fatal(),
        EvictionReason::PaginationOrHistoryFetch => pagination_or_history_fetch(),
        EvictionReason::WorkflowExecutionEnding => workflow_execution_ending(),
        EvictionReason::Unspecified => unspecified(),
    }
}

fn activity_cancel_reason(
    reason: temporalio_common::protos::coresdk::activity_task::ActivityCancelReason,
) -> Atom {
    match reason {
        temporalio_common::protos::coresdk::activity_task::ActivityCancelReason::Cancelled => {
            cancelled()
        }
        temporalio_common::protos::coresdk::activity_task::ActivityCancelReason::TimedOut => {
            timeout()
        }
        temporalio_common::protos::coresdk::activity_task::ActivityCancelReason::WorkerShutdown => {
            shutdown()
        }
        temporalio_common::protos::coresdk::activity_task::ActivityCancelReason::NotFound
        | temporalio_common::protos::coresdk::activity_task::ActivityCancelReason::Paused
        | temporalio_common::protos::coresdk::activity_task::ActivityCancelReason::Reset => {
            cancel()
        }
    }
}

fn make_struct<'a>(env: Env<'a>, module: &str) -> anyhow::Result<Term<'a>> {
    make_ex_struct(env, module).map_err(nif_error)
}

fn module_atom<'a>(env: Env<'a>, module: &str) -> anyhow::Result<Term<'a>> {
    Atom::from_str(env, module)
        .map(|atom| atom.encode(env))
        .map_err(nif_error)
}

fn on_load(env: Env, _load_info: Term) -> bool {
    env.register::<RuntimeResource>().is_ok()
        && env.register::<ClientResource>().is_ok()
        && env.register::<WorkerResource>().is_ok()
}

rustler::init!("Elixir.Temporalex.Native", load = on_load);
