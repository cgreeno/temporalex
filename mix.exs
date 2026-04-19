defmodule Temporalex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/temporalex/temporalex"

  def project do
    [
      app: :temporalex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      preferred_cli_env: [
        credo: :test,
        dialyzer: :dev,
        docs: :dev
      ],
      dialyzer: [
        plt_add_apps: [:mix],
        plt_core_path: "_build/plts",
        plt_local_path: "_build/plts/project.plt"
      ],

      # Hex
      description:
        "Elixir SDK for Temporal, built on the official Rust Core SDK via Rustler NIFs.",
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
      {:protobuf, "~> 0.13"},
      {:google_protos, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:opentelemetry_api, "~> 1.4", optional: true},
      {:opentelemetry_semantic_conventions, "~> 0.2", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides native/temporalex_native/src native/temporalex_native/Cargo.toml
                 .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        # Introduction
        "README.md": [title: "Overview"],
        "guides/introduction/installation.md": [title: "Installation"],

        # Learning
        "guides/learning/workflows.md": [title: "Workflows"],
        "guides/learning/activities.md": [title: "Activities"],
        "guides/learning/signals_and_queries.md": [title: "Signals & Queries"],
        "guides/learning/timers_and_scheduling.md": [title: "Timers & Scheduling"],
        "guides/learning/child_workflows.md": [title: "Child Workflows"],
        "guides/learning/error_handling.md": [title: "Error Handling"],
        "guides/learning/the_dsl.md": [title: "The DSL"],
        "guides/learning/testing.md": [title: "Testing"],
        "guides/learning/observability.md": [title: "Observability"],
        "guides/learning/configuration.md": [title: "Configuration"],

        # Advanced
        "guides/advanced/production.md": [title: "Going to Production"],

        # Recipes
        "guides/recipes/saga_pattern.md": [title: "Saga Pattern"],
        "guides/recipes/fan_out_fan_in.md": [title: "Fan-Out / Fan-In"],
        "guides/recipes/long_running_with_signals.md": [title: "Long-Running with Signals"],
        "guides/recipes/safe_deployments.md": [title: "Safe Deployments"],

        # Changelog
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Introduction: ~r/README|installation/,
        Learning: ~r/guides\/learning/,
        Advanced: ~r/guides\/advanced/,
        Recipes: ~r/guides\/recipes/,
        Changelog: ~r/CHANGELOG/
      ],
      groups_for_modules: [
        Core: [
          Temporalex,
          Temporalex.Workflow,
          Temporalex.Activity,
          Temporalex.DSL,
          Temporalex.Client
        ],
        Runtime: [
          Temporalex.Server,
          Temporalex.Connection
        ],
        Observability: [
          Temporalex.Telemetry,
          Temporalex.OpenTelemetry
        ],
        Testing: [
          Temporalex.Testing
        ],
        Middleware: [
          Temporalex.Interceptor,
          Temporalex.Codec
        ],
        Data: [
          Temporalex.Converter,
          Temporalex.RetryPolicy,
          Temporalex.WorkflowHandle,
          Temporalex.Workflow.Context,
          Temporalex.Activity.Context,
          Temporalex.Error,
          Temporalex.FailureConverter
        ]
      ],
      nest_modules_by_prefix: [
        Temporalex.Workflow,
        Temporalex.Activity
      ],
      filter_modules: fn mod, _meta ->
        mod_str = inspect(mod)

        not String.contains?(mod_str, ".Proto.") and
          not String.contains?(mod_str, ".Native") and
          not String.contains?(mod_str, "WorkflowTaskExecutor")
      end
    ]
  end
end
