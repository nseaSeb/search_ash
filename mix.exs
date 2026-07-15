defmodule SearchAsh.MixProject do
  use Mix.Project

  def project do
    [
      app: :search_ash,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description:
        "Ash extension for multilingual full-text search: a `search do … end` DSL that " <>
          "auto-generates the tsvector index, keeps a stemmed column in sync, and exposes " <>
          "a tenant-aware `search` filter. Built on search_core + the stemmers NIF.",
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:search_core, path: "../search_core"},
      {:ash, "~> 3.29"},
      {:ash_postgres, "~> 2.10"}
    ]
  end
end
