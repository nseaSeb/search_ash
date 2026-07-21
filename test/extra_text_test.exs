defmodule SearchAsh.ExtraTextTest do
  @moduledoc """
  `load` + `extra_text` on `searchable`: the order's document indexes text derived from
  its lines ("which orders contain tomatoes"), plus the `excerpt_length` column. Also
  pins the staleness contract: a direct write to a line does NOT re-index the order —
  `reindex_one/3` (or any order write) reconciles.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Domain, Order, Repo, SearchDocument}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_orders, test_order_lines, test_search_documents",
      []
    )

    :ok
  end

  defp gsearch(query, tenant), do: Domain.global_search!(query, :fr, tenant: tenant)

  defp order_with_lines(number, descriptions, tenant) do
    order = Domain.create_order!(%{number: number}, tenant: tenant)

    for description <- descriptions do
      Domain.create_order_line!(%{order_id: order.id, description: description},
        tenant: tenant
      )
    end

    order
  end

  test "an order write indexes the text of its lines" do
    order = order_with_lines("CMD-001", ["Tomates anciennes 2kg", "Salades"], "a")

    # The lines were created AFTER the order's create synced it — the index does not
    # know them yet. Any write to the order reconciles (extra_text forces recompute).
    assert gsearch("tomates", "a") == []

    Domain.update_order!(order, %{number: "CMD-001"}, tenant: "a")

    assert [%{source_type: "order", label: "CMD-001"}] = gsearch("tomates", "a")
  end

  test "reindex_one/3 repairs the staleness after a direct write to a line" do
    order = order_with_lines("CMD-002", ["Carottes"], "a")
    SearchAsh.reindex_one(Order, order.id, tenant: "a")
    assert [_] = gsearch("carottes", "a")

    # A direct write to the line bypasses the order's sync: the index keeps the old text.
    [line] = Ash.read!(SearchAsh.Test.OrderLine, tenant: "a", authorize?: false)
    Domain.update_order_line!(line, %{description: "Poireaux"}, tenant: "a")

    assert [_] = gsearch("carottes", "a")
    assert gsearch("poireaux", "a") == []

    # The documented reconciliation.
    assert SearchAsh.reindex_one(Order, order.id, tenant: "a") == :upserted

    assert gsearch("carottes", "a") == []
    assert [_] = gsearch("poireaux", "a")
  end

  test "reindex/2 also goes through load + extra_text" do
    order = order_with_lines("CMD-003", ["Tomates cerises"], "a")

    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_search_documents", [])
    SearchAsh.reindex(Order, tenant: "a")

    assert [%{source_id: source_id}] = gsearch("tomates", "a")
    assert source_id == order.id
  end

  test "reindex/2 forwards :domain to the load (a resource may have none configured)" do
    order_with_lines("CMD-005", ["Fenouil"], "a")

    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_search_documents", [])
    SearchAsh.reindex(Order, tenant: "a", domain: SearchAsh.Test.Domain)

    assert [_] = gsearch("fenouil", "a")
  end

  test "bulk create syncs the lines' text through one batched load" do
    # `after_batch` goes through `Index.upsert_all/4`: the lines load runs once for
    # the whole batch. (Lines exist first here, created against explicit order ids.)
    orders =
      Ash.bulk_create!([%{number: "CMD-B1"}, %{number: "CMD-B2"}], Order, :create,
        tenant: "a",
        return_records?: true
      ).records

    for order <- orders do
      Domain.create_order_line!(%{order_id: order.id, description: "Basilic frais"},
        tenant: "a"
      )
    end

    # A bulk update re-syncs both orders — extra_text forces recompute — and both
    # documents pick up their lines.
    Ash.bulk_update!(Order, :update, %{}, tenant: "a", return_errors?: true)

    assert length(gsearch("basilic", "a")) == 2
  end

  test "excerpt stores the raw text, word-truncated with an ellipsis" do
    order = order_with_lines("CMD-004", ["Tomates anciennes et salades croquantes"], "a")
    SearchAsh.reindex_one(Order, order.id, tenant: "a")

    [row] = Ash.read!(SearchDocument, tenant: "a", authorize?: false)

    # excerpt_length is 40: raw text "CMD-004 Tomates anciennes et salades croquantes"
    # is cut on a word boundary and …-suffixed — and stays raw, not stemmed.
    assert row.excerpt == "CMD-004 Tomates anciennes et salades…"
    assert String.length(row.excerpt) <= 41
  end
end
