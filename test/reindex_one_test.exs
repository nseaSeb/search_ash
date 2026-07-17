defmodule SearchAsh.ReindexOneTest do
  @moduledoc """
  Integration tests for `SearchAsh.reindex_one/3`, against real Postgres.

  Different premise from `SearchAsh.GlobalIndexTest`: that file covers the *action* path,
  where a write goes through Ash and the sync/remove changes fire. Every test here starts
  from a write that **bypassed** Ash (a raw `Repo.query!`), which those changes never saw —
  the situation `reindex_one/3` exists to repair.
  """
  use ExUnit.Case, async: false

  alias SearchAsh.Test.{Domain, Invoice, LineItem, Product, Repo, SearchDocument, TrashableNote}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_products, test_invoices, test_line_items, test_trashable_notes, " <>
        "test_search_documents",
      []
    )

    :ok
  end

  defp gsearch(query, tenant), do: Domain.global_search!(query, :fr, tenant: tenant)

  defp gsearch(query, tenant, include_archived?) do
    Domain.global_search!(query, :fr, %{include_archived?: include_archived?}, tenant: tenant)
  end

  defp sql!(statement, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, statement, params)

  defp index_count, do: Repo.aggregate(SearchDocument, :count)

  defp source_ids do
    SearchDocument |> Ash.read!(authorize?: false) |> Enum.map(& &1.source_id) |> Enum.sort()
  end

  # ── Alive branch ────────────────────────────────────────────────────────────────────────

  test "a field changed by raw SQL is stale, and reindex_one/3 refreshes it" do
    product = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")

    sql!("UPDATE test_products SET name = 'Tournevis' WHERE id = $1", [
      Ecto.UUID.dump!(product.id)
    ])

    # The premise: the write bypassed Ash, so the index still holds the old name.
    assert [%{label: "Marteau"}] = gsearch("marteau", "a")

    assert :upserted = SearchAsh.reindex_one(Product, product.id, tenant: "a")

    assert [%{label: "Tournevis"}] = gsearch("tournevis", "a")
    assert [] = gsearch("marteau", "a")
    # Upsert, not insert.
    assert index_count() == 1
  end

  test "reindex_one/3 indexes an alive row that was never indexed" do
    %{rows: [[id]]} =
      sql!(
        "INSERT INTO test_products (org_id, name, sku, discontinued, language) " <>
          "VALUES ('a', 'Marteau', 'MRT', false, 'fr') RETURNING id"
      )

    assert index_count() == 0

    assert :upserted = SearchAsh.reindex_one(Product, Ecto.UUID.load!(id), tenant: "a")

    assert index_count() == 1
    assert [%{label: "Marteau"}] = gsearch("marteau", "a")
  end

  # ── Absent branch ───────────────────────────────────────────────────────────────────────

  test "on_destroy :remove — a source deleted by raw SQL has its index row removed" do
    product = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")
    assert index_count() == 1

    sql!("DELETE FROM test_products WHERE id = $1", [Ecto.UUID.dump!(product.id)])

    assert :removed = SearchAsh.reindex_one(Product, product.id, tenant: "a")
    assert index_count() == 0
  end

  test "on_destroy :archive — a source deleted by raw SQL is archived, NOT removed" do
    # The key regression test: a hardcoded `delete` in the absent branch passes every other
    # test in this file and fails this one. Pin the count as well as the flag — asserting
    # only `archived: true` would pass vacuously against an empty result.
    invoice = Domain.create_invoice!(%{number: "BC-2024"}, tenant: "a")
    assert index_count() == 1

    sql!("DELETE FROM test_invoices WHERE id = $1", [Ecto.UUID.dump!(invoice.id)])

    assert :archived = SearchAsh.reindex_one(Invoice, invoice.id, tenant: "a")

    assert index_count() == 1
    assert [] = gsearch("bc", "a")
    assert [%{archived: true}] = gsearch("bc", "a", true)
  end

  test "a source soft-deleted by raw SQL (base_filter) is reconciled as gone" do
    # The trigger this feature actually exists for: a raw-SQL cascade that stamps `deleted_at`
    # rather than deleting the row. The source is still physically there — only `base_filter`
    # hides it. Every other absence test here fakes it with a physical DELETE, which reaches
    # the same branch by a route production never takes.
    note = Domain.create_trashable_note!(%{title: "Livraison Dupont"}, tenant: "a")
    assert index_count() == 1

    sql!("UPDATE test_trashable_notes SET deleted_at = now() WHERE id = $1", [
      Ecto.UUID.dump!(note.id)
    ])

    # The row is still in the table...
    assert %{num_rows: 1} =
             sql!("SELECT 1 FROM test_trashable_notes WHERE id = $1", [
               Ecto.UUID.dump!(note.id)
             ])

    # ...but `base_filter` applies regardless of `authorize?`, so the read reports it gone.
    assert :removed = SearchAsh.reindex_one(TrashableNote, note.id, tenant: "a")
    assert index_count() == 0
  end

  test "reindex_one/3 is a no-op for a source that is gone and was never indexed" do
    # Both `on_destroy` values: `:archive` cannot raise a tombstone either (an archived row
    # needs language/search_text/label, and the source is gone).
    assert :noop = SearchAsh.reindex_one(Product, Ecto.UUID.generate(), tenant: "a")
    assert :noop = SearchAsh.reindex_one(Invoice, Ecto.UUID.generate(), tenant: "a")
    assert index_count() == 0
  end

  test "a failed read raises and does NOT delete the index row" do
    # The third way "absent" can be a lie, after policy-hidden and base_filter: a read that
    # *fails*. It must never be mistaken for "record gone" — that would delete a live row's
    # index entry on a transient error. An unparseable primary key makes the source read fail;
    # the row must survive and the call must not swallow the failure as a deletion.
    Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")
    assert index_count() == 1

    assert_raise Ash.Error.Invalid, fn ->
      SearchAsh.reindex_one(Product, "not-a-valid-uuid", tenant: "a")
    end

    # Not deleted, not archived — untouched.
    assert index_count() == 1
    assert [%{label: "Marteau"}] = gsearch("marteau", "a")
  end

  # ── Idempotency ─────────────────────────────────────────────────────────────────────────

  test "reindex_one/3 is idempotent on the alive branch" do
    product = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")

    assert :upserted = SearchAsh.reindex_one(Product, product.id, tenant: "a")
    assert :upserted = SearchAsh.reindex_one(Product, product.id, tenant: "a")

    assert index_count() == 1
  end

  test "reindex_one/3 is idempotent on the absent branch, for both on_destroy values" do
    product = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")
    invoice = Domain.create_invoice!(%{number: "BC-2024"}, tenant: "a")

    sql!("DELETE FROM test_products WHERE id = $1", [Ecto.UUID.dump!(product.id)])
    sql!("DELETE FROM test_invoices WHERE id = $1", [Ecto.UUID.dump!(invoice.id)])

    assert :removed = SearchAsh.reindex_one(Product, product.id, tenant: "a")
    # Second call: the row is already gone, so there is nothing left to remove.
    assert :noop = SearchAsh.reindex_one(Product, product.id, tenant: "a")

    assert :archived = SearchAsh.reindex_one(Invoice, invoice.id, tenant: "a")
    # Second call: the row is already archived — its terminal state — so there is nothing left
    # to do. It must not re-archive (a redundant write + spurious notification) and must not
    # delete.
    assert :noop = SearchAsh.reindex_one(Invoice, invoice.id, tenant: "a")

    assert index_count() == 1
    assert [%{archived: true}] = gsearch("bc", "a", true)
  end

  # ── Primary key forms ───────────────────────────────────────────────────────────────────

  test "a map pk is equivalent to a scalar one for a single-field primary key" do
    product = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")
    sql!("DELETE FROM test_products WHERE id = $1", [Ecto.UUID.dump!(product.id)])

    assert :removed = SearchAsh.reindex_one(Product, %{id: product.id}, tenant: "a")
    assert index_count() == 0
  end

  test "a composite pk refreshes the right row on the alive branch" do
    # The alive branch derives source_id from the fetched record (via Document.source_id/2),
    # so this pins the composite upsert path. The pk-derived join is pinned separately by the
    # absent-branch tests below, where source_id_from_pk is what targets the row.
    Domain.create_line_item!(
      %{order_id: "SO-1", line_no: 2, description: "Boulon inox"},
      tenant: "a"
    )

    assert source_ids() == ["SO-1:2"]

    sql!("UPDATE test_line_items SET description = 'Ecrou laiton' WHERE order_id = $1", ["SO-1"])

    assert :upserted =
             SearchAsh.reindex_one(LineItem, %{order_id: "SO-1", line_no: 2}, tenant: "a")

    assert [%{label: "Ecrou laiton"}] = gsearch("ecrou", "a")
  end

  test "a composite pk targets exactly its own index row" do
    # The invariant behind the whole absent branch: `source_id_from_pk` must agree byte for
    # byte with `Document.source_id/2`, or reconciliation hits the wrong row — or none.
    for line_no <- [1, 2] do
      Domain.create_line_item!(
        %{order_id: "SO-1", line_no: line_no, description: "Boulon #{line_no}"},
        tenant: "a"
      )
    end

    assert source_ids() == ["SO-1:1", "SO-1:2"]

    sql!("DELETE FROM test_line_items WHERE order_id = $1 AND line_no = 2", ["SO-1"])

    assert :removed =
             SearchAsh.reindex_one(LineItem, %{order_id: "SO-1", line_no: 2}, tenant: "a")

    assert source_ids() == ["SO-1:1"]
  end

  test "a keyword-list pk is equivalent to a map one" do
    Domain.create_line_item!(
      %{order_id: "SO-1", line_no: 2, description: "Boulon inox"},
      tenant: "a"
    )

    sql!("DELETE FROM test_line_items WHERE order_id = $1 AND line_no = 2", ["SO-1"])

    assert :removed =
             SearchAsh.reindex_one(LineItem, [order_id: "SO-1", line_no: 2], tenant: "a")

    assert index_count() == 0
  end

  test "a scalar pk for a composite-key resource raises, naming the fields" do
    assert_raise ArgumentError, ~r/primary key has 2 fields: \[:order_id, :line_no\]/, fn ->
      SearchAsh.reindex_one(LineItem, "SO-1", tenant: "a")
    end
  end

  test "a pk map missing a field raises, naming the missing one" do
    assert_raise ArgumentError, ~r/with no :line_no/, fn ->
      SearchAsh.reindex_one(LineItem, %{order_id: "SO-1"}, tenant: "a")
    end
  end

  # ── Safety ──────────────────────────────────────────────────────────────────────────────

  test "a row hidden by a read policy is not mistaken for a deleted one" do
    # The test the feature exists for. `LineItem`'s read policy FILTERS (`hidden == false`),
    # so an authorized read returns nil for a live row. An implementation that read with the
    # default `authorize?: true` and no actor would take that nil for "deleted" and destroy
    # the index row of a perfectly live record.
    Domain.create_line_item!(
      %{order_id: "SO-1", line_no: 1, description: "Boulon inox"},
      tenant: "a"
    )

    assert index_count() == 1

    sql!("UPDATE test_line_items SET hidden = true WHERE order_id = $1", ["SO-1"])

    # Prove the premise rather than assume it: an *authorized* read really does return nil for
    # this live row. Without this, the assertion below would pass vacuously against any
    # implementation the day the fixture's policy stopped filtering.
    assert {:ok, nil} =
             Ash.get(LineItem, %{order_id: "SO-1", line_no: 1},
               tenant: "a",
               authorize?: true,
               actor: nil,
               not_found_error?: false
             )

    assert :upserted =
             SearchAsh.reindex_one(LineItem, %{order_id: "SO-1", line_no: 1}, tenant: "a")

    assert index_count() == 1
    assert [%{label: "Boulon inox"}] = gsearch("boulon", "a")
  end

  test "reindex_one/3 rejects :actor and authorize?: true, but accepts authorize?: false" do
    product = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")

    assert_raise ArgumentError, ~r/does not accept :actor/, fn ->
      SearchAsh.reindex_one(Product, product.id, tenant: "a", actor: %{id: 1})
    end

    assert_raise ArgumentError, ~r/does not accept authorize\?: true/, fn ->
      SearchAsh.reindex_one(Product, product.id, tenant: "a", authorize?: true)
    end

    # Harmless: it is what the function does anyway.
    assert :upserted = SearchAsh.reindex_one(Product, product.id, tenant: "a", authorize?: false)
  end

  # ── Tenant ──────────────────────────────────────────────────────────────────────────────

  test "reindex_one/3 reconciles only the given tenant's index row" do
    a = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")
    b = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "b")

    assert index_count() == 2

    sql!("DELETE FROM test_products WHERE id = $1", [Ecto.UUID.dump!(a.id)])

    assert :removed = SearchAsh.reindex_one(Product, a.id, tenant: "a")

    assert index_count() == 1
    assert [%{label: "Marteau"}] = gsearch("marteau", "b")
    assert [] = gsearch("marteau", "a")

    # `b`'s source is untouched.
    assert Ash.get!(Product, b.id, tenant: "b", authorize?: false).name == "Marteau"
  end
end
