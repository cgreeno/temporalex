defmodule Temporalex.SupervisorTest do
  use ExUnit.Case, async: true

  describe "Temporalex as Supervisor" do
    test "connection_name/1 derives correct module name" do
      assert Temporalex.connection_name(MyApp.Temporal) == MyApp.Temporal.Connection
      assert Temporalex.connection_name(Foo) == Foo.Connection
    end

    test "init/1 builds correct child specs" do
      opts = [
        name: MyApp.Temporal,
        address: "http://localhost:7233",
        namespace: "test-ns",
        task_queue: "my-queue",
        workflows: [{"ProcessOrder", &Function.identity/1}],
        activities: [SomeActivity],
        max_concurrent_workflow_tasks: 10
      ]

      {:ok, {sup_flags, children}} = Temporalex.init(opts)

      assert sup_flags.strategy == :rest_for_one
      assert length(children) == 2

      [conn_spec, server_spec] = children

      # Connection child
      assert conn_spec.id == Temporalex.Connection

      assert conn_spec.start ==
               {Temporalex.Connection, :start_link,
                [
                  [
                    name: MyApp.Temporal.Connection,
                    address: "http://localhost:7233",
                    namespace: "test-ns"
                  ]
                ]}

      # Server child — extract opts from start tuple
      assert server_spec.id == {Temporalex.Server, "my-queue"}
      {Temporalex.Server, :start_link, [server_opts]} = server_spec.start
      assert Keyword.fetch!(server_opts, :connection) == MyApp.Temporal.Connection
      assert Keyword.fetch!(server_opts, :task_queue) == "my-queue"
      assert Keyword.fetch!(server_opts, :workflows) == [{"ProcessOrder", &Function.identity/1}]
      assert Keyword.fetch!(server_opts, :activities) == [SomeActivity]
      assert Keyword.fetch!(server_opts, :max_concurrent_workflow_tasks) == 10
    end

    test "init/1 uses defaults for optional fields" do
      opts = [name: MyApp.Temporal, task_queue: "q"]

      {:ok, {_sup_flags, [conn_spec, server_spec]}} = Temporalex.init(opts)

      {Temporalex.Connection, :start_link, [conn_opts]} = conn_spec.start
      assert Keyword.fetch!(conn_opts, :address) == "http://localhost:7233"
      assert Keyword.fetch!(conn_opts, :namespace) == "default"

      {Temporalex.Server, :start_link, [server_opts]} = server_spec.start
      assert Keyword.fetch!(server_opts, :workflows) == []
      assert Keyword.fetch!(server_opts, :activities) == []
    end

    test "init/1 raises when task_queue is missing" do
      assert_raise ArgumentError, ~r/task_queue/, fn ->
        Temporalex.init(name: MyApp.Temporal)
      end
    end

    test "start_link raises when name is missing" do
      assert_raise ArgumentError, ~r/name/, fn ->
        Temporalex.start_link(task_queue: "q")
      end
    end
  end
end
