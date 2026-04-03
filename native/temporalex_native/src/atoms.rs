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
}
