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
      dialyzer: [
        flags: [:error_handling, :underspecs, :unmatched_returns]
      ],
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "BeamAgent",
      source_url: @source_url,
      extras: [
        "README.md",
        "../docs/guides/backend_integration_guide.md",
        "LICENSE"
      ],
      groups_for_modules: [
        "Public API": [
          BeamAgent,
          BeamAgent.Capabilities,
          BeamAgent.Catalog,
          BeamAgent.Checkpoint,
          BeamAgent.Command,
          BeamAgent.Content,
          BeamAgent.Control,
          BeamAgent.Hooks,
          BeamAgent.MCP,
          BeamAgent.Raw,
          BeamAgent.Runtime,
          BeamAgent.SessionStore,
          BeamAgent.Telemetry,
          BeamAgent.Threads,
          BeamAgent.Todo
        ],
        "Backend Wrappers": [
          ClaudeEx,
          ClaudeEx.Session,
          CodexEx,
          CodexEx.Session,
          CopilotEx,
          CopilotEx.Session,
          GeminiEx,
          GeminiEx.Session,
          OpencodeEx,
          OpencodeEx.Session
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
