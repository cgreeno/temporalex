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
      name = :"conn_ok_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Temporalex.Connection.start_link(
          name: name,
          address: "http://localhost:7233",
          connect: false
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts https address" do
      name = :"conn_https_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Temporalex.Connection.start_link(
          name: name,
          address: "https://my-ns.tmprl.cloud:7233",
          connect: false
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "get/1 when not connected" do
    test "returns not_connected when runtime is nil" do
      name = :"conn_notconn_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Temporalex.Connection.start_link(
          name: name,
          address: "http://localhost:7233",
          connect: false
        )

      assert {:error, :not_connected} = Temporalex.Connection.get(name)
      GenServer.stop(pid)
    end
  end

  describe "defaults" do
    test "address defaults to localhost:7233" do
      name = :"conn_defaults_#{System.unique_integer([:positive])}"
      {:ok, pid} = Temporalex.Connection.start_link(name: name, connect: false)
      assert Process.alive?(pid)

      state = :sys.get_state(name)
      assert state.address == "http://localhost:7233"
      assert state.namespace == "default"
      GenServer.stop(pid)
    end
  end
end
