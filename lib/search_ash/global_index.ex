defmodule SearchAsh.GlobalIndex do
  @moduledoc """
  Ash extension that turns a resource into a **unified, cross-entity search index** — one
  row per indexed source object, searched with a single ranked query (Option B).

      defmodule MyApp.Search.Document do
        use Ash.Resource,
          domain: MyApp.Search,
          data_layer: AshPostgres.DataLayer,
          extensions: [SearchAsh.GlobalIndex]

        postgres do
          table "search_documents"
          repo MyApp.Repo
        end

        # Tenant-scope the index like any resource (optional):
        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        global_index do
          default_language :french
        end

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string, allow_nil?: false, public?: true
        end
      end

  It generates the index columns (`source_type`, `source_id`, `language`, `search_text`,
  `archived`, `label`), a `unique_source` identity, a GIN index, an `:upsert` action, a
  `:search_rank` calculation and a **`:global_search`** read action that filters + ranks
  (`ts_rank`, prefix-aware) and returns `(source_type, source_id, archived, label, rank)`.
  It hides `archived` rows by default; pass `include_archived?: true` to get both.

  Source resources feed it with the `SearchAsh.Source` extension. Existing data is
  backfilled with `SearchAsh.reindex/2`.
  """

  @global_index %Spark.Dsl.Section{
    name: :global_index,
    describe: "Configure this resource as a unified search index.",
    schema: [
      default_language: [
        type: :atom,
        default: :french,
        doc: "Language used to stem the query when `:global_search`'s language arg is omitted."
      ],
      search_text_attribute: [
        type: :atom,
        default: :search_text,
        doc: "Attribute holding the pre-stemmed tokens."
      ],
      action: [
        type: :atom,
        default: :global_search,
        doc: "Name of the generated read action."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@global_index],
    transformers: [
      SearchAsh.GlobalIndex.Transformers.AddSchema,
      SearchAsh.GlobalIndex.Transformers.AddActions
    ]
end
