//! Proto bridge: decode/encode between protobuf bytes and Elixir terms.
//!
//! All functions are synchronous NIFs (DirtyCpu) — pure CPU work on in-memory data.

use prost::Message;
use rustler::{Binary, Encoder, Env, NifResult, Term};

use crate::atoms;
use crate::helpers;

/// Disambiguate .encode() — prost and rustler both define it on String/bool/u64.
fn enc<'a, T: Encoder>(val: &T, env: Env<'a>) -> Term<'a> {
    Encoder::encode(val, env)
}

// ---------------------------------------------------------------------------
// Decode: WorkflowActivation bytes → Elixir map
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_workflow_activation<'a>(env: Env<'a>, bytes: Binary) -> NifResult<Term<'a>> {
    use temporalio_common::protos::coresdk::workflow_activation::WorkflowActivation;

    let activation = WorkflowActivation::decode(bytes.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(format!("decode error: {e}"))))?;

    let jobs: Vec<Term<'a>> = activation.jobs.iter().map(|job| decode_job(env, job)).collect();

    let map = make_map(
        env,
        &[
            (atoms::run_id(), enc(&activation.run_id, env)),
            (atoms::is_replaying(), enc(&activation.is_replaying, env)),
            (atoms::history_length(), enc(&(activation.history_length as u64), env)),
            (atoms::jobs(), enc(&jobs, env)),
        ],
    )?;

    Ok(enc(&(atoms::ok(), map), env))
}

fn decode_job<'a>(
    env: Env<'a>,
    job: &temporalio_common::protos::coresdk::workflow_activation::WorkflowActivationJob,
) -> Term<'a> {
    use temporalio_common::protos::coresdk::workflow_activation::workflow_activation_job::Variant;

    match &job.variant {
        Some(Variant::InitializeWorkflow(init)) => {
            let wf_type = init.workflow_type.clone();
            let args = decode_payloads(env, &init.arguments);
            let info = make_map(
                env,
                &[
                    (atoms::workflow_type(), enc(&wf_type, env)),
                    (atoms::workflow_id(), enc(&init.workflow_id, env)),
                    (atoms::arguments(), enc(&args, env)),
                ],
            )
            .unwrap();
            enc(&(atoms::initialize_workflow(), info), env)
        }
        Some(Variant::FireTimer(ft)) => {
            let info = make_map(env, &[(atoms::seq(), enc(&(ft.seq as u64), env))]).unwrap();
            enc(&(atoms::fire_timer(), info), env)
        }
        Some(Variant::ResolveActivity(ra)) => {
            let result_term = decode_activity_resolution(env, ra);
            let info = make_map(
                env,
                &[
                    (atoms::seq(), enc(&(ra.seq as u64), env)),
                    (atoms::result(), result_term),
                ],
            )
            .unwrap();
            enc(&(atoms::resolve_activity(), info), env)
        }
        Some(Variant::SignalWorkflow(sig)) => {
            let input = decode_payloads(env, &sig.input);
            let info = make_map(
                env,
                &[
                    (atoms::signal_name(), enc(&sig.signal_name, env)),
                    (atoms::input(), enc(&input, env)),
                    (atoms::identity(), enc(&sig.identity, env)),
                ],
            )
            .unwrap();
            enc(&(atoms::signal_workflow(), info), env)
        }
        Some(Variant::DoUpdate(upd)) => {
            let input = decode_payloads(env, &upd.input);
            let info = make_map(
                env,
                &[
                    (atoms::id(), enc(&upd.id, env)),
                    (atoms::protocol_instance_id(), enc(&upd.protocol_instance_id, env)),
                    (atoms::name(), enc(&upd.name, env)),
                    (atoms::input(), enc(&input, env)),
                ],
            )
            .unwrap();
            enc(&(atoms::do_update(), info), env)
        }
        Some(Variant::QueryWorkflow(q)) => {
            let args = decode_payloads(env, &q.arguments);
            let info = make_map(
                env,
                &[
                    (atoms::query_id(), enc(&q.query_id, env)),
                    (atoms::query_type(), enc(&q.query_type, env)),
                    (atoms::arguments(), enc(&args, env)),
                ],
            )
            .unwrap();
            enc(&(atoms::query_workflow(), info), env)
        }
        Some(Variant::CancelWorkflow(cw)) => {
            let info = make_map(env, &[(atoms::reason(), enc(&format!("{:?}", cw.reason), env))]).unwrap();
            enc(&(atoms::cancel_workflow(), info), env)
        }
        Some(Variant::NotifyHasPatch(nhp)) => {
            let info = make_map(env, &[(atoms::patch_id(), enc(&nhp.patch_id, env))]).unwrap();
            enc(&(atoms::notify_has_patch(), info), env)
        }
        Some(Variant::RemoveFromCache(rfc)) => {
            use temporalio_common::protos::coresdk::workflow_activation::remove_from_cache::EvictionReason;
            let reason_atom = match rfc.reason() {
                EvictionReason::CacheFull => atoms::cache_full(),
                EvictionReason::LangRequested => atoms::lang_requested(),
                EvictionReason::Nondeterminism => atoms::nondeterminism(),
                _ => atoms::unspecified(),
            };
            let info = make_map(
                env,
                &[
                    (atoms::message(), enc(&rfc.message, env)),
                    (atoms::reason(), enc(&reason_atom, env)),
                ],
            )
            .unwrap();
            enc(&(atoms::remove_from_cache(), info), env)
        }
        Some(Variant::UpdateRandomSeed(urs)) => {
            let info = make_map(
                env,
                &[(atoms::randomness_seed(), enc(&(urs.randomness_seed as u64), env))],
            )
            .unwrap();
            enc(&(atoms::update_random_seed(), info), env)
        }
        Some(Variant::ResolveChildWorkflowExecution(rcw)) => {
            let result_term = decode_child_workflow_resolution(env, rcw);
            let info = make_map(
                env,
                &[
                    (atoms::seq(), enc(&(rcw.seq as u64), env)),
                    (atoms::result(), result_term),
                ],
            )
            .unwrap();
            enc(&(atoms::resolve_child_workflow_execution(), info), env)
        }
        Some(Variant::ResolveChildWorkflowExecutionStart(rcws)) => {
            let info = make_map(
                env,
                &[
                    (atoms::seq(), enc(&(rcws.seq as u64), env)),
                ],
            )
            .unwrap();
            enc(&(atoms::resolve_child_workflow_execution_start(), info), env)
        }
        _ => enc(&(atoms::unsupported(), "unknown_job_variant"), env),
    }
}

fn decode_child_workflow_resolution<'a>(
    env: Env<'a>,
    rcw: &temporalio_common::protos::coresdk::workflow_activation::ResolveChildWorkflowExecution,
) -> Term<'a> {
    use temporalio_common::protos::coresdk::child_workflow::child_workflow_result;

    let status = rcw.result.as_ref().and_then(|r| r.status.as_ref());

    match status {
        Some(child_workflow_result::Status::Completed(c)) => {
            let p = c
                .result
                .as_ref()
                .map(|p| decode_payload(env, p))
                .unwrap_or_else(|| enc(&rustler::types::atom::nil(), env));
            enc(&(atoms::completed(), p), env)
        }
        Some(child_workflow_result::Status::Failed(f)) => {
            let ft = f
                .failure
                .as_ref()
                .map(|fail| decode_failure(env, fail))
                .unwrap_or_else(|| enc(&rustler::types::atom::nil(), env));
            enc(&(atoms::failed(), ft), env)
        }
        Some(child_workflow_result::Status::Cancelled(c)) => {
            let ft = c
                .failure
                .as_ref()
                .map(|fail| decode_failure(env, fail))
                .unwrap_or_else(|| enc(&rustler::types::atom::nil(), env));
            enc(&(atoms::cancelled(), ft), env)
        }
        None => enc(&atoms::error(), env),
    }
}

fn decode_activity_resolution<'a>(
    env: Env<'a>,
    ra: &temporalio_common::protos::coresdk::workflow_activation::ResolveActivity,
) -> Term<'a> {
    use temporalio_common::protos::coresdk::activity_result::activity_resolution::Status;

    let status = ra.result.as_ref().and_then(|r| r.status.as_ref());

    match status {
        Some(Status::Completed(c)) => {
            let p = c
                .result
                .as_ref()
                .map(|p| decode_payload(env, p))
                .unwrap_or_else(|| enc(&rustler::types::atom::nil(), env));
            enc(&(atoms::completed(), p), env)
        }
        Some(Status::Failed(f)) => {
            let ft = f
                .failure
                .as_ref()
                .map(|fail| decode_failure(env, fail))
                .unwrap_or_else(|| enc(&rustler::types::atom::nil(), env));
            enc(&(atoms::failed(), ft), env)
        }
        Some(Status::Cancelled(c)) => {
            let ft = c
                .failure
                .as_ref()
                .map(|fail| decode_failure(env, fail))
                .unwrap_or_else(|| enc(&rustler::types::atom::nil(), env));
            enc(&(atoms::cancelled(), ft), env)
        }
        Some(Status::Backoff(b)) => enc(&(atoms::backoff(), format!("{b:?}")), env),
        None => enc(&atoms::error(), env),
    }
}

// ---------------------------------------------------------------------------
// Decode: ActivityTask bytes → Elixir map
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_activity_task<'a>(env: Env<'a>, bytes: Binary) -> NifResult<Term<'a>> {
    use temporalio_common::protos::coresdk::activity_task::{activity_task, ActivityTask};

    let task = ActivityTask::decode(bytes.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(format!("decode error: {e}"))))?;

    let token = helpers::make_binary(env, &task.task_token);

    // ActivityTask has nested variant: Option<activity_task::Variant> which wraps the oneof
    let variant_term = match &task.variant {
        Some(activity_task::Variant::Start(start)) => {
            let input = decode_payloads(env, &start.input);
            let wf_id = start
                .workflow_execution
                .as_ref()
                .map(|we| we.workflow_id.as_str())
                .unwrap_or("");
            let info = make_map(
                env,
                &[
                    (atoms::activity_type(), enc(&start.activity_type, env)),
                    (atoms::activity_id(), enc(&start.activity_id, env)),
                    (atoms::input(), enc(&input, env)),
                    (atoms::attempt(), enc(&(start.attempt as u64), env)),
                    (atoms::workflow_type(), enc(&start.workflow_type, env)),
                    (atoms::workflow_id(), enc(&wf_id, env)),
                    (atoms::workflow_namespace(), enc(&start.workflow_namespace, env)),
                ],
            )?;
            enc(&(atoms::start(), info), env)
        }
        Some(activity_task::Variant::Cancel(cancel)) => {
            let info = make_map(
                env,
                &[(atoms::reason(), enc(&format!("{:?}", cancel.reason), env))],
            )?;
            enc(&(atoms::cancel(), info), env)
        }
        None => {
            return Err(rustler::Error::Term(Box::new("missing activity task variant")));
        }
    };

    let map = make_map(
        env,
        &[
            (atoms::task_token(), token),
            (atoms::variant(), variant_term),
        ],
    )?;

    Ok(enc(&(atoms::ok(), map), env))
}

// ---------------------------------------------------------------------------
// Encode: Elixir terms → WorkflowActivationCompletion bytes
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_workflow_completion<'a>(
    env: Env<'a>,
    run_id: String,
    status: Term<'a>,
) -> NifResult<Term<'a>> {
    use temporalio_common::protos::coresdk::workflow_completion::{
        self, workflow_activation_completion, WorkflowActivationCompletion,
    };
    use temporalio_common::protos::temporal::api::failure::v1::Failure;

    let (tag, value): (rustler::Atom, Term<'a>) = status.decode()?;

    let completion_status = if tag == atoms::successful() {
        let command_terms: Vec<Term<'a>> = value.decode()?;
        let commands: Vec<temporalio_common::protos::coresdk::workflow_commands::WorkflowCommand> = command_terms
            .iter()
            .filter_map(|cmd| decode_workflow_command(env, *cmd).ok())
            .collect();
        workflow_activation_completion::Status::Successful(workflow_completion::Success {
            commands,
            ..Default::default()
        })
    } else if tag == atoms::failed() {
        let msg: String = value
            .map_get(enc(&atoms::message(), env))
            .ok()
            .and_then(|t: Term| t.decode::<String>().ok())
            .unwrap_or_else(|| "unknown".into());

        workflow_activation_completion::Status::Failed(workflow_completion::Failure {
            failure: Some(Failure {
                message: msg,
                ..Default::default()
            }),
            ..Default::default()
        })
    } else {
        return Err(rustler::Error::Term(Box::new(
            "expected {:successful, []} or {:failed, %{message: ...}}",
        )));
    };

    let completion = WorkflowActivationCompletion {
        run_id,
        status: Some(completion_status),
    };

    let bytes = Message::encode_to_vec(&completion);
    let bin = helpers::make_binary(env, &bytes);
    Ok(enc(&(atoms::ok(), bin), env))
}

fn decode_workflow_command<'a>(
    env: Env<'a>,
    cmd: Term<'a>,
) -> NifResult<temporalio_common::protos::coresdk::workflow_commands::WorkflowCommand> {
    use temporalio_common::protos::coresdk::workflow_commands::{self, *};
    use temporalio_common::protos::coresdk::workflow_commands::workflow_command;

    let (tag, info): (rustler::Atom, Term<'a>) = cmd.decode()?;

    let variant = if tag == atoms::schedule_activity() {
        let seq: u32 = get_map_val(env, info, atoms::seq())?;
        let activity_type: String = get_map_val(env, info, atoms::activity_type())?;
        let task_queue: String = get_map_val_or(env, info, atoms::task_queue(), String::new());
        let input_terms: Vec<Term> = get_map_val_or(env, info, atoms::input(), vec![]);
        let timeout: u64 = get_map_val_or(env, info, atoms::schedule_to_close_timeout_ms(), 30000);

        let input: Vec<_> = input_terms
            .into_iter()
            .filter_map(|t| encode_payload_from_term(env, t).ok())
            .collect();

        workflow_command::Variant::ScheduleActivity(ScheduleActivity {
            seq,
            activity_id: seq.to_string(),
            activity_type,
            task_queue,
            arguments: input,
            schedule_to_close_timeout: Some(ms_to_duration(timeout)),
            ..Default::default()
        })
    } else if tag == atoms::start_timer() {
        let seq: u32 = get_map_val(env, info, atoms::seq())?;
        let ms: u64 = get_map_val(env, info, atoms::start_to_fire_timeout_ms())?;

        workflow_command::Variant::StartTimer(StartTimer {
            seq,
            start_to_fire_timeout: Some(ms_to_duration(ms)),
        })
    } else if tag == atoms::complete_workflow_execution() {
        let result_term = info.map_get(enc(&atoms::result(), env)).ok();
        let result = result_term.and_then(|t| encode_payload_from_term(env, t).ok());

        workflow_command::Variant::CompleteWorkflowExecution(CompleteWorkflowExecution {
            result,
        })
    } else if tag == atoms::fail_workflow_execution() {
        let msg: String = get_map_val_or(env, info, atoms::message(), "unknown".into());

        workflow_command::Variant::FailWorkflowExecution(FailWorkflowExecution {
            failure: Some(temporalio_common::protos::temporal::api::failure::v1::Failure {
                message: msg,
                ..Default::default()
            }),
        })
    } else if tag == atoms::continue_as_new() {
        let wf_type: String = get_map_val_or(env, info, atoms::workflow_type(), String::new());
        let arg_terms: Vec<Term> = get_map_val_or(env, info, atoms::arguments(), vec![]);
        let args: Vec<_> = arg_terms
            .into_iter()
            .filter_map(|t| encode_payload_from_term(env, t).ok())
            .collect();

        workflow_command::Variant::ContinueAsNewWorkflowExecution(ContinueAsNewWorkflowExecution {
            workflow_type: wf_type,
            arguments: args,
            ..Default::default()
        })
    } else if tag == atoms::respond_to_query() {
        let query_id: String = get_map_val(env, info, atoms::query_id())?;

        // Try to get succeeded.response
        let succeeded = info.map_get(enc(&atoms::succeeded(), env)).ok();
        let response = succeeded
            .and_then(|s| s.map_get(enc(&atoms::result(), env)).ok())
            .and_then(|t| encode_payload_from_term(env, t).ok());

        workflow_command::Variant::RespondToQuery(QueryResult {
            query_id,
            variant: Some(query_result::Variant::Succeeded(QuerySuccess {
                response,
            })),
        })
    } else if tag == atoms::set_patch_marker() {
        let patch_id: String = get_map_val(env, info, atoms::patch_id())?;
        let deprecated: bool = get_map_val_or(env, info, atoms::deprecated(), false);

        workflow_command::Variant::SetPatchMarker(SetPatchMarker {
            patch_id,
            deprecated,
            ..Default::default()
        })
    } else if tag == atoms::start_child_workflow_execution() {
        let seq: u32 = get_map_val(env, info, atoms::seq())?;
        let wf_type: String = get_map_val(env, info, atoms::workflow_type())?;
        let wf_id: String = get_map_val(env, info, atoms::workflow_id())?;
        let task_queue: String = get_map_val_or(env, info, atoms::task_queue(), String::new());
        let input_terms: Vec<Term> = get_map_val_or(env, info, atoms::input(), vec![]);
        let input: Vec<_> = input_terms
            .into_iter()
            .filter_map(|t| encode_payload_from_term(env, t).ok())
            .collect();

        workflow_command::Variant::StartChildWorkflowExecution(StartChildWorkflowExecution {
            seq,
            workflow_id: wf_id,
            workflow_type: wf_type,
            task_queue,
            input,
            ..Default::default()
        })
    } else {
        return Err(rustler::Error::Term(Box::new(format!(
            "unknown command type"
        ))));
    };

    Ok(WorkflowCommand {
        variant: Some(variant),
        ..Default::default()
    })
}

/// Convert milliseconds to Duration
fn ms_to_duration(ms: u64) -> prost_wkt_types::Duration {
    prost_wkt_types::Duration {
        seconds: (ms / 1000) as i64,
        nanos: ((ms % 1000) * 1_000_000) as i32,
    }
}

/// Get a required map field by atom key
fn get_map_val<'a, T: rustler::Decoder<'a>>(
    env: Env<'a>,
    map: Term<'a>,
    key: rustler::Atom,
) -> NifResult<T> {
    map.map_get(enc(&key, env))
        .map_err(|_| rustler::Error::Term(Box::new(format!("missing key"))))?
        .decode()
}

/// Get an optional map field with a default
fn get_map_val_or<'a, T: rustler::Decoder<'a>>(
    env: Env<'a>,
    map: Term<'a>,
    key: rustler::Atom,
    default: T,
) -> T {
    map.map_get(enc(&key, env))
        .ok()
        .and_then(|t| t.decode().ok())
        .unwrap_or(default)
}

// ---------------------------------------------------------------------------
// Encode: Elixir terms → ActivityTaskCompletion bytes
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_activity_result<'a>(
    env: Env<'a>,
    task_token: Binary,
    result: Term<'a>,
) -> NifResult<Term<'a>> {
    use temporalio_common::protos::coresdk::activity_result::{self, *};
    use temporalio_common::protos::coresdk::ActivityTaskCompletion;
    use temporalio_common::protos::temporal::api::failure::v1::Failure;

    let (tag, value): (rustler::Atom, Term<'a>) = result.decode()?;

    let exec_result = if tag == atoms::completed() {
        let payload = encode_payload_from_term(env, value)?;
        ActivityExecutionResult {
            status: Some(activity_execution_result::Status::Completed(Success {
                result: Some(payload),
            })),
        }
    } else if tag == atoms::failed() {
        let msg: String = value
            .map_get(enc(&atoms::message(), env))
            .ok()
            .and_then(|t: Term| t.decode::<String>().ok())
            .unwrap_or_else(|| "unknown".into());

        ActivityExecutionResult {
            status: Some(activity_execution_result::Status::Failed(
                activity_result::Failure {
                    failure: Some(Failure {
                        message: msg,
                        ..Default::default()
                    }),
                },
            )),
        }
    } else if tag == atoms::cancelled() {
        ActivityExecutionResult {
            status: Some(activity_execution_result::Status::Cancelled(Cancellation {
                failure: Some(Failure {
                    message: "cancelled".into(),
                    ..Default::default()
                }),
            })),
        }
    } else {
        return Err(rustler::Error::Term(Box::new(
            "expected :completed, :failed, or :cancelled",
        )));
    };

    let completion = ActivityTaskCompletion {
        task_token: task_token.as_slice().to_vec(),
        result: Some(exec_result),
    };

    let bytes = Message::encode_to_vec(&completion);
    let bin = helpers::make_binary(env, &bytes);
    Ok(enc(&(atoms::ok(), bin), env))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn decode_payloads<'a>(
    env: Env<'a>,
    payloads: &[temporalio_common::protos::temporal::api::common::v1::Payload],
) -> Vec<Term<'a>> {
    payloads.iter().map(|p| decode_payload(env, p)).collect()
}

fn decode_payload<'a>(
    env: Env<'a>,
    payload: &temporalio_common::protos::temporal::api::common::v1::Payload,
) -> Term<'a> {
    let metadata: Vec<(Term<'a>, Term<'a>)> = payload
        .metadata
        .iter()
        .map(|(k, v)| (enc(&k.as_str(), env), helpers::make_binary(env, v)))
        .collect();

    let meta_map = Term::map_from_pairs(env, &metadata)
        .unwrap_or_else(|_| enc(&rustler::types::atom::nil(), env));
    let data_bin = helpers::make_binary(env, &payload.data);

    make_map(env, &[(atoms::metadata(), meta_map), (atoms::data(), data_bin)]).unwrap()
}

fn decode_failure<'a>(
    env: Env<'a>,
    failure: &temporalio_common::protos::temporal::api::failure::v1::Failure,
) -> Term<'a> {
    make_map(
        env,
        &[
            (atoms::message(), enc(&failure.message, env)),
            (atoms::source(), enc(&failure.source, env)),
        ],
    )
    .unwrap()
}

fn encode_payload_from_term<'a>(
    env: Env<'a>,
    term: Term<'a>,
) -> NifResult<temporalio_common::protos::temporal::api::common::v1::Payload> {
    let data: Vec<u8> = if let Ok(data_term) = term.map_get(enc(&atoms::data(), env)) {
        data_term
            .decode::<Binary>()
            .map(|b| b.as_slice().to_vec())
            .unwrap_or_default()
    } else if let Ok(bin) = term.decode::<Binary>() {
        bin.as_slice().to_vec()
    } else {
        return Err(rustler::Error::Term(Box::new("expected payload map or binary")));
    };

    let mut metadata = std::collections::HashMap::new();
    if let Ok(meta_term) = term.map_get(enc(&atoms::metadata(), env)) {
        if let Some(iter) = rustler::MapIterator::new(meta_term) {
            for (k, v) in iter {
                if let Ok(key) = k.decode::<String>() {
                    if let Ok(val) = v.decode::<Binary>() {
                        metadata.insert(key, val.as_slice().to_vec());
                    } else if let Ok(val) = v.decode::<String>() {
                        metadata.insert(key, val.into_bytes());
                    }
                }
            }
        }
    }

    Ok(temporalio_common::protos::temporal::api::common::v1::Payload {
        metadata,
        data,
        ..Default::default()
    })
}

fn make_map<'a>(
    env: Env<'a>,
    entries: &[(rustler::Atom, Term<'a>)],
) -> NifResult<Term<'a>> {
    let keys: Vec<Term<'a>> = entries.iter().map(|(k, _)| enc(k, env)).collect();
    let vals: Vec<Term<'a>> = entries.iter().map(|(_, v)| *v).collect();
    Term::map_from_arrays(env, &keys, &vals)
        .map_err(|_| rustler::Error::Term(Box::new("failed to build map")))
}
