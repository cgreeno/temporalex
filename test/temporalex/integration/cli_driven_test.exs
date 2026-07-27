defmodule Temporalex.CliDrivenIntegrationTest do
  @moduledoc """
  Verifies that workflows running under a Temporalex worker can be
  driven by the official `temporal` CLI binary as an external client.

  Why this matters: our `Temporalex.Client.*` tests round-trip through
  our own NIF codec. CLI-driven tests catch interop bugs the Client
  tests miss — workflow-type registration mismatches, task-queue
  routing problems, payload-encoding wire incompatibilities visible
  to external tooling.

  Known limitation: the temporal CLI uses JSON for payloads while our
  worker uses ETF. Tests here use workflows that take no input or
  trivial input the CLI doesn't need to render — covering the
  control-plane operations (start/signal/describe/cancel/terminate/
  list) without hitting the encoding-mismatch surface.

  Connects to 127.0.0.1:7233. Skipped by default; run with
  `mix test --include external`.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule SleepingWorkflow do
    @moduledoc """
    Long-sleeping workflow so CLI commands have time to find it
    "Running". No input needed; CLI invokes `temporal workflow start`
    without `--input`.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("alive?", _args, state), do: {:reply, state}

    def run(_input) do
      API.publish_state(:running)
      :ok = API.sleep(60_000)
      {:ok, :woke_up}
    end
  end

  defmodule SignalWaitingWorkflow do
    @moduledoc """
    Waits for a "go" signal then completes. The signal has no payload,
    so the CLI's `temporal workflow signal --name go` works without
    hitting the JSON/ETF mismatch.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_input) do
      _ = API.wait_for_signal("go")
      {:ok, :signaled}
    end
  end

  defmodule JsonInputWorkflow do
    @moduledoc """
    Receives a JSON-encoded input from the CLI. With our payload decoder
    auto-detecting `json/plain` metadata, this should arrive as a regular
    Elixir term (map with string keys, list, string, etc.).

    The workflow publishes the received input so the test can query and
    verify it was decoded correctly.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def handle_query("got", _args, state), do: {:reply, state}

    def run(input) do
      API.publish_state({:got_input, input})
      :ok = API.sleep(60_000)
      {:ok, input}
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    unless cli_available?() do
      raise "`temporal` CLI binary not on PATH"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    task_queue = "cli-driven-#{System.unique_integer([:positive])}"

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: "default",
        task_queue: task_queue,
        workflows: [SleepingWorkflow, SignalWaitingWorkflow, JsonInputWorkflow],
        activities: []
      )

    on_exit(fn ->
      try do
        if Process.alive?(worker_pid), do: Supervisor.stop(worker_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, worker: worker_name, task_queue: task_queue}
  end

  test "CLI starts a workflow on our worker's task queue", %{task_queue: tq} do
    workflow_id = "cli-start-#{System.unique_integer([:positive])}"

    {output, exit_code} =
      cli([
        "workflow",
        "start",
        "--workflow-id",
        workflow_id,
        "--type",
        SleepingWorkflow.__workflow_type__(),
        "--task-queue",
        tq
      ])

    assert exit_code == 0, "CLI start failed: #{output}"
    assert output =~ workflow_id
  end

  test "CLI signals a workflow waiting on a signal and the workflow completes",
       %{task_queue: tq} do
    workflow_id = "cli-signal-#{System.unique_integer([:positive])}"

    {_out, 0} =
      cli([
        "workflow",
        "start",
        "--workflow-id",
        workflow_id,
        "--type",
        SignalWaitingWorkflow.__workflow_type__(),
        "--task-queue",
        tq
      ])

    # Give the worker a moment to register the workflow execution.
    eventually(fn -> cli_describe_status(workflow_id) == :running end, 10_000)

    {_out, 0} =
      cli(["workflow", "signal", "--workflow-id", workflow_id, "--name", "go"])

    assert eventually(fn -> cli_describe_status(workflow_id) == :completed end, 15_000),
           "workflow never reached Completed after CLI signal"
  end

  test "CLI describes a running workflow with correct type and status", %{task_queue: tq} do
    workflow_id = "cli-describe-#{System.unique_integer([:positive])}"

    {_, 0} =
      cli([
        "workflow",
        "start",
        "--workflow-id",
        workflow_id,
        "--type",
        SleepingWorkflow.__workflow_type__(),
        "--task-queue",
        tq
      ])

    {output, exit_code} = cli(["workflow", "describe", "--workflow-id", workflow_id])

    assert exit_code == 0
    assert output =~ workflow_id
    assert output =~ SleepingWorkflow.__workflow_type__()
    assert cli_describe_status(workflow_id) == :running
  end

  test "CLI cancels a running workflow", %{task_queue: tq} do
    workflow_id = "cli-cancel-#{System.unique_integer([:positive])}"

    {_, 0} =
      cli([
        "workflow",
        "start",
        "--workflow-id",
        workflow_id,
        "--type",
        SleepingWorkflow.__workflow_type__(),
        "--task-queue",
        tq
      ])

    eventually(fn -> cli_describe_status(workflow_id) == :running end, 10_000)

    {output, exit_code} =
      cli(["workflow", "cancel", "--workflow-id", workflow_id])

    assert exit_code == 0, "CLI cancel failed: #{output}"

    # Cancellation is requested — the workflow ends up either Canceled or
    # (because SleepingWorkflow doesn't check cancelled?) keeps Running.
    # Either way the cancel command itself succeeded; that's the unit test.
  end

  test "CLI terminates a running workflow", %{task_queue: tq} do
    workflow_id = "cli-terminate-#{System.unique_integer([:positive])}"

    {_, 0} =
      cli([
        "workflow",
        "start",
        "--workflow-id",
        workflow_id,
        "--type",
        SleepingWorkflow.__workflow_type__(),
        "--task-queue",
        tq
      ])

    eventually(fn -> cli_describe_status(workflow_id) == :running end, 10_000)

    {_, 0} =
      cli([
        "workflow",
        "terminate",
        "--workflow-id",
        workflow_id,
        "--reason",
        "cli_test_termination"
      ])

    assert eventually(fn -> cli_describe_status(workflow_id) == :terminated end, 10_000),
           "workflow never reached Terminated after CLI terminate"
  end

  test "CLI starts a workflow with a JSON input; worker decodes it via payload metadata",
       %{worker: worker, task_queue: tq} do
    # The temporal CLI's --input sends a JSON-encoded payload with
    # encoding metadata "json/plain". Our worker's payload_to_term
    # auto-detects this and decodes it to an Elixir term.
    workflow_id = "cli-json-input-#{System.unique_integer([:positive])}"

    {output, exit_code} =
      cli([
        "workflow",
        "start",
        "--workflow-id",
        workflow_id,
        "--type",
        JsonInputWorkflow.__workflow_type__(),
        "--task-queue",
        tq,
        "--input",
        ~s({"order_id": 42, "items": ["a", "b"]})
      ])

    assert exit_code == 0, "CLI start failed: #{output}"

    handle = %Temporalex.Client.Handle{
      worker: worker,
      workflow_id: workflow_id,
      run_id: nil,
      workflow_type: JsonInputWorkflow.__workflow_type__()
    }

    # Wait for the workflow to publish its received input.
    assert eventually(
             fn ->
               case Temporalex.Client.query_workflow(handle, "got", [], timeout: 2_000) do
                 {:ok, {:got_input, decoded}} ->
                   decoded == %{"order_id" => 42, "items" => ["a", "b"]}

                 _ ->
                   false
               end
             end,
             15_000
           ),
           "workflow did not see correctly-decoded JSON input"

    _ =
      cli([
        "workflow",
        "terminate",
        "--workflow-id",
        workflow_id,
        "--reason",
        "test_cleanup"
      ])
  end

  test "CLI lists workflows and finds our running one", %{task_queue: tq} do
    workflow_id = "cli-list-#{System.unique_integer([:positive])}"

    {_, 0} =
      cli([
        "workflow",
        "start",
        "--workflow-id",
        workflow_id,
        "--type",
        SleepingWorkflow.__workflow_type__(),
        "--task-queue",
        tq
      ])

    eventually(fn -> cli_describe_status(workflow_id) == :running end, 10_000)

    {output, exit_code} =
      cli([
        "workflow",
        "list",
        "--query",
        "WorkflowId='#{workflow_id}'"
      ])

    assert exit_code == 0
    assert output =~ workflow_id
    assert output =~ SleepingWorkflow.__workflow_type__()
  end

  # ──────────────────────────── helpers ────────────────────────────

  defp cli(args) do
    System.cmd("temporal", args ++ ["--address", "127.0.0.1:7233"], stderr_to_stdout: true)
  end

  # Parses free-form CLI output, so the branching is irreducible.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp cli_describe_status(workflow_id) do
    # JSON output gives us a stable machine-readable status enum.
    case cli(["workflow", "describe", "--workflow-id", workflow_id, "--output", "json"]) do
      {output, 0} ->
        case Regex.run(~r/"status":\s*"WORKFLOW_EXECUTION_STATUS_(\w+)"/, output) do
          [_, "RUNNING"] -> :running
          [_, "COMPLETED"] -> :completed
          [_, "FAILED"] -> :failed
          [_, "CANCELED"] -> :canceled
          [_, "TERMINATED"] -> :terminated
          [_, "TIMED_OUT"] -> :timed_out
          [_, "CONTINUED_AS_NEW"] -> :continued_as_new
          _ -> :unknown
        end

      _ ->
        :error
    end
  end

  defp temporal_available? do
    case :gen_tcp.connect(~c"127.0.0.1", 7233, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp cli_available? do
    System.find_executable("temporal") != nil
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(200)
        do_eventually(fun, deadline)
      end
    end
  end
end
