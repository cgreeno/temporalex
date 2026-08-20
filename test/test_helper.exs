Code.require_file("../test_support/temporal_server.ex", __DIR__)
Code.require_file("../test_support/temporal_dev_server.ex", __DIR__)
Code.require_file("../test_support/temporal_namespace.ex", __DIR__)

# External tests share one Temporal dev server, and several declare a FIXED
# task queue that cannot be made unique per run (`use` options are compile
# time, and RFC 0002's one-source rule forbids a worker overriding a declared
# queue). Two runs in one namespace therefore poll the same queue, and
# Temporal delivers each task to whichever worker asks first — one run
# executes the other's workflows, which surfaces as a failure that does not
# reproduce.
#
# Task queues are namespace-scoped, so each run takes its own namespace and
# identical queue names never meet. Concurrent runs are then safe rather than
# forbidden.
# Every spelling counts: `--include external` yields the bare atom while
# `--include external:true` yields {:external, "true"} — a string, not a
# boolean — and both run the external suite.
external? =
  ExUnit.configuration()[:include]
  |> List.wrap()
  |> Enum.any?(fn
    :external -> true
    {:external, _} -> true
    _ -> false
  end)

if external?, do: Temporalex.TestSupport.Namespace.setup!()

ExUnit.start(exclude: [external: true])
