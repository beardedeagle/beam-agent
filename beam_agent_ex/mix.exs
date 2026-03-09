defmodule BeamAgentEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/beardedeagle/beam-agent"

  def project do
    [
      app: :beam_agent_ex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: "Canonical Elixir wrapper for the consolidated beam_agent SDK",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:beam_agent, path: ".."},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "BeamAgent",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
