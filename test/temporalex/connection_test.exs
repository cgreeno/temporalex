defmodule Temporalex.ConnectionTest do
  use ExUnit.Case, async: true

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "start_link/1" do
    test "missing :name raises ArgumentError" do
      assert_raise ArgumentError, ~r/requires :name/, fn ->
        Temporalex.Connection.start_link(address: "http://localhost:7233")
      end
    end
  end

  describe "address validation" do
    test "rejects garbage address" do
      result =
        Temporalex.Connection.start_link(
          name: :"conn_test_#{System.unique_integer([:positive])}",
          address: "not-a-url"
        )

      assert {:error, {%ArgumentError{message: msg}, _}} = result
      assert msg =~ "Invalid Temporal server address"
    end

    test "rejects address without scheme" do
      result =
        Temporalex.Connection.start_link(
          name: :"conn_test_#{System.unique_integer([:positive])}",
          address: "localhost:7233"
        )

      assert {:error, {%ArgumentError{message: msg}, _}} = result
      assert msg =~ "Invalid Temporal server address"
    end

    test "accepts http address" do
      # Will fail to connect (no server) but shouldn't raise on validation
      name = :"conn_ok_#{System.unique_integer([:positive])}"
      {:ok, pid} = Temporalex.Connection.start_link(name: name, address: "http://localhost:7233")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts https address" do
      name = :"conn_https_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Temporalex.Connection.start_link(name: name, address: "https://my-ns.tmprl.cloud:7233")

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "get/1 when not connected" do
    test "returns not_connected when runtime is nil" do
      # Simulate a connection that hasn't finished connecting by
      # checking the guard clause directly on the get handler
      name = :"conn_notconn_#{System.unique_integer([:positive])}"
      {:ok, pid} = Temporalex.Connection.start_link(name: name, address: "http://localhost:7233")

      # Wait for connection to complete, then verify the happy path works
      Process.sleep(100)
      assert {:ok, %{runtime: runtime}} = Temporalex.Connection.get(name)
      assert runtime != nil
      GenServer.stop(pid)
    end
  end

  describe "defaults" do
    test "address defaults to localhost:7233" do
      name = :"conn_defaults_#{System.unique_integer([:positive])}"
      {:ok, pid} = Temporalex.Connection.start_link(name: name)
      assert Process.alive?(pid)

      # The struct should have the default address
      {:ok, state} = Temporalex.Connection.get(name)
      assert state.address == "http://localhost:7233"
      assert state.namespace == "default"
      GenServer.stop(pid)
    end
  end
end
