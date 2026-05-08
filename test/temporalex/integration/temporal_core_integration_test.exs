defmodule Temporalex.TemporalCoreIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.TemporalDevServer

  defmodule Activities do
    use Temporalex.Activity

    defactivity echo(value), start_to_close_timeout: 10_000 do
      {:ok, {:echo, value}}
    end

    defactivity heartbeat(ctx, value),
      start_to_close_timeout: 10_000,
      heartbeat_timeout: 10_000 do
      :ok = Temporalex.Activity.Context.heartbeat(ctx, {:heartbeat, value})
      {:ok, {:heartbeat, value}}
    end

    defactivity long_cancellable(ctx, parent),
      start_to_close_timeout: 30_000,
      heartbeat_timeout: 1_000,
      cancellation_type: :wait_cancellation_completed do
      send(parent, {:long_cancellable_started, self()})
      wait_until_cancelled(ctx, parent)
    end

    defactivity fail_retryable(ctx),
      start_to_close_timeout: 1_000,
      schedule_to_close_timeout: 10_000,
      retry_policy: [initial_interval: 10, maximum_attempts: 2] do
      {:error,
       Temporalex.Failure.application("retryable activity failure",
         type: "RetryableActivityFailure",
         details: [ctx.attempt],
         retryable?: true
       )}
    end

    defactivity fail_non_retryable(ctx),
      start_to_close_timeout: 1_000,
      schedule_to_close_timeout: 10_000,
      retry_policy: [initial_interval: 10, maximum_attempts: 2] do
      {:error,
       Temporalex.Failure.application("non-retryable activity failure",
         type: "NonRetryableActivityFailure",
         details: [ctx.attempt],
         retryable?: false
       )}
    end

    defp wait_until_cancelled(ctx, parent) do
      case Temporalex.Activity.Context.heartbeat(ctx, :working) do
        :ok ->
          Process.sleep(50)
          wait_until_cancelled(ctx, parent)

        {:cancelled, reason} ->
          send(parent, {:long_cancellable_cancelled, reason})
          throw({:cancelled, Temporalex.Failure.cancelled("activity cancelled")})
      end
    end
  end

  defmodule Workflow do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(input) do
      API.sleep(10)
      {:ok, echoed} = Activities.echo(input)
      {:ok, heartbeat} = Activities.heartbeat(input)
      {:ok, {:done, echoed, heartbeat}}
    end
  end

  defmodule InteractiveWorkflow do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("state", _args, state), do: {:reply, state}

    def run(initial) do
      API.publish_state(initial)

      state =
        API.phase!(initial,
          signal: %{
            "add" => fn [amount], state ->
              state = state + amount
              API.publish_state(state)
              {:noreply, state}
            end
          },
          update: %{
            "add" => fn [amount], state ->
              state = state + amount
              API.publish_state(state)
              {:reply, state, state}
            end,
            "finish" => fn _args, state ->
              API.publish_state(state)
              {:stop, :finished, state}
            end
          }
        )

      {:ok, state}
    end
  end

  defmodule WaitingWorkflow do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("state", _args, state), do: {:reply, state}

    def run(label) do
      API.publish_state({:waiting, label})
      API.sleep!(60_000)
      {:ok, {:completed, label}}
    end
  end

  defmodule ActivityCancellationWorkflow do
    use Temporalex.Workflow

    def run(parent) do
      try do
        _result = Activities.long_cancellable!(parent)
        {:ok, :activity_completed}
      rescue
        error in Temporalex.Failure.CancelledError -> {:cancelled, error}
      end
    end
  end

  defmodule SearchAttributeWorkflow do
    use Temporalex.Workflow

    alias Temporalex.SearchAttribute
    alias Temporalex.Workflow.API

    def handle_query("state", _args, state), do: {:reply, state}

    def run(label) do
      :ok =
        API.upsert_search_attributes(%{
          "CustomKeywordField" => SearchAttribute.keyword("upserted-#{label}"),
          "CustomIntField" => SearchAttribute.int(8)
        })

      API.publish_state(:upserted)
      API.sleep!(60_000)
      {:ok, :done}
    end
  end

  defmodule ContinueAsNewWorkflow do
    use Temporalex.Workflow

    alias Temporalex.SearchAttribute
    alias Temporalex.Workflow.API

    def run(%{count: count, target: target, label: label, task_queue: task_queue} = input)
        when count < target do
      API.continue_as_new!(%{input | count: count + 1},
        task_queue: task_queue,
        run_timeout: 60_000,
        task_timeout: 10_000,
        memo: %{label: label, count: count + 1},
        headers: %{source: "continue-as-new"},
        search_attributes: %{
          "CustomKeywordField" => SearchAttribute.keyword("continued-#{label}"),
          "CustomIntField" => SearchAttribute.int(count + 1)
        },
        retry_policy: [initial_interval: 10, maximum_attempts: 2]
      )

      {:ok, :unreachable}
    end

    def run(%{count: count}) do
      info = API.workflow_info()
      {:ok, {:continued, count, info.continue_as_new_suggested}}
    end
  end

  defmodule FailureWorkflow do
    use Temporalex.Workflow

    alias Temporalex.Failure
    alias Temporalex.Workflow.API

    def run(retryable?) do
      attempt = API.workflow_info().attempt

      {:error,
       Failure.application("workflow failed",
         type: "PlannedWorkflowFailure",
         details: [attempt],
         retryable?: retryable?
       )}
    end
  end

  defmodule ActivityFailureWorkflow do
    use Temporalex.Workflow

    def run(:retryable) do
      fail_with_activity_result(Activities.fail_retryable())
    end

    def run(:non_retryable) do
      fail_with_activity_result(Activities.fail_non_retryable())
    end

    defp fail_with_activity_result({:ok, value}), do: {:ok, value}

    defp fail_with_activity_result({:error, %Temporalex.Failure.ActivityError{} = failure}),
      do: {:error, failure}

    defp fail_with_activity_result({:error, %Temporalex.Failure.ApplicationError{} = failure}),
      do: {:error, failure}

    defp fail_with_activity_result({:error, other}), do: {:error, other}
  end

  test "TemporalCore worker runs workflow tasks, activities, and client operations against dev server" do
    temporal =
      TemporalDevServer.start!(
        search_attributes: [
          {"CustomKeywordField", "Keyword"},
          {"CustomTextField", "Text"},
          {"CustomIntField", "Int"},
          {"CustomDoubleField", "Double"},
          {"CustomBoolField", "Bool"},
          {"CustomDatetimeField", "Datetime"},
          {"CustomKeywordListField", "KeywordList"}
        ]
      )

    try do
      worker_name =
        Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

      client_name =
        Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")

      task_queue = "temporalex-native-#{System.unique_integer([:positive])}"

      {:ok, client_pid} =
        Temporalex.Client.start_link(
          name: client_name,
          backend: Temporalex.Backend.TemporalCore,
          target: temporal.target,
          namespace: "default",
          task_queue: task_queue,
          workflow_result_timeout: 30_000
        )

      {:ok, worker_pid} =
        Temporalex.Worker.start_link(
          name: worker_name,
          client: client_name,
          task_queue: task_queue,
          workflows: [
            Workflow,
            InteractiveWorkflow,
            WaitingWorkflow,
            ActivityCancellationWorkflow,
            SearchAttributeWorkflow,
            ContinueAsNewWorkflow,
            FailureWorkflow,
            ActivityFailureWorkflow
          ],
          activities: [Activities],
          max_workflow_pollers: 2,
          max_activity_pollers: 2
        )

      try do
        assert {:error, invalid_start_reason} =
                 Temporalex.Client.start_workflow(client_name, Workflow, :invalid_options,
                   workflow_id: "temporalex-invalid-#{System.unique_integer([:positive])}",
                   workflow_task_timeout: -1,
                   timeout: 10_000
                 )

        assert invalid_start_reason =~ "duration option must be non-negative"

        input = {:native, System.unique_integer([:positive])}
        workflow_id = "temporalex-native-#{System.unique_integer([:positive])}"

        assert {:ok, handle} =
                 Temporalex.Client.start_workflow(client_name, Workflow, input,
                   workflow_id: workflow_id,
                   timeout: 10_000
                 )

        assert handle.workflow_id == workflow_id
        assert is_binary(handle.run_id)
        assert handle.run_id != ""

        assert {:ok, {:done, {:echo, ^input}, {:heartbeat, ^input}}} =
                 Temporalex.Client.get_result(handle, timeout: 30_000)

        interactive_id = "temporalex-interactive-#{System.unique_integer([:positive])}"

        assert {:ok, interactive} =
                 Temporalex.Client.start_workflow(client_name, InteractiveWorkflow, 0,
                   workflow_id: interactive_id,
                   workflow_task_timeout: 10_000,
                   id_reuse_policy: :reject_duplicate,
                   id_conflict_policy: :fail,
                   static_summary: "Temporalex integration test",
                   timeout: 10_000
                 )

        assert TemporalDevServer.eventually(fn ->
                 Temporalex.Client.query_workflow(interactive, "state", [], timeout: 10_000) ==
                   {:ok, 0}
               end)

        assert :ok =
                 Temporalex.Client.signal_workflow(interactive, "add", [2], timeout: 10_000)

        assert TemporalDevServer.eventually(fn ->
                 Temporalex.Client.query_workflow(interactive, "state", [], timeout: 10_000) ==
                   {:ok, 2}
               end)

        assert {:ok, 5} =
                 Temporalex.Client.update_workflow(interactive, "add", [3], timeout: 15_000)

        assert {:ok, description} =
                 Temporalex.Client.describe_workflow(interactive, timeout: 10_000)

        assert description.workflow_id == interactive_id
        assert description.run_id == interactive.run_id
        assert description.workflow_type == InteractiveWorkflow.__workflow_type__()
        assert description.status == :running
        assert is_integer(description.history_length)

        assert {:ok, :finished} =
                 Temporalex.Client.update_workflow(interactive, "finish", [], timeout: 15_000)

        assert {:ok, 5} = Temporalex.Client.get_result(interactive, timeout: 30_000)

        terminated_id = "temporalex-terminated-#{System.unique_integer([:positive])}"

        assert {:ok, terminated} =
                 Temporalex.Client.start_workflow(client_name, WaitingWorkflow, :terminate,
                   workflow_id: terminated_id,
                   timeout: 10_000
                 )

        assert TemporalDevServer.eventually(fn ->
                 Temporalex.Client.query_workflow(terminated, "state", [], timeout: 10_000) ==
                   {:ok, {:waiting, :terminate}}
               end)

        assert :ok =
                 Temporalex.Client.terminate_workflow(terminated,
                   reason: "integration test",
                   details: :terminated_by_test,
                   timeout: 10_000
                 )

        assert {:error, {:terminated, [:terminated_by_test]}} =
                 Temporalex.Client.get_result(terminated, timeout: 30_000)

        cancelled_timer_id = "temporalex-cancelled-timer-#{System.unique_integer([:positive])}"

        assert {:ok, cancelled_timer} =
                 Temporalex.Client.start_workflow(client_name, WaitingWorkflow, :cancel_timer,
                   workflow_id: cancelled_timer_id,
                   timeout: 10_000
                 )

        assert TemporalDevServer.eventually(fn ->
                 Temporalex.Client.query_workflow(cancelled_timer, "state", [], timeout: 10_000) ==
                   {:ok, {:waiting, :cancel_timer}}
               end)

        assert :ok =
                 Temporalex.Client.cancel_workflow(cancelled_timer,
                   reason: "integration cancellation",
                   timeout: 10_000
                 )

        assert {:error, {:cancelled, _details}} =
                 Temporalex.Client.get_result(cancelled_timer, timeout: 30_000)

        cancelled_activity_id =
          "temporalex-cancelled-activity-#{System.unique_integer([:positive])}"

        assert {:ok, cancelled_activity} =
                 Temporalex.Client.start_workflow(
                   client_name,
                   ActivityCancellationWorkflow,
                   self(),
                   workflow_id: cancelled_activity_id,
                   timeout: 10_000
                 )

        assert_receive {:long_cancellable_started, _pid}, 10_000

        assert :ok =
                 Temporalex.Client.cancel_workflow(cancelled_activity,
                   reason: "integration activity cancellation",
                   timeout: 10_000
                 )

        assert_receive {:long_cancellable_cancelled, _reason}, 15_000

        assert {:error, {:cancelled, _details}} =
                 Temporalex.Client.get_result(cancelled_activity, timeout: 30_000)

        search_id = "temporalex-search-attrs-#{System.unique_integer([:positive])}"
        search_label = "search-#{System.unique_integer([:positive])}"

        search_attributes = %{
          "CustomKeywordField" => Temporalex.SearchAttribute.keyword("started-#{search_label}"),
          "CustomTextField" => Temporalex.SearchAttribute.text("temporalex search text"),
          "CustomIntField" => Temporalex.SearchAttribute.int(7),
          "CustomDoubleField" => Temporalex.SearchAttribute.double(2.5),
          "CustomBoolField" => Temporalex.SearchAttribute.bool(true),
          "CustomDatetimeField" => Temporalex.SearchAttribute.datetime(~U[2026-05-08 12:00:00Z]),
          "CustomKeywordListField" => Temporalex.SearchAttribute.keyword_list(["alpha", "beta"])
        }

        assert {:ok, search_handle} =
                 Temporalex.Client.start_workflow(
                   client_name,
                   SearchAttributeWorkflow,
                   search_label,
                   workflow_id: search_id,
                   search_attributes: search_attributes,
                   timeout: 10_000
                 )

        assert TemporalDevServer.eventually(fn ->
                 Temporalex.Client.query_workflow(search_handle, "state", [], timeout: 10_000) ==
                   {:ok, :upserted}
               end)

        assert TemporalDevServer.eventually(fn ->
                 TemporalDevServer.workflow_visible?(
                   temporal,
                   "CustomKeywordField = 'upserted-#{search_label}' and CustomIntField = 8",
                   search_id
                 )
               end)

        assert :ok =
                 Temporalex.Client.terminate_workflow(search_handle,
                   reason: "integration test complete",
                   timeout: 10_000
                 )

        continue_id = "temporalex-continue-as-new-#{System.unique_integer([:positive])}"
        continue_label = "continue-#{System.unique_integer([:positive])}"

        assert {:ok, continue_handle} =
                 Temporalex.Client.start_workflow(
                   client_name,
                   ContinueAsNewWorkflow,
                   %{count: 0, target: 2, label: continue_label, task_queue: task_queue},
                   workflow_id: continue_id,
                   timeout: 10_000
                 )

        assert {:ok, {:continued, 2, false}} =
                 Temporalex.Client.get_result(continue_handle, timeout: 30_000)

        assert TemporalDevServer.eventually(fn ->
                 TemporalDevServer.workflow_visible?(
                   temporal,
                   "CustomKeywordField = 'continued-#{continue_label}' and CustomIntField = 2",
                   continue_id
                 )
               end)

        non_retryable_workflow_id =
          "temporalex-non-retryable-workflow-#{System.unique_integer([:positive])}"

        assert {:ok, non_retryable_workflow} =
                 Temporalex.Client.start_workflow(client_name, FailureWorkflow, false,
                   workflow_id: non_retryable_workflow_id,
                   retry_policy: [initial_interval: 10, maximum_attempts: 2],
                   timeout: 10_000
                 )

        assert {:error, {:failed, %Temporalex.Failure.ApplicationError{} = failure}} =
                 Temporalex.Client.get_result(non_retryable_workflow, timeout: 30_000)

        assert failure.type == "PlannedWorkflowFailure"
        assert failure.details == [1]
        assert failure.retryable? == false

        typed_non_retryable_workflow_id =
          "temporalex-typed-non-retryable-workflow-#{System.unique_integer([:positive])}"

        assert {:ok, typed_non_retryable_workflow} =
                 Temporalex.Client.start_workflow(client_name, FailureWorkflow, true,
                   workflow_id: typed_non_retryable_workflow_id,
                   retry_policy: [
                     initial_interval: 10,
                     maximum_attempts: 2,
                     non_retryable_error_types: ["PlannedWorkflowFailure"]
                   ],
                   timeout: 10_000
                 )

        assert {:error, {:failed, %Temporalex.Failure.ApplicationError{} = failure}} =
                 Temporalex.Client.get_result(typed_non_retryable_workflow, timeout: 30_000)

        assert failure.type == "PlannedWorkflowFailure"
        assert failure.details == [1]
        assert failure.retryable? == true

        retryable_workflow_id =
          "temporalex-retryable-workflow-#{System.unique_integer([:positive])}"

        assert {:ok, retryable_workflow} =
                 Temporalex.Client.start_workflow(client_name, FailureWorkflow, true,
                   workflow_id: retryable_workflow_id,
                   retry_policy: [initial_interval: 10, maximum_attempts: 2],
                   timeout: 10_000
                 )

        assert {:error, {:failed, %Temporalex.Failure.ApplicationError{} = failure}} =
                 Temporalex.Client.get_result(retryable_workflow, timeout: 30_000)

        assert failure.type == "PlannedWorkflowFailure"
        assert failure.details == [2]
        assert failure.retryable? == true

        non_retryable_activity_id =
          "temporalex-non-retryable-activity-#{System.unique_integer([:positive])}"

        assert {:ok, non_retryable_activity} =
                 Temporalex.Client.start_workflow(
                   client_name,
                   ActivityFailureWorkflow,
                   :non_retryable,
                   workflow_id: non_retryable_activity_id,
                   timeout: 10_000
                 )

        assert {:error, {:failed, %Temporalex.Failure.ActivityError{} = failure}} =
                 Temporalex.Client.get_result(non_retryable_activity, timeout: 30_000)

        assert failure.retry_state == :non_retryable_failure
        assert %Temporalex.Failure.ApplicationError{} = cause = failure.cause
        assert cause.type == "NonRetryableActivityFailure"
        assert cause.details == [1]
        assert cause.retryable? == false

        retryable_activity_id =
          "temporalex-retryable-activity-#{System.unique_integer([:positive])}"

        assert {:ok, retryable_activity} =
                 Temporalex.Client.start_workflow(
                   client_name,
                   ActivityFailureWorkflow,
                   :retryable,
                   workflow_id: retryable_activity_id,
                   timeout: 10_000
                 )

        assert {:error, {:failed, %Temporalex.Failure.ActivityError{} = failure}} =
                 Temporalex.Client.get_result(retryable_activity, timeout: 30_000)

        assert failure.retry_state == :maximum_attempts_reached
        assert %Temporalex.Failure.ApplicationError{} = cause = failure.cause
        assert cause.type == "RetryableActivityFailure"
        assert cause.details == [2]
        assert cause.retryable? == true
      after
        if Process.alive?(worker_pid) do
          Supervisor.stop(worker_pid, :normal, 15_000)
        end

        if Process.alive?(client_pid) do
          GenServer.stop(client_pid, :normal, 15_000)
        end
      end
    after
      TemporalDevServer.stop(temporal)
    end
  end
end
