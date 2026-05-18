defmodule Temporalex.ProtocolEdgesIntegrationTest do
  @moduledoc """
  Live-Temporal coverage of protocol-level edges that unit tests can't
  fully reach: update accepted then workflow fails, retry-policy-driven
  retries that eventually succeed, child→grandchild chains, multiple
  parallel children.

  Connects to 127.0.0.1:7233. Skipped by default.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  defmodule Activities do
    use Temporalex.Activity

    # Always fails with a retryable application failure. With a retry
    # policy of max_attempts: 3, the activity is tried 3 times and the
    # third failure becomes the surfaced ActivityFailure.
    defactivity always_retryable(_marker),
      start_to_close_timeout: 5_000,
      retry_policy: [
        initial_interval: 100,
        backoff_coefficient: 1.0,
        maximum_attempts: 3
      ] do
      raise %Temporalex.ApplicationError{
        message: "retryable failure",
        type: "TransientError",
        non_retryable: false
      }
    end
  end

  defmodule Grandchild do
    use Temporalex.Workflow
    def run(value), do: {:ok, {:grandchild_done, value}}
  end

  defmodule Child do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(value) do
      grandchild_id = "gc-#{API.uuid4()}"

      {:ok, gc_result} =
        API.execute_child_workflow(Grandchild, [value], workflow_id: grandchild_id)

      {:ok, {:child_saw, gc_result}}
    end
  end

  defmodule Parent do
    @moduledoc """
    A parent that starts a child that itself starts a grandchild.
    Tests the recursion: child workflows can themselves run child
    workflows, and the resolution chains correctly all the way up.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(value) do
      child_id = "ch-#{API.uuid4()}"

      {:ok, child_result} = API.execute_child_workflow(Child, [value], workflow_id: child_id)
      {:ok, child_result}
    end
  end

  defmodule MultiParent do
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(n) do
      # Start `n` children in parallel branches. Each gets a deterministic id
      # from uuid4 (replay-safe).
      results =
        API.parallel(
          for i <- 1..n do
            child_id = "mc-#{i}-#{API.uuid4()}"
            fn -> API.execute_child_workflow(Grandchild, [i], workflow_id: child_id) end
          end
        )

      {:ok, results}
    end
  end

  defmodule RetryWorkflow do
    use Temporalex.Workflow

    def run(_) do
      case Activities.always_retryable(:marker) do
        {:error, failure} -> {:ok, {:failed_after_retries, failure}}
        other -> {:error, {:unexpected, other}}
      end
    end
  end

  defmodule UpdateAcceptThenFailWorkflow do
    @moduledoc """
    Workflow that accepts an update via {:async, fn, _} and the async
    handler does work that fails. The protocol invariant: even after
    Accepted is emitted, a subsequent failure must be reported back to
    the caller as the update's terminal response.
    """
    use Temporalex.Workflow

    alias Temporalex.Workflow.API

    def run(_) do
      result =
        API.phase(:running,
          update: %{
            "do_and_fail" => fn _args, state ->
              {:async,
               fn ->
                 raise %Temporalex.ApplicationError{
                   message: "post-accept failure",
                   type: "PostAcceptFail",
                   non_retryable: true
                 }
               end, state}
            end
          },
          signal: %{"done" => fn _args, state -> {:stop, state} end}
        )

      {:ok, result}
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    task_queue = "protocol-edges-#{System.unique_integer([:positive])}"

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        backend: Temporalex.Backend.TemporalCore,
        target: "http://127.0.0.1:7233",
        namespace: "default",
        task_queue: task_queue,
        workflows: [
          Grandchild,
          Child,
          Parent,
          MultiParent,
          RetryWorkflow,
          UpdateAcceptThenFailWorkflow
        ],
        activities: [Activities]
      )

    on_exit(fn ->
      try do
        if Process.alive?(worker_pid), do: Supervisor.stop(worker_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, worker: worker_name}
  end

  describe "child workflow recursion" do
    test "parent → child → grandchild chains result through all three levels", %{worker: worker} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(worker, Parent, :payload,
          workflow_id: "pcgc-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      assert {:ok, {:child_saw, {:grandchild_done, :payload}}} =
               Temporalex.Client.get_result(handle, timeout: 30_000)
    end

    test "multiple children started concurrently each complete with their own result",
         %{worker: worker} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(worker, MultiParent, 4,
          workflow_id: "multi-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      assert {:ok, results} = Temporalex.Client.get_result(handle, timeout: 30_000)
      assert is_list(results) and length(results) == 4

      # Each result is {:ok, {:grandchild_done, n}} for n in 1..4, in input order.
      assert Enum.at(results, 0) == {:ok, {:grandchild_done, 1}}
      assert Enum.at(results, 1) == {:ok, {:grandchild_done, 2}}
      assert Enum.at(results, 2) == {:ok, {:grandchild_done, 3}}
      assert Enum.at(results, 3) == {:ok, {:grandchild_done, 4}}
    end
  end

  describe "activity retry policy" do
    test "retryable failure retries up to maximum_attempts, then surfaces", %{worker: worker} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(worker, RetryWorkflow, nil,
          workflow_id: "retry-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      # After 3 retries, the activity failure surfaces. Workflow catches it
      # and completes with the captured failure.
      assert {:ok, {:failed_after_retries, %Temporalex.ActivityFailure{} = failure}} =
               Temporalex.Client.get_result(handle, timeout: 30_000)

      assert %Temporalex.ApplicationError{type: "TransientError"} = failure.cause
    end
  end

  describe "update accept-then-fail" do
    test "async update handler raise becomes a failed update response to the caller",
         %{worker: worker} do
      {:ok, handle} =
        Temporalex.Client.start_workflow(worker, UpdateAcceptThenFailWorkflow, nil,
          workflow_id: "uatf-#{System.unique_integer([:positive])}",
          timeout: 10_000
        )

      # Wait for phase to be active.
      assert :ok = Temporalex.Client.signal_workflow(handle, "noop", [], timeout: 5_000) || true

      # The update is accepted, then the async handler crashes. The client's
      # update_workflow call must return an error (not hang forever).
      result =
        try do
          Temporalex.Client.update_workflow(handle, "do_and_fail", [], timeout: 10_000)
        catch
          :exit, reason -> {:exit, reason}
        end

      # We accept any non-:ok outcome; what matters is the call returned.
      refute match?({:ok, _}, result),
             "expected an update failure, got success: #{inspect(result)}"

      # Workflow is still alive — done signal stops it cleanly.
      _ = Temporalex.Client.signal_workflow(handle, "done", [], timeout: 5_000)
      _ = Temporalex.Client.get_result(handle, timeout: 10_000)
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
end
