defmodule Temporalex.FailureTest do
  use ExUnit.Case, async: true

  alias Temporalex.Failure
  alias Temporalex.Failure.ApplicationError
  alias Temporalex.Failure.CancelledError

  test "application helper defaults to a retryable application error" do
    assert %ApplicationError{
             message: "boom",
             type: "Temporalex.ApplicationError",
             details: [],
             retryable?: true
           } = Failure.application("boom")
  end

  test "application helper accepts type, details, and retryable flag" do
    assert %ApplicationError{
             message: "declined",
             type: "PaymentDeclined",
             details: [%{payment_id: "p1"}],
             retryable?: false
           } =
             Failure.application("declined",
               type: "PaymentDeclined",
               details: [%{payment_id: "p1"}],
               retryable?: false
             )
  end

  test "cancelled helper builds cancellation failure" do
    assert %CancelledError{message: "stopped", details: [:cleanup]} =
             Failure.cancelled("stopped", details: [:cleanup])
  end
end
