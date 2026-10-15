defmodule Goatherd.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/managoat/goatherd"

  def project do
    [
      app: :goatherd,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      escript: escript(),
      description:
        "Run coding agents in remote sandboxes from your terminal. No server, no account.",
      source_url: @source_url,
      test_coverage: [summary: [threshold: 70]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]]
  end

  # A single binary is the whole product: `mix escript.build` produces
  # `goatherd`, which needs an Erlang runtime on PATH and nothing else.
  # Applications are NOT started by an escript, and `config/runtime.exs` never
  # runs in one — `Goatherd.CLI.main/1` does both jobs explicitly.
  # The fakes the vendored libraries' tests run against (an in-memory sandbox,
  # a scripted ACP agent, a fake runtime) compile for tests only, so they stay
  # out of the binary.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp escript do
    [main_module: Goatherd.CLI, name: "goatherd", app: nil]
  end

  defp deps do
    [
      # Managoat.Sandbox, Managoat.Runtimes and Managoat.ACP live in
      # lib/managoat/, vendored from their archived repositories (see NOTICE).
      # The Sprites SDK behind Managoat.Sandbox.Sprites is pinned exactly:
      # 0.2.2 changed a contract in a patch release (a stream that closes
      # without an exit frame became `{:error, _, :closed_before_exit}` where
      # 0.2.0 synthesised `{:exit, _, 0}`), and Managoat.Sandbox depends on it.
      {:sprites, "0.2.2"},
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.3", only: :test},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
