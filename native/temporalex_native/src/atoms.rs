rustler::atoms! {
    ok,
    error,

    // TaskGuard error reasons
    task_crashed,

    // Connect
    connected,
    connect_error,

    // Worker
    worker_started,
    worker_error,

    // Poll loops
    workflow_activation,
    activity_task,
    poll_loop_exited,
    workflow,
    activity,
    shutdown,
    crashed,

    // Completions
    workflow_completion,
    activity_completion,
    shutdown_complete,

    // Client operations
    start_workflow_result,
    signal_workflow_result,
    query_workflow_result,
    cancel_workflow_result,
    terminate_workflow_result,
    get_result_result,
    describe_workflow_result,
    list_workflows_result,

    // Proto bridge: activation job types
    initialize_workflow,
    fire_timer,
    resolve_activity,
    signal_workflow,
    do_update,
    query_workflow,
    cancel_workflow,
    notify_has_patch,
    remove_from_cache,
    update_random_seed,
    resolve_child_workflow_execution_start,
    resolve_child_workflow_execution,
    unsupported,

    // Proto bridge: activity task variants
    start,
    cancel,

    // Proto bridge: result types
    completed,
    failed,
    cancelled,
    backoff,
    successful,
    succeeded,

    // Proto bridge: commands
    schedule_activity,
    start_timer,
    complete_workflow_execution,
    fail_workflow_execution,
    continue_as_new,
    respond_to_query,
    set_patch_marker,

    // Proto bridge: removal reasons
    cache_full,
    lang_requested,
    nondeterminism,
    unspecified,

    // Proto bridge: field atoms
    run_id,
    is_replaying,
    history_length,
    jobs,
    task_token,
    variant,
    activity_type,
    activity_id,
    input,
    attempt,
    workflow_type,
    workflow_id,
    workflow_namespace,
    seq,
    result,
    signal_name,
    identity,
    query_id,
    query_type,
    arguments,
    name,
    id,
    protocol_instance_id,
    message,
    reason,
    source,
    details,
    patch_id,
    deprecated,
    randomness_seed,
    metadata,
    data,
    encoding,
    failure,
    r#type,
    non_retryable,
    task_queue,
    schedule_to_close_timeout_ms,
    start_to_close_timeout_ms,
    heartbeat_timeout_ms,
    schedule_to_start_timeout_ms,
    start_to_fire_timeout_ms,
    headers,
}
