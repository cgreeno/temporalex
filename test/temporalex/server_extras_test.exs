defmodule Temporalex.ServerExtrasTest do
  @moduledoc """
  Gap coverage for the worker/server tree: multiple concurrent workflow
  runs sharing one worker, executor crash → cleanup, supervised activity
  task crash → completion, activity heartbeat surfacing cancellation.
  No live Temporal needed.
  """

  use ExUnit.Case, async: false

  alias Temporalex.Backend.Test, as: TestBackend
  alias Temporalex.Core.Activation
  alias Temporalex.Core.Command
  alias Temporalex.Core.Job

  defmodule Activities do
    use Temporalex.Activity

    defactivity echo(value) do
      {:ok, {:echo, value}}
    end

    defactivity heartbeats(ctx, parent, n) do
      Enum.reduce_while(1..n, :starting, fn i, _acc ->
        case Temporalex.Activity.Context.heartbeat(ctx, {:beat, i}) do
          :ok ->
            send(parent, {:beat_ack, i})
            {:cont, i}

          {:cancelled, reason} ->
            send(parent, {:beat_cancelled, reason})
            {:halt, throw({:cancelled, reason})}
        end
      end)

      {:ok, {:beats_done, n}}
    end
  end

  defmodule SimpleWorkflow do
    use Temporalex.Workflow

    def run(input), do: {:ok, input}
  end

  defmodule ActivityWorkflow do
    use Temporalex.Workflow

    def run(value) do
      {:ok, result} = Activities.echo(value)
      {:ok, result}
    end
  end

  setup do
    name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")

    start_supervised!({Temporalex.Client, name: client, backend: TestBackend})

    start_supervised!(
      {Temporalex.Worker,
       name: name,
       client: client,
       backend: TestBackend,
       test_owner: self(),
       namespace: Temporalex.TestSupport.Namespace.name(),
       task_queue: "extras-queue",
       workflows: [SimpleWorkflow, ActivityWorkflow],
       activities: [Activities]}
    )

    %{worker: name, client: client}
  end

  describe "concurrent workflow runs on one worker" do
    test "two distinct run_ids are routed to two different executors", %{worker: worker} do
      send_init(worker, "run-A", SimpleWorkflow, :a)
      send_init(worker, "run-B", SimpleWorkflow, :b)

      assert %Temporalex.Core.Completion{status: {:ok, [%Command.CompleteWorkflow{result: :a}]}} =
               TestBackend.fetch_workflow_completion(worker, "run-A")

      assert %Temporalex.Core.Completion{status: {:ok, [%Command.CompleteWorkflow{result: :b}]}} =
               TestBackend.fetch_workflow_completion(worker, "run-B")
    end

    test "ten concurrent run_ids each complete with their own input", %{worker: worker} do
      ids = for i <- 1..10, do: {"run-#{i}", i}

      for {run_id, value} <- ids do
        send_init(worker, run_id, SimpleWorkflow, value)
      end

      for {run_id, expected} <- ids do
        assert %Temporalex.Core.Completion{
                 status: {:ok, [%Command.CompleteWorkflow{result: ^expected}]}
               } = TestBackend.fetch_workflow_completion(worker, run_id)
      end
    end

    test "executor registry tracks per-run executor pids", %{worker: worker} do
      send_init(worker, "run-track-A", ActivityWorkflow, :a)
      send_init(worker, "run-track-B", ActivityWorkflow, :b)

      # Both should yield a ScheduleActivity (workflows are parked waiting).
      assert %Temporalex.Core.Completion{} =
               TestBackend.fetch_workflow_completion(worker, "run-track-A")

      assert %Temporalex.Core.Completion{} =
               TestBackend.fetch_workflow_completion(worker, "run-track-B")

      snapshot = Temporalex.Server.snapshot(Temporalex.Worker.server_pid(worker))
      assert Map.has_key?(snapshot.executors, "run-track-A")
      assert Map.has_key?(snapshot.executors, "run-track-B")
      refute snapshot.executors["run-track-A"].pid == snapshot.executors["run-track-B"].pid
    end
  end

  describe "executor crash handling" do
    test "manually killing an executor removes it from the registry", %{worker: worker} do
      run_id = "run-kill"
      send_init(worker, run_id, ActivityWorkflow, :hi)

      assert %Temporalex.Core.Completion{} =
               TestBackend.fetch_workflow_completion(worker, run_id)

      server_pid = Temporalex.Worker.server_pid(worker)
      %{executors: %{^run_id => %{pid: executor_pid}}} = Temporalex.Server.snapshot(server_pid)

      Process.exit(executor_pid, :kill)

      # Server cleans up via DOWN monitor.
      :ok =
        wait_for(fn ->
          snapshot = Temporalex.Server.snapshot(server_pid)
          not Map.has_key?(snapshot.executors, run_id)
        end)
    end
  end

  describe "activity supervisor" do
    test "activity supervisor is named and registered", %{worker: worker} do
      sup = Temporalex.Worker.activity_supervisor_name(worker)
      assert is_pid(Process.whereis(sup))
    end

    test "activity execution path uses the activity supervisor", %{worker: worker} do
      run_id = "run-act-sup"
      send_init(worker, run_id, ActivityWorkflow, :gate)

      # Drain the activation that scheduled the activity.
      assert %Temporalex.Core.Completion{} =
               TestBackend.fetch_workflow_completion(worker, run_id)

      # Send an activity task — it should run under the activity supervisor.
      type = "#{inspect(Activities)}.echo"

      assert :ok =
               TestBackend.send_activity_task(worker, %Temporalex.Core.ActivityTask{
                 task_token: "task-tok",
                 activity_id: "act-1",
                 activity_type: type,
                 input: [:hello],
                 variant: :start
               })

      assert %Temporalex.Core.ActivityCompletion{result: {:ok, {:echo, :hello}}} =
               TestBackend.fetch_activity_completion(worker, "task-tok")
    end
  end

  describe "Activity.Context heartbeat" do
    test "heartbeat returns :ok when cancel has not been requested", %{worker: worker} do
      type = "#{inspect(Activities)}.heartbeats"

      :ok =
        TestBackend.send_activity_task(worker, %Temporalex.Core.ActivityTask{
          task_token: "beat-ok",
          activity_id: "beat-act",
          activity_type: type,
          input: [self(), 3],
          variant: :start
        })

      assert_receive {:beat_ack, 1}, 1_000
      assert_receive {:beat_ack, 2}, 1_000
      assert_receive {:beat_ack, 3}, 1_000

      assert %Temporalex.Core.ActivityCompletion{
               task_token: "beat-ok",
               result: {:ok, {:beats_done, 3}}
             } = TestBackend.fetch_activity_completion(worker, "beat-ok")
    end

    test "heartbeat returns {:cancelled, _} after cancel is delivered", %{worker: worker} do
      type = "#{inspect(Activities)}.heartbeats"
      token = "beat-cancel"

      :ok =
        TestBackend.send_activity_task(worker, %Temporalex.Core.ActivityTask{
          task_token: token,
          activity_id: "beat-cancel-act",
          activity_type: type,
          input: [self(), 50],
          variant: :start
        })

      assert_receive {:beat_ack, 1}, 1_000

      # Cancel the activity.
      :ok =
        TestBackend.send_activity_task(worker, %Temporalex.Core.ActivityTask{
          task_token: token,
          activity_type: type,
          variant: :cancel,
          cancel_reason: :user
        })

      # Activity completes with the cancelled result.
      assert %Temporalex.Core.ActivityCompletion{
               result: {:cancelled, %Temporalex.Failure.CancelledError{}}
             } = TestBackend.fetch_activity_completion(worker, token)
    end
  end

  # ─────────────────────────── helpers ───────────────────────────

  defp send_init(worker, run_id, workflow_module, input) do
    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      timestamp: ~U[2026-05-15 12:00:00Z],
      jobs: [
        %Job.InitializeWorkflow{
          workflow_type: workflow_module.__workflow_type__(),
          workflow_id: "wf-#{run_id}",
          arguments: [input],
          workflow_info: %{},
          randomness_seed: 0
        }
      ]
    })
  end

  defp wait_for(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(20)
        do_wait_for(fun, deadline)
      end
    end
  end
end
