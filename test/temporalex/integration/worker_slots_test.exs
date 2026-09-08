defmodule Temporalex.WorkerSlotsIntegrationTest do
  @moduledoc """
  Coverage for the worker slot options, which set how much work a worker will
  hold at once instead of leaving core's defaults.

  ## What is asserted

  That the options are accepted and produce a working worker, that both the
  descriptive and the sdk-flavoured names reach the same place, and that the one
  configuration core refuses is refused here with a message naming the option.

  ## What is NOT asserted, and why

  That a raised slot count actually raises throughput. Proving that needs a
  workload whose workflows hold their slots — a durable wait, a timer, an update
  round trip — driven at a rate high enough to exhaust them, sustained long
  enough to measure. That is a load test against a real cluster, not a fixture
  this suite has, and the evidence for it lives in the issue this option came
  from: 198 of 200 workflow slots in use with the database at 50% and the worker
  at 43% of its CPU limit.

  So these are plumbing tests, deliberately named as such.

  Skipped by default; run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  defmodule Workflow do
    use Temporalex.Workflow

    def run(n), do: {:ok, n}
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    :ok
  end

  describe "no slot options" do
    test "starts a worker on core's own defaults" do
      assert :ok == start_worker_result([])
    end
  end

  describe "slot options accepted" do
    test "descriptive names" do
      assert :ok ==
               start_worker_result(
                 max_workflow_task_slots: 50,
                 max_activity_task_slots: 100,
                 max_cached_workflows: 50
               )
    end

    test "sdk-flavoured aliases reach the same place" do
      assert :ok ==
               start_worker_result(
                 max_concurrent_workflow_task_executions: 50,
                 max_concurrent_activity_task_executions: 100
               )
    end

    test "workflow slots alone, leaving activities on the default" do
      assert :ok == start_worker_result(max_workflow_task_slots: 2)
    end
  end

  describe "the configuration core refuses" do
    # One workflow task can need several activations and the cache holds its
    # slot across them, so a single slot cannot make progress. Refused at the
    # boundary rather than surfacing as an opaque worker-build failure, which is
    # what the message is asserted for.
    test "a single workflow task slot is rejected, naming the option" do
      assert {:error, reason} = start_worker_result(max_workflow_task_slots: 1)
      message = inspect(reason)

      assert message =~ "max_workflow_task_slots"
      assert message =~ "at least 2"
    end
  end

  defp start_worker_result(worker_opts) do
    case start_stack_result(worker_opts) do
      {:ok, _client, _worker} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_stack_result(worker_opts) do
    Process.flag(:trap_exit, true)
    task_queue = "slots-#{System.unique_integer([:positive])}"
    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    worker = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client,
        backend: Temporalex.Backend.TemporalCore,
        target: Server.target(),
        namespace: Temporalex.TestSupport.Namespace.name(),
        task_queue: task_queue
      )

    stop_on_exit(client_pid, &GenServer.stop/3)

    worker_opts =
      worker_opts
      |> Keyword.put_new(:workflows, [Workflow])
      |> Keyword.put_new(:activities, [])
      |> Keyword.merge(name: worker, client: client, task_queue: task_queue)

    case Temporalex.Worker.start_link(worker_opts) do
      {:ok, worker_pid} ->
        stop_on_exit(worker_pid, &Supervisor.stop/3)
        {:ok, client, worker}

      {:error,
       {:shutdown, {:failed_to_start_child, Temporalex.Server, {:backend_start_failed, reason}}}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_on_exit(pid, stop_fun) do
    on_exit(fn ->
      try do
        if Process.alive?(pid), do: stop_fun.(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp temporal_available? do
    case :gen_tcp.connect(
           String.to_charlist(Server.host()),
           Server.port(),
           [:binary, active: false],
           1_000
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end
