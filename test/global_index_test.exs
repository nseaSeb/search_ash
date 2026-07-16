defmodule SearchAsh.GlobalIndexTest do
  @moduledoc """
  Integration tests for the unified global index (`SearchAsh.GlobalIndex`) fed by a
  source resource (`SearchAsh.Source`), against real Postgres.
  """
  use ExUnit.Case, async: false

  alias SearchAsh.Test.{Domain, Product, Repo, SearchDocument}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_products, test_invoices, test_search_documents",
      []
    )

    :ok
  end

  defp create(attrs, tenant), do: Domain.create_product!(attrs, tenant: tenant)
  defp gsearch(query, tenant), do: Domain.global_search!(query, :french, tenant: tenant)

  defp gsearch(query, tenant, include_archived?) do
    Domain.global_search!(query, :french, %{include_archived?: include_archived?}, tenant: tenant)
  end

  test "creating a source resource indexes it into the global index" do
    create(%{name: "Vis inox M6", sku: "VIS-M6"}, "a")

    assert Repo.aggregate(SearchDocument, :count) == 1

    assert [%{source_type: "product", label: "Vis inox M6", archived: false}] =
             gsearch("vis", "a")
  end

  test "results carry (source_type, source_id) and are ranked" do
    create(%{name: "Vis vis vis", sku: "V1"}, "a")
    create(%{name: "Vis simple", sku: "V2"}, "a")

    results = gsearch("vis", "a")
    assert Enum.all?(results, &(&1.source_type == "product"))
    assert Enum.all?(results, &is_binary(&1.source_id))
    assert hd(results).label == "Vis vis vis"
    assert results == Enum.sort_by(results, & &1.search_rank, :desc)
  end

  test "tenant isolation — look-alike rows never cross tenants" do
    create(%{name: "Chevaux", sku: "A"}, "a")
    create(%{name: "Chevaux", sku: "B"}, "b")

    assert [%{org_id: "a"}] = gsearch("chevaux", "a")
    assert [%{org_id: "b"}] = gsearch("chevaux", "b")
  end

  test "destroy removes the row from the index (on_destroy :remove)" do
    product = create(%{name: "Ephemere", sku: "EPH"}, "a")
    assert Repo.aggregate(SearchDocument, :count) == 1

    Domain.destroy_product!(product, tenant: "a")

    assert Repo.aggregate(SearchDocument, :count) == 0
  end

  test "reindex/2 backfills pre-existing rows" do
    # Insert directly, bypassing the sync change, to simulate existing data.
    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO test_products (org_id, name, sku, discontinued, language) " <>
        "VALUES ('a', 'Marteau', 'MRT', false, 'french')",
      []
    )

    assert Repo.aggregate(SearchDocument, :count) == 0

    SearchAsh.reindex(Product, tenant: "a")

    assert Repo.aggregate(SearchDocument, :count) == 1
    assert [%{label: "Marteau"}] = gsearch("marteau", "a")
  end

  # --- archived, driven by an attribute ---

  test "archived attribute: updating it hides the row from search but keeps it indexed" do
    product = create(%{name: "Boulangerie", sku: "BLG"}, "a")
    assert [%{archived: false}] = gsearch("boulan", "a")

    Domain.update_product!(product, %{discontinued: true}, tenant: "a")

    assert [] = gsearch("boulan", "a")
    assert [%{archived: true}] = gsearch("boulan", "a", true)
    assert Repo.aggregate(SearchDocument, :count) == 1
  end

  # --- archived, driven by a function, kept on destroy (AshArchival-style) ---

  test "archived function (deleted_at) + on_destroy :archive keeps the row archived" do
    invoice = Domain.create_invoice!(%{number: "BC-2024-017"}, tenant: "a")
    assert [%{archived: false}] = gsearch("bc", "a")

    # soft delete via a destroy action
    Domain.destroy_invoice!(invoice, tenant: "a")

    assert [] = gsearch("bc", "a")
    assert [%{archived: true}] = gsearch("bc", "a", true)
    assert Repo.aggregate(SearchDocument, :count) == 1
  end

  test "soft delete via an update (deleted_at) hides but keeps the row" do
    invoice = Domain.create_invoice!(%{number: "BC-2024-018"}, tenant: "a")
    assert [_] = gsearch("bc", "a")

    Domain.update_invoice!(invoice, %{deleted_at: DateTime.utc_now()}, tenant: "a")

    assert [] = gsearch("bc", "a")
    assert [%{archived: true}] = gsearch("bc", "a", true)
  end

  test "include_archived? returns both groups (active + archived) for the UI" do
    Domain.create_invoice!(%{number: "BC-actif"}, tenant: "a")
    to_archive = Domain.create_invoice!(%{number: "BC-archive"}, tenant: "a")
    Domain.destroy_invoice!(to_archive, tenant: "a")

    labels = fn results -> results |> Enum.map(& &1.label) |> Enum.sort() end

    assert ["BC-actif"] = labels.(gsearch("bc", "a"))
    assert ["BC-actif", "BC-archive"] = labels.(gsearch("bc", "a", true))
  end
end
