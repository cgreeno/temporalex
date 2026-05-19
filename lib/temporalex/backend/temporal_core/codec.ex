defmodule Temporalex.Backend.TemporalCore.Codec do
  @moduledoc false

  alias Temporalex.Backend.TemporalCore.PayloadConverter
  alias Temporalex.Backend.TemporalCore.Proto.Schema
  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.ActivityTask
  alias Temporalex.Core.Activation
  alias Temporalex.Core.Command
  alias Temporalex.Core.Completion
  alias Temporalex.Core.Job
  alias Temporalex.Failure

  @activity_task_completion :"coresdk.ActivityTaskCompletion"
  @activity_heartbeat :"coresdk.ActivityHeartbeat"
  @activity_task :"coresdk.activity_task.ActivityTask"
  @workflow_activation :"coresdk.workflow_activation.WorkflowActivation"
  @workflow_activation_completion :"coresdk.workflow_completion.WorkflowActivationCompletion"

  @eviction_reasons %{
    CACHE_FULL: :cache_full,
    CACHE_MISS: :cache_miss,
    NONDETERMINISM: :nondeterminism,
    LANG_FAIL: :lang_fail,
    LANG_REQUESTED: :lang_requested,
    TASK_NOT_FOUND: :task_not_found,
    UNHANDLED_COMMAND: :unhandled_command,
    FATAL: :fatal,
    PAGINATION_OR_HISTORY_FETCH: :pagination_or_history_fetch,
    WORKFLOW_EXECUTION_ENDING: :workflow_execution_ending
  }
  @activity_cancel_reasons %{
    CANCELLED: :cancelled,
    TIMED_OUT: :timeout,
    WORKER_SHUTDOWN: :shutdown
  }
  @retry_states %{
    RETRY_STATE_IN_PROGRESS: :in_progress,
    RETRY_STATE_NON_RETRYABLE_FAILURE: :non_retryable_failure,
    RETRY_STATE_TIMEOUT: :timeout,
    RETRY_STATE_MAXIMUM_ATTEMPTS_REACHED: :maximum_attempts_reached,
    RETRY_STATE_RETRY_POLICY_NOT_SET: :retry_policy_not_set,
    RETRY_STATE_INTERNAL_SERVER_ERROR: :internal_server_error,
    RETRY_STATE_CANCEL_REQUESTED: :cancel_requested
  }
  @retry_states_to_proto Map.new(@retry_states, fn {proto, term} -> {term, proto} end)
  @timeout_types %{
    TIMEOUT_TYPE_START_TO_CLOSE: :start_to_close,
    TIMEOUT_TYPE_SCHEDULE_TO_START: :schedule_to_start,
    TIMEOUT_TYPE_SCHEDULE_TO_CLOSE: :schedule_to_close,
    TIMEOUT_TYPE_HEARTBEAT: :heartbeat
  }
  @timeout_types_to_proto Map.new(@timeout_types, fn {proto, term} -> {term, proto} end)
  @failure_info_types %{
    timeout_failure_info: :timeout_failure,
    canceled_failure_info: :cancelled_failure,
    terminated_failure_info: :terminated_failure,
    server_failure_info: :server_failure,
    reset_workflow_failure_info: :reset_workflow_failure,
    activity_failure_info: :activity_failure,
    child_workflow_execution_failure_info: :child_workflow_failure,
    nexus_operation_execution_failure_info: :nexus_operation_failure,
    nexus_handler_failure_info: :nexus_handler_failure,
    application_failure_info: :failed
  }
  @activity_cancellation_types_to_proto %{
    try_cancel: :TRY_CANCEL,
    wait_cancellation_completed: :WAIT_CANCELLATION_COMPLETED,
    abandon: :ABANDON
  }
  @versioning_intents_to_proto %{
    nil => :UNSPECIFIED,
    unspecified: :UNSPECIFIED,
    compatible: :COMPATIBLE,
    default: :DEFAULT
  }
  @continue_as_new_versioning_behaviors_to_proto %{
    nil => :CONTINUE_AS_NEW_VERSIONING_BEHAVIOR_UNSPECIFIED,
    unspecified: :CONTINUE_AS_NEW_VERSIONING_BEHAVIOR_UNSPECIFIED,
    auto_upgrade: :CONTINUE_AS_NEW_VERSIONING_BEHAVIOR_AUTO_UPGRADE,
    use_ramping_version: :CONTINUE_AS_NEW_VERSIONING_BEHAVIOR_USE_RAMPING_VERSION
  }

  def workflow_activation_from_bytes(bytes) when is_binary(bytes) do
    with {:ok, proto} <- decode(@workflow_activation, bytes, defaults: true),
         {:ok, activation} <- workflow_activation_from_proto(proto) do
      {:ok, activation}
    end
  end

  def activity_task_from_bytes(bytes) when is_binary(bytes) do
    with {:ok, proto} <- decode(@activity_task, bytes, defaults: true),
         {:ok, task} <- activity_task_from_proto(proto) do
      {:ok, task}
    end
  end

  def workflow_completion_to_bytes(%Completion{} = completion, opts) do
    task_queue = Keyword.fetch!(opts, :task_queue)

    with {:ok, proto} <- workflow_completion_to_proto(completion, task_queue),
         {:ok, bytes} <- encode(@workflow_activation_completion, proto) do
      {:ok, bytes}
    end
  end

  def activity_completion_to_bytes(%ActivityCompletion{} = completion) do
    with {:ok, proto} <- activity_completion_to_proto(completion),
         {:ok, bytes} <- encode(@activity_task_completion, proto) do
      {:ok, bytes}
    end
  end

  def activity_heartbeat_to_bytes(task_token, details) when is_binary(task_token) do
    proto = %{
      task_token: task_token,
      details: if(is_nil(details), do: [], else: [PayloadConverter.term_to_payload(details)])
    }

    encode(@activity_heartbeat, proto)
  end

  defp encode(message, proto) do
    case Schema.encode(proto, message) do
      {:ok, binary} -> {:ok, binary}
      {:error, error} -> {:error, format_error(error)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp decode(message, bytes, opts) do
    case Schema.decode(bytes, message, opts) do
      {:ok, proto} -> {:ok, proto}
      {:error, error} -> {:error, format_error(error)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp workflow_activation_from_proto(proto) do
    with {:ok, jobs} <- activation_jobs_from_proto(Map.get(proto, :jobs, [])) do
      {:ok,
       struct!(
         Activation,
         proto
         |> Map.take([
           :run_id,
           :timestamp,
           :is_replaying,
           :history_length,
           :history_size_bytes,
           :continue_as_new_suggested,
           :available_internal_flags
         ])
         |> Map.put(:jobs, jobs)
       )}
    end
  end

  defp activation_jobs_from_proto(jobs) when is_list(jobs) do
    map_ok(jobs, &activation_job_from_proto/1)
  end

  defp activation_job_from_proto(%{
         variant:
           {:initialize_workflow,
            %{
              workflow_type: workflow_type,
              workflow_id: workflow_id,
              attempt: attempt,
              identity: identity,
              first_execution_run_id: first_execution_run_id,
              randomness_seed: randomness_seed
            } = init}
       }) do
    workflow_info = %{
      workflow_id: workflow_id,
      workflow_type: workflow_type,
      attempt: attempt,
      identity: identity,
      run_id: first_execution_run_id
    }

    with_payloads_and_headers(init, :arguments, fn arguments, headers ->
      {:ok,
       %Job.InitializeWorkflow{
         workflow_type: workflow_type,
         workflow_id: workflow_id,
         arguments: arguments,
         headers: headers,
         workflow_info: workflow_info,
         randomness_seed: randomness_seed
       }}
    end)
  end

  defp activation_job_from_proto(%{variant: {:fire_timer, %{seq: seq}}}) do
    {:ok, %Job.TimerFired{seq: seq}}
  end

  defp activation_job_from_proto(%{variant: {:resolve_activity, %{seq: seq} = resolution}}) do
    with {:ok, result} <- activity_resolution_from_proto(Map.get(resolution, :result)) do
      {:ok,
       %Job.ActivityResolved{
         seq: seq,
         result: result
       }}
    end
  end

  defp activation_job_from_proto(%{
         variant: {:update_random_seed, %{randomness_seed: randomness_seed}}
       }) do
    {:ok, %Job.UpdateRandomSeed{randomness_seed: randomness_seed}}
  end

  defp activation_job_from_proto(%{
         variant:
           {:query_workflow,
            %{
              query_id: query_id,
              query_type: query_type
            } = query}
       }) do
    with_payloads_and_headers(query, :arguments, fn args, headers ->
      {:ok,
       %Job.QueryReceived{
         query_id: query_id,
         query_type: query_type,
         args: args,
         headers: headers
       }}
    end)
  end

  defp activation_job_from_proto(%{variant: {:cancel_workflow, %{reason: reason}}}) do
    {:ok, %Job.CancelWorkflow{reason: reason}}
  end

  defp activation_job_from_proto(%{
         variant:
           {:signal_workflow,
            %{
              signal_name: signal_name,
              identity: identity
            } = signal}
       }) do
    with_payloads_and_headers(signal, :input, fn args, headers ->
      {:ok,
       %Job.SignalReceived{
         name: signal_name,
         args: args,
         headers: headers,
         identity: identity
       }}
    end)
  end

  defp activation_job_from_proto(%{variant: {:notify_has_patch, %{patch_id: patch_id}}}) do
    {:ok, %Job.NotifyPatch{id: patch_id}}
  end

  defp activation_job_from_proto(%{
         variant:
           {:do_update,
            %{
              id: id,
              protocol_instance_id: protocol_instance_id,
              name: name,
              run_validator: run_validator
            } = update}
       }) do
    with_payloads_and_headers(update, :input, fn args, headers ->
      {:ok,
       %Job.UpdateReceived{
         id: id,
         protocol_instance_id: protocol_instance_id,
         name: name,
         args: args,
         headers: headers,
         meta: nil,
         run_validator: run_validator
       }}
    end)
  end

  defp activation_job_from_proto(%{
         variant: {:remove_from_cache, %{reason: reason, message: message}}
       }) do
    {:ok,
     %Job.RemoveFromCache{
       reason: eviction_reason_to_atom(reason),
       message: message
     }}
  end

  defp activation_job_from_proto(%{variant: {variant, _value}}) do
    {:error, "unsupported workflow activation job from Temporal Core: #{variant}"}
  end

  defp activation_job_from_proto(_job), do: {:error, "activation job had no variant"}

  defp activity_resolution_from_proto(%{status: {:completed, success}}) do
    case Map.fetch(success, :result) do
      {:ok, payload} ->
        with {:ok, term} <- PayloadConverter.payload_to_term(payload), do: {:ok, {:ok, term}}

      :error ->
        {:error, "activity result missing payload"}
    end
  end

  defp activity_resolution_from_proto(%{status: {:failed, failure}}) do
    with {:ok, failure} <- failure_from_proto(Map.get(failure, :failure)) do
      {:ok, {:error, failure}}
    end
  end

  defp activity_resolution_from_proto(%{status: {:cancelled, cancellation}}) do
    with {:ok, failure} <- failure_from_proto(Map.get(cancellation, :failure)) do
      {:ok, {:cancelled, failure}}
    end
  end

  defp activity_resolution_from_proto(%{status: {:backoff, backoff}}) do
    {:ok,
     {:backoff,
      %{
        attempt: Map.get(backoff, :attempt, 0),
        timeout: Map.get(backoff, :backoff_duration, 0)
      }}}
  end

  defp activity_resolution_from_proto(nil), do: {:error, "activity resolution missing result"}
  defp activity_resolution_from_proto(_resolution), do: {:error, "activity resolution empty"}

  defp activity_task_from_proto(%{
         task_token: task_token,
         variant:
           {:start,
            %{
              workflow_namespace: workflow_namespace,
              workflow_type: workflow_type,
              activity_id: activity_id,
              activity_type: activity_type,
              header_fields: proto_headers,
              input: proto_input,
              attempt: attempt,
              is_local: is_local
            } = start}
       }) do
    execution = Map.get(start, :workflow_execution, %{})

    with {:ok, input} <- payloads_to_terms(proto_input),
         {:ok, headers} <- PayloadConverter.payload_map_to_term(proto_headers) do
      {:ok,
       %ActivityTask{
         task_token: task_token,
         activity_id: activity_id,
         activity_type: activity_type,
         workflow_id: Map.get(execution, :workflow_id, ""),
         run_id: Map.get(execution, :run_id, ""),
         workflow_type: workflow_type,
         namespace: workflow_namespace,
         task_queue: nil,
         input: input,
         attempt: attempt,
         heartbeat_timeout: Map.get(start, :heartbeat_timeout),
         is_local: is_local,
         headers: headers,
         variant: :start,
         cancel_reason: nil
       }}
    end
  end

  defp activity_task_from_proto(%{task_token: task_token, variant: {:cancel, cancel}}) do
    {:ok,
     %ActivityTask{
       task_token: task_token,
       variant: :cancel,
       cancel_reason: activity_cancel_reason(Map.get(cancel, :reason, :NOT_FOUND))
     }}
  end

  defp activity_task_from_proto(%{variant: {variant, _value}}) do
    {:error, "unsupported activity task from Temporal Core: #{variant}"}
  end

  defp activity_task_from_proto(_task), do: {:error, "activity task had no variant"}

  defp failure_from_proto(nil), do: {:ok, nil}

  defp failure_from_proto(failure) do
    with {:ok, cause} <- failure_from_proto(Map.get(failure, :cause)) do
      base_attrs = failure_base_attrs(failure, cause)

      case Map.get(failure, :failure_info) do
        {:application_failure_info, info} ->
          with {:ok, details} <- payloads_to_terms_option(Map.get(info, :details)) do
            {:ok,
             struct!(
               Failure.ApplicationError,
               Map.merge(base_attrs, %{
                 type: info.type,
                 details: details,
                 retryable?: not info.non_retryable
               })
             )}
          end

        {:canceled_failure_info, info} ->
          with {:ok, details} <- payloads_to_terms_option(Map.get(info, :details)) do
            {:ok,
             struct!(
               Failure.CancelledError,
               Map.merge(base_attrs, %{
                 identity: info.identity,
                 details: details
               })
             )}
          end

        {:timeout_failure_info, info} ->
          with {:ok, last_heartbeat_details} <-
                 payloads_to_terms_option(Map.get(info, :last_heartbeat_details)) do
            {:ok,
             struct!(
               Failure.TimeoutError,
               Map.merge(base_attrs, %{
                 timeout_type: timeout_type_from_proto(info.timeout_type),
                 last_heartbeat_details: last_heartbeat_details
               })
             )}
          end

        {:activity_failure_info, info} ->
          {:ok,
           struct!(
             Failure.ActivityError,
             Map.merge(base_attrs, %{
               identity: info.identity,
               activity_id: info.activity_id,
               activity_type: Map.get(info, :activity_type, ""),
               retry_state: retry_state_from_proto(info.retry_state)
             })
           )}

        {:child_workflow_execution_failure_info, info} ->
          execution = Map.get(info, :workflow_execution, %{})

          {:ok,
           struct!(
             Failure.WorkflowExecutionError,
             Map.merge(base_attrs, %{
               namespace: info.namespace,
               workflow_id: Map.get(execution, :workflow_id, ""),
               run_id: Map.get(execution, :run_id, ""),
               workflow_type: Map.get(info, :workflow_type, ""),
               retry_state: retry_state_from_proto(info.retry_state)
             })
           )}

        other ->
          {:ok,
           struct!(
             Failure.UnknownError,
             Map.merge(base_attrs, %{failure_type: failure_info_type(other)})
           )}
      end
    end
  end

  defp failure_base_attrs(%{message: message, source: source, stack_trace: stack_trace}, cause) do
    %{
      message: message,
      source: source,
      stack_trace: stack_trace,
      cause: cause
    }
  end

  defp payloads_to_terms(payloads), do: PayloadConverter.payloads_to_terms(payloads || [])

  defp with_payloads_and_headers(proto, payload_key, fun) do
    with {:ok, args} <- payloads_to_terms(Map.get(proto, payload_key, [])),
         {:ok, headers} <- PayloadConverter.payload_map_to_term(Map.get(proto, :headers, %{})) do
      fun.(args, headers)
    end
  end

  defp payloads_to_terms_option(nil), do: {:ok, []}
  defp payloads_to_terms_option(%{} = payloads) when map_size(payloads) == 0, do: {:ok, []}

  defp payloads_to_terms_option(%{payloads: payloads}) do
    payloads_to_terms(payloads)
  end

  defp map_ok(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup(map, key, default), do: Map.get(map, key, default)

  defp eviction_reason_to_atom(reason), do: lookup(@eviction_reasons, reason, :unspecified)
  defp activity_cancel_reason(reason), do: lookup(@activity_cancel_reasons, reason, :cancel)
  defp retry_state_from_proto(state), do: lookup(@retry_states, state, :unspecified)
  defp timeout_type_from_proto(type), do: lookup(@timeout_types, type, :unspecified)
  defp failure_info_type({type, _}), do: lookup(@failure_info_types, type, :unknown_failure)
  defp failure_info_type(_), do: :unknown_failure

  defp workflow_completion_to_proto(
         %Completion{run_id: run_id, status: {:ok, commands}},
         task_queue
       ) do
    with {:ok, commands} <- commands_to_proto(commands, task_queue) do
      {:ok,
       %{
         run_id: run_id,
         status:
           {:successful,
            %{
              commands: commands,
              used_internal_flags: [],
              versioning_behavior: :VERSIONING_BEHAVIOR_UNSPECIFIED
            }}
       }}
    end
  end

  defp workflow_completion_to_proto(
         %Completion{run_id: run_id, status: {:failed, reason, opts}},
         _task_queue
       ) do
    {:ok,
     %{
       run_id: run_id,
       status:
         {:failed,
          %{
            failure: failure_to_proto(reason, "Temporalex activation failure"),
            force_cause: force_cause_from_opts(opts)
          }}
     }}
  end

  defp workflow_completion_to_proto(_completion, _task_queue) do
    {:error, "unsupported workflow completion status"}
  end

  defp commands_to_proto(commands, task_queue) when is_list(commands) do
    map_ok(commands, &command_to_proto(&1, task_queue))
  end

  defp command_to_proto(%Command.StartTimer{seq: seq, duration_ms: duration_ms}, _task_queue) do
    with {:ok, duration} <- duration_from_ms(duration_ms, "timer duration") do
      {:ok, %{variant: {:start_timer, %{seq: seq, start_to_fire_timeout: duration}}}}
    end
  end

  defp command_to_proto(%Command.CancelTimer{seq: seq}, _task_queue) do
    {:ok, %{variant: {:cancel_timer, %{seq: seq}}}}
  end

  defp command_to_proto(%Command.RequestCancelActivity{seq: seq}, _task_queue) do
    {:ok, %{variant: {:request_cancel_activity, %{seq: seq}}}}
  end

  defp command_to_proto(%Command.ScheduleActivity{} = command, default_task_queue) do
    with {:ok, schedule_to_close_timeout} <-
           duration_from_ms(
             command.schedule_to_close_timeout_ms,
             "activity schedule_to_close_timeout"
           ),
         {:ok, schedule_to_start_timeout} <-
           optional_duration_ms(
             command.schedule_to_start_timeout_ms,
             "activity schedule_to_start_timeout"
           ),
         {:ok, start_to_close_timeout} <-
           duration_from_ms(command.start_to_close_timeout_ms, "activity start_to_close_timeout"),
         {:ok, heartbeat_timeout} <-
           optional_duration_ms(command.heartbeat_timeout_ms, "activity heartbeat_timeout"),
         {:ok, headers} <- PayloadConverter.term_to_payload_map(command.headers),
         {:ok, retry_policy} <- retry_policy_to_proto(command.retry_policy),
         {:ok, cancellation_type} <-
           activity_cancellation_type_to_proto(command.cancellation_type) do
      schedule = %{
        seq: command.seq,
        activity_id: command.activity_id,
        activity_type: command.type,
        task_queue: command.task_queue || default_task_queue,
        headers: headers,
        arguments: PayloadConverter.term_to_payloads_list(command.input || []),
        schedule_to_close_timeout: schedule_to_close_timeout,
        schedule_to_start_timeout: schedule_to_start_timeout,
        start_to_close_timeout: start_to_close_timeout,
        heartbeat_timeout: heartbeat_timeout,
        retry_policy: retry_policy,
        cancellation_type: cancellation_type,
        do_not_eagerly_execute: command.do_not_eagerly_execute
      }

      {:ok, %{variant: {:schedule_activity, drop_nil(schedule)}}}
    end
  end

  defp command_to_proto(%Command.CompleteWorkflow{result: result}, _task_queue) do
    {:ok,
     %{
       variant:
         {:complete_workflow_execution, %{result: PayloadConverter.term_to_payload(result)}}
     }}
  end

  defp command_to_proto(%Command.FailWorkflow{reason: reason}, _task_queue) do
    {:ok,
     %{
       variant:
         {:fail_workflow_execution,
          %{failure: failure_to_proto(reason, "Temporalex workflow failure")}}
     }}
  end

  defp command_to_proto(%Command.ContinueAsNew{} = command, _task_queue) do
    with {:ok, workflow_run_timeout} <-
           optional_duration_ms(
             command.workflow_run_timeout_ms,
             "continue-as-new workflow_run_timeout"
           ),
         {:ok, workflow_task_timeout} <-
           optional_duration_ms(
             command.workflow_task_timeout_ms,
             "continue-as-new workflow_task_timeout"
           ),
         {:ok, memo} <- PayloadConverter.term_to_payload_map(command.memo),
         {:ok, headers} <- PayloadConverter.term_to_payload_map(command.headers),
         {:ok, search_attributes} <- search_attributes_to_proto(command.search_attributes),
         {:ok, retry_policy} <- retry_policy_to_proto(command.retry_policy),
         {:ok, versioning_intent} <- versioning_intent_to_proto(command.versioning_intent),
         {:ok, initial_versioning_behavior} <-
           continue_as_new_versioning_behavior_to_proto(command.initial_versioning_behavior) do
      continue = %{
        workflow_type: command.workflow_type || "",
        task_queue: command.task_queue || "",
        arguments: [PayloadConverter.term_to_payload(command.input)],
        workflow_run_timeout: workflow_run_timeout,
        workflow_task_timeout: workflow_task_timeout,
        memo: memo,
        headers: headers,
        search_attributes: search_attributes,
        retry_policy: retry_policy,
        versioning_intent: versioning_intent,
        initial_versioning_behavior: initial_versioning_behavior
      }

      {:ok, %{variant: {:continue_as_new_workflow_execution, drop_nil(continue)}}}
    end
  end

  defp command_to_proto(%Command.CancelWorkflow{}, _task_queue) do
    {:ok, %{variant: {:cancel_workflow_execution, %{}}}}
  end

  defp command_to_proto(%Command.RespondToQuery{} = command, _task_queue) do
    with {:ok, result} <- query_result_to_proto(command.result) do
      {:ok,
       %{
         variant:
           {:respond_to_query,
            %{
              query_id: command.query_id,
              variant: result
            }}
       }}
    end
  end

  defp command_to_proto(%Command.RespondToUpdate{} = command, _task_queue) do
    with {:ok, response} <- update_response_to_proto(command.response) do
      {:ok,
       %{
         variant:
           {:update_response,
            %{
              protocol_instance_id: command.protocol_instance_id,
              response: response
            }}
       }}
    end
  end

  defp command_to_proto(%Command.SetPatchMarker{} = command, _task_queue) do
    {:ok,
     %{
       variant:
         {:set_patch_marker,
          %{
            patch_id: command.id,
            deprecated: command.deprecated
          }}
     }}
  end

  defp command_to_proto(%Command.UpsertSearchAttributes{attrs: attrs}, _task_queue) do
    with {:ok, indexed_fields} <- PayloadConverter.search_attributes_to_payload_map(attrs) do
      {:ok,
       %{
         variant:
           {:upsert_workflow_search_attributes,
            %{search_attributes: %{indexed_fields: indexed_fields}}}
       }}
    end
  end

  defp command_to_proto(command, _task_queue) do
    {:error, "unsupported workflow command #{inspect(command.__struct__)}"}
  end

  defp activity_completion_to_proto(%ActivityCompletion{task_token: task_token, result: result}) do
    with {:ok, status} <- activity_result_to_proto(result) do
      {:ok, %{task_token: task_token, result: %{status: status}}}
    end
  end

  defp activity_result_to_proto({:ok, value}) do
    {:ok, {:completed, %{result: PayloadConverter.term_to_payload(value)}}}
  end

  defp activity_result_to_proto({:error, reason}) do
    {:ok, {:failed, %{failure: failure_to_proto(reason, "Temporalex activity failure")}}}
  end

  defp activity_result_to_proto({:cancelled, reason}) do
    {:ok, {:cancelled, %{failure: cancelled_failure_to_proto(reason)}}}
  end

  defp activity_result_to_proto(_result) do
    {:error, "activity completion result must be a tagged tuple"}
  end

  defp query_result_to_proto({:ok, value}) do
    {:ok, {:succeeded, %{response: PayloadConverter.term_to_payload(value)}}}
  end

  defp query_result_to_proto({:error, reason}) do
    {:ok, {:failed, failure_to_proto(reason, "Temporalex query failure")}}
  end

  defp query_result_to_proto(_result) do
    {:error, "query result must be {:ok, value} or {:error, reason}"}
  end

  defp update_response_to_proto(:accepted), do: {:ok, {:accepted, %{}}}

  defp update_response_to_proto({:completed, value}) do
    {:ok, {:completed, PayloadConverter.term_to_payload(value)}}
  end

  defp update_response_to_proto({:rejected, reason}) do
    {:ok, {:rejected, failure_to_proto(reason, "Temporalex update rejected")}}
  end

  defp update_response_to_proto(_response), do: {:error, "unsupported update response"}

  defp failure_proto_base(error, default_message, opts) do
    message =
      case Keyword.get(opts, :message, :non_empty) do
        :nil_only -> error.message || default_message
        :non_empty -> non_empty(error.message, default_message)
      end

    %{
      message: message,
      source: error.source || "Temporalex",
      stack_trace: error.stack_trace || "",
      cause: maybe_failure(error.cause, "Temporalex caused failure")
    }
  end

  defp failure_proto(error, default_message, failure_info, opts \\ []) do
    Map.put(failure_proto_base(error, default_message, opts), :failure_info, failure_info)
  end

  defp failure_to_proto({:exception, error, _stacktrace}, default_message) do
    failure_to_proto(error, default_message)
  end

  defp failure_to_proto(%Failure.ApplicationError{} = error, default_message) do
    failure_proto(
      error,
      default_message,
      {:application_failure_info,
       %{
         type: non_empty(error.type, "Temporalex.ApplicationError"),
         non_retryable: not error.retryable?,
         details: %{payloads: PayloadConverter.term_to_payloads_list(error.details || [])}
       }}
    )
  end

  defp failure_to_proto(%Failure.CancelledError{} = error, _default_message) do
    failure_proto(
      error,
      "Temporalex activity cancelled",
      {:canceled_failure_info,
       %{
         details: %{payloads: PayloadConverter.term_to_payloads_list(error.details || [])},
         identity: error.identity || ""
       }},
      message: :nil_only
    )
  end

  defp failure_to_proto(%Failure.TimeoutError{} = error, default_message) do
    failure_proto(
      error,
      default_message,
      {:timeout_failure_info,
       %{
         timeout_type: timeout_type_to_proto(error.timeout_type),
         last_heartbeat_details: %{
           payloads: PayloadConverter.term_to_payloads_list(error.last_heartbeat_details || [])
         }
       }}
    )
  end

  defp failure_to_proto(%Failure.ActivityError{} = error, default_message) do
    failure_proto(
      error,
      default_message,
      {:activity_failure_info,
       %{
         identity: error.identity || "",
         activity_type: if(blank?(error.activity_type), do: nil, else: error.activity_type),
         activity_id: error.activity_id || "",
         retry_state: retry_state_to_proto(error.retry_state)
       }}
    )
  end

  defp failure_to_proto(%Failure.WorkflowExecutionError{} = error, default_message) do
    failure_proto(
      error,
      default_message,
      {:child_workflow_execution_failure_info,
       %{
         namespace: error.namespace || "",
         workflow_execution:
           if(blank?(error.workflow_id) and blank?(error.run_id),
             do: nil,
             else: %{workflow_id: error.workflow_id || "", run_id: error.run_id || ""}
           ),
         workflow_type: if(blank?(error.workflow_type), do: nil, else: error.workflow_type),
         retry_state: retry_state_to_proto(error.retry_state)
       }}
    )
  end

  defp failure_to_proto(term, default_message) do
    message =
      if is_binary(term) and term != "" do
        term
      else
        default_message
      end

    %{
      message: message,
      source: "Temporalex",
      failure_info:
        {:application_failure_info,
         %{
           type: "Temporalex.ApplicationError",
           non_retryable: false,
           details: %{payloads: [PayloadConverter.term_to_payload(term)]}
         }}
    }
  end

  defp cancelled_failure_to_proto(%Failure.CancelledError{} = error),
    do: failure_to_proto(error, error.message)

  defp cancelled_failure_to_proto(reason) do
    %{
      message: "Temporalex activity cancelled",
      source: "Temporalex",
      failure_info:
        {:canceled_failure_info,
         %{details: %{payloads: [PayloadConverter.term_to_payload(reason)]}}}
    }
  end

  defp maybe_failure(nil, _message), do: nil
  defp maybe_failure(cause, message), do: failure_to_proto(cause, message)

  defp duration_from_ms(ms, option_name) do
    with {:ok, ms} <- non_negative_millis(ms, option_name) do
      {:ok, ms}
    end
  end

  defp optional_duration_ms(nil, _option_name), do: {:ok, nil}
  defp optional_duration_ms(ms, option_name), do: duration_from_ms(ms, option_name)

  defp non_negative_millis(ms, _option_name) when is_integer(ms) and ms >= 0, do: {:ok, ms}

  defp non_negative_millis(ms, option_name) when is_integer(ms),
    do: {:error, "#{option_name} must be non-negative"}

  defp non_negative_millis(_ms, option_name),
    do: {:error, "#{option_name} must be an integer number of milliseconds"}

  defp search_attributes_to_proto(nil), do: {:ok, nil}

  defp search_attributes_to_proto(attrs) do
    with {:ok, indexed_fields} <- PayloadConverter.search_attributes_to_payload_map(attrs) do
      {:ok, %{indexed_fields: indexed_fields}}
    end
  end

  defp retry_policy_to_proto(nil), do: {:ok, nil}

  defp retry_policy_to_proto(%Command.RetryPolicy{} = policy) do
    with {:ok, initial_interval} <-
           optional_duration_ms(policy.initial_interval_ms, "retry_policy.initial_interval"),
         {:ok, maximum_interval} <-
           optional_duration_ms(policy.maximum_interval_ms, "retry_policy.maximum_interval"),
         {:ok, backoff_coefficient} <- backoff_coefficient_to_proto(policy.backoff_coefficient),
         {:ok, maximum_attempts} <- maximum_attempts_to_proto(policy.maximum_attempts),
         {:ok, non_retryable_error_types} <-
           non_retryable_error_types_to_proto(policy.non_retryable_error_types) do
      {:ok,
       drop_nil(%{
         initial_interval: initial_interval,
         backoff_coefficient: backoff_coefficient,
         maximum_interval: maximum_interval,
         maximum_attempts: maximum_attempts,
         non_retryable_error_types: non_retryable_error_types
       })}
    end
  end

  defp retry_policy_to_proto(_policy), do: {:error, "retry_policy must be a canonical policy"}

  defp backoff_coefficient_to_proto(nil), do: {:ok, nil}

  defp backoff_coefficient_to_proto(value) when is_number(value) and value >= 1.0,
    do: {:ok, value * 1.0}

  defp backoff_coefficient_to_proto(value) when is_number(value),
    do: {:error, "retry_policy.backoff_coefficient must be 1.0 or larger"}

  defp backoff_coefficient_to_proto(_value),
    do: {:error, "retry_policy.backoff_coefficient must be numeric"}

  defp maximum_attempts_to_proto(attempts)
       when is_integer(attempts) and attempts >= 0 and attempts <= 2_147_483_647,
       do: {:ok, attempts}

  defp maximum_attempts_to_proto(_attempts),
    do: {:error, "retry_policy.maximum_attempts must fit in a non-negative i32"}

  defp non_retryable_error_types_to_proto(error_types) do
    if is_list(error_types) and Enum.all?(error_types, &is_binary/1) do
      {:ok, error_types}
    else
      {:error, "retry_policy.non_retryable_error_types must be a list of strings"}
    end
  end

  defp activity_cancellation_type_to_proto(type) do
    enum_to_proto(
      @activity_cancellation_types_to_proto,
      type,
      "unsupported activity cancellation type"
    )
  end

  defp versioning_intent_to_proto(intent) do
    enum_to_proto(
      @versioning_intents_to_proto,
      intent,
      "unsupported continue-as-new versioning_intent"
    )
  end

  defp continue_as_new_versioning_behavior_to_proto(behavior) do
    enum_to_proto(
      @continue_as_new_versioning_behaviors_to_proto,
      behavior,
      "unsupported continue-as-new initial_versioning_behavior"
    )
  end

  defp retry_state_to_proto(state),
    do: lookup(@retry_states_to_proto, state, :RETRY_STATE_UNSPECIFIED)

  defp timeout_type_to_proto(type),
    do: lookup(@timeout_types_to_proto, type, :TIMEOUT_TYPE_UNSPECIFIED)

  defp enum_to_proto(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end

  defp force_cause_from_opts(opts) do
    case Keyword.get(opts, :force_cause) do
      :nondeterminism -> :WORKFLOW_TASK_FAILED_CAUSE_NON_DETERMINISTIC_ERROR
      _ -> :WORKFLOW_TASK_FAILED_CAUSE_UNSPECIFIED
    end
  end

  defp non_empty(value, _default) when is_binary(value) and value != "", do: value
  defp non_empty(_value, default), do: default

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # PB routes a nil value on an adapted message field (e.g. google.protobuf.Duration)
  # into the adapter rather than eliding it, so omit optional fields by dropping the
  # key entirely instead of leaving it nil.
  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
