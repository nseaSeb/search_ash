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

  ## Choosing the language

  Each indexed row is stemmed in one language, resolved one of two ways — pick whichever
  fits the resource:

    * `language_attribute :language` (the default) reads the language **per row** from
      that attribute, so one resource can hold rows in many languages.
    * `language :fr` fixes **one** language for every row of the resource. Use it for
      a mono-language resource, which then needs no language attribute at all.

  The two are mutually exclusive, and setting neither is only valid when the resource
  actually has a `:language` attribute — a compile-time verifier enforces both rules.

      searchable do
        index MyApp.Search.Document
        source_type :page_statique
        fields [:titre, :corps]
        language :fr                 # no :language attribute on this resource
      end

  The extension sets `require_atomic? false` on the update/destroy actions it augments
  (stemming happens in Elixir, so the sync can't be expressed as an atomic SQL statement),
  so you don't
  set it yourself. Because the sync writes only to the *separate* index table (never to a
  source attribute), it is atomic-compatible: `Ash.bulk_create`/`bulk_update`/`bulk_destroy`
  keep the index in sync with no `strategy:` option required.

  On create/update it upserts a stemmed document into the index (tenant-aware). `archived`
  derives the index flag from a source attribute's truthiness (a boolean, or a
  `deleted_at` timestamp) or a `record -> boolean` function; `:global_search` hides
  archived rows by default. On destroy, `on_destroy` either removes the row (`:remove`,
  default) or keeps it archived (`:archive`, for AshArchival-style soft deletes).

  Backfill existing rows with `SearchAsh.reindex(MyApp.Sales.BonDeCommande)`.

  ## Writes that bypass Ash

  The sync above is a `Ash.Resource.Change`, so it only runs when Ash builds a changeset. A
  write that goes straight to the database — a raw `Repo.query!`, a SQL cascade updating a
  denormalized column across rows, a restore — never reaches it, and the index silently keeps
  the old document. Reconcile the affected records afterwards with `SearchAsh.reindex_one/3`,
  which re-reads each one and works out whether to re-index or remove it — or sweep a whole
  source for index rows whose record is gone with `SearchAsh.prune/2`.

  ## Composite primary keys

  A row is identified in the index by its `source_id`, built by joining the primary key parts
  with `":"`. With a single-column key (the usual case — a `uuid_primary_key`) this is exact.
  With a **composite key of two or more string columns**, the join is ambiguous: `{"a:b", "c"}`
  and `{"a", "b:c"}` both render `"a:b:c"` and would share one index row, one masking the
  other. Integer parts, or a single-column key, cannot collide. If you index a resource whose
  primary key is several string columns and those values may themselves contain `":"`, that is
  a limitation to be aware of — it does not affect single-column or integer keys.
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
      language: [
        type: :atom,
        required: false,
        doc:
          "A single language for **every** row of this resource, e.g. `language :fr`. " <>
            "Use this for a mono-language resource that has no language attribute. " <>
            "An ISO 639-1 code — see `SearchCore.Language`. Mutually exclusive with " <>
            "`language_attribute`."
      ],
      # No `default:` here on purpose: the default is applied by
      # `SearchAsh.Source.Info.language_attribute/1` when read, which leaves the DSL state
      # able to tell "explicitly set to :language" apart from "not set at all" — that is
      # what makes the `language` / `language_attribute` exclusivity check possible.
      language_attribute: [
        type: :atom,
        required: false,
        doc:
          "Attribute holding each row's language (default `:language`). Mutually " <>
            "exclusive with `language`."
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
    transformers: [SearchAsh.Source.Transformers.AddSync],
    verifiers: [SearchAsh.Source.Verifiers.VerifyLanguage]
end
