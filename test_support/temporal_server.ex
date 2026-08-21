defmodule Temporalex.TestSupport.Server do
  @moduledoc false

  # Where the shared dev server is. Overridable, because server VERSION is
  # load-bearing for some tests and a long-lived local container drifts behind
  # what CI runs: `:priority` is recorded by server 1.31.2 and silently dropped
  # by 1.27.4. Rather than making everyone rebuild their local server,
  #
  #     temporal server start-dev --port 7333 --headless
  #     TEMPORAL_ADDRESS=127.0.0.1:7333 mix test --include external
  #
  # runs the suite against a current server. CI needs no override: it starts
  # `temporal server start-dev` on the default port.
  #
  # Every shared-server test reads this, including the `temporal` CLI calls a
  # few of them make — a half-swept suite is worse than none, because the
  # per-run namespace lands on one server while the clients talk to another.
  # The four own-server tests are exempt by design: they start their own dev
  # server on a free port and pass that target explicitly.

  @default "127.0.0.1:7233"

  @doc "host:port of the shared dev server."
  def address, do: System.get_env("TEMPORAL_ADDRESS", @default)

  @doc "The same thing as a client `:target` URL."
  def target, do: "http://" <> address()

  @doc "Host half of the address, for a raw connectivity probe."
  def host, do: address() |> String.split(":", parts: 2) |> hd()

  @doc "Port half of the address, for a raw connectivity probe."
  def port, do: address() |> String.split(":", parts: 2) |> List.last() |> String.to_integer()

  @doc "Args placing a `temporal` CLI call on the same server."
  def cli_address_args, do: ["--address", address()]

  @doc "Whether anything is listening, so a test can fail with a clear reason."
  def reachable? do
    case :gen_tcp.connect(String.to_charlist(host()), port(), [:binary], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
