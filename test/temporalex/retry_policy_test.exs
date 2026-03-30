defmodule Temporalex.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Temporalex.RetryPolicy

  describe "defaults" do
    test "struct has sensible defaults" do
      policy = %RetryPolicy{}
      assert policy.max_attempts == 0
      assert policy.initial_interval == 1_000
      assert policy.backoff_coefficient == 2.0
      assert policy.maximum_interval == nil
      assert policy.non_retryable_error_types == []
    end
  end

  describe "new/1" do
    test "creates with defaults" do
      policy = RetryPolicy.new()
      assert policy.max_attempts == 0
      assert policy.initial_interval == 1_000
    end

    test "overrides specific fields" do
      policy = RetryPolicy.new(max_attempts: 5, initial_interval: 2_000)
      assert policy.max_attempts == 5
      assert policy.initial_interval == 2_000
      assert policy.backoff_coefficient == 2.0
    end

    test "sets all fields" do
      policy =
        RetryPolicy.new(
          max_attempts: 3,
          initial_interval: 500,
          backoff_coefficient: 1.5,
          maximum_interval: 60_000,
          non_retryable_error_types: ["CardDeclined", "NotFound"]
        )

      assert policy.max_attempts == 3
      assert policy.initial_interval == 500
      assert policy.backoff_coefficient == 1.5
      assert policy.maximum_interval == 60_000
      assert policy.non_retryable_error_types == ["CardDeclined", "NotFound"]
    end
  end

  describe "from_opts/1" do
    test "passes through existing struct" do
      policy = RetryPolicy.new(max_attempts: 7)
      assert ^policy = RetryPolicy.from_opts(policy)
    end

    test "converts keyword list to struct" do
      policy = RetryPolicy.from_opts(max_attempts: 3, initial_interval: 500)
      assert %RetryPolicy{max_attempts: 3, initial_interval: 500} = policy
    end
  end

  describe "to_proto/1" do
    test "converts defaults to proto" do
      proto = RetryPolicy.new() |> RetryPolicy.to_proto()
      assert proto.maximum_attempts == 0
      assert proto.initial_interval == %Google.Protobuf.Duration{seconds: 1, nanos: 0}
      assert proto.backoff_coefficient == 2.0
      assert proto.maximum_interval == nil
      assert proto.non_retryable_error_types == []
    end

    test "converts custom values to proto" do
      proto =
        RetryPolicy.new(
          max_attempts: 5,
          initial_interval: 2_500,
          maximum_interval: 30_000,
          non_retryable_error_types: ["Permanent"]
        )
        |> RetryPolicy.to_proto()

      assert proto.maximum_attempts == 5
      assert proto.initial_interval == %Google.Protobuf.Duration{seconds: 2, nanos: 500_000_000}
      assert proto.maximum_interval == %Google.Protobuf.Duration{seconds: 30, nanos: 0}
      assert proto.non_retryable_error_types == ["Permanent"]
    end

    test "ms_to_duration: exact seconds" do
      proto = RetryPolicy.new(initial_interval: 5_000) |> RetryPolicy.to_proto()
      assert proto.initial_interval == %Google.Protobuf.Duration{seconds: 5, nanos: 0}
    end

    test "ms_to_duration: sub-second" do
      proto = RetryPolicy.new(initial_interval: 250) |> RetryPolicy.to_proto()
      assert proto.initial_interval == %Google.Protobuf.Duration{seconds: 0, nanos: 250_000_000}
    end

    test "ms_to_duration: mixed seconds and millis" do
      proto = RetryPolicy.new(initial_interval: 1_750) |> RetryPolicy.to_proto()
      assert proto.initial_interval == %Google.Protobuf.Duration{seconds: 1, nanos: 750_000_000}
    end

    test "nil maximum_interval stays nil in proto" do
      proto = RetryPolicy.new(maximum_interval: nil) |> RetryPolicy.to_proto()
      assert proto.maximum_interval == nil
    end
  end
end
