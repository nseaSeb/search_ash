defmodule SearchDemo.SearchTest do
  @moduledoc """
  End-to-end regression tests against real Postgres. Locks the behaviours we found by
  hand in the GreenAsh console: multilingual + tenant-scoped search, indexing on
  create, de-indexing on destroy, ranking, and the search-as-you-type edge cases
  (blank query, too-short query, prefix matching).
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchDemo.Repo
  alias SearchDemo.Search.Document

  setup do
    for schema <- [
          Document,
          SearchDemo.Post,
          SearchDemo.Sales.Facture,
          SearchDemo.Sales.Client,
          SearchDemo.Sales.Produit
        ] do
      Repo.delete_all(schema)
    end

    :ok
  end

  describe "search_ash extension — :search on Post" do
    test "finds a stemmed French match" do
      SearchDemo.Blog.create_post!(
        %{title: "Les chevaux", body: "ils mangent", language: :fr},
        tenant: "org_a"
      )

      assert [%{title: "Les chevaux"}] =
               SearchDemo.Blog.search_posts!("chevaux", :fr, tenant: "org_a")
    end

    test "tenant isolation — a query only returns the caller's rows" do
      SearchDemo.Blog.create_post!(%{title: "A", body: "cheval", language: :fr},
        tenant: "org_a"
      )

      SearchDemo.Blog.create_post!(%{title: "B", body: "cheval", language: :fr},
        tenant: "org_b"
      )

      assert [%{title: "A"}] = SearchDemo.Blog.search_posts!("cheval", :fr, tenant: "org_a")
      assert [%{title: "B"}] = SearchDemo.Blog.search_posts!("cheval", :fr, tenant: "org_b")
    end

    test "blank query lists all (no crash)" do
      SearchDemo.Blog.create_post!(%{title: "X", body: "y", language: :fr}, tenant: "org_a")
      assert length(SearchDemo.Blog.search_posts!("", :fr, tenant: "org_a")) == 1
    end

    test "too-short query (< min_length) lists all instead of crashing" do
      SearchDemo.Blog.create_post!(%{title: "X", body: "y", language: :fr}, tenant: "org_a")
      assert length(SearchDemo.Blog.search_posts!("b", :fr, tenant: "org_a")) == 1
    end

    test "prefix — a partial word matches" do
      SearchDemo.Blog.create_post!(%{title: "Boulangerie", body: "pain", language: :fr},
        tenant: "org_a"
      )

      assert [%{title: "Boulangerie"}] =
               SearchDemo.Blog.search_posts!("boulan", :fr, tenant: "org_a")
    end

    test "a query in the wrong language does not match" do
      SearchDemo.Blog.create_post!(%{title: "Chevaux", body: "chevaux", language: :fr},
        tenant: "org_a"
      )

      assert [] = SearchDemo.Blog.search_posts!("running", :en, tenant: "org_a")
    end
  end

  describe "global search — SearchDemo.Search.Document (Option B)" do
    setup do
      SearchDemo.Sales.create_facture!(
        %{
          numero: "F-001",
          client_nom: "Ferme des Chevaux",
          description: "Foin pour les chevaux ; un cheval de trait."
        },
        tenant: "org_a"
      )

      SearchDemo.Sales.create_client!(
        %{nom: "Chevaux & Co", notes: "Éleveur de chevaux."},
        tenant: "org_a"
      )

      SearchDemo.Sales.create_facture!(
        %{numero: "F-002", client_nom: "Boulangerie du coin", description: "Farine et pain."},
        tenant: "org_a"
      )

      SearchDemo.Sales.create_produit!(
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

      [facture] =
        SearchDemo.Sales.Facture
        |> Ash.Query.filter(numero == "F-001")
        |> Ash.read!(tenant: "org_a")

      SearchDemo.Sales.destroy_facture!(facture, tenant: "org_a")

      assert Repo.aggregate(Document, :count) == count_before - 1
      refute "F-001" in labels(search("chevaux", "org_a"))
    end

    test "results are ranked, most relevant first" do
      results = search("chevaux", "org_a")
      # F-001 mentions cheval/chevaux twice → ranks above the client (once).
      assert hd(results).label == "F-001"
      assert results == Enum.sort_by(results, & &1.search_rank, :desc)
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

  # These tests are about indexing, ranking and tenancy — not roles — so they search as an
  # admin, who finds every entity type. Roles have their own describe block.
  describe "roles — what a user may find" do
    setup do
      SearchDemo.Sales.create_facture!(
        %{numero: "F-100", client_nom: "Dupont", description: "Réparation toiture."},
        tenant: "org_a"
      )

      SearchDemo.Sales.create_client!(%{nom: "Dupont SARL", notes: "Client historique."},
        tenant: "org_a"
      )

      SearchDemo.Sales.create_produit!(%{reference: "P-1", libelle: "Tuile Dupont", description: "Toiture."},
        tenant: "org_a"
      )

      :ok
    end

    defp types(results), do: results |> Enum.map(& &1.source_type) |> Enum.sort() |> Enum.uniq()

    test ":admin finds every entity type" do
      assert types(search("dupont", "org_a", user(:admin, "org_a"))) ==
               ["client", "facture", "produit"]
    end

    test ":commercial finds factures and clients, never produits" do
      assert types(search("dupont", "org_a", user(:commercial, "org_a"))) == ["client", "facture"]
    end

    test ":support finds clients only" do
      results = search("dupont", "org_a", user(:support, "org_a"))

      assert types(results) == ["client"]
      # The facture's label never reaches them — not even to say it exists.
      refute "F-100" in labels(results)
    end

    test "no actor is refused outright: the policies fail closed" do
      # With no actor every clause is statically false, so Ash refuses at strict-check
      # time rather than running a query that filters everything out. With an actor the
      # same expressions become a SQL filter — hence the roles above returning subsets.
      assert_raise Ash.Error.Forbidden, fn ->
        SearchDemo.Search.global_search!("dupont", :fr, tenant: "org_a")
      end
    end

    test "a role narrows the search, it does not replace it" do
      # :commercial may find factures, but still only the ones matching the query.
      assert labels(search("toiture", "org_a", user(:commercial, "org_a"))) == ["F-100"]
      assert search("inexistant", "org_a", user(:commercial, "org_a")) == []
    end

    test "roles compose with tenant isolation, they do not bypass it" do
      SearchDemo.Sales.create_client!(%{nom: "Dupont autre org"}, tenant: "org_b")

      assert labels(search("dupont", "org_b", user(:admin, "org_b"))) == ["Dupont autre org"]
    end
  end

  defp search(query, tenant), do: search(query, tenant, user(:admin, tenant))

  defp search(query, tenant, actor),
    do: SearchDemo.Search.global_search!(query, :fr, tenant: tenant, actor: actor)

  defp user(role, tenant),
    do: SearchDemo.Accounts.create_user!(%{nom: to_string(role), role: role}, tenant: tenant)

  defp labels(results), do: results |> Enum.map(& &1.label) |> Enum.sort()
end
