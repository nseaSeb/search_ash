defmodule SearchAsh.IndexAttributeTest do
  @moduledoc """
  `index_attribute` — extra typed columns on the index, filled from the source record, so
  a results page can range-filter on a date, sort by it, and narrow in SQL.

  The rule these columns exist under: **derived from content, never authorization**. They
  are rewritten on every sync, which is exactly why they cannot go stale the way a
  mirrored access right would.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Domain, Order, Repo, SearchDocument}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_orders, test_order_lines, test_invoices, test_search_documents",
      []
    )

    :ok
  end

  defp order(number, date, ref \\ "CLI-1", tenant \\ "a") do
    Domain.create_order!(%{number: number, date_emission: date, client_ref: ref},
      tenant: tenant
    )
  end

  defp rows, do: Ash.read!(SearchDocument, tenant: "a", authorize?: false)

  defp search(args) do
    SearchDocument
    |> Ash.Query.for_read(:global_search, args)
    |> Ash.Query.set_tenant("a")
  end

  describe "filling the columns" do
    test "an attribute-named source is copied into the index" do
      order("CMD-1", ~D[2026-06-15], "CLI-42")

      assert [%{document_date: ~D[2026-06-15], client_ref: "CLI-42"}] = rows()
    end

    test "a function source is computed (and sees the `load`ed relations)" do
      o = order("CMD-2", ~D[2026-06-15])

      for d <- ["Tomates", "Salades"] do
        Domain.create_order_line!(%{order_id: o.id, description: d}, tenant: "a")
      end

      # The lines arrived after the create's sync — any write reconciles.
      SearchAsh.reindex_one(Order, o.id, tenant: "a")

      assert [%{line_count: 2}] = rows()
    end

    test "several sources fill ONE column from DIFFERENT attributes" do
      # A document has many dates (issued, delivered, due, created) and each entity type
      # names them differently. What a results page needs is *one comparable axis*: each
      # source maps whatever "the date this is from" means for it onto the same column.
      order("CMD-1", ~D[2026-03-01])
      Domain.create_invoice!(%{number: "F-1", date_facture: ~D[2026-05-20]}, tenant: "a")

      dated = rows() |> Enum.map(&{&1.source_type, &1.document_date}) |> Enum.sort()
      assert dated == [{"invoice", ~D[2026-05-20]}, {"order", ~D[2026-03-01]}]

      # One filter spans both entity types — no per-type column to know about.
      results =
        search(%{query: ""})
        |> Ash.Query.filter(document_date >= ^~D[2026-04-01])
        |> Ash.read!()

      assert Enum.map(results, & &1.source_type) == ["invoice"]
    end

    test "a source that does not fill a column leaves it NULL" do
      order("CMD-3", ~D[2026-06-15])
      Domain.create_invoice!(%{number: "F-1"}, tenant: "a")

      by_type = Map.new(rows(), &{&1.source_type, &1})
      assert by_type["order"].document_date == ~D[2026-06-15]
      # Invoice declares client_ref but no document_date.
      assert by_type["invoice"].document_date == nil
      assert by_type["invoice"].client_ref == "F-1"
    end
  end

  describe "what the columns are for" do
    setup do
      order("CMD-JAN", ~D[2026-01-10])
      order("CMD-JUN", ~D[2026-06-15])
      order("CMD-DEC", ~D[2026-12-01])
      :ok
    end

    test "range filter — 'the documents of the first half'" do
      results =
        search(%{query: "cmd"})
        |> Ash.Query.filter(document_date >= ^~D[2026-01-01] and document_date <= ^~D[2026-06-30])
        |> Ash.read!()

      assert Enum.map(results, & &1.label) |> Enum.sort() == ["CMD-JAN", "CMD-JUN"]
    end

    test "sort — 'most recent first', overriding relevance" do
      results =
        search(%{query: "cmd"})
        |> Ash.Query.unset([:sort])
        |> Ash.Query.sort(document_date: :desc)
        |> Ash.read!()

      assert Enum.map(results, & &1.label) == ["CMD-DEC", "CMD-JUN", "CMD-JAN"]
    end

    test "narrowing in SQL — the caller's own rule, on a content column" do
      # This is how an application keeps its access rule while letting Postgres do the
      # filtering: the lib stores a client reference (content), the app decides which
      # references this user may see.
      results =
        search(%{query: "cmd"})
        |> Ash.Query.filter(client_ref in ^["CLI-1"])
        |> Ash.read!(page: [limit: 10, count: true])

      assert results.count == 3
    end
  end

  describe "keeping them honest" do
    test "changing ONLY the source attribute re-indexes, with nothing else to trigger it" do
      # Product has no `extra_text` and no `load`, and an attribute-driven `archived`, so
      # `recompute?` cannot short-circuit — the re-index has to come from
      # `guarded_attributes` watching the index_attribute's source. `ref_interne` is in
      # neither `fields` nor `label_field`, so nothing else can explain a refresh.
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_products, test_search_documents", [])
      p = Domain.create_product!(%{name: "Vis", sku: "V1", ref_interne: "R-1"}, tenant: "a")
      assert [%{client_ref: "R-1"}] = rows()

      Domain.update_product!(p, %{ref_interne: "R-2"}, tenant: "a")

      assert [%{client_ref: "R-2"}] = rows()
    end

    test "changing ONLY the source attribute still re-indexes" do
      o = order("CMD-4", ~D[2026-06-15])
      assert [%{document_date: ~D[2026-06-15]}] = rows()

      # No searchable field, label or language changed — only the date.
      Domain.update_order!(o, %{date_emission: ~D[2026-07-01]}, tenant: "a")

      assert [%{document_date: ~D[2026-07-01]}] = rows()
    end

    test "archiving keeps the typed columns" do
      # Invoice: `on_destroy :archive` + `index_attribute :client_ref, :number`. The source
      # is gone by then, so the archived row must still carry what was indexed.
      invoice = Domain.create_invoice!(%{number: "F-ARCH"}, tenant: "a")
      Domain.destroy_invoice!(invoice, tenant: "a")

      assert [%{archived: true, client_ref: "F-ARCH", excerpt: "F-ARCH"}] = rows()
    end

    test "reindex/2 fills them for pre-existing rows" do
      o = order("CMD-5", ~D[2026-06-15], "CLI-9")
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_search_documents", [])

      SearchAsh.reindex(Order, tenant: "a")

      assert [%{document_date: ~D[2026-06-15], client_ref: "CLI-9", source_id: id}] = rows()
      assert id == o.id
    end
  end

  test "the generated upsert accepts the user-declared columns" do
    accept = SearchDocument |> Ash.Resource.Info.action(:upsert) |> Map.fetch!(:accept)

    for column <- [:document_date, :client_ref, :line_count, :label_normalized, :excerpt] do
      assert column in accept
    end

    # The tenant attribute is set from `tenant:`, never accepted as an attribute.
    refute :org_id in accept
    refute :id in accept
  end
end
