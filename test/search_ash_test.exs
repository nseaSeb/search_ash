defmodule SearchAshTest do
  use ExUnit.Case, async: true

  # A resource using the extension on a non-Postgres data layer, so we can assert the
  # generated entities without a database. (End-to-end Postgres behaviour — the GIN
  # index, migration round-trip and tsvector search — is covered by examples/blog.)
  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false
    resources(do: resource(SearchAshTest.Article))
  end

  defmodule Article do
    use Ash.Resource,
      domain: SearchAshTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [SearchAsh]

    search do
      fields [:title, :body]
      language_attribute :language
    end

    actions do
      defaults([:read])

      create :create do
        accept([:title, :body, :language])
      end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:body, :string, public?: true)

      attribute(:language, :atom,
        public?: true,
        constraints: [one_of: [:fr, :en]]
      )
    end
  end

  test "generates the search_text attribute" do
    attr = Ash.Resource.Info.attribute(Article, :search_text)
    assert attr
    assert attr.type == Ash.Type.String
  end

  test "generates the :search read action with query and language arguments" do
    action = Ash.Resource.Info.action(Article, :search)
    assert action.type == :read
    argument_names = Enum.map(action.arguments, & &1.name)
    assert :query in argument_names
    assert :language in argument_names
  end

  test "adds the keep-in-sync global change" do
    change_modules =
      Article
      |> Ash.Resource.Info.changes()
      |> Enum.map(fn
        %{change: {module, _opts}} -> module
        _ -> nil
      end)

    assert SearchAsh.Changes.SyncSearchText in change_modules
  end

  test "SearchAsh.Info reads the configuration" do
    assert SearchAsh.Info.fields(Article) == [:title, :body]
    assert SearchAsh.Info.language_attribute(Article) == :language
    assert SearchAsh.Info.search_text_attribute(Article) == :search_text
    assert SearchAsh.Info.action(Article) == :search
  end

  test "the sync change stems fields into search_text on create" do
    {:ok, article} =
      Article
      |> Ash.Changeset.for_create(:create, %{
        title: "Les chevaux",
        body: "qui mangent",
        language: :fr
      })
      |> Ash.create()

    # "chevaux" -> stem "cheval"; both title and body stemmed & folded.
    assert article.search_text =~ "cheval"
    refute article.search_text =~ "chevaux"
  end

  test "a conflicting :search_rank calculation (with rank? on) raises a clear DSL error" do
    assert_raise Spark.Error.DslError, ~r/search_rank/, fn ->
      defmodule Conflicting do
        use Ash.Resource,
          domain: SearchAshTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [SearchAsh]

        search do
          fields [:title]
        end

        calculations do
          calculate(:search_rank, :float, expr(1.0))
        end

        actions do
          defaults([:read])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, public?: true)
          attribute(:language, :atom, public?: true, constraints: [one_of: [:fr]])
        end
      end
    end
  end
end
