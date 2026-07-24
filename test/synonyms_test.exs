defmodule SearchAsh.SynonymsTest do
  @moduledoc """
  Query-time synonym expansion on `:global_search` (`global_index do synonyms … end`),
  against real Postgres. The `SearchDocument` index maps, in French, `bl → bon de livraison`
  and `cde → commande` (inline form); `SynonymMfaDocument` carries the `{module, function}`
  form for the `Info` resolution tests.
  """
  use ExUnit.Case, async: false

  alias SearchAsh.GlobalIndex.Info
  alias SearchAsh.Test.{Domain, FuzzyDocument, Repo, SearchDocument, SynonymMfaDocument}

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_products, test_search_documents", [])
    :ok
  end

  defp create(attrs, tenant), do: Domain.create_product!(attrs, tenant: tenant)
  defp gsearch(query, tenant), do: Domain.global_search!(query, :fr, tenant: tenant)
  defp labels(results), do: results |> Enum.map(& &1.label) |> Enum.sort()

  describe "expansion at query time" do
    test "an abbreviation reaches the words it stands for" do
      create(%{name: "Bon de livraison Dupont", sku: "X1"}, "a")
      create(%{name: "Marteau", sku: "M1"}, "a")

      # `bl` is not a stored token anywhere; only the synonym `bon de livraison` reaches it.
      assert labels(gsearch("bl", "a")) == ["Bon de livraison Dupont"]
    end

    test "a single-token synonym works too" do
      create(%{name: "Commande spéciale", sku: "C1"}, "a")

      assert labels(gsearch("cde", "a")) == ["Commande spéciale"]
    end

    test "a multi-word synonym is an AND-group: half the phrase does not match" do
      # `bl` expands to `(bl | (bon & livraison))`. A row with `bon` but not `livraison`
      # must not come back — this is the precedence the parentheses exist to enforce.
      create(%{name: "Bon marché", sku: "B1"}, "a")
      create(%{name: "Bon de livraison Dupont", sku: "X1"}, "a")

      assert labels(gsearch("bl", "a")) == ["Bon de livraison Dupont"]
    end

    test "the abbreviation still combines with an ordinary term (AND across the group)" do
      create(%{name: "Bon de livraison Dupont", sku: "X1"}, "a")
      create(%{name: "Bon de livraison Martin", sku: "X2"}, "a")

      # `bl dupont` -> `(bl | (bon & livraison)) & dupont`: only the Dupont row qualifies.
      assert labels(gsearch("bl dupont", "a")) == ["Bon de livraison Dupont"]
    end

    test "an unmapped query is unaffected, and a mapped word still matches literally" do
      create(%{name: "Bon de livraison Dupont", sku: "X1"}, "a")

      assert gsearch("xyz", "a") == []
      assert labels(gsearch("livraison", "a")) == ["Bon de livraison Dupont"]
    end
  end

  describe "Info.synonyms/2 resolves both DSL forms" do
    test "inline per-language map" do
      assert Info.synonyms(SearchDocument, :fr) == %{
               "bl" => ["bon de livraison"],
               "cde" => ["commande"]
             }
    end

    test "inline map with no entry for the language yields %{}" do
      assert Info.synonyms(SearchDocument, :en) == %{}
    end

    test "{module, function} form is called with the language" do
      assert Info.synonyms(SynonymMfaDocument, :fr) == %{"bl" => ["bon de livraison"]}
    end

    test "{module, function} returning no entry for the language yields %{}" do
      assert Info.synonyms(SynonymMfaDocument, :en_porter) == %{}
    end

    test "an index with no synonyms configured yields %{}" do
      assert Info.synonyms(FuzzyDocument, :fr) == %{}
    end
  end
end
