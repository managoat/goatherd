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
  defp escript do
    [main_module: Goatherd.CLI, name: "goatherd", app: nil]
  end

  defp deps do
    [
      {:managoat_sandbox, "~> 0.2"},
      {:managoat_runtimes, "~> 0.2"},
      {:managoat_acp, "~> 0.1"},
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
