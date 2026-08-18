defmodule Temporalex.FailureGuardTest do
  @moduledoc """
  `Temporalex.Failure.is_failure/2` and the accessors: matching a failure by
  its Temporal type without reaching through the wrapper by hand, and without
  collapsing it (the wrapper's diagnostics stay reachable).

  Both failure depths are exercised deliberately. Live evidence for why there
  are two: `test/temporalex/integration/local_activity_test.exs` (a failed
  LOCAL activity arrives as the business error itself) and
  `test/temporalex/integration/structured_errors_test.exs` (a failed REMOTE
  activity arrives wrapped in `%ActivityError{}`).
  """

  use ExUnit.Case, async: true

  import Temporalex.Failure, only: [is_failure: 2]

  alias Temporalex.Failure
  alias Temporalex.Failure.ActivityError
  alias Temporalex.Failure.ApplicationError

  defp wrapped(type, opts \\ []) do
    %ActivityError{
      activity_type: "Payments.charge",
      retry_state: Keyword.get(opts, :retry_state, :non_retryable_failure),
      cause: %ApplicationError{message: "over limit", type: type, retryable?: false}
    }
  end

  defp bare(type), do: %ApplicationError{message: "over limit", type: type}

  describe "is_failure/2 in a case" do
    defp classify(result) do
      case result do
        {:ok, value} -> {:ok, value}
        {:error, e} when is_failure(e, "AmountTooLarge") -> :limit
        {:error, e} when is_failure(e, "GatewayDeclined") -> :declined
        {:error, _e} -> :other
      end
    end

    test "matches a REMOTE failure through the wrapper" do
      assert classify({:error, wrapped("AmountTooLarge")}) == :limit
    end

    test "matches a LOCAL failure at the top level" do
      assert classify({:error, bare("AmountTooLarge")}) == :limit
    end

    test "discriminates between types at both depths" do
      assert classify({:error, wrapped("GatewayDeclined")}) == :declined
      assert classify({:error, bare("GatewayDeclined")}) == :declined
      assert classify({:error, wrapped("SomethingElse")}) == :other
      assert classify({:error, bare("SomethingElse")}) == :other
    end

    test "the happy path is untouched" do
      assert classify({:ok, :receipt}) == {:ok, :receipt}
    end
  end

  describe "is_failure/2 in function heads" do
    defp settle({:error, e}) when is_failure(e, "AmountTooLarge"), do: :limit
    defp settle({:error, e}) when is_failure(e, "Transient"), do: :retry_later
    defp settle({:error, _e}), do: :escalate
    defp settle({:ok, v}), do: {:done, v}

    test "one clause per error type, no nested patterns" do
      assert settle({:error, wrapped("AmountTooLarge")}) == :limit
      assert settle({:error, bare("Transient")}) == :retry_later
      assert settle({:error, wrapped("Unknown")}) == :escalate
      assert settle({:ok, 1}) == {:done, 1}
    end
  end

  describe "is_failure/2 degrades instead of raising" do
    # A guard whose expression raises is simply false, which is exactly the
    # behaviour wanted here: shapes with no type to compare must not match,
    # and must not crash the caller either.
    test "a wrapper with no cause does not match" do
      refute_failure(%ActivityError{cause: nil}, "AmountTooLarge")
    end

    test "an unstructured raise (bare exception as cause) does not match" do
      refute_failure(%ActivityError{cause: %RuntimeError{message: "boom"}}, "AmountTooLarge")
    end

    test "a non-map cause does not match" do
      refute_failure(%ActivityError{cause: :insufficient_funds}, "AmountTooLarge")
    end

    test "a bare exception with no :type does not match" do
      refute_failure(%RuntimeError{message: "boom"}, "AmountTooLarge")
    end

    test "non-map reasons do not match" do
      for reason <- [:insufficient_funds, "a string", 42, nil, {:tuple, 1}, [1, 2]] do
        refute_failure(reason, "AmountTooLarge")
      end
    end

    defp refute_failure(error, type) do
      matched? =
        case {:error, error} do
          {:error, e} when is_failure(e, type) -> true
          _ -> false
        end

      refute matched?, "#{inspect(error)} should not match type #{inspect(type)}"
    end
  end

  describe "the wrapper survives the match" do
    test "diagnostics are still reachable on the matched error" do
      kept =
        case {:error, wrapped("AmountTooLarge")} do
          {:error, e} when is_failure(e, "AmountTooLarge") ->
            {:kept, e.retry_state, e.activity_type}
        end

      assert kept == {:kept, :non_retryable_failure, "Payments.charge"}
    end
  end

  describe "accessors" do
    test "type/1 reads either depth, nil when absent" do
      assert Failure.type(wrapped("AmountTooLarge")) == "AmountTooLarge"
      assert Failure.type(bare("AmountTooLarge")) == "AmountTooLarge"
      assert Failure.type(%ActivityError{cause: %RuntimeError{message: "boom"}}) == nil
      assert Failure.type(%ActivityError{cause: nil}) == nil
      assert Failure.type(%RuntimeError{message: "boom"}) == nil
      assert Failure.type(:insufficient_funds) == nil
      assert Failure.type(nil) == nil
    end

    test "retry_state/1 and activity_type/1 read the wrapper, nil elsewhere" do
      wrapper = wrapped("AmountTooLarge", retry_state: :maximum_attempts_reached)

      assert Failure.retry_state(wrapper) == :maximum_attempts_reached
      assert Failure.activity_type(wrapper) == "Payments.charge"

      assert Failure.retry_state(bare("AmountTooLarge")) == nil
      assert Failure.activity_type(bare("AmountTooLarge")) == nil
      assert Failure.retry_state(:atom) == nil
      assert Failure.activity_type(nil) == nil
    end

    test "cause/1 unwraps one level, nil when there is nothing to unwrap" do
      assert %ApplicationError{type: "AmountTooLarge"} = Failure.cause(wrapped("AmountTooLarge"))
      assert Failure.cause(%ActivityError{cause: nil}) == nil
      assert Failure.cause(:atom) == nil
    end

    test "type/1 prefers the error's own type over its cause's" do
      # An ApplicationError may itself carry a cause; its own type wins.
      nested = %ApplicationError{
        message: "outer",
        type: "Outer",
        cause: %ApplicationError{message: "inner", type: "Inner"}
      }

      assert Failure.type(nested) == "Outer"
    end
  end
end
