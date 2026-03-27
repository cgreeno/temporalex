defmodule Temporalex.ErrorTest do
  use ExUnit.Case, async: true

  alias Temporalex.Error.{ActivityFailure, TimeoutError, CancelledError, ApplicationError}
  alias Temporalex.FailureConverter
  alias Temporal.Api.Failure.V1.Failure

  describe "error structs" do
    test "ActivityFailure formats message" do
      err = %ActivityFailure{
        message: "connection timeout",
        activity_type: "MyApp.Activities.Fetch",
        activity_id: "42"
      }

      assert Exception.message(err) =~
               "Activity failed: connection timeout (type=MyApp.Activities.Fetch, id=42)"
    end

    test "TimeoutError formats message" do
      err = %TimeoutError{message: "exceeded limit", timeout_type: :start_to_close}
      assert Exception.message(err) =~ "Timeout: exceeded limit (type=start_to_close)"
    end

    test "CancelledError formats message" do
      err = %CancelledError{message: "user requested"}
      assert Exception.message(err) =~ "Cancelled: user requested"
    end

    test "ApplicationError formats message with type" do
      err = %ApplicationError{message: "bad input", type: "ValidationError", non_retryable: true}
      assert Exception.message(err) =~ "ApplicationError[ValidationError]: bad input"
    end

    test "ApplicationError formats message without type" do
      err = %ApplicationError{message: "something broke", type: nil, non_retryable: false}
      assert Exception.message(err) =~ "ApplicationError: something broke"
    end
  end

  describe "FailureConverter.to_failure/1" do
    test "converts ActivityFailure to Failure proto" do
      err = %ActivityFailure{message: "fail", activity_type: "T", activity_id: "1"}
      failure = FailureConverter.to_failure(err)
      assert %Failure{} = failure
      assert failure.message =~ "Activity failed"
    end

    test "converts TimeoutError to Failure proto" do
      err = %TimeoutError{message: "timed out", timeout_type: :heartbeat}
      failure = FailureConverter.to_failure(err)
      assert %Failure{} = failure
      assert {:timeout_failure_info, _} = failure.failure_info
    end

    test "converts CancelledError to Failure proto" do
      err = %CancelledError{message: "cancelled"}
      failure = FailureConverter.to_failure(err)
      assert {:canceled_failure_info, _} = failure.failure_info
    end

    test "converts ApplicationError to Failure proto" do
      err = %ApplicationError{message: "app err", type: "MyType", non_retryable: true}
      failure = FailureConverter.to_failure(err)
      assert {:application_failure_info, info} = failure.failure_info
      assert info.type == "MyType"
      assert info.non_retryable == true
    end

    test "converts plain string to Failure proto" do
      failure = FailureConverter.to_failure("something broke")
      assert failure.message == "something broke"
    end

    test "converts generic exception to Failure proto" do
      err = RuntimeError.exception("boom")
      failure = FailureConverter.to_failure(err)
      assert failure.message == "boom"
    end
  end

  describe "FailureConverter.from_failure/1" do
    test "converts timeout failure back to TimeoutError" do
      failure = %Failure{
        message: "timed out",
        failure_info:
          {:timeout_failure_info,
           %Temporal.Api.Failure.V1.TimeoutFailureInfo{
             timeout_type: :TIMEOUT_TYPE_START_TO_CLOSE
           }}
      }

      err = FailureConverter.from_failure(failure)
      assert %TimeoutError{timeout_type: :start_to_close} = err
    end

    test "converts cancelled failure back to CancelledError" do
      failure = %Failure{
        message: "cancelled",
        failure_info: {:canceled_failure_info, %Temporal.Api.Failure.V1.CanceledFailureInfo{}}
      }

      err = FailureConverter.from_failure(failure)
      assert %CancelledError{message: "cancelled"} = err
    end

    test "converts application failure back to ApplicationError" do
      failure = %Failure{
        message: "app err",
        failure_info:
          {:application_failure_info,
           %Temporal.Api.Failure.V1.ApplicationFailureInfo{
             type: "ValidationError",
             non_retryable: true
           }}
      }

      err = FailureConverter.from_failure(failure)
      assert %ApplicationError{type: "ValidationError", non_retryable: true} = err
    end

    test "converts unknown failure to ApplicationError" do
      failure = %Failure{message: "unknown"}
      err = FailureConverter.from_failure(failure)
      assert %ApplicationError{message: "unknown"} = err
    end
  end
end
