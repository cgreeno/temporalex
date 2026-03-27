defmodule Temporalex.ClientTest do
  @moduledoc """
  Unit tests for Client API edge cases and argument handling.
  """
  use ExUnit.Case, async: true

  alias Temporalex.Client

  describe "start_workflow argument validation" do
    test "raises when keyword list is passed as args without opts" do
      assert_raise ArgumentError, ~r/keyword list as args/, fn ->
        Client.start_workflow(:conn, SomeModule, id: "wf-1", task_queue: "q")
      end
    end
  end

  describe "resolve_connection" do
    test "returns error tuple for dead PID instead of crashing" do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      assert {:error, {:connection_error, :not_alive}} =
               Client.signal_workflow(dead_pid, "wf-1", "sig")
    end

    test "returns error tuple for unregistered atom name" do
      assert {:error, {:connection_error, :not_alive}} =
               Client.signal_workflow(:totally_nonexistent_process, "wf-1", "sig")
    end
  end
end
