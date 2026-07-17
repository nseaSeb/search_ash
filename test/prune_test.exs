defmodule SearchAsh.PruneTest do
  @moduledoc """
  Integration tests for `SearchAsh.prune/2` — the orphan sweep, against real Postgres.

  An orphan is an index row whose source record no longer exists. They accrue when source
  rows are deleted outside Ash without a following `reindex_one/3`. `prune/2` finds them by
  diffing the index against the live source set.
  """
  use ExUnit.Case, async: false

  alias SearchAsh.Test.{Domain, Invoice, LineItem, OffsetPage, Product, Repo, SearchDocument}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_products, test_invoices, test_line_items, test_offset_pages, " <>
        "test_search_documents",
      []
    )

    :ok
  end

  defp sql!(statement, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, statement, params)
  defp index_count, do: Repo.aggregate(SearchDocument, :count)

  defp source_types do
    SearchDocument
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.source_type)
    |> Enum.sort()
  end

  test "prune/2 removes index rows whose source was deleted outside Ash" do
    keep = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")
    gone = Domain.create_product!(%{name: "Tournevis", sku: "TRN"}, tenant: "a")

    assert index_count() == 2

    sql!("DELETE FROM test_products WHERE id = $1", [Ecto.UUID.dump!(gone.id)])

    assert 1 = SearchAsh.prune(Product, tenant: "a")

    assert index_count() == 1
    assert [%{label: "Marteau"}] = Domain.global_search!("marteau", :fr, tenant: "a")
    assert [] = Domain.global_search!("tournevis", :fr, tenant: "a")
    # The surviving source is untouched.
    assert Ash.get!(Product, keep.id, tenant: "a", authorize?: false).name == "Marteau"
  end

  test "prune/2 removes and counts several orphans at once" do
    # The reduce accumulator otherwise only ever runs 0 -> 1 across the suite; a counting bug
    # (or a constant return) for N > 1 would slip through. Three orphans, one survivor.
    survivor = Domain.create_product!(%{name: "Survivant", sku: "S0"}, tenant: "a")

    doomed =
      for n <- 1..3 do
        Domain.create_product!(%{name: "Perime #{n}", sku: "P#{n}"}, tenant: "a")
      end

    assert index_count() == 4

    for p <- doomed, do: sql!("DELETE FROM test_products WHERE id = $1", [Ecto.UUID.dump!(p.id)])

    assert 3 = SearchAsh.prune(Product, tenant: "a")

    assert index_count() == 1
    assert [%{label: "Survivant"}] = Domain.global_search!("survivant", :fr, tenant: "a")
    assert Ash.get!(Product, survivor.id, tenant: "a", authorize?: false).name == "Survivant"
  end

  test "prune/2 returns 0 and changes nothing when there are no orphans" do
    Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")

    assert 0 = SearchAsh.prune(Product, tenant: "a")
    assert index_count() == 1
  end

  test "prune/2 only touches the given resource's source_type" do
    # Pruning Product with every product deleted must not touch the invoice row. prune is
    # structurally confined to its own source_type — the destroy it applies is scoped to
    # `(source_type, source_id)` — so another type's rows are unreachable, not merely filtered.
    Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")
    Domain.create_invoice!(%{number: "BC-2024"}, tenant: "a")

    assert source_types() == ["invoice", "product"]

    sql!("DELETE FROM test_products")

    assert 1 = SearchAsh.prune(Product, tenant: "a")

    # The invoice index row survives — prune never looked at it.
    assert source_types() == ["invoice"]
  end

  test "prune/2 archives orphans of an on_destroy: :archive resource instead of deleting" do
    invoice = Domain.create_invoice!(%{number: "BC-2024"}, tenant: "a")

    sql!("DELETE FROM test_invoices WHERE id = $1", [Ecto.UUID.dump!(invoice.id)])

    assert 1 = SearchAsh.prune(Invoice, tenant: "a")

    # Kept, flagged archived — the same on_destroy the destroy path and reindex_one/3 honour.
    assert index_count() == 1
    assert [] = Domain.global_search!("bc", :fr, tenant: "a")

    assert [%{archived: true}] =
             Domain.global_search!("bc", :fr, %{include_archived?: true}, tenant: "a")

    # The tombstone is now in its terminal state: a second prune must find nothing to do,
    # not re-archive it forever (which would also fire a no-op notification per tombstone).
    assert 0 = SearchAsh.prune(Invoice, tenant: "a")
    assert index_count() == 1
  end

  test "prune/2 sweeps only the named tenant" do
    a = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")
    _b = Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "b")

    # Delete tenant a's source only.
    sql!("DELETE FROM test_products WHERE id = $1", [Ecto.UUID.dump!(a.id)])

    assert 1 = SearchAsh.prune(Product, tenant: "a")

    assert index_count() == 1
    assert [] = Domain.global_search!("marteau", :fr, tenant: "a")
    assert [%{label: "Marteau"}] = Domain.global_search!("marteau", :fr, tenant: "b")
  end

  test "prune/2 does not treat a policy-hidden live row as an orphan" do
    # The mirror of reindex_one's security test, and the sharpest reason prune belongs in the
    # library rather than a hand-rolled support script. LineItem's read policy filters
    # (`hidden == false`). A prune that streamed the live set with the default `authorize?:
    # true` and no actor would find the hidden row missing, call it an orphan, and DELETE its
    # index row — for a row that is perfectly alive.
    Domain.create_line_item!(%{order_id: "SO-1", line_no: 1, description: "Boulon inox"},
      tenant: "a"
    )

    Domain.create_line_item!(%{order_id: "SO-1", line_no: 2, description: "Ecrou laiton"},
      tenant: "a"
    )

    assert index_count() == 2

    sql!("UPDATE test_line_items SET hidden = true WHERE line_no = 1")

    # Prove the premise: an authorized stream really does omit the hidden row.
    visible =
      LineItem
      |> Ash.read!(tenant: "a", authorize?: true, actor: nil)
      |> Enum.map(& &1.line_no)
      |> Enum.sort()

    assert visible == [2]

    # Yet prune, reading unauthorized, sees both as live and removes neither.
    assert 0 = SearchAsh.prune(LineItem, tenant: "a")
    assert index_count() == 2
  end

  test "prune/2 forwards :stream_with for a source whose read can't keyset-stream" do
    # OffsetPage's primary read is offset-only, so Ash.stream! (keyset by default) can't stream
    # it — the same condition under which `reindex/2` needs `stream_with: :offset`. prune used
    # to drop the option, so it failed on exactly these resources.
    keep = Domain.create_offset_page!(%{title: "Accueil"}, tenant: "a")
    gone = Domain.create_offset_page!(%{title: "Obsolete"}, tenant: "a")
    assert index_count() == 2

    # Proof the fixture reproduces the condition: without the option, streaming can't proceed.
    assert_raise Ash.Error.Invalid.NonStreamableAction, fn ->
      SearchAsh.prune(OffsetPage, tenant: "a")
    end

    sql!("DELETE FROM test_offset_pages WHERE id = $1", [Ecto.UUID.dump!(gone.id)])

    # With it forwarded, prune streams via offset and sweeps the orphan.
    assert 1 = SearchAsh.prune(OffsetPage, tenant: "a", stream_with: :offset)

    assert index_count() == 1
    assert [%{label: "Accueil"}] = Domain.global_search!("accueil", :fr, tenant: "a")
    assert Ash.get!(OffsetPage, keep.id, tenant: "a", authorize?: false).title == "Accueil"
  end

  test "prune/2 rejects :actor and authorize?: true, but accepts authorize?: false" do
    Domain.create_product!(%{name: "Marteau", sku: "MRT"}, tenant: "a")

    assert_raise ArgumentError, ~r/does not accept :actor/, fn ->
      SearchAsh.prune(Product, tenant: "a", actor: %{id: 1})
    end

    assert_raise ArgumentError, ~r/does not accept authorize\?: true/, fn ->
      SearchAsh.prune(Product, tenant: "a", authorize?: true)
    end

    assert 0 = SearchAsh.prune(Product, tenant: "a", authorize?: false)
  end
end
