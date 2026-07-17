defmodule SearchAsh.StaticLanguageTest do
  @moduledoc """
  A source resource with no `:language` attribute, using `language :french` in the
  `searchable` block. Before the static option existed, `language` resolved to `nil`,
  which failed the index's `allow_nil?: false` inside the sync's after_action and rolled
  back the whole source write — so every create on such a resource was impossible.
  """
  use ExUnit.Case, async: false

  alias SearchAsh.Test.{Domain, Repo, SearchDocument, StaticPage}
  alias SearchAsh.Source.Info

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_static_pages, test_search_documents", [])
    :ok
  end

  defp create(attrs, tenant \\ "a"), do: Domain.create_static_page!(attrs, tenant: tenant)

  defp indexed_row(tenant \\ "a") do
    SearchDocument
    |> Ash.read!(tenant: tenant)
    |> List.first()
  end

  test "create succeeds on a resource that has no :language attribute" do
    page = create(%{title: "Les chevaux", body: "ils mangent"})

    assert page.title == "Les chevaux"
    refute Map.has_key?(page, :language)
    assert Repo.aggregate(SearchDocument, :count) == 1
  end

  test "the indexed row carries the static language and a stemmed, non-empty search_text" do
    create(%{title: "Les chevaux", body: "ils mangent"})

    row = indexed_row()
    # Canonical ISO, not the `:french` spelling used in the DSL: the index is
    # single-vocabulary so consumers filtering `language` have one form to match.
    assert row.language == :fr
    assert row.source_type == "static_page"
    assert row.label == "Les chevaux"

    # Stemmed, not merely copied: "chevaux" is stored under its stem.
    assert row.search_text != ""
    assert row.search_text =~ "cheval"
    refute row.search_text =~ "chevaux"
  end

  test "the statically-stemmed row is findable through global search" do
    create(%{title: "Boulangerie", body: "pain frais"})

    assert [%{label: "Boulangerie"}] = Domain.global_search!("boulan", :french, tenant: "a")
  end

  test "update re-indexes without needing a language attribute" do
    page = create(%{title: "Les chevaux", body: "x"})
    Domain.update_static_page!(page, %{title: "Les oiseaux"})

    row = indexed_row()
    assert row.language == :fr
    assert row.search_text =~ "oiseau"
    assert Repo.aggregate(SearchDocument, :count) == 1
  end

  test "reindex/2 backfills a static-language resource" do
    create(%{title: "Les chevaux", body: "x"})
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_search_documents", [])
    assert Repo.aggregate(SearchDocument, :count) == 0

    SearchAsh.reindex(StaticPage, tenant: "a")

    assert Repo.aggregate(SearchDocument, :count) == 1
    assert indexed_row().language == :fr
  end

  describe "Info" do
    test "exposes the static language, and nil for an attribute-driven resource" do
      assert Info.language(StaticPage) == :fr
      assert Info.language(SearchAsh.Test.Product) == nil
    end

    test "language_attribute still defaults to :language for attribute-driven resources" do
      assert Info.language_attribute(SearchAsh.Test.Product) == :language
    end
  end

  describe "Document.resolve_language/2" do
    test "prefers the static language over anything on the record" do
      # Even a stray :language key on the record must not win.
      assert SearchAsh.Source.Document.resolve_language(StaticPage, %{language: :en}) == :fr
    end

    test "reads the attribute when no static language is set" do
      assert SearchAsh.Source.Document.resolve_language(SearchAsh.Test.Product, %{
               language: :en
             }) == :en
    end

    test "is nil when the record resolves to no usable language" do
      refute SearchAsh.Source.Document.resolve_language(SearchAsh.Test.Product, %{language: nil})

      refute SearchAsh.Source.Document.resolve_language(SearchAsh.Test.Product, %{
               language: :klingon
             })

      # An English name is now just another unknown atom.
      refute SearchAsh.Source.Document.resolve_language(SearchAsh.Test.Product, %{
               language: :french
             })
    end
  end

  describe "an unresolvable language fails loudly, not opaquely" do
    test "nil language names the resource, the attribute and the way out" do
      error =
        assert_raise ArgumentError, fn ->
          SearchAsh.Source.Document.to_attrs(SearchAsh.Test.Product, %{
            id: "1",
            name: "Vis",
            sku: "V",
            language: nil
          })
        end

      assert error.message =~ "cannot index SearchAsh.Test.Product"
      assert error.message =~ ":language attribute is nil"
      assert error.message =~ "language :fr"
    end

    test "an unsupported language names the offending value" do
      error =
        assert_raise ArgumentError, fn ->
          SearchAsh.Source.Document.to_attrs(SearchAsh.Test.Product, %{
            id: "1",
            name: "Vis",
            sku: "V",
            language: :klingon
          })
        end

      # Names the value *and* where it came from.
      assert error.message =~ ":klingon (from :language) is not a supported language"
    end
  end

  describe "the failure message fits the resource it is about" do
    test "a static-language resource is not told to fix an attribute it does not have" do
      message = SearchAsh.Source.Document.no_language_message(StaticPage, %{title: "x"})

      assert message =~ "`language :fr` is not a supported language"
      assert message =~ "no language attribute to change"

      # It must not send the reader after a column this resource does not have, nor tell
      # them to write the very option that just failed.
      refute message =~ "allow_nil?"
      refute message =~ "attribute is nil"
      refute message =~ "drop the attribute"
    end

    test "an attribute-driven resource still gets the attribute advice" do
      message =
        SearchAsh.Source.Document.no_language_message(SearchAsh.Test.Product, %{language: nil})

      assert message =~ ":language attribute is nil"
      assert message =~ "allow_nil?: false"
      assert message =~ "fix it statically"
    end
  end

  describe "loaded?/2" do
    test "does not require a language attribute when the language is static" do
      assert SearchAsh.Source.Document.loaded?(StaticPage, %{title: "a", body: "b"})
    end
  end
end
