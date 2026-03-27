defmodule Temporalex.TestingTest do
  use ExUnit.Case, async: true
  use Temporalex.Testing

  defmodule SimpleWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(%{name: name}) do
      set_state(%{greeted: name})
      {:ok, "Hello, #{name}!"}
    end

    def run(_), do: {:ok, "Hello, world!"}
  end

  defmodule FailWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(%{reason: reason}), do: {:error, reason}
  end

  defmodule PatchedWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(_args) do
      result =
        if patched?("v2-algo") do
          "new"
        else
          "old"
        end

      {:ok, result}
    end
  end

  defmodule SimpleActivity do
    use Temporalex.Activity, start_to_close_timeout: 5_000

    @impl true
    def perform(%{x: x}), do: {:ok, x * 2}
  end

  defmodule ContextActivity do
    use Temporalex.Activity, start_to_close_timeout: 5_000

    @impl true
    def perform(_ctx, %{x: x}), do: {:ok, x + 1}
  end

  defmodule ChargePayment do
    use Temporalex.Activity, start_to_close_timeout: 5_000

    @impl true
    def perform(%{amount: _amount}), do: {:ok, "real-charge"}
  end

  defmodule ShipOrder do
    use Temporalex.Activity, start_to_close_timeout: 5_000

    @impl true
    def perform(_input), do: {:ok, "real-ship"}
  end

  defmodule OrderWorkflow do
    use Temporalex.Workflow

    @impl true
    def run(%{amount: amount}) do
      {:ok, charge_id} = execute_activity(ChargePayment, %{amount: amount})
      {:ok, ship_id} = execute_activity(ShipOrder, %{charge_id: charge_id})
      {:ok, ship_id}
    end
  end

  # ============================================================
  # run_workflow
  # ============================================================

  describe "run_workflow/2,3" do
    test "runs a simple workflow" do
      assert {:ok, "Hello, Alice!"} = run_workflow(SimpleWorkflow, %{name: "Alice"})
    end

    test "workflow state is accessible" do
      run_workflow(SimpleWorkflow, %{name: "Bob"})
      assert %{greeted: "Bob"} = get_workflow_state()
    end

    test "failing workflow returns error" do
      assert {:error, "broken"} = run_workflow(FailWorkflow, %{reason: "broken"})
    end

    test "workflow with patches (replay, patch active)" do
      assert {:ok, "new"} = run_workflow(PatchedWorkflow, %{}, patches: ["v2-algo"])
    end
  end

  # ============================================================
  # run_activity
  # ============================================================

  describe "run_activity/2" do
    test "runs a perform/1 activity" do
      assert {:ok, 10} = run_activity(SimpleActivity, %{x: 5})
    end

    test "runs a perform/2 activity with context" do
      assert {:ok, 6} = run_activity(ContextActivity, %{x: 5})
    end
  end

  # ============================================================
  # workflow_context
  # ============================================================

  describe "workflow_context/1" do
    test "sets up process dictionary" do
      info = workflow_context(workflow_module: SimpleWorkflow)
      assert info.workflow_type == "Temporalex.TestingTest.SimpleWorkflow"
      assert Process.get(:__temporal_workflow_info__) == info
      assert Process.get(:__temporal_state__) == nil
      assert Process.get(:__temporal_patches__) == MapSet.new()
      assert Process.get(:__temporal_cancelled__) == false
    end

    test "accepts pre-notified patches" do
      workflow_context(patches: ["p1", "p2"])
      patches = Process.get(:__temporal_patches__)
      assert MapSet.member?(patches, "p1")
      assert MapSet.member?(patches, "p2")
    end

    test "auto-generates unique IDs" do
      ctx1 = workflow_context()
      ctx2 = workflow_context()
      assert ctx1.workflow_id != ctx2.workflow_id
      assert ctx1.run_id != ctx2.run_id
    end
  end

  # ============================================================
  # Activity stubs
  # ============================================================

  describe "activity stubs" do
    test "workflow with stubbed activities via run_workflow option" do
      result =
        run_workflow(OrderWorkflow, %{amount: 100},
          activities: %{
            ChargePayment => fn %{amount: a} -> {:ok, "charged-#{a}"} end,
            ShipOrder => fn %{charge_id: id} -> {:ok, "shipped-#{id}"} end
          }
        )

      assert {:ok, "shipped-charged-100"} = result
    end

    test "assert_activity_called tracks which activities ran" do
      run_workflow(OrderWorkflow, %{amount: 50},
        activities: %{
          ChargePayment => fn _ -> {:ok, "ch"} end,
          ShipOrder => fn _ -> {:ok, "sh"} end
        }
      )

      assert_activity_called(ChargePayment)
      assert_activity_called(ShipOrder)
    end

    test "assert_activity_called with specific input" do
      run_workflow(OrderWorkflow, %{amount: 75},
        activities: %{
          ChargePayment => fn _ -> {:ok, "ch"} end,
          ShipOrder => fn _ -> {:ok, "sh"} end
        }
      )

      assert_activity_called(ChargePayment, %{amount: 75})
    end

    test "get_activity_calls returns calls in order" do
      run_workflow(OrderWorkflow, %{amount: 42},
        activities: %{
          ChargePayment => fn _ -> {:ok, "ch"} end,
          ShipOrder => fn _ -> {:ok, "sh"} end
        }
      )

      calls = get_activity_calls()
      assert [{ChargePayment, %{amount: 42}}, {ShipOrder, %{charge_id: "ch"}}] = calls
    end

    test "stub_activity registers stubs individually" do
      workflow_context(workflow_module: OrderWorkflow)
      stub_activity(ChargePayment, fn _ -> {:ok, "stub-charge"} end)
      stub_activity(ShipOrder, fn _ -> {:ok, "stub-ship"} end)

      assert {:ok, "stub-ship"} = OrderWorkflow.run(%{amount: 10})
      assert_activity_called(ChargePayment)
      assert_activity_called(ShipOrder)
    end

    test "stubbed activity error propagates as MatchError" do
      assert_raise MatchError, fn ->
        run_workflow(OrderWorkflow, %{amount: 0},
          activities: %{
            ChargePayment => fn _ -> {:error, "declined"} end,
            ShipOrder => fn _ -> {:ok, "shipped"} end
          }
        )
      end
    end
  end

  # ============================================================
  # Telemetry events
  # ============================================================

  describe "telemetry" do
    test "workflow events are emitted" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:temporalex, :workflow, :start],
          [:temporalex, :workflow, :stop]
        ])

      meta = %{workflow_id: "wf-1", workflow_type: "Test", run_id: "r-1", task_queue: "q"}
      start_time = Temporalex.Telemetry.workflow_start(meta)
      Temporalex.Telemetry.workflow_stop(start_time, Map.put(meta, :result, :ok))

      assert_receive {[:temporalex, :workflow, :start], ^ref, %{system_time: _},
                      %{workflow_id: "wf-1"}}

      assert_receive {[:temporalex, :workflow, :stop], ^ref, %{duration: _}, %{result: :ok}}
    end

    test "activity events are emitted" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:temporalex, :activity, :start],
          [:temporalex, :activity, :stop]
        ])

      meta = %{activity_type: "MyActivity", activity_id: "a-1", task_queue: "q"}
      start_time = Temporalex.Telemetry.activity_start(meta)
      Temporalex.Telemetry.activity_stop(start_time, Map.put(meta, :result, :ok))

      assert_receive {[:temporalex, :activity, :start], ^ref, %{system_time: _},
                      %{activity_type: "MyActivity"}}

      assert_receive {[:temporalex, :activity, :stop], ^ref, %{duration: _}, %{result: :ok}}
    end

    test "activation event includes job and command counts" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:temporalex, :worker, :activation]
        ])

      Temporalex.Telemetry.worker_activation(1_000_000, %{
        run_id: "r-1",
        task_queue: "q",
        job_count: 3,
        command_count: 2
      })

      assert_receive {[:temporalex, :worker, :activation], ^ref,
                      %{duration: 1_000_000, job_count: 3, command_count: 2}, %{run_id: "r-1"}}
    end

    test "OpenTelemetry setup attaches handlers" do
      # opentelemetry_api is in deps, so setup succeeds (spans are no-ops without full SDK)
      assert :ok = Temporalex.OpenTelemetry.setup()
      Temporalex.OpenTelemetry.teardown()
    end
  end
end
