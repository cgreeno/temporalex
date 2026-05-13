defmodule Temporalex.ServerIntegrationTest do
  use ExUnit.Case, async: false

  alias Temporalex.Backend.Test, as: TestBackend
  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.ActivityTask
  alias Temporalex.Core.Command
  alias Temporalex.Core.Job
  alias Temporalex.Core.Activation
  alias Temporalex.Workflow.API

  defmodule Activities do
    use Temporalex.Activity

    defactivity echo(value) do
      {:ok, {:echo, value}}
    end

    defactivity fail(reason) do
      {:error, reason}
    end

    defactivity invalid_return(value) do
      value
    end

    defactivity crash(message) do
      raise message
    end

    defactivity cancellable(ctx, parent) do
      send(parent, {:activity_started, self()})

      receive do
        :heartbeat ->
          case Temporalex.Activity.Context.heartbeat(ctx, :details) do
            :ok -> {:ok, :not_cancelled}
            {:cancelled, reason} -> throw({:cancelled, reason})
          end
      after
        1_000 -> {:error, :activity_test_timeout}
      end
    end
  end

  defmodule ActivityWorkflow do
    use Temporalex.Workflow

    def run(value) do
      {:ok, result} = Activities.echo(value)
      {:ok, result}
    end
  end

  defmodule SignalWorkflow do
    use Temporalex.Workflow

    def run(_) do
      value = API.wait_for_signal("go")
      {:ok, value}
    end
  end

  defmodule QueryWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(_) do
      API.publish_state(:waiting)
      {:ok, :gate} = Activities.echo(:gate)
      {:ok, :done}
    end
  end

  setup do
    name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    start_supervised!(
      {Temporalex.Worker,
       name: name,
       backend: TestBackend,
       test_owner: self(),
       namespace: "default",
       task_queue: "temporalex-test",
       workflows: [ActivityWorkflow, SignalWorkflow, QueryWorkflow],
       activities: [Activities]}
    )

    %{worker: name}
  end

  test "worker starts the documented server and supervisor tree", %{worker: worker} do
    assert is_pid(Process.whereis(worker))
    assert is_pid(Process.whereis(Temporalex.Worker.server_name(worker)))
    assert is_pid(Process.whereis(Temporalex.Worker.executor_supervisor_name(worker)))
    assert is_pid(Process.whereis(Temporalex.Worker.activity_supervisor_name(worker)))
  end

  test "server routes workflow activation to an executor and submits completion", %{
    worker: worker
  } do
    run_id = "run-route"
    activity_type = "#{inspect(Activities)}.echo"

    :ok =
      TestBackend.send_activation(worker, %Activation{
        run_id: run_id,
        timestamp: ~U[2026-05-07 12:00:00Z],
        jobs: [initialize(ActivityWorkflow, :one)]
      })

    assert %Temporalex.Core.Completion{
             run_id: ^run_id,
             status:
               {:ok,
                [
                  %Command.ScheduleActivity{
                    seq: 0,
                    thread_id: [],
                    type: ^activity_type,
                    input: [:one]
                  }
                ]}
           } = TestBackend.fetch_workflow_completion(worker, run_id)

    snapshot = Temporalex.Server.snapshot(Temporalex.Worker.server_pid(worker))
    assert %{^run_id => %{pid: pid}} = snapshot.executors
    assert Process.alive?(pid)
    assert snapshot.pending_activations == %{}
  end

  test "server resumes an existing executor with a resolution activation", %{worker: worker} do
    run_id = "run-resume"

    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      jobs: [initialize(ActivityWorkflow, :one)]
    })

    assert %Temporalex.Core.Completion{status: {:ok, [%Command.ScheduleActivity{seq: seq}]}} =
             TestBackend.fetch_workflow_completion(worker, run_id)

    TestBackend.clear_completions(worker)

    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      jobs: [%Job.ActivityResolved{seq: seq, result: {:ok, {:echo, :one}}}]
    })

    assert %Temporalex.Core.Completion{
             status: {:ok, [%Command.CompleteWorkflow{result: {:echo, :one}}]}
           } = TestBackend.fetch_workflow_completion(worker, run_id)
  end

  test "eviction activation submits an empty completion and removes the executor", %{
    worker: worker
  } do
    run_id = "run-evict"

    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      jobs: [initialize(SignalWorkflow, nil)]
    })

    assert %Temporalex.Core.Completion{status: {:ok, []}} =
             TestBackend.fetch_workflow_completion(worker, run_id)

    TestBackend.clear_completions(worker)

    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      jobs: [%Job.RemoveFromCache{reason: :evict, message: "test"}]
    })

    assert %Temporalex.Core.Completion{status: {:ok, []}} =
             TestBackend.fetch_workflow_completion(worker, run_id)

    snapshot = Temporalex.Server.snapshot(Temporalex.Worker.server_pid(worker))
    refute Map.has_key?(snapshot.executors, run_id)
  end

  test "unknown workflow type becomes activation failure completion", %{worker: worker} do
    run_id = "run-unknown"

    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      jobs: [
        %Job.InitializeWorkflow{
          workflow_type: "Missing.Workflow",
          workflow_id: "wf-unknown",
          arguments: [nil],
          workflow_info: %{},
          randomness_seed: 0
        }
      ]
    })

    assert %Temporalex.Core.Completion{
             status:
               {:failed, {:unknown_workflow_type, "Missing.Workflow"},
                force_cause: :workflow_task_failed}
           } = TestBackend.fetch_workflow_completion(worker, run_id)
  end

  test "query-only activations route through the server without advancing workflow units", %{
    worker: worker
  } do
    run_id = "run-query"

    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      jobs: [initialize(QueryWorkflow, nil)]
    })

    assert %Temporalex.Core.Completion{status: {:ok, [%Command.ScheduleActivity{seq: seq}]}} =
             TestBackend.fetch_workflow_completion(worker, run_id)

    TestBackend.clear_completions(worker)

    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      jobs: [%Job.QueryReceived{query_id: "q1", query_type: "state", args: []}]
    })

    assert %Temporalex.Core.Completion{
             status: {:ok, [%Command.RespondToQuery{query_id: "q1", result: {:ok, :waiting}}]}
           } = TestBackend.fetch_workflow_completion(worker, run_id)

    snapshot = Temporalex.Server.snapshot(Temporalex.Worker.server_pid(worker))
    [executor] = Map.values(snapshot.executors)
    assert Temporalex.Core.Executor.inspect_state(executor.pid).pending |> Map.has_key?(seq)
  end

  test "server runs activity tasks and submits activity completions", %{worker: worker} do
    token = "activity-token-success"

    TestBackend.send_activity_task(
      worker,
      activity_task(token, "#{inspect(Activities)}.echo", [:value])
    )

    assert %ActivityCompletion{task_token: ^token, result: {:ok, {:echo, :value}}} =
             TestBackend.fetch_activity_completion(worker, token)
  end

  test "server normalizes activity errors, invalid returns, and exceptions", %{worker: worker} do
    TestBackend.send_activity_task(
      worker,
      activity_task("activity-fail", "#{inspect(Activities)}.fail", [:bad])
    )

    assert %ActivityCompletion{result: {:error, :bad}} =
             TestBackend.fetch_activity_completion(worker, "activity-fail")

    TestBackend.send_activity_task(
      worker,
      activity_task("activity-invalid", "#{inspect(Activities)}.invalid_return", [:bad_return])
    )

    assert %ActivityCompletion{result: {:error, {:invalid_activity_return, :bad_return}}} =
             TestBackend.fetch_activity_completion(worker, "activity-invalid")

    TestBackend.send_activity_task(
      worker,
      activity_task("activity-crash", "#{inspect(Activities)}.crash", ["boom"])
    )

    assert %ActivityCompletion{result: {:error, {:exception, %RuntimeError{}, _stack}}} =
             TestBackend.fetch_activity_completion(worker, "activity-crash")
  end

  test "activity context supports cooperative cancellation", %{worker: worker} do
    token = "activity-cancel"

    TestBackend.send_activity_task(
      worker,
      activity_task(token, "#{inspect(Activities)}.cancellable", [self()])
    )

    assert_receive {:activity_started, activity_pid}

    TestBackend.send_activity_task(worker, %ActivityTask{
      task_token: token,
      activity_type: "#{inspect(Activities)}.cancellable",
      variant: :cancel,
      cancel_reason: :requested
    })

    send(activity_pid, :heartbeat)

    assert %ActivityCompletion{task_token: ^token, result: {:cancelled, :cancelled}} =
             TestBackend.fetch_activity_completion(worker, token)
  end

  test "executor monitor cleanup removes crashed executors from registry", %{worker: worker} do
    run_id = "run-crash-cleanup"

    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      jobs: [initialize(SignalWorkflow, nil)]
    })

    assert %Temporalex.Core.Completion{status: {:ok, []}} =
             TestBackend.fetch_workflow_completion(worker, run_id)

    snapshot = Temporalex.Server.snapshot(Temporalex.Worker.server_pid(worker))
    executor_pid = snapshot.executors[run_id].pid

    Process.exit(executor_pid, :kill)

    assert eventually(fn ->
             snapshot = Temporalex.Server.snapshot(Temporalex.Worker.server_pid(worker))
             not Map.has_key?(snapshot.executors, run_id)
           end)
  end

  defp initialize(workflow, input) do
    %Job.InitializeWorkflow{
      workflow_type: workflow.__workflow_type__(),
      workflow_id: "wf-#{System.unique_integer([:positive])}",
      arguments: [input],
      workflow_info: %{},
      randomness_seed: 0
    }
  end

  defp activity_task(token, type, input) do
    %ActivityTask{
      task_token: token,
      activity_id: token,
      activity_type: type,
      workflow_id: "wf-activity",
      run_id: "run-activity",
      workflow_type: inspect(ActivityWorkflow),
      namespace: "default",
      task_queue: "temporalex-test",
      input: input,
      attempt: 1,
      variant: :start
    }
  end

  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        eventually_until(fun, deadline)
    end
  end
end
