defmodule Temporalex.RuntimeTest do
  use ExUnit.Case, async: true

  # P2-8: create_runtime() returns {:ok, runtime_resource}
  test "create_runtime returns a resource reference" do
    assert {:ok, runtime} = Temporalex.Native.create_runtime()
    assert is_reference(runtime)
  end

  # P2-9: Runtime GenServer starts, holds resource, Runtime.get() returns it
  test "Runtime.get() returns {:ok, resource}" do
    assert {:ok, runtime} = Temporalex.Runtime.get()
    assert is_reference(runtime)
  end

  test "Runtime.get() returns the same resource on repeated calls" do
    {:ok, r1} = Temporalex.Runtime.get()
    {:ok, r2} = Temporalex.Runtime.get()
    assert r1 == r2
  end
end
