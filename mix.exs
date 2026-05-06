defmodule Temporalex.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/cgreeno/temporalex"

  def project do
    [
      app: :temporalex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # Hex
      description:
        "Workflow orchestration for Elixir, built on the Temporal Core SDK (Rust) via Rustler NIFs.",
      package: package(),

      # Docs
      name: "Temporalex",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      mod: {Temporalex, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.37", runtime: false},
      {:protobuf, "~> 0.13"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(
        lib
        native/temporalex_native/src
        native/temporalex_native/Cargo.toml
        native/temporalex_native/Cargo.lock
        .formatter.exs
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
        docs/architecture.md
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "docs/architecture.md": [title: "Architecture"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_modules: [
        "Public API": [
          Temporalex,
          Temporalex.Workflow,
          Temporalex.Workflow.API,
          Temporalex.Activity,
          Temporalex.Activity.Context,
          Temporalex.Client
        ],
        Worker: [
          Temporalex.Worker
        ],
        Errors: [
          Temporalex.ActivityFailure,
          Temporalex.ApplicationError,
          Temporalex.CancelledError,
          Temporalex.ChildWorkflowFailure,
          Temporalex.NondeterminismError,
          Temporalex.TimeoutError
        ],
        Testing: [
          Temporalex.Testing
        ],
        Internal: [
          Temporalex.Converter,
          Temporalex.Runtime,
          Temporalex.Worker.Server,
          Temporalex.Worker.Executor,
          Temporalex.Worker.Replay,
          Temporalex.Testing.Executor
        ]
      ],
      filter_modules: fn mod, _meta ->
        # Hide the Native NIF surface — users should never call it directly.
        not String.starts_with?(inspect(mod), "Temporalex.Native")
      end
    ]
  end
end
