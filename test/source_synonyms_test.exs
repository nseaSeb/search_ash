defmodule SearchAsh.SourceSynonymsTest do
  @moduledoc """
  Query-time synonym expansion on the per-resource `:search` action
  (`search do synonyms … end`), against real Postgres. `Article` maps, in French,
  `bl → bon de livraison` and `cde → commande` (inline form); `SynonymMfaArticle` carries
  the `{module, function}` form for the `Info` resolution tests.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Info
  alias SearchAsh.Test.{Article, Domain, Repo, SynonymMfaArticle}

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_articles", [])
    :ok
  end

  defp create(attrs, tenant), do: Domain.create_article!(attrs, tenant: tenant)
  defp search(query, tenant), do: Domain.search_articles!(query, :fr, tenant: tenant)
  defp titles(results), do: results |> Enum.map(& &1.title) |> Enum.sort()

  describe "expansion at query time" do
    test "an abbreviation reaches the words it stands for" do
      create(%{title: "Bon de livraison Dupont", body: "x", language: :fr}, "a")
      create(%{title: "Marteau", body: "y", language: :fr}, "a")

      assert titles(search("bl", "a")) == ["Bon de livraison Dupont"]
    end

    test "a single-token synonym works too" do
      create(%{title: "Commande spéciale", body: "x", language: :fr}, "a")

      assert titles(search("cde", "a")) == ["Commande spéciale"]
    end

    test "a multi-word synonym is an AND-group: half the phrase does not match" do
      create(%{title: "Bon marché", body: "x", language: :fr}, "a")
      create(%{title: "Bon de livraison Dupont", body: "x", language: :fr}, "a")

      assert titles(search("bl", "a")) == ["Bon de livraison Dupont"]
    end

    test "the abbreviation still combines with an ordinary term (AND across the group)" do
      create(%{title: "Bon de livraison Dupont", body: "x", language: :fr}, "a")
      create(%{title: "Bon de livraison Martin", body: "x", language: :fr}, "a")

      assert titles(search("bl dupont", "a")) == ["Bon de livraison Dupont"]
    end

    test "an unmapped query is unaffected, and a mapped word still matches literally" do
      create(%{title: "Bon de livraison Dupont", body: "x", language: :fr}, "a")

      assert search("xyz", "a") == []
      assert titles(search("livraison", "a")) == ["Bon de livraison Dupont"]
    end
  end

  describe "Info.synonyms/2 resolves both DSL forms" do
    test "inline per-language map" do
      assert Info.synonyms(Article, :fr) == %{
               "bl" => ["bon de livraison"],
               "cde" => ["commande"]
             }
    end

    test "inline map with no entry for the language yields %{}" do
      assert Info.synonyms(Article, :en) == %{}
    end

    test "{module, function} form is called with the language" do
      assert Info.synonyms(SynonymMfaArticle, :fr) == %{"bl" => ["bon de livraison"]}
    end

    test "{module, function} returning no entry for the language yields %{}" do
      assert Info.synonyms(SynonymMfaArticle, :en_porter) == %{}
    end
  end
end
