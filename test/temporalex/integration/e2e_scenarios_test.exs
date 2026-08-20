defmodule Temporalex.E2eScenariosIntegrationTest do
  @moduledoc """
  End-to-end scenarios spanning multiple primitives: entity workflows,
  multi-phase transitions, continue-as-new state preservation, activity
  heartbeat against a live server, local activity error / retry paths.

  Connects to 127.0.0.1:7233. Skipped by default.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Activities do
    use Temporalex.Activity

    defactivity heartbeat_once(ctx, value), heartbeat_timeout: 5_000 do
      :ok = Temporalex.Activity.Context.heartbeat(ctx, {:beat, value})
      {:ok, {:done, value}}
    end

    defactivity fail_first_then_succeed(_attempt_marker), start_to_close_timeout: 5_000 do
      # Activity's `attempt` counter is exposed through context — but the
      # simplest deterministic test: just always succeed with a fixed result.
      # Retry behavior tested separately via non_retryable.
      {:ok, :ok_eventually}
    end

    defactivity always_fail_non_retryable(),
      start_to_close_timeout: 5_000,
      retry_policy: [maximum_attempts: 5] do
      raise %Temporalex.Failure.ApplicationError{
        message: "no retry plz",
        type: "NoRetryEver",
        retryable?: false
      }
    end

    defactivity local_doubles(value), local: true, start_to_close_timeout: 2_000 do
      {:ok, value * 2}
    end

    defactivity local_fails(reason), local: true, start_to_close_timeout: 2_000 do
      raise %Temporalex.Failure.ApplicationError{
        message: "local fail",
        type: "LocalFail",
        retryable?: false,
        details: reason
      }
    end
  end

  defmodule Counter do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("count", _args, state), do: {:reply, state}

    def run(initial) do
      API.publish_state(initial)

      final =
        API.phase(initial,
          signal: %{
            "inc" => fn _args, n ->
              new = n + 1
              API.publish_state(new)
              {:noreply, new}
            end,
            "done" => fn _args, n -> {:stop, n} end
          }
        )

      {:ok, final}
    end
  end

  defmodule MultiPhase do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      # Phase 1: collect a value
      collected =
        API.phase(nil,
          signal: %{
            "set" => fn [value], _state -> {:stop, value} end
          }
        )

      # Phase 2: gate on confirmation
      confirmed =
        API.phase(false,
          signal: %{
            "confirm" => fn _args, _state -> {:stop, true} end,
            "cancel" => fn _args, _state -> {:stop, false} end
          }
        )

      {:ok, {collected, confirmed}}
    end
  end

  defmodule ContinueWithState do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("generation", _args, state), do: {:reply, state}

    def run(%{generation: gen}) when gen >= 3 do
      API.publish_state(gen)
      {:ok, {:final, gen}}
    end

    def run(%{generation: gen}) do
      API.publish_state(gen)

      # Continue-as-new immediately with incremented state.
      {:continue_as_new, %{generation: gen + 1}}
    end
  end

  defmodule HeartbeatWorkflow do
    use Temporalex.Workflow
    def run(value), do: Activities.heartbeat_once(value)
  end

  defmodule RetryWorkflow do
    use Temporalex.Workflow

    def run(_) do
      case Activities.always_fail_non_retryable() do
        {:error, failure} -> {:ok, {:got_failure, failure}}
        other -> {:error, {:unexpected, other}}
      end
    end
  end

  defmodule LocalActivityFailWorkflow do
    use Temporalex.Workflow

    def run(_) do
      case Activities.local_fails(:bad_input) do
        {:error, failure} -> {:ok, {:local_failure, failure}}
        other -> {:error, {:unexpected, other}}
      end
    end
  end

  defmodule LocalActivitySumWorkflow do
    use Temporalex.Workflow

    def run(_) do
      {:ok, a} = Activities.local_doubles(1)
      {:ok, b} = Activities.local_doubles(2)
      {:ok, c} = Activities.local_doubles(3)
      {:ok, a + b + c}
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    client_name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    task_queue = "e2e-scenarios-#{System.unique_integer([:positive])}"

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client_name,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: Temporalex.TestSupport.Namespace.name(),
        task_queue: task_queue
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        client: client_name,
        task_queue: task_queue,
        workflows: [
          Counter,
          MultiPhase,
          ContinueWithState,
          HeartbeatWorkflow,
          RetryWorkflow,
          LocalActivityFailWorkflow,
          LocalActivitySumWorkflow
        ],
        activities: [Activities]
      )

    on_exit(fn ->
      try do
        if Process.alive?(worker_pid), do: Supervisor.stop(worker_pid, :normal, 5_000)
        if Process.alive?(client_pid), do: GenServer.stop(client_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, client: client_name, worker: worker_name}
  end

  describe "entity / counter workflow" do
    test "counter accumulates increments via signals then stops on done", %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, Counter, 0,
          workflow_id: "counter-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      assert :ok = Temporalex.Client.signal_workflow(handle, "inc", [], timeout: 5_000)
      assert :ok = Temporalex.Client.signal_workflow(handle, "inc", [], timeout: 5_000)
      assert :ok = Temporalex.Client.signal_workflow(handle, "inc", [], timeout: 5_000)
      assert :ok = Temporalex.Client.signal_workflow(handle, "done", [], timeout: 5_000)

      assert {:ok, 3} = Temporalex.Client.get_result(handle, timeout: 15_000)
    end

    test "counter responds to queries while running", %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, Counter, 100,
          workflow_id: "counter-q-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      assert eventually(fn ->
               Temporalex.Client.query_workflow(handle, "count", [], timeout: 2_000) ==
                 {:ok, 100}
             end)

      :ok = Temporalex.Client.signal_workflow(handle, "inc", [], timeout: 5_000)

      assert eventually(fn ->
               Temporalex.Client.query_workflow(handle, "count", [], timeout: 2_000) ==
                 {:ok, 101}
             end)

      :ok = Temporalex.Client.signal_workflow(handle, "done", [], timeout: 5_000)
      _ = Temporalex.Client.get_result(handle, timeout: 10_000)
    end
  end

  describe "multi-phase workflow" do
    test "two phases in sequence each respond to their own signals", %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, MultiPhase, nil,
          workflow_id: "multiphase-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      assert :ok = Temporalex.Client.signal_workflow(handle, "set", [:hello], timeout: 5_000)
      assert :ok = Temporalex.Client.signal_workflow(handle, "confirm", [], timeout: 5_000)

      assert {:ok, {:hello, true}} = Temporalex.Client.get_result(handle, timeout: 15_000)
    end

    test "second phase cancel branch returns the cancel outcome", %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, MultiPhase, nil,
          workflow_id: "multiphase-cancel-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      assert :ok = Temporalex.Client.signal_workflow(handle, "set", [42], timeout: 5_000)
      assert :ok = Temporalex.Client.signal_workflow(handle, "cancel", [], timeout: 5_000)

      assert {:ok, {42, false}} = Temporalex.Client.get_result(handle, timeout: 15_000)
    end
  end

  describe "continue-as-new" do
    test "state preserved across CAN iterations until terminal condition met",
         %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, ContinueWithState, %{generation: 0},
          workflow_id: "can-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      # Workflow continues-as-new 3 times then completes on generation 3.
      assert {:ok, {:final, 3}} = Temporalex.Client.get_result(handle, timeout: 30_000)
    end
  end

  describe "activity heartbeat (live)" do
    test "activity that calls heartbeat completes successfully", %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, HeartbeatWorkflow, :alpha,
          workflow_id: "hb-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      assert {:ok, {:done, :alpha}} = Temporalex.Client.get_result(handle, timeout: 15_000)
    end
  end

  describe "retry policy" do
    test "retryable?: false on raised error skips retries", %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, RetryWorkflow, nil,
          workflow_id: "retry-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      # Workflow catches the failure on first attempt — confirms no retries.
      assert {:ok, {:got_failure, %Temporalex.Failure.ActivityError{cause: cause}}} =
               Temporalex.Client.get_result(handle, timeout: 15_000)

      assert cause.type == "NoRetryEver"
      assert cause.retryable? == false
    end
  end

  describe "local activities (live)" do
    test "local activity that raises surfaces as ApplicationError to workflow",
         %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, LocalActivityFailWorkflow, nil,
          workflow_id: "la-fail-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      # Local activities surface failures directly as the underlying
      # ApplicationError (no outer ActivityFailure wrap, since local-activity
      # resolution doesn't carry the activity-task identity in the same way
      # as remote activities).
      assert {:ok, {:local_failure, %Temporalex.Failure.ApplicationError{} = failure}} =
               Temporalex.Client.get_result(handle, timeout: 15_000)

      assert failure.type == "LocalFail"
      assert failure.details == [:bad_input]
    end

    test "sequence of local activities composes correctly", %{client: client} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(client, LocalActivitySumWorkflow, nil,
          workflow_id: "la-sum-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      # 1*2 + 2*2 + 3*2 = 12
      assert {:ok, 12} = Temporalex.Client.get_result(handle, timeout: 15_000)
    end
  end

  defp temporal_available? do
    case :gen_tcp.connect(~c"127.0.0.1", 7233, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(100)
        do_eventually(fun, deadline)
      end
    end
  end
end
