defmodule SearchAsh.PostgresSearchTest do
  @moduledoc """
  Integration tests for the generated `:search` action against real Postgres tsvector.
  Locks the extension's behaviour independently of any example app.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Article, Domain, Repo}

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_articles", [])
    :ok
  end

  defp create(attrs, tenant), do: Domain.create_article!(attrs, tenant: tenant)

  defp search(query, tenant, lang \\ :french),
    do: Domain.search_articles!(query, lang, tenant: tenant)

  test "create indexes the row; a stemmed query finds it" do
    create(%{title: "Les chevaux", body: "ils mangent", language: :french}, "a")
    assert [%{title: "Les chevaux"}] = search("chevaux", "a")
  end

  test "tenant isolation — a query only returns the caller's rows" do
    create(%{title: "A", body: "cheval", language: :french}, "a")
    create(%{title: "B", body: "cheval", language: :french}, "b")

    assert [%{title: "A"}] = search("cheval", "a")
    assert [%{title: "B"}] = search("cheval", "b")
  end

  test "results are ranked by relevance and expose :search_rank" do
    create(%{title: "cheval cheval cheval", body: "cheval", language: :french}, "a")
    create(%{title: "cheval", body: "autre", language: :french}, "a")

    results = search("cheval", "a")
    assert hd(results).title == "cheval cheval cheval"
    assert results == Enum.sort_by(results, & &1.search_rank, :desc)
    assert is_float(hd(results).search_rank)
  end

  test "prefix — a partial word matches" do
    create(%{title: "Boulangerie", body: "pain", language: :french}, "a")
    assert [%{title: "Boulangerie"}] = search("boulan", "a")
  end

  test "blank and too-short queries list all (no crash)" do
    create(%{title: "X", body: "y", language: :french}, "a")
    create(%{title: "Z", body: "w", language: :french}, "a")

    assert length(search("", "a")) == 2
    assert length(search("b", "a")) == 2
  end

  test "a query in the wrong language does not match" do
    create(%{title: "Chevaux", body: "chevaux", language: :french}, "a")
    assert [] = search("running", "a", :english)
  end

  test "update re-syncs the index" do
    article = create(%{title: "Boulangerie", body: "pain", language: :french}, "a")
    assert [_] = search("boulan", "a")

    Domain.update_article!(article, %{title: "Cordonnerie"}, tenant: "a")

    assert [] = search("boulan", "a")
    assert [%{title: "Cordonnerie"}] = search("cordon", "a")
  end

  test "update with a narrowed select does not wipe unloaded fields from the index" do
    article = create(%{title: "Chevaux", body: "galop", language: :french}, "a")
    assert [_] = search("galop", "a")

    # Reload the record WITHOUT body, then update the title. The sync must not recompute
    # search_text from the (unloaded) body and drop "galop" from the index.
    partial =
      Article
      |> Ash.Query.select([:id, :title, :language, :org_id])
      |> Ash.Query.filter(id == ^article.id)
      |> Ash.read_one!(tenant: "a")

    Domain.update_article!(partial, %{title: "Cheval"}, tenant: "a")

    assert [_] = search("galop", "a")
  end

  test "an unsupported language falls back to the default instead of crashing" do
    create(%{title: "chevaux", body: "x", language: :french}, "a")
    # :klingon is not a Stemmers language → normalized to the default (:french).
    assert [%{title: "chevaux"}] = search("chevaux", "a", :klingon)
  end

  test "a blank query is unranked and does not load :search_rank" do
    create(%{title: "x", body: "y", language: :french}, "a")
    [row] = search("", "a")
    assert match?(%Ash.NotLoaded{}, row.search_rank)
  end

  test "a real query loads :search_rank as a float" do
    create(%{title: "cheval", body: "cheval", language: :french}, "a")
    [row] = search("cheval", "a")
    assert is_float(row.search_rank)
  end
end
