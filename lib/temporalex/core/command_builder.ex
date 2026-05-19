defmodule Temporalex.Core.CommandBuilder do
  @moduledoc false

  alias Temporalex.Core.Command
  alias Temporalex.Core.Op

  @activity_opts [
    :activity_id,
    :task_queue,
    :timeout,
    :schedule_to_close_timeout,
    :schedule_to_start_timeout,
    :start_to_close_timeout,
    :heartbeat_timeout,
    :headers,
    :retry_policy,
    :cancellation_type,
    :do_not_eagerly_execute
  ]
  @continue_as_new_opts [
    :workflow_type,
    :task_queue,
    :run_timeout,
    :workflow_run_timeout,
    :task_timeout,
    :workflow_task_timeout,
    :memo,
    :headers,
    :search_attributes,
    :retry_policy,
    :versioning_intent,
    :initial_versioning_behavior
  ]

  def schedule_activity(seq, thread_id, %Op.ExecuteActivity{
        type: type,
        input: input,
        opts: opts
      }) do
    with {:ok, opts} <- keyword_options(opts, "activity options"),
         :ok <- validate_known_options(opts, @activity_opts, "activity"),
         {:ok, activity_id} <- activity_id_from_opts(opts, seq),
         {:ok, task_queue} <- optional_string_option(opts, :task_queue, "activity task_queue"),
         {:ok, timeout_ms} <- activity_timeout_ms(opts),
         {:ok, schedule_to_close_timeout_ms} <-
           duration_from_opts(
             opts,
             [:schedule_to_close_timeout],
             timeout_ms,
             "activity schedule_to_close_timeout"
           ),
         {:ok, schedule_to_start_timeout_ms} <-
           optional_duration_from_opts(
             opts,
             [:schedule_to_start_timeout],
             "activity schedule_to_start_timeout"
           ),
         {:ok, heartbeat_timeout_ms} <-
           optional_duration_from_opts(opts, [:heartbeat_timeout], "activity heartbeat_timeout"),
         {:ok, headers} <- payload_map_option(opts, :headers, "activity headers"),
         {:ok, retry_policy} <- retry_policy_from_opts(opts),
         {:ok, cancellation_type} <- activity_cancellation_type_from_opts(opts),
         {:ok, do_not_eagerly_execute} <- boolean_option(opts, :do_not_eagerly_execute, false) do
      {:ok,
       %Command.ScheduleActivity{
         seq: seq,
         thread_id: thread_id,
         activity_id: activity_id,
         type: type,
         task_queue: task_queue,
         input: input,
         headers: headers,
         schedule_to_close_timeout_ms: schedule_to_close_timeout_ms,
         schedule_to_start_timeout_ms: schedule_to_start_timeout_ms,
         start_to_close_timeout_ms: timeout_ms,
         heartbeat_timeout_ms: heartbeat_timeout_ms,
         retry_policy: retry_policy,
         cancellation_type: cancellation_type,
         do_not_eagerly_execute: do_not_eagerly_execute
       }}
    end
  end

  def continue_as_new(default_workflow_type, %Op.ContinueAsNew{input: input, opts: opts}) do
    with {:ok, opts} <- keyword_options(opts, "continue_as_new! options"),
         :ok <- validate_known_options(opts, @continue_as_new_opts, "continue_as_new!"),
         {:ok, workflow_type} <- workflow_type_from_opts(opts, default_workflow_type),
         {:ok, task_queue} <-
           optional_string_option(opts, :task_queue, "continue_as_new! task_queue"),
         {:ok, workflow_run_timeout_ms} <-
           optional_duration_from_opts(
             opts,
             [:run_timeout, :workflow_run_timeout],
             "continue_as_new! workflow_run_timeout"
           ),
         {:ok, workflow_task_timeout_ms} <-
           optional_duration_from_opts(
             opts,
             [:task_timeout, :workflow_task_timeout],
             "continue_as_new! workflow_task_timeout"
           ),
         {:ok, memo} <- payload_map_option(opts, :memo, "continue_as_new! memo"),
         {:ok, headers} <- payload_map_option(opts, :headers, "continue_as_new! headers"),
         {:ok, search_attributes} <- search_attributes_from_opts(opts),
         {:ok, retry_policy} <- retry_policy_from_opts(opts),
         {:ok, versioning_intent} <- versioning_intent_from_opts(opts),
         {:ok, initial_versioning_behavior} <- continue_as_new_versioning_behavior_from_opts(opts) do
      {:ok,
       %Command.ContinueAsNew{
         input: input,
         workflow_type: workflow_type,
         task_queue: task_queue,
         workflow_run_timeout_ms: workflow_run_timeout_ms,
         workflow_task_timeout_ms: workflow_task_timeout_ms,
         memo: memo,
         headers: headers,
         search_attributes: search_attributes,
         retry_policy: retry_policy,
         versioning_intent: versioning_intent,
         initial_versioning_behavior: initial_versioning_behavior
       }}
    end
  end

  defp keyword_options(nil, _option_name), do: {:ok, []}

  defp keyword_options(opts, _option_name) when is_list(opts) do
    if Enum.all?(opts, fn
         {key, _value} -> is_atom(key)
         _other -> false
       end) do
      {:ok, opts}
    else
      validation_error("options must be a keyword list")
    end
  end

  defp keyword_options(_opts, option_name),
    do: validation_error("#{option_name} must be a keyword list")

  defp validate_known_options(opts, known, option_name) do
    unknown = Keyword.keys(opts) -- known

    if unknown == [] do
      :ok
    else
      validation_error("unknown #{option_name} option(s): #{inspect(unknown)}")
    end
  end

  defp activity_id_from_opts(opts, seq) do
    case Keyword.get(opts, :activity_id, "activity-#{seq}") do
      activity_id when is_binary(activity_id) and activity_id != "" ->
        {:ok, activity_id}

      _other ->
        validation_error("activity activity_id must be a non-empty string")
    end
  end

  defp workflow_type_from_opts(opts, default_workflow_type) do
    case Keyword.fetch(opts, :workflow_type) do
      :error ->
        {:ok, default_workflow_type}

      {:ok, workflow_type} ->
        normalize_workflow_type(workflow_type)
    end
  end

  defp normalize_workflow_type(workflow_type) when is_binary(workflow_type),
    do: {:ok, workflow_type}

  defp normalize_workflow_type(workflow_module) when is_atom(workflow_module) do
    if function_exported?(workflow_module, :__workflow_type__, 0) do
      {:ok, workflow_module.__workflow_type__()}
    else
      {:ok, inspect(workflow_module)}
    end
  end

  defp normalize_workflow_type(_workflow_type) do
    validation_error("continue_as_new! workflow_type must be a string or workflow module")
  end

  defp optional_string_option(opts, key, option_name) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> validation_error("#{option_name} must be a string")
    end
  end

  defp activity_timeout_ms(opts) do
    timeout = find_option(opts, [:timeout, :start_to_close_timeout]) || 60_000
    non_negative_millis(timeout, "activity timeout")
  end

  defp duration_from_opts(opts, keys, default_ms, option_name) do
    case find_option(opts, keys) do
      nil -> non_negative_millis(default_ms, option_name)
      ms -> non_negative_millis(ms, option_name)
    end
  end

  defp optional_duration_from_opts(opts, keys, option_name) do
    case find_option(opts, keys) do
      nil -> {:ok, nil}
      ms -> non_negative_millis(ms, option_name)
    end
  end

  defp non_negative_millis(ms, _option_name) when is_integer(ms) and ms >= 0, do: {:ok, ms}

  defp non_negative_millis(ms, option_name) when is_integer(ms),
    do: validation_error("#{option_name} must be non-negative")

  defp non_negative_millis(_ms, option_name),
    do: validation_error("#{option_name} must be an integer number of milliseconds")

  defp payload_map_option(opts, key, option_name) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, %{}}

      {:ok, nil} ->
        {:ok, %{}}

      {:ok, map} when is_map(map) ->
        {:ok, Map.new(map, fn {map_key, value} -> {to_string(map_key), value} end)}

      {:ok, _other} ->
        validation_error("#{option_name} must be a map")
    end
  end

  defp search_attributes_from_opts(opts) do
    case Keyword.fetch(opts, :search_attributes) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, attrs} when is_map(attrs) ->
        try do
          {:ok, Temporalex.SearchAttribute.validate_map!(attrs)}
        rescue
          error in ArgumentError -> {:error, error}
        end

      {:ok, _attrs} ->
        validation_error("continue_as_new! search_attributes must be a map")
    end
  end

  defp retry_policy_from_opts(opts) do
    case Keyword.fetch(opts, :retry_policy) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, retry_policy} -> retry_policy_from_term(retry_policy)
    end
  end

  defp retry_policy_from_term(opts) when is_list(opts) do
    with {:ok, opts} <- keyword_options(opts, "retry_policy"),
         :ok <-
           validate_known_options(
             opts,
             [
               :initial_interval,
               :backoff_coefficient,
               :maximum_interval,
               :maximum_attempts,
               :non_retryable_error_types
             ],
             "retry_policy"
           ),
         {:ok, initial_interval_ms} <-
           optional_duration_from_opts(opts, [:initial_interval], "retry_policy.initial_interval"),
         {:ok, maximum_interval_ms} <-
           optional_duration_from_opts(opts, [:maximum_interval], "retry_policy.maximum_interval"),
         {:ok, backoff_coefficient} <- backoff_coefficient_from_opts(opts),
         {:ok, maximum_attempts} <- maximum_attempts_from_opts(opts),
         {:ok, non_retryable_error_types} <- non_retryable_error_types_from_opts(opts) do
      {:ok,
       %Command.RetryPolicy{
         initial_interval_ms: initial_interval_ms,
         backoff_coefficient: backoff_coefficient,
         maximum_interval_ms: maximum_interval_ms,
         maximum_attempts: maximum_attempts,
         non_retryable_error_types: non_retryable_error_types
       }}
    end
  end

  defp retry_policy_from_term(_opts), do: validation_error("retry_policy must be a keyword list")

  defp backoff_coefficient_from_opts(opts) do
    case Keyword.get(opts, :backoff_coefficient) do
      nil ->
        {:ok, nil}

      value when is_number(value) and value >= 1.0 ->
        {:ok, value * 1.0}

      value when is_number(value) ->
        validation_error("retry_policy.backoff_coefficient must be 1.0 or larger")

      _value ->
        validation_error("retry_policy.backoff_coefficient must be numeric")
    end
  end

  defp maximum_attempts_from_opts(opts) do
    attempts = Keyword.get(opts, :maximum_attempts, 0)

    cond do
      not is_integer(attempts) ->
        validation_error("retry_policy.maximum_attempts must fit in a non-negative i32")

      attempts < 0 or attempts > 2_147_483_647 ->
        validation_error("retry_policy.maximum_attempts must fit in a non-negative i32")

      true ->
        {:ok, attempts}
    end
  end

  defp non_retryable_error_types_from_opts(opts) do
    error_types = Keyword.get(opts, :non_retryable_error_types, [])

    if is_list(error_types) and Enum.all?(error_types, &is_binary/1) do
      {:ok, error_types}
    else
      validation_error("retry_policy.non_retryable_error_types must be a list of strings")
    end
  end

  defp activity_cancellation_type_from_opts(opts) do
    case Keyword.get(opts, :cancellation_type, :wait_cancellation_completed) do
      :try_cancel -> {:ok, :try_cancel}
      :wait_cancellation_completed -> {:ok, :wait_cancellation_completed}
      :abandon -> {:ok, :abandon}
      _ -> validation_error("unsupported activity cancellation type")
    end
  end

  defp versioning_intent_from_opts(opts) do
    case Keyword.get(opts, :versioning_intent, :unspecified) do
      nil -> {:ok, :unspecified}
      :unspecified -> {:ok, :unspecified}
      :compatible -> {:ok, :compatible}
      :default -> {:ok, :default}
      _ -> validation_error("unsupported continue-as-new versioning_intent")
    end
  end

  defp continue_as_new_versioning_behavior_from_opts(opts) do
    case Keyword.get(opts, :initial_versioning_behavior, :unspecified) do
      nil -> {:ok, :unspecified}
      :unspecified -> {:ok, :unspecified}
      :auto_upgrade -> {:ok, :auto_upgrade}
      :use_ramping_version -> {:ok, :use_ramping_version}
      _ -> validation_error("unsupported continue-as-new initial_versioning_behavior")
    end
  end

  defp boolean_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _value -> validation_error("#{key} must be a boolean")
    end
  end

  defp find_option(opts, keys) do
    Enum.find_value(keys, fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, nil} -> nil
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp validation_error(message), do: {:error, ArgumentError.exception(message)}
end
