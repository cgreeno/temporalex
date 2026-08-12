defmodule Temporalex.ActivitySurfaceTest do
  @moduledoc """
  RFC 0003 activity-surface tests that need no Temporal server: module
  defaults, `name:`, definition-time and call-time option validation, and
  `Temporalex.Testing.run_activity/4`.
  """

  use ExUnit.Case, async: true

  defmodule Payments do
    use Temporalex.Activity, start_to_close_timeout: 30_000

    defactivity charge(amount), name: "payments.charge" do
      {:ok, {:charged, amount}}
    end

    defactivity refund(amount), start_to_close_timeout: 5_000, retry_policy: [maximum_attempts: 2] do
      {:ok, {:refunded, amount}}
    end

    defactivity audit(ctx, entry) do
      {:ok, {entry, ctx.attempt, Temporalex.Activity.cancelled?(ctx)}}
    end

    defactivity stamp(value), local: true, start_to_close_timeout: 2_000 do
      {:ok, {:stamped, value}}
    end
  end

  describe "module defaults and per-activity overrides" do
    test "module defaults land on every activity's declared opts" do
      charge = find_activity(:charge)
      assert charge.opts[:start_to_close_timeout] == 30_000
    end

    test "per-activity options override module defaults key by key" do
      refund = find_activity(:refund)
      assert refund.opts[:start_to_close_timeout] == 5_000
      assert refund.opts[:retry_policy] == [maximum_attempts: 2]
    end
  end

  describe "name: — the wire type decoupled from the module name" do
    test "name: sets the type verbatim" do
      assert find_activity(:charge).type == "payments.charge"
    end

    test "without name: the type derives from module + function" do
      assert find_activity(:refund).type == "#{inspect(Payments)}.refund"
    end
  end

  describe "definition-time validation" do
    test "an unknown option refuses to compile, listing what is allowed" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule BadOpt do
            use Temporalex.Activity

            defactivity nope(x), start_to_close_tiemout: 5_000 do
              {:ok, x}
            end
          end
        end

      assert Exception.message(error) =~ ":start_to_close_tiemout"
      assert Exception.message(error) =~ ":start_to_close_timeout"
    end

    test "heartbeat_timeout on a local activity refuses to compile with the why" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule LocalBeat do
            use Temporalex.Activity

            defactivity nope(x), local: true, heartbeat_timeout: 5_000 do
              {:ok, x}
            end
          end
        end

      assert Exception.message(error) =~ "cannot heartbeat"
    end

    test "task_queue on a local activity refuses to compile with the why" do
      assert_raise ArgumentError, ~r/only applies to regular activities/, fn ->
        defmodule LocalQueue do
          use Temporalex.Activity

          defactivity nope(x), local: true, task_queue: "elsewhere" do
            {:ok, x}
          end
        end
      end
    end

    test "a duplicate activity name refuses to compile with the why" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule Twice do
            use Temporalex.Activity

            defactivity ping(x) do
              {:ok, x}
            end

            defactivity ping(x, y) do
              {:ok, {x, y}}
            end
          end
        end

      assert Exception.message(error) =~ "already defined"
      assert Exception.message(error) =~ "wire type"
    end

    test "unknown module-level defaults refuse to compile" do
      assert_raise ArgumentError, ~r/:tiemout/, fn ->
        defmodule BadDefaults do
          use Temporalex.Activity, tiemout: 5_000
        end
      end
    end

    test "a module default a local activity cannot honour is caught at that activity" do
      assert_raise ArgumentError, ~r/heartbeat_timeout/, fn ->
        defmodule BeatDefaults do
          use Temporalex.Activity, heartbeat_timeout: 5_000

          defactivity fine(x) do
            {:ok, x}
          end

          defactivity nope(x), local: true do
            {:ok, x}
          end
        end
      end
    end
  end

  describe "call-site options" do
    test "unknown call-site options raise before anything is dispatched" do
      error =
        assert_raise ArgumentError, fn -> Payments.charge!(100, tiemout: 5_000) end

      assert Exception.message(error) =~ ":tiemout"
      assert Exception.message(error) =~ "allowed"
    end

    test "both timeout spellings in one call raise instead of silently dropping one" do
      error =
        assert_raise ArgumentError, fn ->
          Payments.charge!(100, timeout: 9_000, start_to_close_timeout: 1_000)
        end

      assert Exception.message(error) =~ "two spellings of one knob"
    end

    test "both spellings on use defaults refuse to compile" do
      assert_raise ArgumentError, ~r/two spellings of one knob/, fn ->
        defmodule DoubleDefaults do
          use Temporalex.Activity, timeout: 9_000, start_to_close_timeout: 1_000
        end
      end
    end

    test "both spellings on one defactivity refuse to compile" do
      assert_raise ArgumentError, ~r/two spellings of one knob/, fn ->
        defmodule DoubleSpelled do
          use Temporalex.Activity

          defactivity nope(x), timeout: 9_000, start_to_close_timeout: 1_000 do
            {:ok, x}
          end
        end
      end
    end

    test "valid call-site options still require workflow context to run" do
      # Validation passes, then dispatch refuses outside a workflow — proving
      # option checking happens first and the call would otherwise proceed.
      assert_raise RuntimeError, ~r/outside workflow execution/, fn ->
        Payments.charge!(100, timeout: 10_000)
      end
    end

    test "existing arities keep working — opts are a new optional argument" do
      assert function_exported?(Payments, :charge!, 1)
      assert function_exported?(Payments, :charge!, 2)
      assert function_exported?(Payments, :charge, 1)
      assert function_exported?(Payments, :charge, 2)
    end
  end

  describe "Temporalex.Testing.run_activity/4" do
    test "runs the real implementation with no Temporal anywhere" do
      assert Temporalex.Testing.run_activity(Payments, :charge, [100]) == {:ok, {:charged, 100}}
    end

    test "fabricates a context for ctx-taking activities, with honest defaults" do
      assert {:ok, {"entry", 1, false}} =
               Temporalex.Testing.run_activity(Payments, :audit, ["entry"])
    end

    test "context: overrides merge onto the fabricated context" do
      assert {:ok, {"entry", 7, false}} =
               Temporalex.Testing.run_activity(Payments, :audit, ["entry"], context: [attempt: 7])
    end

    test "cancelled: false is the explicit negative, not a crash" do
      assert {:ok, {"entry", 1, false}} =
               Temporalex.Testing.run_activity(Payments, :audit, ["entry"],
                 context: [cancelled: false]
               )
    end

    test "an unknown context field raises instructively, not as a KeyError" do
      error =
        assert_raise ArgumentError, fn ->
          Temporalex.Testing.run_activity(Payments, :audit, ["entry"], context: [attemp: 3])
        end

      assert Exception.message(error) =~ ":attemp"
      assert Exception.message(error) =~ ":attempt"
    end

    test "a local activity's body runs identically — it is just a function" do
      assert Temporalex.Testing.run_activity(Payments, :stamp, [7]) == {:ok, {:stamped, 7}}
    end

    test "cancelled: true seeds a working cancellation flag" do
      assert {:ok, {"entry", 1, true}} =
               Temporalex.Testing.run_activity(Payments, :audit, ["entry"],
                 context: [cancelled: true]
               )
    end

    test "run_activity! unwraps success" do
      assert Temporalex.Testing.run_activity!(Payments, :charge, [100]) == {:charged, 100}
    end

    test "run_activity! raises the error" do
      defmodule Failing do
        use Temporalex.Activity

        defactivity boom(reason), start_to_close_timeout: 1_000 do
          {:error, %ArgumentError{message: "bad #{reason}"}}
        end

        defactivity odd(x), start_to_close_timeout: 1_000 do
          {:not_a_contract_shape, x}
        end
      end

      assert_raise ArgumentError, "bad input", fn ->
        Temporalex.Testing.run_activity!(Failing, :boom, ["input"])
      end

      assert_raise RuntimeError, ~r/must return/, fn ->
        Temporalex.Testing.run_activity!(Failing, :odd, [1])
      end
    end

    test "run_activity! raises with the reason for non-exception errors" do
      defmodule PlainError do
        use Temporalex.Activity

        defactivity nope(reason), start_to_close_timeout: 1_000 do
          {:error, reason}
        end
      end

      assert_raise RuntimeError, ~r/:gateway_down/, fn ->
        Temporalex.Testing.run_activity!(PlainError, :nope, [:gateway_down])
      end
    end

    test "context: on an activity that never sees ctx is a test bug and raises" do
      assert_raise ArgumentError, ~r/does not declare a ctx argument/, fn ->
        Temporalex.Testing.run_activity(Payments, :charge, [100], context: [attempt: 2])
      end
    end

    test "an unknown activity raises listing what is defined" do
      error =
        assert_raise ArgumentError, fn ->
          Temporalex.Testing.run_activity(Payments, :chrage, [100])
        end

      assert Exception.message(error) =~ "chrage/1"
      assert Exception.message(error) =~ "charge/1"
    end

    test "a non-activity module raises instructively" do
      assert_raise ArgumentError, ~r/use Temporalex.Activity/, fn ->
        Temporalex.Testing.run_activity(Enum, :map, [1])
      end
    end
  end

  describe "through the executor — driven by the Testing kit" do
    # async: true is safe: the Testing runner is per-run state.

    defmodule ChargeWorkflow do
      use Temporalex.Workflow

      def run({amount, call_opts}) do
        {:ok, Payments.charge(amount, call_opts)}
      end
    end

    test "declared options land on the scheduled command" do
      {:ok, run} = Temporalex.Testing.start_workflow(ChargeWorkflow, {100, []})

      activity = Temporalex.Testing.assert_next_activity(run, type: "payments.charge")
      assert activity.start_to_close_timeout_ms == 30_000

      Temporalex.Testing.complete_activity(run, activity, {:ok, :receipt})
      Temporalex.Testing.assert_completed(run, {:ok, :receipt})
      Temporalex.Testing.assert_replay(run)
    end

    defmodule ShortSpelling do
      # Declares the :timeout spelling deliberately — the cross-alias case:
      # the command builder reads :timeout first, so without alias handling a
      # :start_to_close_timeout from a lower layer would silently lose to this.
      use Temporalex.Activity, timeout: 30_000

      defactivity ping(x), name: "alias.ping" do
        {:ok, x}
      end

      defactivity pong(x), name: "alias.pong", start_to_close_timeout: 5_000 do
        {:ok, x}
      end
    end

    defmodule PongWorkflow do
      use Temporalex.Workflow

      def run(x), do: {:ok, ShortSpelling.pong(x)}
    end

    defmodule AliasWorkflow do
      use Temporalex.Workflow

      def run(call_opts), do: {:ok, ShortSpelling.ping(1, call_opts)}
    end

    test "a call-site start_to_close_timeout beats a declared timeout: alias" do
      # :timeout and :start_to_close_timeout are one knob; the call site must
      # win regardless of which spelling either side used.
      {:ok, run} = Temporalex.Testing.start_workflow(AliasWorkflow, start_to_close_timeout: 5_000)

      activity = Temporalex.Testing.assert_next_activity(run, type: "alias.ping")
      assert activity.start_to_close_timeout_ms == 5_000

      Temporalex.Testing.complete_activity(run, activity, {:ok, 1})
      Temporalex.Testing.assert_completed(run, {:ok, 1})
      Temporalex.Testing.assert_replay(run)
    end

    test "a per-activity start_to_close_timeout beats a module-default timeout: alias" do
      # Same alias rule one layer down: the per-activity declaration is the
      # override, the module default is the base.
      {:ok, run} = Temporalex.Testing.start_workflow(PongWorkflow, 1)

      activity = Temporalex.Testing.assert_next_activity(run, type: "alias.pong")
      assert activity.start_to_close_timeout_ms == 5_000

      Temporalex.Testing.complete_activity(run, activity, {:ok, 1})
      Temporalex.Testing.assert_completed(run, {:ok, 1})
      Temporalex.Testing.assert_replay(run)
    end

    test "and the same-spelling override still works" do
      {:ok, run} =
        Temporalex.Testing.start_workflow(ChargeWorkflow, {100, [start_to_close_timeout: 5_000]})

      activity = Temporalex.Testing.assert_next_activity(run, type: "payments.charge")
      assert activity.start_to_close_timeout_ms == 5_000

      Temporalex.Testing.complete_activity(run, activity, {:ok, :receipt})
      Temporalex.Testing.assert_completed(run, {:ok, :receipt})
      Temporalex.Testing.assert_replay(run)
    end

    test "call-site options override the declaration on the wire" do
      {:ok, run} = Temporalex.Testing.start_workflow(ChargeWorkflow, {100, [timeout: 10_000]})

      activity = Temporalex.Testing.assert_next_activity(run, type: "payments.charge")
      assert activity.start_to_close_timeout_ms == 10_000

      Temporalex.Testing.complete_activity(run, activity, {:ok, :receipt})
      Temporalex.Testing.assert_completed(run, {:ok, :receipt})
      Temporalex.Testing.assert_replay(run)
    end

    test "a cancelled activity comes back as {:error, %CancelledError{}} — one result shape" do
      {:ok, run} = Temporalex.Testing.start_workflow(ChargeWorkflow, {100, []})

      activity = Temporalex.Testing.assert_next_activity(run, type: "payments.charge")
      Temporalex.Testing.cancel_activity(run, activity, "operator request")

      assert {:ok, {:error, %Temporalex.Failure.CancelledError{message: "operator request"}}} =
               completed_result(run)

      Temporalex.Testing.assert_replay(run)
    end

    test "a backend-delivered CancelledError passes through untouched" do
      {:ok, run} = Temporalex.Testing.start_workflow(ChargeWorkflow, {100, []})
      activity = Temporalex.Testing.assert_next_activity(run, type: "payments.charge")

      original = Temporalex.Failure.cancelled("deadline moved", details: [:shard, 4])
      Temporalex.Testing.cancel_activity(run, activity, original)

      assert {:ok, {:error, ^original}} = completed_result(run)
      Temporalex.Testing.assert_replay(run)
    end

    test "a non-binary cancellation reason is wrapped with its details kept" do
      {:ok, run} = Temporalex.Testing.start_workflow(ChargeWorkflow, {100, []})
      activity = Temporalex.Testing.assert_next_activity(run, type: "payments.charge")

      Temporalex.Testing.cancel_activity(run, activity, {:shard_rebalance, 4})

      assert {:ok, {:error, %Temporalex.Failure.CancelledError{details: [{:shard_rebalance, 4}]}}} =
               completed_result(run)

      Temporalex.Testing.assert_replay(run)
    end

    defp completed_result(run) do
      {:ok, Temporalex.Testing.assert_completed(run)}
    end
  end

  describe "raw API local dispatch — the executor's own validation" do
    defmodule RawLocalWorkflow do
      use Temporalex.Workflow

      def run(_) do
        Temporalex.Workflow.API.execute_local_activity!("t", [], heartbeat_timeout: 5_000)
      end
    end

    test "unknown options fail the workflow listing what is allowed" do
      {:ok, run} = Temporalex.Testing.start_workflow(RawLocalWorkflow, nil)

      error = Temporalex.Testing.assert_failed(run)
      assert Exception.message(error) =~ ":heartbeat_timeout"
      assert Exception.message(error) =~ "allowed"
    end
  end

  describe "allowlist staleness (RFC 0002 §10 precedent)" do
    test "the surface allowlists match the command builder's" do
      assert Temporalex.Activity.__dispatch_opts__(false) ==
               Temporalex.Core.CommandBuilder.__activity_opts__(),
             "surface @dispatch_opts drifted from CommandBuilder @activity_opts — " <>
               "an option accepted at one layer and unknown at the other either " <>
               "raises spuriously or silently does nothing"

      assert Temporalex.Activity.__dispatch_opts__(true) ==
               Temporalex.Core.CommandBuilder.__local_activity_opts__(),
             "surface @local_dispatch_opts drifted from CommandBuilder @local_activity_opts"
    end

    test "the timeout alias set matches the command builder's" do
      assert Temporalex.Activity.__timeout_aliases__() ==
               Temporalex.Core.CommandBuilder.__timeout_aliases__(),
             "the alias set drifted — __merge_opts__ would stop retiring an " <>
               "alias the command builder resolves, resurrecting the silent drop"
    end
  end

  describe "Temporalex.Activity context verbs" do
    test "heartbeat/2 and cancelled?/1 delegate to Context" do
      context = %Temporalex.Activity.Context{}
      assert Temporalex.Activity.heartbeat(context) == :ok
      refute Temporalex.Activity.cancelled?(context)
    end
  end

  defp find_activity(name) do
    Enum.find(Payments.__temporal_activities__(), &(&1.name == name))
  end
end
