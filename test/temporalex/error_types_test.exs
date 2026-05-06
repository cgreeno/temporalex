defmodule Temporalex.ErrorTypesTest do
  @moduledoc """
  Priority 6 — Error Types (E1-E8) from TESTS_V2.md.
  """

  use ExUnit.Case, async: true

  alias Temporalex.{
    ActivityFailure,
    ApplicationError,
    CancelledError,
    ChildWorkflowFailure,
    NondeterminismError,
    TimeoutError
  }

  alias Temporalex.Testing

  # --- Test activities / workflows for E7-E8 ---

  defmodule Acts do
    use Temporalex.Activity

    defactivity(work(x), do: {:ok, x})

    defactivity non_retryable(tag),
      retry_policy: %{
        initial_interval_ms: 100,
        max_interval_ms: 1_000,
        backoff_coefficient: 2.0,
        max_attempts: 3,
        non_retryable_error_types: ["PermanentFailure"]
      } do
      {:error, {:permanent, tag}}
    end
  end

  defmodule FailingChainWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      case Acts.work(:go) do
        {:ok, v} -> {:ok, v}
        {:error, reason} -> {:error, {:workflow_saw, reason}}
      end
    end
  end

  defmodule RetryableVsNonRetryableWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      Acts.non_retryable(:any)
    end
  end

  # --- Tests ---

  describe "E1 — ActivityFailure" do
    test "has activity_type and cause fields; message/1 describes the failure" do
      err = %ActivityFailure{
        activity_type: "MyApp.Activities.Charge",
        activity_id: "act-123",
        cause: %{reason: :card_declined}
      }

      assert err.activity_type == "MyApp.Activities.Charge"
      assert err.cause == %{reason: :card_declined}
      assert Exception.message(err) =~ "Activity MyApp.Activities.Charge failed"
      assert Exception.message(err) =~ "card_declined"
    end
  end

  describe "E2 — ChildWorkflowFailure" do
    test "has workflow_type, workflow_id, and cause fields" do
      err = %ChildWorkflowFailure{
        workflow_type: "MyApp.Workflows.Order",
        workflow_id: "order-42",
        cause: %{reason: :shipping_failed}
      }

      assert err.workflow_type == "MyApp.Workflows.Order"
      assert err.workflow_id == "order-42"
      assert err.cause == %{reason: :shipping_failed}
      assert Exception.message(err) =~ "Child workflow"
      assert Exception.message(err) =~ "order-42"
      assert Exception.message(err) =~ "shipping_failed"
    end
  end

  describe "E3 — ApplicationError with non_retryable flag" do
    test "carries a non_retryable flag so retry policies can respect it" do
      retryable = %ApplicationError{
        type: "TransientError",
        message: "temporary",
        non_retryable: false
      }

      permanent = %ApplicationError{
        type: "PermanentFailure",
        message: "card invalid",
        non_retryable: true
      }

      refute retryable.non_retryable
      assert permanent.non_retryable

      assert Exception.message(retryable) == "ApplicationError(TransientError): temporary"
      assert Exception.message(permanent) == "ApplicationError(PermanentFailure): card invalid"
    end
  end

  describe "E4 — TimeoutError with timeout_type" do
    test "timeout_type identifies which timeout fired" do
      for type <- [:schedule_to_start, :schedule_to_close, :start_to_close, :heartbeat] do
        err = %TimeoutError{timeout_type: type}
        assert err.timeout_type == type
        assert Exception.message(err) == "Timeout: #{type}"
      end
    end
  end

  describe "E5 — CancelledError with details" do
    test "details field carries cancellation context" do
      err = %CancelledError{details: %{reason: "user requested"}}

      assert err.details == %{reason: "user requested"}
      assert Exception.message(err) =~ "Cancelled"
      assert Exception.message(err) =~ "user requested"
    end
  end

  describe "E6 — NondeterminismError" do
    test "carries a message describing the divergence" do
      err = %NondeterminismError{
        message: "expected activity seq=2, got timer seq=2"
      }

      assert Exception.message(err) == "expected activity seq=2, got timer seq=2"
    end

    test "the replay module raises NondeterminismError with a descriptive message" do
      log = [{:activity, 1, :ok}]

      assert_raise NondeterminismError, ~r/Nondeterminism/, fn ->
        Temporalex.Worker.Replay.consume(log, :timer, 1)
      end
    end
  end

  describe "E7 — error chain preservation (activity → workflow → client)" do
    test "activity failure tuple reaches the workflow, wrapped by workflow's return" do
      {:ok, exec} = Testing.start_workflow(FailingChainWorkflow, %{})

      assert {:activity, _} = Testing.next(exec)

      # Activity returns a structured failure. Workflow pattern-matches and
      # wraps it in its own error tuple — exactly how error chains preserve
      # context across layers.
      assert {:error, {:workflow_saw, %{kind: :card_declined, retriable: false}}} =
               Testing.resolve(exec, {:error, %{kind: :card_declined, retriable: false}})
    end
  end

  describe "E8 — workflow retry with retryable vs non-retryable failure" do
    test "retry_policy's non_retryable_error_types option is preserved on the activity call" do
      {:ok, exec} = Testing.start_workflow(RetryableVsNonRetryableWorkflow, %{})

      assert {:activity, call} = Testing.next(exec)
      policy = Keyword.fetch!(call.opts, :retry_policy)

      assert policy.non_retryable_error_types == ["PermanentFailure"]
      assert policy.max_attempts == 3

      # Retry enforcement itself is Core-SDK-side; when a failure is
      # classified as non-retryable, the server stops scheduling retries
      # and surfaces the failure to the workflow immediately.
      assert {:error, :permanent} = Testing.resolve(exec, {:error, :permanent})
    end
  end
end
