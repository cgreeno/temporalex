defmodule Temporalex.WorkerVersioningIntegrationTest do
  @moduledoc """
  Coverage for the `:versioning` worker option, which selects the worker's
  versioning strategy instead of leaving it hardcoded to `None`.

  ## What is asserted

  That each strategy is accepted and produces a working worker, and that the
  configurations which cannot mean anything are rejected with a clear error.

  ## What is NOT asserted, and why

  That pinned or auto-upgrade routing is *respected* — that a pinned workflow
  stays on its version while a newer one is Current. Two reasons:

    * The dev server this suite runs against has the API switched off
      (`temporal worker deployment list` → "Deployments are disabled on this
      namespace", server 1.27.4). Enabling it needs dynamic config.
    * Proving routing needs two workers on different build ids running
      concurrently plus `set-current-version` between assertions, which is a
      fixture class this suite does not have.

  `WorkflowExecutionDescription` also does not expose `versioning_info`, so even
  with deployments enabled the assertion would have to go through the CLI.

  So the accepted-strategy tests below are plumbing tests, deliberately named as
  such. Routing coverage is tracked separately.

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

  describe "strategy None (no :versioning option)" do
    test "omitting :versioning leaves behaviour unchanged" do
      {client, _worker} = start_stack([])
      assert {:ok, 7} = run_workflow(client)
    end

    test "a bare :build_id still works and only identifies" do
      {client, _worker} = start_stack([], build_id: "release-abc123")
      assert {:ok, 7} = run_workflow(client)
    end
  end

  # Plumbing only: these prove the option is accepted and reaches
  # WorkerDeploymentOptions, not that routing honours it.
  #
  # They assert the worker *starts* rather than running a workflow through it.
  # With deployments disabled server-side a `use_versioning: true` worker starts
  # cleanly but is never given work, so a workflow assertion here would time out
  # for a reason unrelated to this code.
  describe "deployment-based strategy is accepted (plumbing)" do
    test ":pinned" do
      assert {:ok, _client, _worker} =
               start_stack_result([],
                 versioning: [
                   deployment_name: "bookings-worker",
                   build_id: "release-abc123",
                   use_versioning: true,
                   default_behavior: :pinned
                 ]
               )
    end

    test ":auto_upgrade" do
      assert {:ok, _client, _worker} =
               start_stack_result([],
                 versioning: [
                   deployment_name: "notifications-worker",
                   build_id: "release-abc123",
                   use_versioning: true,
                   default_behavior: :auto_upgrade
                 ]
               )
    end

    test "registering a deployment without opting into versioning" do
      {client, _worker} =
        start_stack([],
          versioning: [deployment_name: "bookings-worker", build_id: "release-abc123"]
        )

      assert {:ok, 7} = run_workflow(client)
    end

    test ":build_id is inherited from the top-level option" do
      assert {:ok, _client, _worker} =
               start_stack_result([],
                 build_id: "release-inherited",
                 versioning: [
                   deployment_name: "bookings-worker",
                   use_versioning: true,
                   default_behavior: :pinned
                 ]
               )
    end
  end

  describe "configurations that cannot mean anything are rejected" do
    # Neither core nor the server rejects this: every workflow task would report
    # an unspecified behavior, and the server records the execution as
    # unversioned while clearing the deployment version. Versioning would be on
    # and provably doing nothing.
    test "use_versioning without default_behavior" do
      assert {:error, error} =
               start_worker_result(
                 versioning: [
                   deployment_name: "bookings-worker",
                   build_id: "release-abc123",
                   use_versioning: true
                 ]
               )

      assert Exception.message(error) =~
               "default_behavior is required when use_versioning is true"
    end

    test ":unspecified is not an accepted behaviour" do
      assert {:error, error} =
               start_worker_result(
                 versioning: [deployment_name: "bookings-worker", default_behavior: :unspecified]
               )

      assert Exception.message(error) =~ "must be :pinned or :auto_upgrade"
    end

    test "an unknown behaviour is rejected" do
      assert {:error, error} =
               start_worker_result(
                 versioning: [deployment_name: "bookings-worker", default_behavior: :sideways]
               )

      assert Exception.message(error) =~ "must be :pinned or :auto_upgrade"
    end
  end

  defp run_workflow(client) do
    {:ok, handle} =
      Temporalex.Client.start_workflow(client, Workflow, 7,
        workflow_id: "versioning-#{System.unique_integer([:positive])}",
        timeout: 10_000
      )

    Temporalex.Client.get_result(handle, timeout: 10_000)
  end

  defp start_stack(client_opts, worker_opts \\ []) do
    case start_stack_result(client_opts, worker_opts) do
      {:ok, client, worker} -> {client, worker}
      other -> flunk("expected the stack to start, got: #{inspect(other)}")
    end
  end

  # Returns {:error, reason} when the worker rejects its versioning config.
  defp start_worker_result(worker_opts) do
    case start_stack_result([], worker_opts) do
      {:ok, _client, _worker} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_stack_result(client_opts, worker_opts) do
    Process.flag(:trap_exit, true)
    task_queue = "versioning-#{System.unique_integer([:positive])}"
    client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")
    worker = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        Keyword.merge(client_opts,
          name: client,
          backend: Temporalex.Backend.TemporalCore,
          target: Server.target(),
          namespace: Temporalex.TestSupport.Namespace.name(),
          task_queue: task_queue
        )
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

      _ ->
        false
    end
  end
end
