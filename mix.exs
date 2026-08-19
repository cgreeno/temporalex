defmodule Temporalex.MixProject do
  use Mix.Project

  @version "0.5.3"
  @source_url "https://github.com/cgreeno/temporalex"

  def project do
    [
      app: :temporalex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "_build/plts",
        plt_local_path: "_build/plts"
      ],

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

  def cli do
    [preferred_envs: [credo: :test]]
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
      {:jason, "~> 1.4"},
      {:pb, "~> 0.1.0"},
      {:rustler, "~> 0.37", runtime: false, optional: true},
      {:rustler_precompiled, "~> 0.8"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
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
        native/temporalex_nif/Cross.toml
        priv/proto
        .formatter.exs
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
        docs
        checksum-*.exs
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
