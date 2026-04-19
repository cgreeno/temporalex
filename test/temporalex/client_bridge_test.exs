defmodule Temporalex.ClientBridgeTest do
  use ExUnit.Case, async: false

  alias Temporalex.Client

  defmodule DummyWorkflow do
    use Temporalex.Workflow

    def run(_args), do: {:ok, nil}
  end

  defmodule FakeNative do
    def start_workflow(_client, request, pid) do
      request_ref = elem(request, 6)
      send(pid, {:captured_start_request, request})
      send(pid, {:start_workflow_result, request_ref, {:ok, "run-current"}})
      :ok
    end

    def signal_workflow(_client, request, pid) do
      request_ref = elem(request, 6)
      send(pid, {:captured_signal_request, request})
      send(pid, {:signal_workflow_result, request_ref, :ok})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:temporalex, :native_module)
    Application.put_env(:temporalex, :native_module, FakeNative)

    on_exit(fn ->
      if previous do
        Application.put_env(:temporalex, :native_module, previous)
      else
        Application.delete_env(:temporalex, :native_module)
      end
    end)

    :ok
  end

  test "start_workflow ignores stale replies from prior calls" do
    send(self(), {:start_workflow_result, -1, {:ok, "stale-run"}})

    assert {:ok, handle} =
             Client.start_workflow(%{client: :fake, namespace: "default"}, DummyWorkflow, nil,
               id: "wf-1",
               task_queue: "q"
             )

    assert handle.run_id == "run-current"
    assert_received {:captured_start_request, request}
    assert elem(request, 1) == "wf-1"
    assert is_integer(elem(request, 6))
    assert_received {:start_workflow_result, -1, {:ok, "stale-run"}}
  end

  test "signal_workflow ignores stale replies from prior calls" do
    send(self(), {:signal_workflow_result, -1, {:error, "stale failure"}})

    assert :ok =
             Client.signal_workflow(
               %{client: :fake, namespace: "default"},
               "wf-1",
               "poke",
               %{value: 1}
             )

    assert_received {:captured_signal_request, request}
    assert elem(request, 1) == "wf-1"
    assert elem(request, 3) == "poke"
    assert is_integer(elem(request, 6))
    assert_received {:signal_workflow_result, -1, {:error, "stale failure"}}
  end
end
