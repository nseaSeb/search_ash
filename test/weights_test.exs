defmodule SearchAsh.WeightsTest do
  @moduledoc """
  `weights` — per-field rank weights, so a hit in a reference or a title outranks the same
  hit in a body.

  The column stores a weighted tsvector **literal** built in Elixir (`SearchCore.weighted/3`);
  the SQL side casts it (`search_text::tsvector`) instead of calling `to_tsvector`, in the
  index, the filter and the rank alike — they must stay the same expression for the GIN
  index to be used.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Domain, Repo, SearchDocument}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_products, test_invoices, test_search_documents, test_articles",
      []
    )

    :ok
  end

  describe "what gets stored" do
    test "the column holds a weighted tsvector literal, not plain text" do
      Domain.create_product!(%{name: "Marteau", sku: "MRT-42"}, tenant: "a")

      [row] = Ash.read!(SearchDocument, tenant: "a", authorize?: false)
      # Product weights: sku :a, name :b. Positions run across the fields, in order.
      assert row.search_text == "'marteau':1B 'mrt':2A '42':3A"
    end

    test "Postgres accepts it and the lexemes round-trip" do
      Domain.create_product!(%{name: "Chevaux", sku: "CH-42"}, tenant: "a")

      %{rows: [[text]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT (search_text::tsvector)::text FROM test_search_documents",
          []
        )

      # Postgres re-orders lexemes alphabetically and keeps our weights.
      assert text == "'42':3A 'ch':2A 'cheval':1B"
    end

    test "a field left out of `weights` stays at the default weight" do
      # Invoice declares no weights at all, so nothing carries A/B/C.
      Domain.create_invoice!(%{number: "FA-001"}, tenant: "a")

      [row] = Ash.read!(SearchDocument, tenant: "a", authorize?: false)
      assert row.search_text == "'fa':1 '001':2"
      refute row.search_text =~ ~r/:\d+[ABC]/
    end
  end

  describe "what the weights do" do
    test "global index: the same term ranks higher in the heavier field" do
      # "alpha" sits in the :a-weighted sku for one product, in the :b-weighted name
      # for the other. Same term, same document length — only the weight differs.
      Domain.create_product!(%{name: "Zeta", sku: "alpha"}, tenant: "a")
      Domain.create_product!(%{name: "alpha", sku: "Zeta"}, tenant: "a")

      results = Domain.global_search!("alpha", :fr, tenant: "a")
      by_label = Map.new(results, &{&1.label, &1.search_rank})

      assert by_label["Zeta"] > by_label["alpha"],
             "the :a-weighted sku hit should outrank the :b-weighted name hit"
    end

    test "per-resource :search honours weights too" do
      Domain.create_article!(
        %{title: "Boulangerie", body: "rien", language: :fr},
        tenant: "a"
      )

      Domain.create_article!(
        %{title: "rien", body: "Boulangerie", language: :fr},
        tenant: "a"
      )

      [first, second] = Domain.search_articles!("boulangerie", :fr, tenant: "a")
      assert first.title == "Boulangerie"
      assert first.search_rank > second.search_rank
    end

    test "term frequency still counts within a weight class" do
      # Both labels sit in the same ranking tier (neither equals nor starts with the
      # term), so the comparison is on ts_rank alone — repetition wins.
      Domain.create_product!(%{name: "Boite vis vis vis", sku: "Z1"}, tenant: "a")
      Domain.create_product!(%{name: "Boite vis", sku: "Z2"}, tenant: "a")

      results = Domain.global_search!("vis", :fr, tenant: "a")
      assert Enum.map(results, & &1.label_match_tier) |> Enum.uniq() == [2]
      assert hd(results).label == "Boite vis vis vis"
    end
  end

  describe "extra_text carries its own class" do
    setup do
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_orders, test_order_lines", [])
      :ok
    end

    test "two derived contributions, two different weights" do
      # Order declares the lines at :d (body text) and the date in words at :b.
      o =
        Domain.create_order!(%{number: "CMD-1", date_emission: ~D[2026-07-21]}, tenant: "a")

      Domain.create_order_line!(%{order_id: o.id, description: "Tomates"}, tenant: "a")
      SearchAsh.reindex_one(SearchAsh.Test.Order, o.id, tenant: "a")

      [row] = Ash.read!(SearchDocument, tenant: "a", authorize?: false)

      # The line's word carries no class letter (:d); the date's words carry B.
      assert row.search_text =~ ~r/'tomat':\d+ /
      assert row.search_text =~ ~r/'juillet':\d+B/
    end

    test "the heavier contribution ranks above the lighter one" do
      a = Domain.create_order!(%{number: "CMD-A", date_emission: ~D[2026-07-21]}, tenant: "a")
      b = Domain.create_order!(%{number: "CMD-B"}, tenant: "a")

      # Same word in both documents: once as a :b-weighted date, once as a :d-weighted line.
      Domain.create_order_line!(%{order_id: b.id, description: "juillet"}, tenant: "a")
      for id <- [a.id, b.id], do: SearchAsh.reindex_one(SearchAsh.Test.Order, id, tenant: "a")

      by_label =
        Domain.global_search!("juillet", :fr, tenant: "a") |> Map.new(&{&1.label, &1.search_rank})

      assert by_label["CMD-A"] > by_label["CMD-B"]
    end
  end

  describe "weight_values — what a class is worth" do
    test "raising class :b closes the gap with :a" do
      # SearchDocument prices :b at 0.9 instead of Postgres' 0.4. Product weights put the
      # sku in :a and the name in :b, so the same term in either field now scores close.
      Domain.create_product!(%{name: "Zeta", sku: "alpha"}, tenant: "a")
      Domain.create_product!(%{name: "alpha", sku: "Zeta"}, tenant: "a")

      by_label =
        Domain.global_search!("alpha", :fr, tenant: "a") |> Map.new(&{&1.label, &1.search_rank})

      # :a still wins, but by a hair rather than by 2.5x — at Postgres' default the ratio
      # would be 0.6079 / 0.2432.
      assert by_label["Zeta"] > by_label["alpha"]
      assert by_label["alpha"] / by_label["Zeta"] > 0.85
    end

    test "unset classes keep Postgres' own values" do
      assert SearchAsh.Weights.to_array(%{}) == [0.1, 0.2, 0.4, 1.0]
      # {D, C, B, A} — ascending importance, the reverse of how anyone says it.
      assert SearchAsh.Weights.to_array(%{b: 0.9}) == [0.1, 0.2, 0.9, 1.0]
      assert SearchAsh.Weights.to_array(%{a: 0.5, d: 0.0}) == [0.0, 0.2, 0.4, 0.5]
    end
  end

  describe "the index still serves the query" do
    test "the GIN index is usable for the query the preparation builds" do
      # The invariant worth protecting is that the index expression and the query
      # expression still MATCH after the switch from `to_tsvector(...)` to a cast — not
      # which plan the planner happens to prefer at a given size. So ask the planner what
      # it would do if a sequential scan were off the table. `SET LOCAL` inside a
      # transaction: the pool would hand a separate `SET` to another connection.
      Domain.create_product!(%{name: "Aiguille", sku: "AIG"}, tenant: "a")

      {:ok, plan} =
        Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])

          %{rows: rows} =
            Ecto.Adapters.SQL.query!(
              Repo,
              "EXPLAIN SELECT id FROM test_search_documents " <>
                "WHERE search_text::tsvector @@ to_tsquery('simple', 'aiguill')",
              []
            )

          rows |> List.flatten() |> Enum.join("\n")
        end)

      assert plan =~ "test_search_documents_search_idx", plan
    end
  end
end
