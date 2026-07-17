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
          default_language :fr
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

  ## Authorization: the tenant is the boundary, and nothing finer

  An index row holds only the columns listed above plus your tenant attribute — there is
  no way to carry an `owner_id`, a team, or a visibility flag into it. `:global_search`
  filters on the tenant, `archived` and the tsvector match; it **does not consult the
  source resource's policies or the actor**.

  That fits a SaaS where every user of a tenant may see everything in it. It does **not**
  fit per-user or per-team visibility inside a tenant: a user would see the `label` of
  rows they cannot read. Post-filtering against the sources breaks ranking and pagination
  (you would filter *after* ranking, so a page can come back empty) — the standard
  denormalized-index problem. Until `extra_attrs` lands (roadmap), per-resource
  `SearchAsh` (`search do … end`) is the honest option there: it queries the source table
  itself, so your policies apply.
  """

  @global_index %Spark.Dsl.Section{
    name: :global_index,
    describe: "Configure this resource as a unified search index.",
    schema: [
      default_language: [
        type: :atom,
        default: :fr,
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
