defmodule SearchAsh.MixProject do
  use Mix.Project

  @version "0.4.1"
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
      test_coverage: test_coverage(),
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
      {:sourceror, "~> 1.0", only: [:dev, :test], runtime: false},
      # Ash policies need a SAT solver; simple_sat is pure Elixir, fitting for a NIF-free stack.
      {:simple_sat, "~> 0.1", only: :test}
    ]
  end

  # Inside the monorepo the sibling source is what we want to build against — a change to
  # search_core should be visible here before it is published. Set SEARCH_ASH_LOCAL_CORE=1
  # for that; the published package always resolves through Hex.
  defp search_core_dep do
    if System.get_env("SEARCH_ASH_LOCAL_CORE") in ~w(1 true) do
      {:search_core, path: "../search_core", override: true}
    else
      {:search_core, "~> 0.3"}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE",
        ".formatter.exs",
        "CHANGELOG.md",
        "documentation"
      ]
    ]
  end

  # Cover only traces modules loaded at *test* time, which shapes what this number can
  # honestly say:
  #
  #   * Ignored below: derived `Inspect` impls, the test fixtures themselves, and the
  #     structs Spark generates for DSL options and entity targets. None of it is code
  #     this project wrote or could test.
  #   * NOT ignored, though they report 0%: the DSL transformers. They run at *compile*
  #     time, when every fixture resource is built — so they are exercised by the whole
  #     suite, just not measurably. (The per-resource ones score higher only because
  #     `verify_language_test.exs` compiles resources inside test bodies.) Hiding them
  #     would overstate the number; leaving them in understates it. The honest reading is
  #     that runtime modules sit in the 90s.
  defp test_coverage do
    [
      # NB: the threshold lives under `:summary`, not at the top level — Mix reads it with
      # `get_threshold(summary_opts)`, so a bare `threshold:` here is silently ignored and
      # you get the 90% default.
      summary: [threshold: 70],
      ignore_modules: [
        ~r/^Inspect\./,
        ~r/^SearchAsh\.Test\./,
        ~r/\.Options$/,
        ~r/^SearchAsh\.Source\.Searchable\./
      ]
    ]
  end

  defp docs do
    [
      main: "SearchAsh",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "documentation/tour.livemd",
        "documentation/global-search.md",
        "documentation/architecture.md",
        "documentation/upgrading-0.4.md",
        "documentation/roadmap.md"
      ],
      # Render ```mermaid fences on HexDocs (GitHub renders them natively).
      before_closing_body_tag: fn
        :html ->
          """
          <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
          <script>
            document.addEventListener("DOMContentLoaded", function () {
              mermaid.initialize({
                startOnLoad: false,
                theme: document.body.className.includes("dark") ? "dark" : "default"
              });
              let id = 0;
              for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
                const preEl = codeEl.parentElement;
                const graphDefinition = codeEl.textContent;
                const graphEl = document.createElement("div");
                const graphId = "mermaid-graph-" + id++;
                mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
                  graphEl.innerHTML = svg;
                  bindFunctions?.(graphEl);
                  preEl.insertAdjacentElement("afterend", graphEl);
                  preEl.remove();
                });
              }
            });
          </script>
          """

        _ ->
          ""
      end
    ]
  end
end
