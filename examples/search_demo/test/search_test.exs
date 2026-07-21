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
          SearchDemo.Sales.Ligne,
          SearchDemo.Sales.Facture,
          SearchDemo.Sales.Client,
          SearchDemo.Sales.Produit,
          SearchDemo.Accounts.User
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

    test "too-short query (< min_length) matches nothing (0.4.0)" do
      SearchDemo.Blog.create_post!(%{title: "X", body: "y", language: :fr}, tenant: "org_a")
      assert SearchDemo.Blog.search_posts!("b", :fr, tenant: "org_a") == []
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

    test "results are ranked: label match first, then ts_rank" do
      results = search("chevaux", "org_a")
      # 0.4.0 ranks by label tier before ts_rank: "Chevaux & Co" *starts with* the
      # term, so it outranks F-001 — whose body mentions horses more often but whose
      # label ("F-001") says nothing to the user who typed "chevaux".
      # (`labels/1` sorts, so map here: this asserts the ORDER.)
      assert Enum.map(results, & &1.label) == ["Chevaux & Co", "F-001"]
      assert Enum.map(results, & &1.label_match_tier) == [1, 3]
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

    test "blank query lists all; a tokenless query matches nothing" do
      assert length(search("", "org_a")) == 3
      # 0.4.0: "b" and "de" produce no usable token — nothing, not the whole base.
      assert search("b", "org_a") == []
      assert search("de", "org_a") == []
    end

    test "every result carries (source_type, source_id) for linking" do
      for d <- search("chevaux", "org_a") do
        assert d.source_type in ["facture", "client", "produit"]
        assert is_binary(d.source_id)
      end
    end
  end

  describe "roles — what a user may find" do
    setup do
      SearchDemo.Sales.create_facture!(
        %{numero: "F-100", client_nom: "Dupont", description: "Réparation toiture."},
        tenant: "org_a"
      )

      SearchDemo.Sales.create_client!(%{nom: "Dupont SARL", notes: "Client historique."},
        tenant: "org_a"
      )

      SearchDemo.Sales.create_produit!(
        %{reference: "P-1", libelle: "Tuile Dupont", description: "Toiture."},
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

    test "the index refuses a hand-written row, while the extension still mirrors freely" do
      # No create policy is declared, and Ash refuses an action no policy matches — so the
      # index cannot be hand-edited. The extension is unaffected: it mirrors with
      # `authorize?: false`, because the source write it rides on was already authorized.
      assert_raise Ash.Error.Forbidden, fn ->
        SearchDemo.Search.Document
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            source_type: "facture",
            source_id: "forge",
            language: :fr,
            search_text: "injecte",
            archived: false,
            label: "Ligne forgee"
          },
          tenant: "org_a"
        )
        |> Ash.create!()
      end

      # The mirror still works — the three rows from setup are indexed.
      assert Repo.aggregate(Document, :count) == 3
    end

    test "roles compose with tenant isolation, they do not bypass it" do
      SearchDemo.Sales.create_client!(%{nom: "Dupont autre org"}, tenant: "org_b")

      assert labels(search("dupont", "org_b", user(:admin, "org_b"))) == ["Dupont autre org"]
    end
  end

  # These tests are about indexing, ranking and tenancy — not roles — so they search as an
  # admin, who finds every entity type. Roles have their own describe block.
  defp search(query, tenant), do: search(query, tenant, user(:admin, tenant))

  defp search(query, tenant, actor),
    do: SearchDemo.Search.global_search!(query, :fr, tenant: tenant, actor: actor)

  describe "0.4.0 — results-page features, end to end" do
    test "fuzzy: a typo in the label still finds the client" do
      SearchDemo.Sales.create_client!(%{nom: "Dupont", notes: "RAS"}, tenant: "org_a")

      assert ["Dupont"] = labels(search("duont", "org_a"))
    end

    test "fuzzy: a fragment of a reference finds the facture" do
      SearchDemo.Sales.create_facture!(
        %{numero: "BL-2024-0012", client_nom: "X", description: "Y"},
        tenant: "org_a"
      )

      assert ["BL-2024-0012"] = labels(search("0012", "org_a"))
    end

    test "extra_text: a facture is found by the text of its lignes" do
      facture =
        SearchDemo.Sales.create_facture!(
          %{numero: "F-100", client_nom: "Ferme", description: "Livraison"},
          tenant: "org_a"
        )

      SearchDemo.Sales.create_ligne!(
        %{facture_id: facture.id, designation: "Tomates anciennes 2kg"},
        tenant: "org_a"
      )

      # The ligne came after the facture's sync — reconcile (any facture write would too).
      SearchAsh.reindex_one(SearchDemo.Sales.Facture, facture.id, tenant: "org_a")

      assert [doc] = search("tomates", "org_a")
      assert doc.label == "F-100"
      # excerpt_length 160: the raw text (fields + lignes) is stored for display.
      assert doc.excerpt =~ "Tomates anciennes"
    end

    test "counts_by_type/3 gives the tab badges" do
      SearchDemo.Sales.create_facture!(
        %{numero: "F-200", client_nom: "Chevaux & Co", description: "Foin"},
        tenant: "org_a"
      )

      SearchDemo.Sales.create_client!(%{nom: "Chevaux & Co", notes: ""}, tenant: "org_a")

      # The index is policied and fails closed, so the counts compose with the actor's
      # role like the search itself does: an admin counts both types, support only clients.
      assert SearchAsh.counts_by_type(Document, "chevaux",
               tenant: "org_a",
               actor: user(:admin, "org_a")
             ) == %{"facture" => 1, "client" => 1}

      assert SearchAsh.counts_by_type(Document, "chevaux",
               tenant: "org_a",
               actor: user(:support, "org_a")
             ) == %{"client" => 1}
    end

    test "pagination: the results page can count and slice" do
      for i <- 1..5 do
        SearchDemo.Sales.create_facture!(
          %{numero: "F-30#{i}", client_nom: "Ferme des chevaux", description: "Foin"},
          tenant: "org_a"
        )
      end

      page =
        Document
        |> Ash.Query.for_read(:global_search, %{query: "chevaux"})
        |> Ash.Query.set_tenant("org_a")
        |> Ash.read!(page: [limit: 2, offset: 0, count: true], authorize?: false)

      assert page.count == 5
      assert length(page.results) == 2
    end

    test "types: tabs restrict the entity kinds searched" do
      SearchDemo.Sales.create_facture!(
        %{numero: "F-400", client_nom: "Chevaux & Co", description: ""},
        tenant: "org_a"
      )

      SearchDemo.Sales.create_client!(%{nom: "Chevaux & Co", notes: ""}, tenant: "org_a")

      results =
        Document
        |> Ash.Query.for_read(:global_search, %{query: "chevaux", types: [:client]})
        |> Ash.Query.set_tenant("org_a")
        |> Ash.read!(authorize?: false)

      assert Enum.map(results, & &1.source_type) == ["client"]
    end
  end

  # Memoised per (role, tenant): inserting a fresh row on every search would litter the
  # table, and an actor only has to carry a role.
  defp user(role, tenant) do
    key = {:user, role, tenant}

    case Process.get(key) do
      nil ->
        user =
          SearchDemo.Accounts.create_user!(%{nom: to_string(role), role: role}, tenant: tenant)

        Process.put(key, user)
        user

      user ->
        user
    end
  end

  defp labels(results), do: results |> Enum.map(& &1.label) |> Enum.sort()
end
