defmodule SearchAsh.FuzzySearchTest do
  @moduledoc """
  `fuzzy? true`: `:global_search` also matches the folded label by trigram similarity
  (typos) and substring (partial references), against real Postgres + pg_trgm.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Domain, FuzzyDocument, Repo}

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_contacts, test_fuzzy_documents", [])
    :ok
  end

  # FuzzyDocument sets `default_limit 5`, so the action paginates by default and hands
  # back an `Ash.Page.Offset`. Unwrap it here; `describe "the default limit"` below pins
  # the page itself.
  defp fsearch(query), do: Domain.fuzzy_search!(query, :fr).results

  test "the DSL adds the trigram index alongside the tsvector one" do
    names =
      FuzzyDocument
      |> AshPostgres.DataLayer.Info.custom_indexes()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == ["test_fuzzy_documents_label_trgm_idx", "test_fuzzy_documents_search_idx"]
  end

  test "typo tolerance: duont finds Dupont" do
    Domain.create_contact!(%{name: "Dupont", ref: "CLI-001"})
    Domain.create_contact!(%{name: "Martin", ref: "CLI-002"})

    # similarity("duont", "dupont") = 0.44, above the 0.35 threshold.
    assert [%{label: "Dupont"}] = fsearch("duont")
  end

  test "fuzzy_threshold keeps a look-alike reference out of an exact search" do
    Domain.create_contact!(%{name: "BL-2024-0012", ref: "bon"})
    Domain.create_contact!(%{name: "FA-2024-0113", ref: "bon"})

    # similarity between the two references is 0.30 — under the threshold, so searching
    # one no longer drags the other back. (At the database's own 0.3 floor it would.)
    assert ["BL-2024-0012"] = fsearch("bl-2024-0012") |> Enum.map(& &1.label)
  end

  test "substring on a reference: 0012 finds BL-2024-0012" do
    Domain.create_contact!(%{name: "BL-2024-0012", ref: "bon"})
    Domain.create_contact!(%{name: "BL-2024-0777", ref: "bon"})

    assert [%{label: "BL-2024-0012"}] = fsearch("0012")
  end

  test "accents fold on both sides: maraicher fuzzy-finds Maraîchère" do
    Domain.create_contact!(%{name: "Maraîchère du coin", ref: "M1"})

    assert [%{label: "Maraîchère du coin"}] = fsearch("maraichere")
  end

  test "FTS matches rank above fuzzy-only matches" do
    # "Dupont" is an exact FTS + label match; "Dupond" only matches by trigram.
    Domain.create_contact!(%{name: "Dupond", ref: "C1"})
    Domain.create_contact!(%{name: "Dupont", ref: "C2"})

    assert ["Dupont", "Dupond"] = fsearch("dupont") |> Enum.map(& &1.label)
  end

  test "LIKE metacharacters in the query are literals, not wildcards" do
    Domain.create_contact!(%{name: "Dupont", ref: "C1"})

    # "upont" reaches Dupont through the substring channel…
    assert [%{label: "Dupont"}] = fsearch("upont")

    # …but "up_nt" must not: an unescaped underscore would read as "any character"
    # and `up_nt` would LIKE-match `upont`. Escaped, it is a literal and matches nothing.
    assert fsearch("up_nt") == []
  end

  describe "the substring branch is bounded by a minimum length" do
    # Ungated, `LIKE '%vi%'` matched 66% of a 20k-row table in a sequential scan —
    # pg_trgm cannot index a pattern shorter than one trigram. Short queries were where
    # fuzzy? was noisiest *and* slowest at once.

    test "a 2-character term no longer sweeps every label containing those letters" do
      Domain.create_contact!(%{name: "Service après-vente", ref: "S1"})
      Domain.create_contact!(%{name: "Avis client", ref: "A1"})
      Domain.create_contact!(%{name: "Vidange moteur", ref: "V1"})

      # None of these three is a *word* starting with "vi" — they only contain it.
      assert fsearch("vi") |> Enum.map(& &1.label) == ["Vidange moteur"]
    end

    test "…but the term still matches as a prefix, so it is not made sterile" do
      # The gate drops the substring branch only. FTS prefix matching is untouched,
      # so a short query keeps finding words that begin with it.
      Domain.create_contact!(%{name: "Vidange moteur", ref: "V1"})
      Domain.create_contact!(%{name: "Service après-vente", ref: "S1"})

      assert [%{label: "Vidange moteur"}] = fsearch("vi")
    end

    test "3 characters — the trigram boundary — still matches by substring" do
      Domain.create_contact!(%{name: "Service après-vente", ref: "S1"})

      # "vic" begins no word in the label; only the substring branch can reach it.
      assert [%{label: "Service après-vente"}] = fsearch("vic")
    end

    test "a short reference fragment: 001 reaches BL-2024-0012, 12 does not" do
      Domain.create_contact!(%{name: "BL-2024-0012", ref: "bon"})

      assert [%{label: "BL-2024-0012"}] = fsearch("001")
      assert fsearch("12") == []
    end
  end

  test "a tokenless query returns nothing, even with fuzzy on" do
    Domain.create_contact!(%{name: "Dupont de la Vega", ref: "C1"})

    assert fsearch("de") == []
  end

  test "without fuzzy?, the same typo finds nothing (opt-in stays opt-in)" do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_products, test_search_documents", [])
    Domain.create_product!(%{name: "Dupont", sku: "D1"}, tenant: "a")

    assert Domain.global_search!("duont", :fr, tenant: "a") == []
  end

  describe "the default limit" do
    setup do
      for i <- 1..12, do: Domain.create_contact!(%{name: "Client #{i}", ref: "C#{i}"})
      :ok
    end

    test "a caller who asks for no page gets a bounded one, not the whole index" do
      page = Domain.fuzzy_search!("client", :fr)

      assert %Ash.Page.Offset{} = page
      # FuzzyDocument: `default_limit 5`.
      assert length(page.results) == 5
      assert page.more?
    end

    test "the caller's own limit still wins" do
      page = Domain.fuzzy_search!("client", :fr, page: [limit: 3, count: true])

      assert length(page.results) == 3
      assert page.count == 12
    end
  end
end
