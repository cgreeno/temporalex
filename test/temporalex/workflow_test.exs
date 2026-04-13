defmodule Temporalex.WorkflowTest do
  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test activity modules ---

  defmodule Activities.Payment do
    use Temporalex.Activity

    defactivity charge(amount) do
      {:ok, "charge_#{amount}"}
    end
  end

  defmodule Activities.Email do
    use Temporalex.Activity

    defactivity send_receipt(charge_id) do
      _ = charge_id
      {:ok, :sent}
    end
  end

  # --- Test workflow modules ---

  defmodule SimpleWorkflow do
    use Temporalex.Workflow

    def run(args) do
      {:ok, charge} = Activities.Payment.charge(args["amount"])
      {:ok, _} = Activities.Email.send_receipt(charge)
      {:ok, %{charge_id: charge}}
    end
  end

  defmodule PublishingWorkflow do
    use Temporalex.Workflow

    def handle_query("status", _args, state), do: {:reply, state}

    def run(args) do
      API.publish_state(%{step: :charging})
      {:ok, charge} = Activities.Payment.charge(args["amount"])
      API.publish_state(%{step: :done, charge: charge})
      {:ok, charge}
    end
  end

  defmodule SleepWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      API.sleep(5000)
      {:ok, charge} = Activities.Payment.charge(100)
      {:ok, charge}
    end
  end

  defmodule SideEffectWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      id = API.side_effect(fn -> "generated-id-123" end)
      {:ok, charge} = Activities.Payment.charge(id)
      {:ok, %{id: id, charge: charge}}
    end
  end

  defmodule SignalWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      approval = API.wait_for_signal("approval")
      {:ok, charge} = Activities.Payment.charge(approval["amount"])
      {:ok, %{approved: true, charge: charge}}
    end
  end

  defmodule FailingWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      {:error, :something_went_wrong}
    end
  end

  defmodule ContinueAsNewWorkflow do
    use Temporalex.Workflow

    def run(args) do
      gen = args["generation"] || 0

      if gen >= 3 do
        {:ok, :done}
      else
        {:continue_as_new, %{"generation" => gen + 1}}
      end
    end
  end

  defmodule CancelCheckWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      # Block on an activity so the test can cancel before checking
      {:ok, _} = Activities.Payment.charge(100)

      if API.cancelled?() do
        {:error, :cancelled}
      else
        {:ok, :not_cancelled}
      end
    end
  end

  # --- Tests ---

  describe "sequential workflow" do
    test "two activities in sequence" do
      {:ok, exec} = Testing.start_workflow(SimpleWorkflow, %{"amount" => 100})

      assert {:activity, call} = Testing.next(exec)
      assert call.type == "Temporalex.WorkflowTest.Activities.Payment.charge"
      assert call.input == [100]

      assert {:activity, call} = Testing.resolve(exec, {:ok, "charge_100"})
      assert call.type == "Temporalex.WorkflowTest.Activities.Email.send_receipt"
      assert call.input == ["charge_100"]

      assert {:ok, result} = Testing.resolve(exec, {:ok, :sent})
      assert result == %{charge_id: "charge_100"}
    end
  end

  describe "publish_state and queries" do
    test "queries return published state" do
      {:ok, exec} = Testing.start_workflow(PublishingWorkflow, %{"amount" => 50})

      # After first publish_state, workflow blocks on activity
      assert {:activity, _call} = Testing.next(exec)
      assert {:reply, %{step: :charging}} = Testing.query(exec, "status")

      # After resolve, workflow publishes final state then completes
      assert {:ok, _result} = Testing.resolve(exec, {:ok, "charge_50"})
      assert {:reply, %{step: :done, charge: "charge_50"}} = Testing.query(exec, "status")
    end
  end

  describe "sleep" do
    test "blocks then continues" do
      {:ok, exec} = Testing.start_workflow(SleepWorkflow, %{})

      assert {:sleep, 5000} = Testing.next(exec)

      assert {:activity, call} = Testing.resolve(exec, :ok)
      assert call.type =~ "Payment.charge"

      assert {:ok, result} = Testing.resolve(exec, {:ok, "charged"})
      assert result == "charged"
    end
  end

  describe "side_effect" do
    test "executes function and returns result inline" do
      {:ok, exec} = Testing.start_workflow(SideEffectWorkflow, %{})

      # side_effect runs immediately, so next blocking point is the activity
      assert {:activity, call} = Testing.next(exec)
      assert call.input == ["generated-id-123"]

      assert {:ok, result} = Testing.resolve(exec, {:ok, "charge_xyz"})
      assert result == %{id: "generated-id-123", charge: "charge_xyz"}
    end
  end

  describe "wait_for_signal" do
    test "blocks until signal arrives" do
      {:ok, exec} = Testing.start_workflow(SignalWorkflow, %{})

      assert {:signal, "approval"} = Testing.next(exec)

      # Send the signal — unblocks wait_for_signal, workflow hits activity
      Testing.send_signal(exec, "approval", %{"amount" => 200})
      assert {:activity, call} = Testing.next(exec)
      assert call.input == [200]

      assert {:ok, result} = Testing.resolve(exec, {:ok, "charge_200"})
      assert result == %{approved: true, charge: "charge_200"}
    end
  end

  describe "workflow results" do
    test "error result" do
      {:ok, exec} = Testing.start_workflow(FailingWorkflow, %{})
      assert {:error, :something_went_wrong} = Testing.next(exec)
    end

    test "continue_as_new" do
      {:ok, exec} = Testing.start_workflow(ContinueAsNewWorkflow, %{"generation" => 0})
      assert {:continue_as_new, %{"generation" => 1}} = Testing.next(exec)
    end

    test "successful completion" do
      {:ok, exec} = Testing.start_workflow(ContinueAsNewWorkflow, %{"generation" => 3})
      assert {:ok, :done} = Testing.next(exec)
    end
  end

  describe "cancellation" do
    test "cancelled? returns false by default, true after cancel" do
      {:ok, exec} = Testing.start_workflow(CancelCheckWorkflow, %{})

      # Workflow blocks on activity
      assert {:activity, _call} = Testing.next(exec)

      # Cancel, then resolve the activity — workflow checks cancelled?
      Testing.cancel(exec)
      assert {:error, :cancelled} = Testing.resolve(exec, {:ok, "done"})
    end
  end
end
