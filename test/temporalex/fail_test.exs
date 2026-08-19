defmodule Temporalex.FailTest do
  @moduledoc """
  Covers `Temporalex.fail!/2`, the raise side of the README's flagship error
  example, and the shape the match side sees: Temporal's failure tree, with
  the `%ActivityError{}` wrapper kept and the business error as its cause.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Failure.ActivityError
  alias Temporalex.Failure.ApplicationError

  describe "fail!/2" do
    test "raises an ApplicationError with the named options mapped" do
      error =
        assert_raise ApplicationError, "amount exceeds limit", fn ->
          Temporalex.fail!("amount exceeds limit", type: "AmountTooLarge", retry: false)
        end

      assert error.type == "AmountTooLarge"
      assert error.retryable? == false
    end

    test "retry defaults to true and details ride along" do
      error =
        assert_raise ApplicationError, fn ->
          Temporalex.fail!("soft", details: [amount: 10_001])
        end

      assert error.retryable? == true
      assert error.details == [amount: 10_001]
    end

    test "a non-boolean retry: is refused at the call site, not in the codec" do
      for bad <- [nil, "false", 0, :no] do
        error = assert_raise ArgumentError, fn -> Temporalex.fail!("m", retry: bad) end
        assert Exception.message(error) =~ "retry: must be true or false"
        assert Exception.message(error) =~ inspect(bad)
      end
    end

    test "a non-binary type: is refused — it would be dropped on the wire" do
      # nil included deliberately: an explicit `type: nil` is a present option
      # with a bad value, not an absent one, and it used to slip through and be
      # replaced by the generic default on the wire.
      for bad <- [:AtomType, 42, "", nil] do
        error = assert_raise ArgumentError, fn -> Temporalex.fail!("m", type: bad) end
        assert Exception.message(error) =~ "must be a non-empty String.t()"
        assert Exception.message(error) =~ inspect(bad)
      end
    end

    test "an omitted type: is still fine — absent is not the same as nil" do
      error = assert_raise Temporalex.Failure.ApplicationError, fn -> Temporalex.fail!("m") end
      assert error.type == "Temporalex.ApplicationError"
    end

    test "unknown options raise listing what is allowed" do
      error =
        assert_raise ArgumentError, fn -> Temporalex.fail!("x", retryable: false) end

      assert Exception.message(error) =~ ":retryable"
      assert Exception.message(error) =~ ":retry"
    end

    test "a repeated allowed option is not mistaken for an unknown one" do
      error =
        assert_raise ApplicationError, fn ->
          Temporalex.fail!("dupe", type: "First", type: "Second")
        end

      assert error.type == "First"
    end
  end

  describe "the shape activity dispatch delivers" do
    defmodule Acts do
      use Temporalex.Activity

      defactivity charge(amount), start_to_close_timeout: 5_000 do
        {:ok, amount}
      end
    end

    defmodule ChargeWorkflow do
      use Temporalex.Workflow

      # The README flagship shape: reach through the wrapper to the cause.
      def run(amount) do
        case Acts.charge(amount) do
          {:ok, charge} -> {:ok, {:charged, charge}}
          {:error, %{cause: %{type: "AmountTooLarge"}}} -> {:ok, :limit_exceeded}
          {:error, other} -> {:ok, {:unexpected, other}}
        end
      end
    end

    test "the wrapper reaches the workflow with the business error as its cause" do
      {:ok, run} = Temporalex.Testing.start_workflow(ChargeWorkflow, 20_000)
      activity = Temporalex.Testing.assert_next_activity(run)

      wrapper = %ActivityError{
        cause: %ApplicationError{message: "amount exceeds limit", type: "AmountTooLarge"}
      }

      Temporalex.Testing.complete_activity(run, activity, {:error, wrapper})
      Temporalex.Testing.assert_completed(run, :limit_exceeded)
      Temporalex.Testing.assert_replay(run)
    end

    test "the wrapper's own diagnostics survive dispatch: retry_state, activity_type" do
      {:ok, run} = Temporalex.Testing.start_workflow(ChargeWorkflow, 1)
      activity = Temporalex.Testing.assert_next_activity(run)

      wrapper = %ActivityError{
        activity_type: "charge",
        activity_id: "7",
        retry_state: :maximum_attempts_reached,
        cause: %ApplicationError{message: "transient", type: "Transient"}
      }

      Temporalex.Testing.complete_activity(run, activity, {:error, wrapper})

      # Falls to the catch-all clause carrying the whole tree. Folding to the
      # cause would discard the three fields asserted below.
      assert {:completed, {:unexpected, %ActivityError{} = delivered}} =
               Temporalex.Testing.Runner.terminal(run)

      assert delivered.retry_state == :maximum_attempts_reached
      assert delivered.activity_type == "charge"
      assert delivered.activity_id == "7"
      assert %ApplicationError{type: "Transient"} = delivered.cause
    end

    defmodule BangRescueWorkflow do
      use Temporalex.Workflow

      # The bang raises the wrapper, so rescue names ActivityError and reads
      # the business error off its cause.
      def run(amount) do
        charge = Acts.charge!(amount)
        {:ok, {:charged, charge}}
      rescue
        e in ActivityError -> {:ok, {:rescued, e.cause.type}}
      end
    end

    test "the bang raises the wrapper, rescue-able as ActivityError" do
      {:ok, run} = Temporalex.Testing.start_workflow(BangRescueWorkflow, 20_000)
      activity = Temporalex.Testing.assert_next_activity(run)

      wrapper = %ActivityError{cause: %ApplicationError{message: "limit", type: "AmountTooLarge"}}
      Temporalex.Testing.complete_activity(run, activity, {:error, wrapper})

      Temporalex.Testing.assert_completed(run, {:rescued, "AmountTooLarge"})
      Temporalex.Testing.assert_replay(run)
    end

    defmodule FailingWorkflow do
      use Temporalex.Workflow

      def run(_input) do
        Temporalex.fail!("order state is unrecoverable", type: "Unrecoverable")
      end
    end

    test "fail! in workflow code fails the workflow with the business error" do
      {:ok, run} = Temporalex.Testing.start_workflow(FailingWorkflow, nil)

      error = Temporalex.Testing.assert_failed(run)
      assert %ApplicationError{type: "Unrecoverable"} = error
      assert error.message == "order state is unrecoverable"
    end

    test "a wrapper without a structured cause arrives intact" do
      {:ok, run} = Temporalex.Testing.start_workflow(ChargeWorkflow, 1)
      activity = Temporalex.Testing.assert_next_activity(run)

      wrapper = %ActivityError{message: "opaque", cause: nil}
      Temporalex.Testing.complete_activity(run, activity, {:error, wrapper})

      Temporalex.Testing.assert_completed(run, {:unexpected, wrapper})
    end
  end
end
