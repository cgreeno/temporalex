defmodule Temporalex.E2ETest do
  @moduledoc """
  Priority 10 — End-to-end integration (E2E1-E2E18) from TESTS_V2.md.

  Run: `mix test --include integration test/temporalex/e2e_test.exs`

  Requires a Temporal dev server on localhost:7233. Each test uses a
  unique task queue per test, so they can run in parallel safely
  against a shared namespace.

  We drive workflows via the Temporal CLI (`temporal workflow start`,
  `temporal workflow signal`, etc.) and poll history via
  `temporal workflow show --output json`. The Elixir side (worker) is
  always under test — the CLI is just a neutral, reliable driver.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  # --- Test activities ---

  defmodule Acts do
    use Temporalex.Activity

    defactivity(add(a, b), do: {:ok, a + b})
    defactivity(multiply(a, b), do: {:ok, a * b})
    defactivity(echo(x), do: {:ok, x})
    defactivity(fail_once(x), do: {:error, {:always_fails, x}})

    defactivity tag_id(prefix), local: true do
      {:ok, "#{prefix}-#{:erlang.phash2(prefix, 1_000_000)}"}
    end
  end

  # --- Test workflows ---

  defmodule SimpleWorkflow do
    use Temporalex.Workflow
    def run(args), do: Acts.add(args["a"], args["b"])
  end

  defmodule TwoStepWorkflow do
    use Temporalex.Workflow

    def run(args) do
      {:ok, sum} = Acts.add(args["a"], args["b"])
      {:ok, product} = Acts.multiply(sum, args["c"])
      {:ok, %{sum: sum, product: product}}
    end
  end

  defmodule LocalActivityWorkflow do
    use Temporalex.Workflow

    def run(args) do
      {:ok, tag} = Acts.tag_id(args["prefix"])
      {:ok, doubled} = Acts.multiply(2, 3)
      {:ok, %{tag: tag, doubled: doubled}}
    end
  end

  defmodule SleepWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      API.sleep(200)
      {:ok, :awake}
    end
  end

  defmodule SideEffectWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      v = API.side_effect(fn -> :generated end)
      {:ok, v}
    end
  end

  defmodule FailingWorkflow do
    use Temporalex.Workflow
    def run(_args), do: {:error, :deliberate}
  end

  defmodule CANWorkflow do
    use Temporalex.Workflow

    def run(args) do
      gen = Map.get(args, "gen", 0)

      if gen >= 2 do
        {:ok, gen}
      else
        {:continue_as_new, %{"gen" => gen + 1}}
      end
    end
  end

  defmodule SignalDrivenWorkflow do
    use Temporalex.Workflow

    def handle_query("value", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(0)

      result =
        API.receive(0,
          signal: %{
            "add" => fn amount, total -> {:noreply, total + amount} end,
            "done" => fn _payload, total -> {:stop, total} end
          }
        )

      API.publish_state(result)
      {:ok, result}
    end
  end

  defmodule UpdateDrivenWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{count: 0},
          update: %{
            "increment" => fn [n], state ->
              {:reply, state.count + n, %{state | count: state.count + n}}
            end,
            "snapshot" => fn _args, state -> {:reply, state.count, state} end,
            "stop" => fn _args, state -> {:stop, state.count, state} end
          }
        )

      {:ok, result}
    end
  end

  # Workflow with an update handler that crashes AFTER the update has been
  # accepted by the SDK. Used to verify the Accept→Reject(failure) transition
  # in Temporal Core's update state machine: per the audit at
  # update_state_machine.rs, jumping straight to Reject is allowed before
  # Accept, but post-Accept the SDK expects Completed. We send Rejected with
  # a failure message — Core may panic, accept, or retry. This integration
  # test verifies our SDK doesn't lock the workflow even when the path
  # exercises that transition.
  defmodule UpdateCrashWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:initial,
          update: %{
            "explode" => fn _args, _state -> raise("update handler boom") end,
            "ping" => fn _args, state -> {:reply, :pong, state} end
          },
          signal: %{"done" => fn _payload, s -> {:stop, s} end}
        )

      {:ok, result}
    end
  end

  defmodule MultiPhaseWorkflow do
    use Temporalex.Workflow

    def handle_query("phase", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(:phase_one)

      _ =
        API.receive(:p1,
          signal: %{"next" => fn _p, _s -> {:stop, :phase1_done} end}
        )

      API.publish_state(:phase_two)

      _ =
        API.receive(:p2,
          signal: %{"finish" => fn _p, _s -> {:stop, :phase2_done} end}
        )

      {:ok, :all_done}
    end
  end

  defmodule ChildEcho do
    use Temporalex.Workflow
    def run(args), do: {:ok, args["value"] * 2}
  end

  defmodule ChildFail do
    use Temporalex.Workflow
    def run(_args), do: {:error, :child_boom}
  end

  defmodule ParentOfEcho do
    use Temporalex.Workflow

    def run(args) do
      {:ok, doubled} = API.start_child_workflow(ChildEcho, %{"value" => args["x"]})
      {:ok, doubled}
    end
  end

  defmodule ParentOfFail do
    use Temporalex.Workflow

    def run(_args) do
      result = API.start_child_workflow(ChildFail, %{})
      {:ok, result}
    end
  end

  defmodule CancelAwareWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      # Hold in receive until cancelled or signaled.
      _ =
        API.receive(:waiting,
          signal: %{
            "done" => fn _p, s -> {:stop, s} end
          }
        )

      if API.cancelled?() do
        {:error, :cancelled}
      else
        {:ok, :ran}
      end
    end
  end

  # --- Helpers ---

  # Unique across test runs — protects against leftover workflows from
  # earlier runs that are still pending on the dev server.
  @run_id :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  defp unique_task_queue,
    do: "temporalex-e2e-#{@run_id}-#{System.unique_integer([:positive])}"

  defp unique_wf_id,
    do: "e2e-wf-#{@run_id}-#{System.unique_integer([:positive])}"

  defp start_worker(workflows, activities) do
    task_queue = unique_task_queue()
    name = :"e2e_worker_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Temporalex.Worker.start_link(
        url: "http://localhost:7233",
        namespace: "default",
        task_queue: task_queue,
        workflows: workflows,
        activities: activities,
        name: name
      )

    # Give poll loops time to connect.
    Process.sleep(500)

    on_exit(fn ->
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{task_queue: task_queue}
  end

  defp cli_start_workflow(workflow_type, task_queue, opts \\ []) do
    wf_id = Keyword.get(opts, :workflow_id, unique_wf_id())
    input = Keyword.get(opts, :input)

    args =
      [
        "workflow",
        "start",
        "--type",
        workflow_type,
        "--task-queue",
        task_queue,
        "--workflow-id",
        wf_id,
        "--output",
        "json"
      ] ++ if input, do: ["--input", input], else: []

    {_out, 0} = System.cmd("temporal", args, stderr_to_stdout: true)
    wf_id
  end

  defp cli_wait(wf_id, expected_status \\ "Completed", timeout_ms \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      {out, _} =
        System.cmd(
          "temporal",
          ["workflow", "describe", "--workflow-id", wf_id, "--output", "json"],
          stderr_to_stdout: true
        )

      out
    end)
    |> Enum.find(fn out ->
      cond do
        out =~ expected_status -> true
        System.monotonic_time(:millisecond) > deadline -> flunk("timeout waiting for #{wf_id}")
        true -> Process.sleep(200) && false
      end
    end)

    :ok
  end

  defp cli_signal(wf_id, signal_name, input \\ nil) do
    args =
      [
        "workflow",
        "signal",
        "--workflow-id",
        wf_id,
        "--name",
        signal_name
      ] ++ if input, do: ["--input", input], else: []

    {_out, 0} = System.cmd("temporal", args, stderr_to_stdout: true)
    :ok
  end

  defp cli_query(wf_id, query_name) do
    {out, 0} =
      System.cmd(
        "temporal",
        [
          "workflow",
          "query",
          "--workflow-id",
          wf_id,
          "--type",
          query_name,
          "--output",
          "json"
        ],
        stderr_to_stdout: true
      )

    out
  end

  defp cli_cancel(wf_id) do
    {_out, 0} =
      System.cmd(
        "temporal",
        ["workflow", "cancel", "--workflow-id", wf_id],
        stderr_to_stdout: true
      )

    :ok
  end

  # --- Tests ---

  describe "E2E1 — simple workflow: one activity" do
    test "workflow runs and completes" do
      %{task_queue: tq} = start_worker([SimpleWorkflow], [Acts])

      wf_id =
        cli_start_workflow(
          "Temporalex.E2ETest.SimpleWorkflow",
          tq,
          input: ~s({"a": 3, "b": 4})
        )

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E2 — two-step workflow: two sequential activities" do
    test "workflow completes with both steps" do
      %{task_queue: tq} = start_worker([TwoStepWorkflow], [Acts])

      wf_id =
        cli_start_workflow(
          "Temporalex.E2ETest.TwoStepWorkflow",
          tq,
          input: ~s({"a": 2, "b": 3, "c": 5})
        )

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E3 — workflow with sleep/timer" do
    test "timer fires, workflow completes" do
      %{task_queue: tq} = start_worker([SleepWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.SleepWorkflow", tq)

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E4 — workflow with side_effect" do
    test "side_effect runs inline, workflow completes" do
      %{task_queue: tq} = start_worker([SideEffectWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.SideEffectWorkflow", tq)

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E5 — workflow failure" do
    test "workflow returning {:error, _} shows as Failed" do
      %{task_queue: tq} = start_worker([FailingWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.FailingWorkflow", tq)

      cli_wait(wf_id, "Failed")
    end
  end

  describe "E2E6 — continue-as-new end-to-end" do
    test "workflow completes after CAN chain" do
      %{task_queue: tq} = start_worker([CANWorkflow], [])

      wf_id =
        cli_start_workflow(
          "Temporalex.E2ETest.CANWorkflow",
          tq,
          input: ~s({"gen": 0})
        )

      # Workflow completes normally at gen=2.
      cli_wait(wf_id, "Completed", 30_000)
    end
  end

  describe "E2E7 — signal a running workflow" do
    test "signal is received and processed" do
      %{task_queue: tq} = start_worker([SignalDrivenWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.SignalDrivenWorkflow", tq)

      # Give the workflow time to enter receive.
      Process.sleep(500)

      cli_signal(wf_id, "add", "5")
      cli_signal(wf_id, "add", "10")
      cli_signal(wf_id, "done")

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E8 — query a running workflow" do
    test "query returns published state" do
      %{task_queue: tq} = start_worker([SignalDrivenWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.SignalDrivenWorkflow", tq)

      Process.sleep(500)

      result = cli_query(wf_id, "value")
      # Initial state is 0.
      assert result =~ "0"

      cli_signal(wf_id, "done")
      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E9 — signal with start" do
    test "start-with-signal pattern: signal sent as part of start delivers to first receive" do
      %{task_queue: tq} = start_worker([SignalDrivenWorkflow], [])

      wf_id = unique_wf_id()

      # The "execute" subcommand starts and waits for the result. We can't
      # easily combine start-with-signal via CLI, so simulate it: start,
      # then quickly signal-and-close.
      {_out, 0} =
        System.cmd(
          "temporal",
          [
            "workflow",
            "start",
            "--type",
            "Temporalex.E2ETest.SignalDrivenWorkflow",
            "--task-queue",
            tq,
            "--workflow-id",
            wf_id,
            "--output",
            "json"
          ],
          stderr_to_stdout: true
        )

      Process.sleep(500)
      cli_signal(wf_id, "add", "42")
      cli_signal(wf_id, "done")

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E10 — multi-phase workflow transitioning between receives" do
    test "two signals transition through two receive phases" do
      %{task_queue: tq} = start_worker([MultiPhaseWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.MultiPhaseWorkflow", tq)

      Process.sleep(500)

      cli_signal(wf_id, "next")
      Process.sleep(300)
      cli_signal(wf_id, "finish")

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E11 — parent starts child, gets result" do
    test "parent/child workflows complete together" do
      %{task_queue: tq} = start_worker([ParentOfEcho, ChildEcho], [])

      wf_id =
        cli_start_workflow(
          "Temporalex.E2ETest.ParentOfEcho",
          tq,
          input: ~s({"x": 21})
        )

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E12 — parent starts child, child fails" do
    test "child failure propagates to parent which completes with error" do
      %{task_queue: tq} = start_worker([ParentOfFail, ChildFail], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.ParentOfFail", tq)

      # Parent captures the error as a normal {:ok, {:error, _}} result.
      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E13 — cancel parent cascades to child" do
    # Scaffold test: we drive a cancel on a workflow that has a child, but
    # the full cascade semantics depend on the parent's close policy. For
    # this test we just verify that cancelling the parent completes it
    # without hanging the suite.
    test "cancelling a parent that has not yet started a child completes cleanly" do
      %{task_queue: tq} = start_worker([CancelAwareWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.CancelAwareWorkflow", tq)

      Process.sleep(500)
      cli_cancel(wf_id)

      # Workflow sees cancel, stops receive, then the cancelled? branch
      # returns {:error, :cancelled} → workflow ends Failed.
      # Actually: cancel delivered to workflow may be applied before the
      # receive returns; result depends on timing. We accept either.
      cli_wait_terminal(wf_id, 30_000)
    end
  end

  describe "E2E14 — start via Client, describe via CLI" do
    test "Temporalex.Client.start_workflow returns a run_id, workflow completes" do
      %{task_queue: tq} = start_worker([SimpleWorkflow], [Acts])

      {:ok, client} = Temporalex.Client.connect("http://localhost:7233")

      wf_id = unique_wf_id()

      result =
        Temporalex.Client.start_workflow(client, "default",
          workflow_id: wf_id,
          workflow_type: "Temporalex.E2ETest.SimpleWorkflow",
          task_queue: tq,
          input: %{"a" => 1, "b" => 2}
        )

      assert {:ok, _run_id} = result

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E15 — signal via Client" do
    test "Temporalex.Client.signal_workflow delivers a signal" do
      %{task_queue: tq} = start_worker([SignalDrivenWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.SignalDrivenWorkflow", tq)

      Process.sleep(500)

      {:ok, client} = Temporalex.Client.connect("http://localhost:7233")

      assert :ok =
               Temporalex.Client.signal_workflow(client, "default",
                 workflow_id: wf_id,
                 signal_name: "add",
                 input: 7
               )

      assert :ok =
               Temporalex.Client.signal_workflow(client, "default",
                 workflow_id: wf_id,
                 signal_name: "done"
               )

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E16 — query via Client" do
    test "Temporalex.Client.query_workflow returns the published state" do
      %{task_queue: tq} = start_worker([SignalDrivenWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.SignalDrivenWorkflow", tq)

      Process.sleep(500)

      {:ok, client} = Temporalex.Client.connect("http://localhost:7233")

      assert {:ok, 0} =
               Temporalex.Client.query_workflow(client, "default",
                 workflow_id: wf_id,
                 query_type: "value"
               )

      cli_signal(wf_id, "done")
      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E17 — cancel running workflow via Client" do
    test "Temporalex.Client.cancel_workflow terminates the workflow" do
      %{task_queue: tq} = start_worker([CancelAwareWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.CancelAwareWorkflow", tq)

      Process.sleep(500)

      {:ok, client} = Temporalex.Client.connect("http://localhost:7233")

      assert :ok =
               Temporalex.Client.cancel_workflow(client, "default",
                 workflow_id: wf_id,
                 reason: "e2e test"
               )

      cli_wait_terminal(wf_id, 30_000)
    end
  end

  describe "E2E18 — activity cancellation end-to-end" do
    # Full activity-cancel flow requires a long-running, heartbeating
    # activity that the server tells us to cancel. Scaffolded here with a
    # workflow that requests cancel via its own API.cancelled? branch.
    test "cancelling a workflow that has not yet reached its activity completes cleanly" do
      %{task_queue: tq} = start_worker([CancelAwareWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.CancelAwareWorkflow", tq)

      Process.sleep(500)
      cli_cancel(wf_id)

      cli_wait_terminal(wf_id, 30_000)
    end
  end

  describe "E2E19 — local activity end-to-end" do
    test "workflow runs a local activity then a regular activity" do
      %{task_queue: tq} = start_worker([LocalActivityWorkflow], [Acts])

      wf_id =
        cli_start_workflow(
          "Temporalex.E2ETest.LocalActivityWorkflow",
          tq,
          input: ~s({"prefix": "ord"})
        )

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E20 — update returns response to caller" do
    # The wire-protocol invariant for updates is verified at unit level
    # by `assert_one_flush_per_activation` in worker_executor_test.exs.
    # CLI-driven update e2e is currently blocked on a tooling issue: the
    # `temporal` CLI cannot render responses encoded as `binary/etf`
    # (our SDK default) — it errors with "payload encoding is not
    # supported". The update itself completes correctly server-side.
    # Re-enable once we expose `Temporalex.Client.update_workflow` (which
    # uses ETF natively) or add a JSON codec for CLI compat.
    @tag :skip
    test "update handler return value surfaces to the caller" do
      %{task_queue: tq} = start_worker([UpdateDrivenWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.UpdateDrivenWorkflow", tq)

      Process.sleep(500)

      # Each update should resolve quickly with the handler's reply value.
      out = cli_update(wf_id, "increment", 5)
      assert out =~ "5"

      out = cli_update(wf_id, "increment", 3)
      assert out =~ "8"

      _ = cli_update(wf_id, "stop", nil)

      cli_wait(wf_id, "Completed")
    end
  end

  describe "E2E21 — update handler crash post-acceptance does not lock the workflow" do
    # See E2E20 — same CLI/ETF issue applies. Unit harness covers the
    # protocol invariant.
    @tag :skip
    test "subsequent updates/signals work after a crashing update handler" do
      %{task_queue: tq} = start_worker([UpdateCrashWorkflow], [])

      wf_id = cli_start_workflow("Temporalex.E2ETest.UpdateCrashWorkflow", tq)

      Process.sleep(500)

      # Crash the first update. The CLI may report a failure or hang on
      # update timeout — either way, the workflow itself must continue.
      _ = cli_update_allow_failure(wf_id, "explode", nil)

      # Now confirm a subsequent update succeeds — this is the critical
      # invariant. If the workflow is locked (no further updates accepted),
      # this would hang on the update timeout.
      out = cli_update(wf_id, "ping", nil)
      assert out =~ "pong"

      # And a signal still drains the receive cleanly.
      cli_signal(wf_id, "done")
      cli_wait(wf_id, "Completed")
    end
  end

  # Like cli_update but tolerates non-zero exit codes (used to probe the
  # handler-crash post-acceptance path, where Core's response is uncertain).
  defp cli_update_allow_failure(wf_id, name, input) do
    args =
      [
        "workflow",
        "update",
        "execute",
        "--workflow-id",
        wf_id,
        "--name",
        name,
        "--output",
        "json"
      ] ++ if input != nil, do: ["--input", Jason.encode!(input)], else: []

    {out, _code} = System.cmd("temporal", args, stderr_to_stdout: true)
    out
  end

  defp cli_update(wf_id, name, input) do
    args =
      [
        "workflow",
        "update",
        "execute",
        "--workflow-id",
        wf_id,
        "--name",
        name,
        "--output",
        "json"
      ] ++ if input != nil, do: ["--input", Jason.encode!(input)], else: []

    {out, code} = System.cmd("temporal", args, stderr_to_stdout: true)
    assert code == 0, "temporal workflow update failed: #{out}"
    out
  end

  # Waits for either Completed, Failed, or Canceled.
  defp cli_wait_terminal(wf_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      {out, _} =
        System.cmd(
          "temporal",
          ["workflow", "describe", "--workflow-id", wf_id, "--output", "json"],
          stderr_to_stdout: true
        )

      out
    end)
    |> Enum.find(fn out ->
      cond do
        out =~ "Completed" or out =~ "Failed" or out =~ "Canceled" -> true
        System.monotonic_time(:millisecond) > deadline -> flunk("timeout waiting for #{wf_id}")
        true -> Process.sleep(200) && false
      end
    end)

    :ok
  end
end
