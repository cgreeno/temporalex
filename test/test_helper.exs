Code.require_file("../test_support/temporal_dev_server.ex", __DIR__)

# The external suite is not isolated: it shares one Temporal dev server, and
# several tests declare a FIXED task queue (`use Temporalex.Workflow,
# queue: "surface-greet"` and friends). Those cannot be made unique per run —
# `use` options are evaluated at compile time, so two runs of one build share
# the string, and RFC 0002's one-source rule deliberately forbids overriding a
# declared queue at the worker. Two concurrent runs therefore poll the same
# queue on the same server, and Temporal delivers each task to whichever
# worker asks first: run A's workflow gets executed by run B's worker, which
# surfaces as a failure that does not reproduce.
#
# So external runs are serialised. The lock is a listening socket rather than
# a lock file because the OS releases it when the process dies — there is no
# stale lock to clean up after a crash or a Ctrl-C.
#
# Proper isolation (a namespace per run, which would scope the queues) is
# tracked separately; this only has to make interference impossible.
external_lock_port = 47_233

if :external in List.wrap(ExUnit.configuration()[:include]) do
  case :gen_tcp.listen(external_lock_port, [:binary, active: false]) do
    {:ok, _socket} ->
      # Owned by this process, which lives for the whole run, so it is
      # released automatically when the run ends.
      :ok

    {:error, :eaddrinuse} ->
      IO.puts(:stderr, """

      Another external test run is already in progress (lock: TCP port \
      #{external_lock_port}).

      The external suite shares one Temporal dev server and several tests use
      fixed task queues, so two runs steal each other's workflow tasks and
      produce failures that do not reproduce. Wait for the other run to
      finish, or run `mix test` without `--include external`.

      If you are certain no other run is active, something is holding port \
      #{external_lock_port}: `lsof -i :#{external_lock_port}`.
      """)

      System.halt(1)

    {:error, reason} ->
      IO.puts(
        :stderr,
        "could not acquire the external-test lock on port " <>
          "#{external_lock_port}: #{inspect(reason)}"
      )

      System.halt(1)
  end
end

ExUnit.start(exclude: [external: true])
