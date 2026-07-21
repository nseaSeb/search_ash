defmodule SearchAsh.GlobalSearchV040Test do
  @moduledoc """
  The 0.4.0 additions to `:global_search`, against real Postgres: the tokenless-query
  fix, pagination, the label ranking tiers, the `types` argument, `counts_by_type/3`,
  and the `label_normalized`/`excerpt` columns.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Domain, Repo, SearchDocument, SecuredDocument}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_products, test_invoices, test_search_documents",
      []
    )

    :ok
  end

  defp create(attrs, tenant), do: Domain.create_product!(attrs, tenant: tenant)
  defp gsearch(query, tenant), do: Domain.global_search!(query, :fr, tenant: tenant)

  defp gquery(args, tenant) do
    SearchDocument
    |> Ash.Query.for_read(:global_search, args)
    |> Ash.Query.set_tenant(tenant)
  end

  describe "a query with no usable token returns nothing" do
    test "stopwords-only and too-short queries match zero rows, not the whole base" do
      create(%{name: "Vis inox", sku: "V1"}, "a")
      create(%{name: "Marteau", sku: "M1"}, "a")

      assert gsearch("de", "a") == []
      assert gsearch("le la de", "a") == []
      assert gsearch("b", "a") == []
    end

    test "a blank or absent query still lists everything (unranked)" do
      create(%{name: "Vis inox", sku: "V1"}, "a")
      create(%{name: "Marteau", sku: "M1"}, "a")

      assert length(gsearch("", "a")) == 2
      assert length(gsearch("   ", "a")) == 2
    end
  end

  describe "pagination" do
    test "offset pagination with count" do
      for i <- 1..5, do: create(%{name: "Vis numero #{i}", sku: "V#{i}"}, "a")

      page =
        gquery(%{query: "vis"}, "a")
        |> Ash.read!(page: [limit: 2, offset: 2, count: true])

      assert %Ash.Page.Offset{} = page
      assert page.count == 5
      assert length(page.results) == 2
    end

    test "pages are stable and disjoint (rank ties broken by pk)" do
      # Identical text everywhere → every rank ties; only the pk tiebreaker keeps the
      # pages from overlapping.
      for i <- 1..6, do: create(%{name: "Clou acier", sku: "C#{i}"}, "a")

      pages =
        for offset <- [0, 2, 4] do
          gquery(%{query: "clou"}, "a")
          |> Ash.read!(page: [limit: 2, offset: offset])
          |> Map.fetch!(:results)
          |> Enum.map(& &1.id)
        end

      ids = List.flatten(pages)
      assert length(ids) == 6
      assert length(Enum.uniq(ids)) == 6
    end

    test "an unpaginated call still returns a plain list" do
      create(%{name: "Vis inox", sku: "V1"}, "a")
      assert [%{label: "Vis inox"}] = gsearch("vis", "a")
    end

    test "keyset pagination walks the ranked sort" do
      for i <- 1..5, do: create(%{name: "Vis numero #{i}", sku: "V#{i}"}, "a")

      # With both modes enabled, a bare limit pages by offset; `after:` switches to
      # keyset, resuming from the last result's keyset metadata.
      page1 =
        gquery(%{query: "vis"}, "a")
        |> Ash.read!(page: [limit: 2])

      page2 =
        gquery(%{query: "vis"}, "a")
        |> Ash.read!(page: [limit: 2, after: List.last(page1.results).__metadata__.keyset])

      assert %Ash.Page.Keyset{} = page2
      ids = Enum.map(page1.results ++ page2.results, & &1.id)
      assert length(Enum.uniq(ids)) == 4
    end
  end

  describe "label ranking tiers" do
    test "exact label > starts-with > contains > body-only match" do
      # The tiers compare the label against the WHOLE folded term.
      create(%{name: "Coffret perceuse 18V", sku: "X3"}, "a")
      create(%{name: "Perceuse 18V filaire", sku: "X4"}, "a")
      create(%{name: "Perceuse 18V", sku: "X2"}, "a")
      create(%{name: "Visseuse compacte", sku: "perceuse 18V"}, "a")

      assert [
               "Perceuse 18V",
               "Perceuse 18V filaire",
               "Coffret perceuse 18V",
               "Visseuse compacte"
             ] = gsearch("perceuse 18v", "a") |> Enum.map(& &1.label)
    end

    test "single-word term: exact, prefix, contains, body" do
      create(%{name: "Vis", sku: "A"}, "a")
      create(%{name: "Visseuse", sku: "B"}, "a")
      create(%{name: "Boite à vis", sku: "C"}, "a")
      create(%{name: "Rondelle", sku: "vis"}, "a")

      assert ["Vis", "Visseuse", "Boite à vis", "Rondelle"] =
               gsearch("vis", "a") |> Enum.map(& &1.label)
    end

    test "accent-insensitive: maraicher finds and top-ranks Maraîcher" do
      create(%{name: "Maraîcher", sku: "M1"}, "a")
      create(%{name: "Outils du maraîcher", sku: "M2"}, "a")

      assert ["Maraîcher", "Outils du maraîcher"] =
               gsearch("maraicher", "a") |> Enum.map(& &1.label)
    end

    test "a pre-0.4.0 row (NULL label_normalized) still matches, ranked as body-only" do
      create(%{name: "Vis moderne", sku: "V1"}, "a")

      # Simulate a row indexed before the migration backfill: same searchable text,
      # but no folded label.
      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO test_search_documents " <>
          "(org_id, source_type, source_id, language, search_text, label) " <>
          "VALUES ('a', 'product', 'legacy', 'fr', 'vis ancienne', 'Vis ancienne')",
        []
      )

      assert ["Vis moderne", "Vis ancienne"] = gsearch("vis", "a") |> Enum.map(& &1.label)
    end
  end

  describe "the types argument" do
    setup do
      create(%{name: "Vis inox", sku: "V1"}, "a")
      Domain.create_invoice!(%{number: "Facture vis 42"}, tenant: "a")
      :ok
    end

    defp searched_types(args, tenant) do
      gquery(args, tenant) |> Ash.read!() |> Enum.map(& &1.source_type) |> Enum.sort()
    end

    test "restricts to the given types" do
      assert searched_types(%{query: "vis", types: [:product]}, "a") == ["product"]
      assert searched_types(%{query: "vis", types: [:invoice]}, "a") == ["invoice"]

      assert searched_types(%{query: "vis", types: [:invoice, :product]}, "a") ==
               ["invoice", "product"]
    end

    test "types casts strings too — what a form submits" do
      # The argument is `{:array, :string}` (atoms cast via to_string), so a
      # `source_type` declared as a string in the DSL — whose atom may not exist —
      # never crashes the cast.
      assert searched_types(%{query: "vis", types: ["product"]}, "a") == ["product"]
    end

    test "nil and [] both mean no type filter" do
      assert searched_types(%{query: "vis"}, "a") == ["invoice", "product"]
      assert searched_types(%{query: "vis", types: []}, "a") == ["invoice", "product"]
    end
  end

  describe "counts_by_type/3" do
    test "counts the matches per source_type" do
      create(%{name: "Vis inox", sku: "V1"}, "a")
      create(%{name: "Vis laiton", sku: "V2"}, "a")
      Domain.create_invoice!(%{number: "Facture vis 42"}, tenant: "a")
      Domain.create_invoice!(%{number: "Facture clous"}, tenant: "a")

      assert SearchAsh.counts_by_type(SearchDocument, "vis", tenant: "a") ==
               %{"product" => 2, "invoice" => 1}

      # A blank term counts everything, per type.
      assert SearchAsh.counts_by_type(SearchDocument, "", tenant: "a") ==
               %{"product" => 2, "invoice" => 2}

      # Explicit :types count exactly those (including zeroes).
      assert SearchAsh.counts_by_type(SearchDocument, "clous",
               tenant: "a",
               types: [:product, :invoice]
             ) ==
               %{"product" => 0, "invoice" => 1}

      # `[]` means "not specified" — the same convention as the action's `types`
      # argument. An empty tab multi-select must yield the full badge set, not %{}.
      assert SearchAsh.counts_by_type(SearchDocument, "vis", tenant: "a", types: []) ==
               %{"product" => 2, "invoice" => 1}
    end

    test "an index that paginates by default still counts correctly" do
      # FuzzyDocument sets `default_limit 5`. Without unsetting the page, the distinct
      # read would come back as an `Ash.Page` (not enumerable) and, once that was fixed,
      # would still only see the first 5 types.
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_contacts, test_fuzzy_documents", [])
      for i <- 1..12, do: Domain.create_contact!(%{name: "Client #{i}", ref: "C#{i}"})

      assert SearchAsh.counts_by_type(SearchAsh.Test.FuzzyDocument, "client") ==
               %{"contact" => 12}
    end

    test "the index's policies apply to the actor" do
      Ecto.Adapters.SQL.query!(
        Repo,
        "TRUNCATE test_secured_products, test_secured_invoices, test_secured_documents",
        []
      )

      Domain.create_secured_product!(%{name: "Vis inox"}, tenant: "a")
      Domain.create_secured_invoice!(%{number: "Vis facture 42"}, tenant: "a")

      assert SearchAsh.counts_by_type(SecuredDocument, "vis",
               tenant: "a",
               actor: %{visible_types: ["invoice"]},
               authorize?: true
             ) == %{"invoice" => 1}
    end
  end

  describe "label_normalized and excerpt columns" do
    test "label_normalized stores the folded label" do
      create(%{name: "Maraîcher Bio", sku: "M1"}, "a")

      assert [%{label: "Maraîcher Bio", label_normalized: "maraicher bio"}] =
               gsearch("maraicher", "a")
    end

    test "excerpt is nil for a source without excerpt_length" do
      create(%{name: "Vis inox", sku: "V1"}, "a")
      assert [%{excerpt: nil}] = gsearch("vis", "a")
    end

    test "on_destroy :archive keeps label_normalized AND excerpt" do
      # Archiving re-upserts the row instead of rebuilding the document (the source may be
      # gone), so every stored column must survive the flip.
      invoice = Domain.create_invoice!(%{number: "Facture Été 42"}, tenant: "a")
      Domain.destroy_invoice!(invoice, tenant: "a")

      [row] = Ash.read!(SearchDocument, tenant: "a", authorize?: false)
      assert row.archived
      assert row.label_normalized == "facture ete 42"
      assert row.excerpt == "Facture Été 42"
    end
  end
end
