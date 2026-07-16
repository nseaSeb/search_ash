defmodule SearchAsh.GlobalIndexTest do
  @moduledoc """
  Integration tests for the unified global index (`SearchAsh.GlobalIndex`) fed by a
  source resource (`SearchAsh.Source`), against real Postgres.
  """
  use ExUnit.Case, async: false

  alias SearchAsh.Test.{Domain, Invoice, Product, Repo, SearchDocument}

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

  # Bulk operations keep the index in sync with NO `strategy:` option — the sync/remove
  # changes are atomic-compatible (`atomic/3` -> :ok) and mirror each record in
  # `after_batch/3`, so the default `:atomic_batches` strategy works transparently.
  test "bulk create/update/destroy keep the index in sync (default strategy)" do
    products =
      Ash.bulk_create!(
        [%{name: "Bulk A", sku: "BA"}, %{name: "Bulk B", sku: "BB"}],
        Product,
        :create,
        tenant: "a",
        return_records?: true
      ).records

    assert Repo.aggregate(SearchDocument, :count) == 2

    # bulk_update, default strategy — the index must reflect the new name.
    Ash.bulk_update!(products, :update, %{name: "Renamed"}, tenant: "a", return_records?: true)

    assert length(gsearch("renamed", "a")) == 2
    assert gsearch("bulk", "a") == []
    assert Repo.aggregate(SearchDocument, :count) == 2

    # A bulk_update that flips the archived attribute must hide the rows from search
    # (default) while keeping them indexed.
    renamed = Ash.read!(Product, tenant: "a")
    Ash.bulk_update!(renamed, :update, %{discontinued: true}, tenant: "a", return_records?: true)
    assert gsearch("renamed", "a") == []
    assert length(gsearch("renamed", "a", true)) == 2

    # bulk_destroy, default strategy — the index rows must be gone (on_destroy: :remove).
    Ash.bulk_destroy!(renamed, :destroy, %{}, tenant: "a")

    assert Repo.aggregate(SearchDocument, :count) == 0
  end

  # Covers the other destroy branch under bulk: on_destroy :archive + function-driven
  # `archived`. Default strategy, no `strategy:` option.
  test "bulk_destroy with on_destroy: :archive keeps rows flagged archived (default strategy)" do
    invoices =
      Ash.bulk_create!(
        [%{number: "BC-B1"}, %{number: "BC-B2"}],
        Invoice,
        :create,
        tenant: "a",
        return_records?: true
      ).records

    assert length(gsearch("bc", "a")) == 2

    Ash.bulk_destroy!(invoices, :destroy, %{}, tenant: "a")

    # Rows are kept but hidden by default, and returned (archived: true) when asked for.
    assert gsearch("bc", "a") == []
    assert [%{archived: true}, %{archived: true}] = gsearch("bc", "a", true)
    assert Repo.aggregate(SearchDocument, :count) == 2
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
