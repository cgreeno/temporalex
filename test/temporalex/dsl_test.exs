defmodule Temporalex.DSLTest do
  use ExUnit.Case, async: true
  use Temporalex.Testing

  # ============================================================
  # Test modules using the DSL
  # ============================================================

  defmodule Payments do
    use Temporalex.DSL

    defactivity charge(amount), timeout: 30_000 do
      # In real code this would call Stripe, etc.
      {:ok, "charged-#{amount}"}
    end

    defactivity send_receipt(email), timeout: 5_000 do
      {:ok, "receipt-sent-to-#{email}"}
    end

    def process_order(%{amount: amount, email: email}) do
      with {:ok, charge_id} <- charge(amount),
           {:ok, _receipt} <- send_receipt(email) do
        {:ok, charge_id}
      end
    end
  end

  defmodule Shipping do
    use Temporalex.DSL

    defactivity ship(item) do
      {:ok, "shipped-#{item}"}
    end
  end

  # ============================================================
  # Direct mode — no context, no stubs, just runs the impl
  # ============================================================

  describe "direct mode" do
    test "activity function runs implementation directly" do
      assert {:ok, "charged-100"} = Payments.charge(100)
    end

    test "workflow function works end-to-end" do
      assert {:ok, "charged-50"} = Payments.process_order(%{amount: 50, email: "a@b.com"})
    end
  end

  # ============================================================
  # Test mode — stubs via run_workflow
  # ============================================================

  describe "test mode with stubs" do
    test "stubs replace activity calls" do
      result =
        run_workflow(&Payments.process_order/1, %{amount: 100, email: "x@y.com"},
          activities: %{
            {Payments, :charge} => fn amount -> {:ok, "stub-charged-#{amount}"} end,
            {Payments, :send_receipt} => fn _ -> {:ok, "stub-receipt"} end
          }
        )

      assert {:ok, "stub-charged-100"} = result
    end

    test "activity calls are recorded for assertions" do
      run_workflow(&Payments.process_order/1, %{amount: 75, email: "test@test.com"},
        activities: %{
          {Payments, :charge} => fn _ -> {:ok, "ch"} end,
          {Payments, :send_receipt} => fn _ -> {:ok, "r"} end
        }
      )

      calls = get_activity_calls()
      assert [{{Payments, :charge}, 75}, {{Payments, :send_receipt}, "test@test.com"}] = calls
    end

    test "stub_activity works individually" do
      workflow_context()
      stub_activity({Payments, :charge}, fn amt -> {:ok, "individual-#{amt}"} end)
      stub_activity({Payments, :send_receipt}, fn _ -> {:ok, "ok"} end)

      assert {:ok, "individual-200"} = Payments.process_order(%{amount: 200, email: "z@z.com"})
    end

    test "stub error propagates through with chain" do
      result =
        run_workflow(&Payments.process_order/1, %{amount: 0, email: "e@e.com"},
          activities: %{
            {Payments, :charge} => fn _ -> {:error, "declined"} end,
            {Payments, :send_receipt} => fn _ -> {:ok, "receipt"} end
          }
        )

      # with chain short-circuits on {:error, _}
      assert {:error, "declined"} = result
    end
  end

  # ============================================================
  # Module metadata
  # ============================================================

  describe "module metadata" do
    test "__temporal_activities__ lists registered activities" do
      activities = Payments.__temporal_activities__()
      names = Enum.map(activities, &elem(&1, 0))
      assert :charge in names
      assert :send_receipt in names
    end

    test "impl functions are generated" do
      assert {:ok, "charged-42"} = Payments.__temporal_perform_charge__(42)

      assert {:ok, "receipt-sent-to-a@b.com"} =
               Payments.__temporal_perform_send_receipt__("a@b.com")
    end

    test "activity type strings" do
      assert "Temporalex.DSLTest.Payments.charge" =
               Temporalex.DSL.activity_type_string(Payments, :charge)
    end
  end

  # ============================================================
  # Workflow mode — with process context (schedules commands)
  # ============================================================

  # ============================================================
  # Mixed with old-style module activities
  # ============================================================

  describe "module activities with stubs" do
    defmodule LegacyActivity do
      use Temporalex.Activity, start_to_close_timeout: 5_000

      @impl true
      def perform(%{x: x}), do: {:ok, x * 2}
    end

    defmodule MixedWorkflow do
      use Temporalex.Workflow

      @impl true
      def run(%{x: x}) do
        {:ok, doubled} = execute_activity(LegacyActivity, %{x: x})
        {:ok, doubled}
      end
    end

    test "old-style module activities still work with run_workflow" do
      assert {:ok, 10} =
               run_workflow(MixedWorkflow, %{x: 5},
                 activities: %{LegacyActivity => fn %{x: x} -> {:ok, x * 2} end}
               )
    end
  end
end
