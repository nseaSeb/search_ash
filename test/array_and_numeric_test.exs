defmodule SearchAsh.ArrayAndNumericTest do
  @moduledoc """
  Array attributes (tags) and numeric ones (amounts), on both paths — the searchable text
  and the typed index columns. They are complementary, not alternatives: `fields` makes a
  tag findable from the search box, `index_attribute` makes it filterable and countable.

  The array case had a silent corruption: `to_string/1` on a list takes the iodata path,
  so `["urgent", "vip"]` became `"urgentvip"`. Neither tag was findable and a junk token
  entered the index, with nothing to signal it. A list of *atoms* raised instead — which,
  being visible, was the lesser bug. Both are covered here.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Domain, Repo, SearchDocument}

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_products, test_search_documents", [])
    :ok
  end

  defp product(attrs), do: Domain.create_product!(attrs, tenant: "a")
  defp search(q), do: Domain.global_search!(q, :fr, tenant: "a") |> Enum.map(& &1.label)
  defp rows, do: Ash.read!(SearchDocument, tenant: "a", authorize?: false)

  describe "an array attribute in `fields`" do
    test "each member is indexed separately, not concatenated" do
      product(%{name: "Vis inox", sku: "V1", tags: ["urgent", "vip"]})

      # The corruption this guards against: joining without a separator produced the
      # single token "urgentvip", so neither of these searches found anything.
      assert search("urgent") == ["Vis inox"]
      assert search("vip") == ["Vis inox"]
      assert search("urgentvip") == []

      [row] = rows()
      assert row.search_text =~ "'urgent'"
      assert row.search_text =~ "'vip'"
      refute row.search_text =~ "urgentvip"
    end

    test "a member carrying punctuation stays intact" do
      # `["bl-2024", "urgent"]` used to concatenate to "bl-2024urgent", which tokenized
      # to ["bl", "2024urgent"] — a junk token that matched nothing real.
      product(%{name: "Bon", sku: "B1", tags: ["bl-2024", "urgent"]})

      assert search("2024") == ["Bon"]
      assert search("urgent") == ["Bon"]
      assert rows() |> hd() |> Map.fetch!(:search_text) =~ "'2024'"
    end

    test "an empty list and a nil contribute nothing and do not crash" do
      product(%{name: "Sans tags", sku: "S1", tags: []})
      product(%{name: "Nil tags", sku: "S2"})

      assert Enum.sort(search("tags")) == ["Nil tags", "Sans tags"]
    end
  end

  describe "an array `index_attribute`" do
    test "Ash casts the list into the index column, and `has/2` filters on it" do
      product(%{name: "Urgent A", sku: "A", tags: ["urgent", "vip"]})
      product(%{name: "Urgent B", sku: "B", tags: ["urgent"]})
      product(%{name: "Autre", sku: "C", tags: ["export"]})

      found =
        SearchDocument
        |> Ash.Query.for_read(:global_search, %{query: ""})
        |> Ash.Query.set_tenant("a")
        |> Ash.Query.filter(has(tags, "urgent"))
        |> Ash.read!()
        |> Enum.map(& &1.label)
        |> Enum.sort()

      assert found == ["Urgent A", "Urgent B"]
    end

    test "the two paths are complementary, not redundant" do
      # Same record: found by typing the tag, AND filterable by it.
      product(%{name: "Facture", sku: "F1", tags: ["urgent"]})

      assert search("urgent") == ["Facture"]

      filtered =
        SearchDocument
        |> Ash.Query.for_read(:global_search, %{query: ""})
        |> Ash.Query.set_tenant("a")
        |> Ash.Query.filter(has(tags, "urgent"))
        |> Ash.read!()

      assert length(filtered) == 1
    end
  end

  describe "a numeric `index_attribute`" do
    setup do
      product(%{name: "Petit", sku: "P", montant: Decimal.new("500")})
      product(%{name: "Moyen", sku: "M", montant: Decimal.new("1500")})
      product(%{name: "Gros", sku: "G", montant: Decimal.new("9000")})
      :ok
    end

    defp by_amount(filter_fun) do
      SearchDocument
      |> Ash.Query.for_read(:global_search, %{query: ""})
      |> Ash.Query.set_tenant("a")
      |> filter_fun.()
      |> Ash.read!()
      |> Enum.map(& &1.label)
    end

    test "range filter" do
      assert by_amount(&Ash.Query.filter(&1, montant > 1000)) |> Enum.sort() ==
               ["Gros", "Moyen"]

      assert by_amount(&Ash.Query.filter(&1, montant > 1000 and montant < 5000)) ==
               ["Moyen"]
    end

    test "sorting, biggest first" do
      sorted =
        SearchDocument
        |> Ash.Query.for_read(:global_search, %{query: ""})
        |> Ash.Query.set_tenant("a")
        |> Ash.Query.sort(montant: :desc_nils_last)
        |> Ash.read!()
        |> Enum.map(& &1.label)

      assert sorted == ["Gros", "Moyen", "Petit"]
    end
  end

  describe "SearchAsh.Text.indexable/1" do
    test "joins list members with a separator" do
      # Joining with no separator is exactly the bug: it would return "urgentvip".
      assert SearchAsh.Text.indexable(["urgent", "vip"]) == "urgent vip"
    end

    test "atoms in a list no longer raise" do
      assert SearchAsh.Text.indexable([:urgent, :vip]) == "urgent vip"
    end

    test "false indexes as nothing, as it did before this module existed" do
      # An accident of the old `to_string(value || "")` rather than a decision — but a
      # patch release should not change what a boolean field puts in the index.
      assert SearchAsh.Text.indexable(false) == ""
      assert SearchAsh.Text.indexable(true) == "true"
    end

    test "a map raises a directed error instead of a bare protocol error" do
      # Without the clause this is a `Protocol.UndefinedError` from inside the library,
      # raised in the source write's transaction, which rolls the caller's write back
      # with nothing naming the cause.
      assert_raise ArgumentError, ~r/cannot index a map.*extra_text/s, fn ->
        SearchAsh.Text.indexable(%{couleur: "rouge"})
      end

      # Structs that implement String.Chars stay fine.
      assert SearchAsh.Text.indexable(~D[2026-01-05]) == "2026-01-05"
      assert SearchAsh.Text.indexable(Decimal.new("12.50")) == "12.50"
    end

    test "scalars, nil and nested lists" do
      assert SearchAsh.Text.indexable("chat") == "chat"
      assert SearchAsh.Text.indexable(42) == "42"
      assert SearchAsh.Text.indexable(nil) == ""
      assert SearchAsh.Text.indexable([]) == ""
      assert SearchAsh.Text.indexable([["a", "b"], "c"]) == "a b c"
      assert SearchAsh.Text.indexable(["a", nil, "b"]) == "a  b"
    end
  end
end
