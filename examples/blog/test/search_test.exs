defmodule Blog.SearchTest do
  @moduledoc """
  End-to-end regression tests against real Postgres. Locks the behaviours we found by
  hand in the GreenAsh console: multilingual + tenant-scoped search, indexing on
  create, de-indexing on destroy, ranking, and the search-as-you-type edge cases
  (blank query, too-short query, prefix matching).
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Blog.Repo
  alias Blog.Search.Document

  setup do
    for schema <- [Document, Blog.Post, Blog.Sales.Facture, Blog.Sales.Client, Blog.Sales.Produit] do
      Repo.delete_all(schema)
    end

    :ok
  end

  describe "search_ash extension — :search on Post" do
    test "finds a stemmed French match" do
      Blog.Blog.create_post!(
        %{title: "Les chevaux", body: "ils mangent", language: :french},
        tenant: "org_a"
      )

      assert [%{title: "Les chevaux"}] =
               Blog.Blog.search_posts!("chevaux", :french, tenant: "org_a")
    end

    test "tenant isolation — a query only returns the caller's rows" do
      Blog.Blog.create_post!(%{title: "A", body: "cheval", language: :french}, tenant: "org_a")
      Blog.Blog.create_post!(%{title: "B", body: "cheval", language: :french}, tenant: "org_b")

      assert [%{title: "A"}] = Blog.Blog.search_posts!("cheval", :french, tenant: "org_a")
      assert [%{title: "B"}] = Blog.Blog.search_posts!("cheval", :french, tenant: "org_b")
    end

    test "blank query lists all (no crash)" do
      Blog.Blog.create_post!(%{title: "X", body: "y", language: :french}, tenant: "org_a")
      assert length(Blog.Blog.search_posts!("", :french, tenant: "org_a")) == 1
    end

    test "too-short query (< min_length) lists all instead of crashing" do
      Blog.Blog.create_post!(%{title: "X", body: "y", language: :french}, tenant: "org_a")
      assert length(Blog.Blog.search_posts!("b", :french, tenant: "org_a")) == 1
    end

    test "prefix — a partial word matches" do
      Blog.Blog.create_post!(%{title: "Boulangerie", body: "pain", language: :french}, tenant: "org_a")
      assert [%{title: "Boulangerie"}] = Blog.Blog.search_posts!("boulan", :french, tenant: "org_a")
    end

    test "a query in the wrong language does not match" do
      Blog.Blog.create_post!(%{title: "Chevaux", body: "chevaux", language: :french}, tenant: "org_a")
      assert [] = Blog.Blog.search_posts!("running", :english, tenant: "org_a")
    end
  end

  describe "global search — Blog.Search.Document (Option B)" do
    setup do
      Blog.Sales.create_facture!(
        %{numero: "F-001", client_nom: "Ferme des Chevaux",
          description: "Foin pour les chevaux ; un cheval de trait."},
        tenant: "org_a"
      )

      Blog.Sales.create_client!(
        %{nom: "Chevaux & Co", notes: "Éleveur de chevaux."},
        tenant: "org_a"
      )

      Blog.Sales.create_facture!(
        %{numero: "F-002", client_nom: "Boulangerie du coin", description: "Farine et pain."},
        tenant: "org_a"
      )

      Blog.Sales.create_produit!(
        %{reference: "PB-1", libelle: "Chevaux de bois", description: "Jouet."},
        tenant: "org_b"
      )

      :ok
    end

    test "1/ creating an object indexes it" do
      # 3 org_a sources + 1 org_b source were created in setup.
      assert Repo.aggregate(Document, :count) == 4

      assert "F-001" in labels(search("chevaux", "org_a"))
    end

    test "2/ destroying an object removes it from the index" do
      count_before = Repo.aggregate(Document, :count)
      [facture] = Blog.Sales.Facture |> Ash.Query.filter(numero == "F-001") |> Ash.read!(tenant: "org_a")

      Blog.Sales.destroy_facture!(facture, tenant: "org_a")

      assert Repo.aggregate(Document, :count) == count_before - 1
      refute "F-001" in labels(search("chevaux", "org_a"))
    end

    test "results are ranked, most relevant first" do
      results = search("chevaux", "org_a")
      # F-001 mentions cheval/chevaux twice → ranks above the client (once).
      assert hd(results).label == "F-001"
      assert results == Enum.sort_by(results, & &1.rank, :desc)
    end

    test "tenant isolation — look-alike rows never cross tenants" do
      a = search("chevaux", "org_a")
      assert Enum.all?(a, &(&1.org_id == "org_a"))
      refute "Chevaux de bois" in labels(a)

      assert ["Chevaux de bois"] = labels(search("chevaux", "org_b"))
    end

    test "prefix — \"boulan\" finds the Boulangerie facture" do
      assert ["F-002"] = labels(search("boulan", "org_a"))
    end

    test "blank / too-short query lists all (no crash)" do
      assert length(search("", "org_a")) == 3
      assert length(search("b", "org_a")) == 3
    end

    test "every result carries (source_type, source_id) for linking" do
      for d <- search("chevaux", "org_a") do
        assert d.source_type in ["facture", "client", "produit"]
        assert is_binary(d.source_id)
      end
    end
  end

  defp search(query, tenant),
    do: Blog.Search.global_search!(query, :french, tenant: tenant)

  defp labels(results), do: results |> Enum.map(& &1.label) |> Enum.sort()
end
