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
# boolean — and both run the external suite. :priority_effect counts too: it
# is excluded from the external suite (see below) but still talks to a real
# server, so it needs a namespace of its own just the same.
server_tags = [:external, :priority_effect]

needs_server? =
  ExUnit.configuration()[:include]
  |> List.wrap()
  |> Enum.any?(fn
    tag when is_atom(tag) -> tag in server_tags
    {tag, _} -> tag in server_tags
    _ -> false
  end)

if needs_server?, do: Temporalex.TestSupport.Namespace.setup!()

# :priority_effect is excluded on top of :external because it fails on every
# server we can currently run against — the dev server accepts priority and
# ignores it. It is the demonstration the feature owes, kept runnable with
# `--include priority_effect` for the day a server enforces it. The canary in
# test/temporalex/integration/priority_test.exs is what tells us that day came.
ExUnit.start(exclude: [external: true, priority_effect: true])
