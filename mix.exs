defmodule Temporalex.MixProject do
  use Mix.Project

  @version "0.2.0-dev"

  def project do
    [
      app: :temporalex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
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
end
