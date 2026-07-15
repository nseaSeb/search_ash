defmodule SearchAsh do
  @moduledoc """
  An Ash extension that adds multilingual full-text search to a resource with one
  `search do … end` block.

      defmodule MyApp.Post do
        use Ash.Resource,
          domain: MyApp.Blog,
          data_layer: AshPostgres.DataLayer,
          extensions: [SearchAsh]

        search do
          fields [:title, :body]
          language_attribute :language
        end

        # ... attributes :title, :body, :language ...
      end

  From that block the extension generates, at compile time:

    * a `:search_text` string attribute (unless you defined one), holding the
      stemmed tokens;
    * a global change that keeps `:search_text` in sync on create/update, stemming
      each row in its own language via `SearchCore` (the `stemmers` Rust NIF);
    * a GIN expression index `to_tsvector('simple', search_text)` on the Postgres
      table — emitted into your migrations and tracked in the resource snapshot, so
      `mix ash_postgres.generate_migrations` round-trips it cleanly;
    * a `:search` read action taking `query` and `language` arguments, filtering on
      the tsvector with a tsquery built from the *same* pipeline (so a search for
      "chevaux" matches a row that stored "cheval").

  Stemming happens in Elixir, so the Postgres side always uses the `'simple'`
  configuration.
  """

  @search %Spark.Dsl.Section{
    name: :search,
    describe: "Configure multilingual full-text search for this resource.",
    examples: [
      """
      search do
        fields [:title, :body]
        language_attribute :language
      end
      """
    ],
    schema: [
      fields: [
        type: {:list, :atom},
        required: true,
        doc: "Attributes whose text is concatenated and indexed for search."
      ],
      language_attribute: [
        type: :atom,
        default: :language,
        doc: "Attribute holding each row's language (a `Stemmers` language atom)."
      ],
      search_text_attribute: [
        type: :atom,
        default: :search_text,
        doc: "Attribute the stemmed tokens are stored in (added automatically if absent)."
      ],
      index_name: [
        type: :string,
        required: false,
        doc: "Name of the generated GIN index. Defaults to `#{"\#{table}"}_search_idx`."
      ],
      action: [
        type: :atom,
        default: :search,
        doc: "Name of the generated read action."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@search],
    transformers: [
      SearchAsh.Transformers.AddSearchTextAttribute,
      SearchAsh.Transformers.AddSyncChange,
      SearchAsh.Transformers.AddSearchAction,
      SearchAsh.Transformers.AddSearchIndex
    ]
end
