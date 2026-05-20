defmodule Temporalex.MixProject do
  use Mix.Project

  @version "0.3.2"
  @source_url "https://github.com/cgreeno/temporalex"

  def project do
    [
      app: :temporalex,
      version: @version,
      elixir: "~> 1.17",
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
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.37", runtime: false},
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
        native/temporalex_nif/src
        native/temporalex_nif/Cargo.toml
        native/temporalex_nif/Cargo.lock
        .formatter.exs
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
        docs
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        "docs/sdk_overview.md": [title: "SDK Overview"],
        "docs/programming_model.md": [title: "Programming Model"],
        "docs/implementation_principles.md": [title: "Implementation Principles"],
        "docs/scheduler_and_replay.md": [title: "Scheduler and Replay"]
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
          Temporalex.Worker,
          Temporalex.Server
        ],
        Backend: [
          Temporalex.Backend,
          Temporalex.Backend.Test,
          Temporalex.Backend.TemporalCore
        ],
        Core: [
          Temporalex.Core.Executor
        ]
      ],
      filter_modules: fn mod, _meta ->
        not String.starts_with?(inspect(mod), "Temporalex.Native")
      end
    ]
  end
end
