defmodule SearchAsh.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/nseaSeb/search_ash"

  def project do
    [
      app: :search_ash,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description:
        "Ash extension for multilingual full-text search: a `search do … end` DSL that " <>
          "auto-generates the tsvector index, keeps a stemmed column in sync, and exposes " <>
          "a tenant-aware, ranked `search` action. Built on search_core.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      search_core_dep(),
      {:ash, "~> 3.29"},
      {:ash_postgres, "~> 2.10"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:sourceror, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  # Inside the monorepo the sibling source is what we want to build against — a change to
  # search_core should be visible here before it is published. Set SEARCH_ASH_LOCAL_CORE=1
  # for that; the published package always resolves through Hex.
  defp search_core_dep do
    if System.get_env("SEARCH_ASH_LOCAL_CORE") in ~w(1 true) do
      {:search_core, path: "../search_core", override: true}
    else
      {:search_core, "~> 0.2"}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "LICENSE", ".formatter.exs", "CHANGELOG.md"]
    ]
  end

  defp docs do
    [
      main: "SearchAsh",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
