defmodule SearchAsh.Source do
  @moduledoc """
  Ash extension that mirrors a resource into a `SearchAsh.GlobalIndex` so it shows up in
  the unified global search.

      defmodule MyApp.Sales.BonDeCommande do
        use Ash.Resource,
          domain: MyApp.Sales,
          data_layer: AshPostgres.DataLayer,
          extensions: [SearchAsh.Source]

        searchable do
          index MyApp.Search.Document
          source_type :bon_de_commande
          fields [:numero, :client_nom, :description]
          language_attribute :language
          label_field :numero
          archived :deleted_at         # optional — truthy value marks the row archived
        end

        # ... attributes + create/update/destroy actions ...
      end

  The extension sets `require_atomic? false` on the update/destroy actions it augments
  (the sync stems through a NIF and can't run in an atomic SQL statement), so you don't
  set it yourself. Because the sync writes only to the *separate* index table (never to a
  source attribute), it is atomic-compatible: `Ash.bulk_create`/`bulk_update`/`bulk_destroy`
  keep the index in sync with no `strategy:` option required.

  On create/update it upserts a stemmed document into the index (tenant-aware). `archived`
  derives the index flag from a source attribute's truthiness (a boolean, or a
  `deleted_at` timestamp) or a `record -> boolean` function; `:global_search` hides
  archived rows by default. On destroy, `on_destroy` either removes the row (`:remove`,
  default) or keeps it archived (`:archive`, for AshArchival-style soft deletes).

  Backfill existing rows with `SearchAsh.reindex(MyApp.Sales.BonDeCommande)`.
  """

  @searchable %Spark.Dsl.Section{
    name: :searchable,
    describe: "Mirror this resource into a unified search index.",
    schema: [
      index: [
        type: {:spark, SearchAsh.GlobalIndex},
        required: true,
        doc: "The `SearchAsh.GlobalIndex` resource to feed."
      ],
      source_type: [
        type: {:or, [:atom, :string]},
        required: true,
        doc: "Tag identifying this resource's rows in the index (e.g. `:bon_de_commande`)."
      ],
      fields: [
        type: {:list, :atom},
        required: true,
        doc: "Attributes whose text is concatenated, stemmed and indexed."
      ],
      language_attribute: [
        type: :atom,
        default: :language,
        doc: "Attribute holding each row's language."
      ],
      label_field: [
        type: :atom,
        required: false,
        doc: "Attribute used as the human-readable label stored in the index."
      ],
      archived: [
        type: {:or, [:atom, {:fun, 1}]},
        required: false,
        doc:
          "How to derive the index `archived` flag (default `false` — always visible). " <>
            "Either an attribute name whose **truthiness** marks the row archived (works " <>
            "for a boolean flag or a `deleted_at` timestamp), or a 1-arity function " <>
            "`record -> boolean`. A function is called with the record as the action " <>
            "loads it, so it must only read attributes that are loaded — avoid " <>
            "`select_by_default? false` attributes unless you arrange to load them."
      ],
      on_destroy: [
        type: {:or, [{:literal, :remove}, {:literal, :archive}]},
        default: :remove,
        doc:
          "What to do with the index row when the source is destroyed: `:remove` (default, " <>
            "for hard delete) or `:archive` to keep it with `archived: true` (for a " <>
            "soft-delete via a destroy action, e.g. AshArchival)."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@searchable],
    transformers: [SearchAsh.Source.Transformers.AddSync]
end
