defmodule Blog.MixProject do
  use Mix.Project

  def project do
    [
      app: :blog,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Blog.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:search_ash, path: "../.."},
      {:search_core, path: "../../../search_core"},
      {:ash, "~> 3.29"},
      {:ash_postgres, "~> 2.10"},
      # GreenAsh: a terminal-style admin console over the Ash resources (dev only).
      {:green_ash, "~> 0.1"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:ash_phoenix, "~> 2.0"},
      {:bandit, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ash.reset"]
    ]
  end
end
