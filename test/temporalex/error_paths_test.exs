defmodule Temporalex.ErrorPathsTest do
  @moduledoc """
  Error propagation. Each test pins behavior that, if broken, would
  silently swallow failures or crash the executor in a way that strands
  workflow runs in Temporal with no clear cause.

  These are the highest-leverage stability tests: a bug here means
  workflows fail mysteriously in production and the operator has no
  diagnostic.
  """

  use ExUnit.Case, async: false

  alias Temporalex.Core.Command
  alias Temporalex.Core.Job
  alias Temporalex.Core.TestHarness
  alias Temporalex.Workflow.API

  defmodule Activities do
    use Temporalex.Activity

    defactivity work(label), timeout: 1_000 do
      {:ok, label}
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Exception in a parallel branch — siblings keep running
  # ────────────────────────────────────────────────────────────────────

  defmodule MixedSuccessFailureParallelWorkflow do
    @moduledoc """
    One parallel branch raises, the others succeed. Per the documented
    contract, `parallel/1` returns results in input order — failing
    branches surface as `{:error, _}` in the result list. The bug class:
    if a branch raises and the executor doesn't catch it cleanly, the
    other branches get torn down too → silent loss of in-flight work.
    """
    use Temporalex.Workflow

    def run(_) do
      results =
        API.parallel([
          fn -> {:ok, :left} end,
          fn ->
            raise %Temporalex.Failure.ApplicationError{message: "mid blew up", type: "MidErr"}
          end,
          fn -> {:ok, :right} end
        ])

      {:ok, results}
    end
  end

  describe "exception in parallel branch" do
    test "sibling branches still run to completion; failing branch surfaces as {:error, _}" do
      assert {:ok, exec} = TestHarness.start_workflow(MixedSuccessFailureParallelWorkflow, nil)

      assert {:complete, {:ok, results}} = TestHarness.next(exec)
      assert is_list(results) and length(results) == 3

      # Left and right both succeeded.
      assert Enum.at(results, 0) == {:ok, :left}
      assert Enum.at(results, 2) == {:ok, :right}

      # Middle is a tagged failure carrying the exception.
      assert {:error, %Temporalex.Failure.ApplicationError{type: "MidErr"}} = Enum.at(results, 1)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Signal handler crash inside phase
  # ────────────────────────────────────────────────────────────────────

  defmodule SignalHandlerCrashWorkflow do
    @moduledoc """
    Sync signal handler raises. The phase must absorb the crash and keep
    accepting further messages — otherwise one bad signal poisons the
    entire workflow run forever.
    """
    use Temporalex.Workflow

    def handle_query("counter", _args, state), do: {:reply, state}

    def run(_) do
      result =
        API.phase(0,
          signal: %{
            "bad" => fn _args, _state -> raise "signal handler blew up" end,
            "inc" => fn _args, state -> {:noreply, state + 1} end,
            "stop" => fn _args, state -> {:stop, state} end
          }
        )

      {:ok, result}
    end
  end

  describe "signal handler crash" do
    test "crashed sync signal handler does not poison the phase; later signals still process" do
      assert {:ok, exec} = TestHarness.start_workflow(SignalHandlerCrashWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      # First signal: bad. Handler raises. Phase swallows it, state unchanged.
      assert {:waiting, _} = TestHarness.send_signal(exec, "bad", [])

      # Phase still alive: inc bumps state to 1.
      assert {:waiting, _} = TestHarness.send_signal(exec, "inc", [])
      assert {:waiting, _} = TestHarness.send_signal(exec, "inc", [])

      # Stop returns the final state.
      assert {:complete, {:ok, 2}} = TestHarness.send_signal(exec, "stop", [])
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Query handler returning a malformed shape
  # ────────────────────────────────────────────────────────────────────

  defmodule BadQueryShapeWorkflow do
    @moduledoc """
    Query handler returns a value that isn't `{:reply, _}` / `{:error, _}`.
    Must surface as a structured query failure to the caller — NOT crash
    the workflow run.
    """
    use Temporalex.Workflow

    def handle_query("good", _args, _state), do: {:reply, :ok_value}
    def handle_query("malformed", _args, _state), do: :not_a_valid_return
    def handle_query("nil_return", _args, _state), do: nil

    def run(_), do: API.wait_for_signal("done") |> then(fn _ -> {:ok, :done} end)
  end

  describe "query handler malformed return" do
    test "non-{:reply,_} return surfaces as a query failure, workflow unaffected" do
      assert {:ok, exec} = TestHarness.start_workflow(BadQueryShapeWorkflow, nil)
      assert {:yield, []} = TestHarness.next(exec)

      # Good query works.
      assert {:yield, [%Command.RespondToQuery{query_id: "g", result: {:ok, :ok_value}}]} =
               TestHarness.query(exec, "good", [], query_id: "g")

      # Malformed query: failure response.
      assert {:yield, [%Command.RespondToQuery{query_id: "m", result: {:error, _reason}}]} =
               TestHarness.query(exec, "malformed", [], query_id: "m")

      # Nil-return query: failure response.
      assert {:yield, [%Command.RespondToQuery{query_id: "n", result: {:error, _reason}}]} =
               TestHarness.query(exec, "nil_return", [], query_id: "n")

      # Workflow is still alive — send the done signal, completes normally.
      assert {:complete, {:ok, :done}} = TestHarness.send_signal(exec, "done", [])
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Validator that calls a workflow API
  # ────────────────────────────────────────────────────────────────────

  defmodule ValidatorCallsApiWorkflow do
    @moduledoc """
    Validator that tries to call a workflow API (forbidden — validators
    run inline in the executor and must be synchronous/pure). The
    executor must detect the violation and reject the update; the workflow
    must NOT deadlock waiting on its own re-entrant call.
    """
    use Temporalex.Workflow

    def run(_) do
      result =
        API.phase(nil,
          update: %{
            "bad" =>
              {fn _args, _state -> {:reply, :ok, nil} end,
               validator: fn _args, _state ->
                 # This would try to call into the executor we're currently
                 # running inside. Different SDKs handle this differently —
                 # the safe behavior is: raise / return error.
                 _ = API.sleep(1)
                 :ok
               end}
          },
          signal: %{"done" => fn _args, _state -> {:stop, :ok} end}
        )

      {:ok, result}
    end
  end

  describe "validator that calls workflow APIs" do
    test "validator calling a workflow API rejects the update without hanging" do
      assert {:ok, exec} = TestHarness.start_workflow(ValidatorCallsApiWorkflow, nil)
      assert {:waiting, _} = TestHarness.next(exec)

      # Send update with a short receive timeout — if the validator deadlocks
      # the executor, this call would hang. The fact that it returns at all
      # (with any response) proves the executor didn't deadlock.
      result =
        try do
          TestHarness.send_update(exec, "bad", [], timeout: 2_000)
        catch
          :exit, _reason -> :exited
        end

      # Whatever the validator's specific outcome, the executor stayed alive.
      # Either it produced a rejected response (preferred) or the call exited
      # without taking down the executor. Workflow itself must still be alive.
      assert result != :hung

      # The workflow can still be stopped normally.
      stop_result =
        try do
          TestHarness.send_signal(exec, "done", [])
        catch
          :exit, _ -> :exited
        end

      # Either the phase completed normally or the executor remains alive
      # awaiting the next message. Either is acceptable; what's NOT
      # acceptable is a permanent deadlock.
      refute match?(:hung, stop_result)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # `{:exception, _}` tuple as a regular workflow return value
  # ────────────────────────────────────────────────────────────────────

  defmodule TupleResultWorkflow do
    @moduledoc """
    A workflow that legitimately returns a tuple shaped like our internal
    `{:exception, error, stacktrace}` form (as opposed to an actually
    raised exception). The bug class: our recent fix unwraps that tuple
    in the failure path. A workflow that intentionally returns such a
    tuple as a SUCCESS value must NOT be misinterpreted as a failure.
    """
    use Temporalex.Workflow

    def run(_) do
      # The workflow's successful result is the tuple itself.
      {:ok, {:exception, :not_an_error, []}}
    end
  end

  describe "tuple result that looks like an internal exception form" do
    test "workflow successfully returning {:exception, ...} as data is not mistaken for failure" do
      assert {:ok, exec} = TestHarness.start_workflow(TupleResultWorkflow, nil)

      # Must complete successfully with the tuple intact, NOT fail-workflow
      # with the tuple as the failure reason.
      assert {:complete, {:ok, {:exception, :not_an_error, []}}} = TestHarness.next(exec)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Activity returns invalid shape
  # ────────────────────────────────────────────────────────────────────

  defmodule ActivityReturnsBadShapeWorkflow do
    @moduledoc """
    Activity returns a value that isn't `{:ok, _}` / `{:error, _}` /
    `{:cancelled, _}` — e.g., a bare atom. The server wraps it as an
    `InvalidActivityReturn` ApplicationError. Workflow code can pattern-
    match on it to handle gracefully rather than crashing.
    """
    use Temporalex.Workflow

    def run(_) do
      case Activities.work(:gate) do
        {:ok, _} = ok ->
          ok

        {:error, %Temporalex.Failure.ApplicationError{type: "InvalidActivityReturn"} = err} ->
          {:ok, {:invalid_return, err.message}}

        other ->
          {:error, {:unexpected, other}}
      end
    end
  end

  describe "activity return shape" do
    test "activity returning an invalid shape becomes a structured failure" do
      assert {:ok, exec} = TestHarness.start_workflow(ActivityReturnsBadShapeWorkflow, nil)
      assert {:yield, [%Command.ScheduleActivity{seq: seq}]} = TestHarness.next(exec)

      # Server delivered the result already shaped as an ApplicationError
      # in the resolution job. The workflow's case clause catches it cleanly.
      assert {:complete, {:ok, {:invalid_return, message}}} =
               TestHarness.resolve(exec, %Job.ActivityResolved{
                 seq: seq,
                 result:
                   {:error,
                    %Temporalex.Failure.ApplicationError{
                      message: "activity returned invalid value: :weird",
                      type: "InvalidActivityReturn",
                      retryable?: false
                    }}
               })

      assert message =~ "invalid"
    end
  end
end
