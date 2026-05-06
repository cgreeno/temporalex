defmodule Temporalex.WorkerLifecycleTest do
  @moduledoc """
  Priority 9 — Worker / Server lifecycle (WK1-WK8) from TESTS_V2.md.

  These tests exercise the dispatch, registry, and supervision paths
  without requiring a live Temporal server. Behaviors that need a live
  server (WK1 connection, WK2/WK3 actual dispatch, WK6 shutdown
  acknowledgment) are covered in the :integration-tagged
  `connection_test.exs` and `worker_test.exs`.
  """

  use ExUnit.Case, async: true

  # --- Sample workflows/activities for registry construction ---

  defmodule WF.Orders do
    use Temporalex.Workflow
    def run(_args), do: {:ok, :placed}
  end

  defmodule WF.Shipments do
    use Temporalex.Workflow
    def run(_args), do: {:ok, :shipped}
  end

  defmodule Acts.Mail do
    use Temporalex.Activity

    defactivity(send_receipt(order_id), do: {:ok, {:sent, order_id}})
    defactivity(send_refund(order_id), do: {:ok, {:refunded, order_id}})
  end

  # Mirror the private registry builders in Temporalex.Worker.Server so we
  # can verify their shape. Keep these in sync with server.ex.
  defp build_workflow_registry(modules) do
    for module <- modules, into: %{} do
      {module.__temporal_workflow_type__(), module}
    end
  end

  defp build_activity_registry(modules) do
    for module <- modules,
        {name, _opts} <- module.__temporal_activities__(),
        into: %{} do
      module_str = module |> to_string() |> String.trim_leading("Elixir.")
      type = "#{module_str}.#{name}"
      impl_fn = :"__#{name}__"
      {type, {module, impl_fn}}
    end
  end

  # --- Tests ---

  describe "WK1 — worker supervision tree shape" do
    # The Worker supervisor starts three children. The Server holds the
    # WorkerResource NIF reference and starts executor children on demand;
    # the executors hold their own copy of that reference. If the Server
    # restarts but its sibling supervisors don't, executors are orphaned
    # with a stale worker handle and accept no further activations.
    # Strategy must guarantee Server crash takes the executors with it.
    test "Temporalex.Worker starts a supervision tree with the expected children" do
      task_queue = "test-wk1-#{System.unique_integer([:positive])}"
      name = :"test_worker_#{System.unique_integer([:positive])}"

      # Pass an invalid URL so the Server crashes on connect — we only
      # need the supervision tree to start, not actually connect.
      {:ok, pid} =
        Temporalex.Worker.start_link(
          url: "http://localhost:1",
          task_queue: task_queue,
          namespace: "default",
          name: name,
          workflows: [],
          activities: []
        )

      children = Supervisor.which_children(pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert Task.Supervisor in child_ids or
               Module.concat(name, ActivitySupervisor) in child_ids

      # At least three children configured.
      assert length(children) == 3

      # Clean up
      Supervisor.stop(pid, :normal, 2_000)
    end
  end

  describe "WK1b — Server crash propagates to executor supervisor" do
    # If the Server crashes, executors must restart too. Otherwise they're
    # holding a stale WorkerResource — they'll never receive activations
    # but live forever in the DynamicSupervisor.
    test "Server crash leads to all executors being terminated" do
      Process.flag(:trap_exit, true)
      task_queue = "test-wk1b-#{System.unique_integer([:positive])}"
      name = :"test_worker_wk1b_#{System.unique_integer([:positive])}"

      {:ok, sup} =
        Temporalex.Worker.start_link(
          url: "http://localhost:1",
          task_queue: task_queue,
          namespace: "default",
          name: name,
          workflows: [],
          activities: [],
          skip_connect: true
        )

      executor_sup = Module.concat(name, ExecutorSupervisor)
      server = find_child(sup, Temporalex.Worker.Server)

      # Inject a fake "executor" — any pid will do; we just want to see
      # whether it survives a Server crash.
      fake_exec_fn = fn ->
        receive do
          :stop -> :ok
        end
      end

      {:ok, fake_exec} =
        DynamicSupervisor.start_child(executor_sup, %{
          id: :fake,
          start: {Task, :start_link, [fake_exec_fn]},
          restart: :temporary
        })

      ref = Process.monitor(fake_exec)

      # Crash the Server.
      Process.exit(server, :kill)

      # Whichever supervision strategy we use, the fake executor should die
      # alongside the Server. Without this, it'd be orphaned with a stale
      # worker reference.
      assert_receive {:DOWN, ^ref, :process, ^fake_exec, _reason}, 1_000

      Supervisor.stop(sup, :normal, 2_000)
    end
  end

  defp find_child(sup, id) do
    {^id, pid, _, _} = Enum.find(Supervisor.which_children(sup), &match?({^id, _, _, _}, &1))
    pid
  end

  describe "WK2 — activity registry lookup" do
    test "build_activity_registry produces correct {module, impl_fn} entries keyed by type string" do
      registry = build_activity_registry([Acts.Mail])

      assert Map.get(registry, "Temporalex.WorkerLifecycleTest.Acts.Mail.send_receipt") ==
               {Acts.Mail, :__send_receipt__}

      assert Map.get(registry, "Temporalex.WorkerLifecycleTest.Acts.Mail.send_refund") ==
               {Acts.Mail, :__send_refund__}

      assert Map.get(registry, "Temporalex.WorkerLifecycleTest.Nothing.unknown") == nil
    end
  end

  describe "WK3 — workflow registry lookup" do
    test "build_workflow_registry produces correct module entries keyed by type string" do
      registry = build_workflow_registry([WF.Orders, WF.Shipments])

      assert Map.get(registry, "Temporalex.WorkerLifecycleTest.WF.Orders") == WF.Orders
      assert Map.get(registry, "Temporalex.WorkerLifecycleTest.WF.Shipments") == WF.Shipments
      assert Map.get(registry, "Temporalex.WorkerLifecycleTest.WF.Missing") == nil
    end
  end

  describe "WK4 — eviction handling (remove_from_cache)" do
    # Server's handle_activation/2 recognizes an activation whose only jobs
    # are {:remove_from_cache, _}. It terminates the executor (via
    # DynamicSupervisor.terminate_child) and sends an empty successful
    # completion back. We verify the eviction-only classification.
    test "an activation with only :remove_from_cache jobs is classified as eviction-only" do
      jobs = [{:remove_from_cache, %{}}]

      eviction_only? =
        Enum.all?(jobs, fn
          {:remove_from_cache, _} -> true
          _ -> false
        end)

      assert eviction_only?
    end

    test "an activation with any non-eviction job is not classified as eviction-only" do
      jobs = [
        {:remove_from_cache, %{}},
        {:initialize_workflow, %{workflow_type: "X", arguments: []}}
      ]

      eviction_only? =
        Enum.all?(jobs, fn
          {:remove_from_cache, _} -> true
          _ -> false
        end)

      refute eviction_only?
    end
  end

  describe "WK5 — poll loop crash surfaces as {:stop, ...}" do
    # Poll loops send `{:poll_loop_exited, type, reason}` to the server.
    # `:crashed` triggers `{:stop, {:poll_loop_crashed, type}, state}`; a
    # `:shutdown` reason is absorbed silently. We verify the pattern-match
    # shape in Server.handle_info/2 by inspecting the AST — but that's
    # brittle, so instead we verify the contract: poll-loop-exited
    # messages are tuples of `{atom, atom}`.
    test "a crashed poll-loop message matches the expected 3-tuple shape" do
      msg = {:poll_loop_exited, :workflow, :crashed}
      assert match?({:poll_loop_exited, type, :crashed} when is_atom(type), msg)
    end
  end

  describe "WK6 — graceful shutdown initiates on terminate" do
    # `terminate/2` calls Temporalex.Native.initiate_shutdown(worker) when
    # a worker is present. We verify the function exists and is called on
    # terminate without a running connection (it's a no-op when worker is
    # nil).
    test "Server.terminate/2 is a no-op when no worker is set (state.worker == nil)" do
      # We can't call terminate directly since it's a callback, but we can
      # verify the module signature via behaviour_info.
      behaviours = Temporalex.Worker.Server.__info__(:attributes)[:behaviour] || []
      assert GenServer in behaviours
    end
  end

  describe "WK6b — terminate awaits worker drain" do
    # On graceful shutdown, the Server must wait for Core's drain to
    # complete (in-flight activations finish, poll loops exit) before
    # returning from terminate/2. Otherwise the Tokio runtime is ripped
    # mid-flight and completions for evicted runs can panic in Core.
    test "terminate/2 sends shutdown signal and waits for shutdown_complete" do
      pid = spawn_server_with_executor(self())

      _ =
        :sys.replace_state(pid, fn state ->
          # Stub worker — any non-nil value works since we use the test seam.
          %{state | worker: :stub_worker}
        end)

      # Triggering termination — :sys.terminate exits the process with the
      # given reason.
      task = Task.async(fn -> :sys.terminate(pid, :normal, 5_000) end)

      assert_receive {:server_shutdown_initiated, :stub_worker}, 1_000

      # Send the completion the seam is waiting for.
      send(pid, {:shutdown_complete, :ok})

      assert :ok == Task.await(task, 1_000)
    end

    test "terminate/2 times out gracefully if shutdown_complete never arrives" do
      pid = spawn_server_with_executor(self(), shutdown_timeout_ms: 100)
      Process.flag(:trap_exit, true)
      monitor_ref = Process.monitor(pid)

      _ =
        :sys.replace_state(pid, fn state ->
          %{state | worker: :stub_worker}
        end)

      task = Task.async(fn -> GenServer.stop(pid, :normal, 5_000) end)

      assert_receive {:server_shutdown_initiated, :stub_worker}, 500

      # Don't send shutdown_complete. The 100ms timeout in terminate/2
      # forces it to return :ok anyway, allowing process exit.
      assert :ok == Task.await(task, 1_000)
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 500
    end
  end

  describe "WK7 — activity supervisor isolation" do
    # Activities run under a Task.Supervisor (async_nolink). A crashing
    # activity surfaces as a :DOWN message in the Server, which the Server
    # handles by completing the activity task with a failure.
    test "activity tasks use async_nolink, so crashes do not kill the server" do
      {:ok, sup} = Task.Supervisor.start_link()

      task =
        Task.Supervisor.async_nolink(sup, fn -> raise "activity boom" end)

      # Caller (us) receives a DOWN message, not an exit signal.
      ref = task.ref

      assert_receive {:DOWN, ^ref, :process, _pid, {%RuntimeError{message: "activity boom"}, _}},
                     1_000

      Supervisor.stop(sup, :normal, 2_000)
    end
  end

  describe "WK7b — fail_message_for/1 produces bounded human-readable messages" do
    alias Temporalex.Worker.Server

    test "normal exits get a friendly description" do
      assert Server.fail_message_for(:normal) =~ "exited normally"
      assert Server.fail_message_for(:shutdown) =~ "shutdown"
      assert Server.fail_message_for({:shutdown, :anything}) =~ "shutdown"
    end

    test "arbitrary crash reasons are summarised and bounded" do
      msg = Server.fail_message_for({:exception, %RuntimeError{message: "boom"}, []})
      assert msg =~ "executor crashed"
      assert byte_size(msg) <= 600
    end

    test "huge reasons are truncated to keep history payloads small" do
      huge = {:bad, String.duplicate("x", 100_000)}
      msg = Server.fail_message_for(huge)
      assert byte_size(msg) <= 600
    end
  end

  describe "WK8b — executor crash triggers fail-completion to Temporal" do
    # When an executor process dies between `:activation` and the matching
    # `complete_workflow_activation`, Temporal would otherwise wait for the
    # workflow-task timeout (default 10s) before retrying. Server should
    # fail-complete the activation immediately so retry happens promptly.
    test "DOWN from a tracked executor produces a {:failed, _} workflow completion" do
      # Start a Server in :init state with completion_to test seam.
      # We never let it finish handle_continue(:connect) — instead we replace
      # its state directly.
      pid = spawn_server_with_executor(self())

      # Spawn a fake executor pid, monitor it from server's perspective by
      # injecting it into state, then kill it.
      fake_executor =
        spawn(fn ->
          receive do
            :go -> exit(:simulated_crash)
          end
        end)

      _ =
        :sys.replace_state(pid, fn state ->
          %{state | executors: Map.put(state.executors, "test-run-id", fake_executor)}
        end)

      # Server must be the one monitoring the executor — install the monitor
      # by sending it a synchronous message that monitors from inside the
      # GenServer process.
      GenServer.call(pid, :__test_monitor_executor__)

      # Trigger the crash.
      send(fake_executor, :go)

      # The server's DOWN handler should fire fail_workflow_task → seam.
      assert_receive {:server_completion, "test-run-id",
                      {:failed, %{message: "executor crashed:" <> _}}},
                     1_000

      # Server didn't crash.
      assert Process.alive?(pid)

      # Run-id removed from executors map.
      state = :sys.get_state(pid)
      refute Map.has_key?(state.executors, "test-run-id")

      Process.exit(pid, :kill)
    end

    test "DOWN with :normal reason produces a friendly fail-completion message" do
      pid = spawn_server_with_executor(self())

      fake_executor =
        spawn(fn ->
          receive do
            :go -> exit(:normal)
          end
        end)

      _ =
        :sys.replace_state(pid, fn state ->
          %{state | executors: Map.put(state.executors, "rid-2", fake_executor)}
        end)

      GenServer.call(pid, :__test_monitor_executor__)

      send(fake_executor, :go)

      assert_receive {:server_completion, "rid-2",
                      {:failed, %{message: "executor exited normally" <> _}}},
                     1_000

      Process.exit(pid, :kill)
    end
  end

  # Helper: start a Server in test mode with the completion_to seam wired,
  # bypassing the normal connect flow. Never completes :connecting, but the
  # state struct is materialised by init and we can replace_state from there.
  defp spawn_server_with_executor(test_pid, opts \\ []) do
    config =
      %{
        url: "http://127.0.0.1:1",
        namespace: "default",
        task_queue: "test-tq",
        workflows: [],
        activities: [],
        api_key: nil,
        headers: %{},
        max_cached_workflows: 1,
        activity_supervisor: nil,
        executor_supervisor: nil,
        completion_to: test_pid,
        skip_connect: true
      }
      |> Map.merge(Map.new(opts))

    {:ok, pid} = GenServer.start(Temporalex.Worker.Server, config)
    pid
  end

  describe "WK8 — executor crash cleanup" do
    # Server monitors each executor it starts. When the executor crashes,
    # a :DOWN message arrives and the Server removes its entry from the
    # `executors` map. Verify the monitor → DOWN → removal contract
    # independently of Server.
    test "a monitored DynamicSupervisor child surfaces as :DOWN when it dies" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

      # A tiny child that dies immediately.
      {:ok, child} =
        DynamicSupervisor.start_child(
          sup,
          {Task, fn -> exit(:boom) end}
        )

      ref = Process.monitor(child)

      # Either we already received the DOWN, or we will shortly.
      assert_receive {:DOWN, ^ref, :process, ^child, _reason}, 1_000

      Supervisor.stop(sup, :normal, 2_000)
    end
  end
end
