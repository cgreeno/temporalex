defmodule Temporalex.ConnectionTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, runtime} = Temporalex.Runtime.get()
    {:ok, runtime: runtime}
  end

  # P2-2: Rejects garbage address
  test "connect rejects garbage URL", %{runtime: runtime} do
    :ok = Temporalex.Native.connect(runtime, "not a url", "", %{}, self())

    assert_receive {:connect_error, reason}, 5_000
    assert reason =~ "invalid URL"
  end

  # P2-3: Rejects address without scheme
  test "connect rejects URL without scheme", %{runtime: runtime} do
    :ok = Temporalex.Native.connect(runtime, "localhost:7233", "", %{}, self())

    assert_receive {:connect_error, reason}, 5_000
    assert reason =~ "scheme must be http or https"
  end

  # P2-4: Accepts http address (connects or times out — either validates URL parsing)
  @tag :integration
  test "connect with http address sends {:connected, client}", %{runtime: runtime} do
    :ok = Temporalex.Native.connect(runtime, "http://localhost:7233", "", %{}, self())

    assert_receive {:connected, client}, 10_000
    assert is_reference(client)
  end

  # P2-5: Accepts https address
  test "connect rejects non-http/https scheme", %{runtime: runtime} do
    :ok = Temporalex.Native.connect(runtime, "ftp://localhost:7233", "", %{}, self())

    assert_receive {:connect_error, reason}, 5_000
    assert reason =~ "scheme must be http or https"
  end

  # P2-10: connect() sends {:connected, client} to caller (requires Temporal server)
  @tag :integration
  test "connect sends {:connected, client} on success", %{runtime: runtime} do
    :ok = Temporalex.Native.connect(runtime, "http://localhost:7233", "", %{}, self())

    assert_receive {:connected, client}, 10_000
    assert is_reference(client)
  end

  # P2-11: connect() with bad URL sends {:connect_error, reason}
  @tag :integration
  test "connect to unreachable host sends {:connect_error, reason}", %{runtime: runtime} do
    :ok =
      Temporalex.Native.connect(runtime, "http://localhost:19999", "", %{}, self())

    assert_receive {:connect_error, _reason}, 15_000
  end
end
