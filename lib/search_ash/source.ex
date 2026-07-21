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

  ## Text from related records (`load` + `extra_text`)

  `fields` reads attributes of the record itself. To index text that lives on *related*
  records — "which orders mention tomatoes?" — combine `load` (an Ash load statement run
  before the document is built) with `extra_text` (a function deriving text from the
  loaded record):

      searchable do
        index MyApp.Search.Document
        source_type :commande
        fields [:numero]
        label_field :numero
        load [:lignes]
        extra_text fn commande -> Enum.map(commande.lignes, & &1.designation) end
      end

  `extra_text` is **repeatable, and each entry carries its own rank class** (`:d` by
  default, as body text). That is how two things you derive can matter differently:

      extra_text fn commande -> Enum.map(commande.lignes, & &1.designation) end
      extra_text &date_in_words(&1.updated_at), weight: :b
      extra_text &date_in_words(&1.inserted_at), weight: :c

  A date spelled out is just more text — the same pipeline stems both sides, so a search
  box query like `juillet` finds it, with no support needed from the extension. Keep it
  next to a typed `index_attribute` for the same date: one serves the search box, the
  other range filters and sorting.

  The load runs at the single indexing choke point, so every path gets it: the sync on
  writes, `SearchAsh.reindex/2`, `SearchAsh.reindex_one/3`. Because the extension cannot
  tell what `extra_text` reads, every update of the resource re-indexes it (no
  changed-field short-circuit).

  **The staleness contract.** The sync fires on writes to *this* resource. A direct write
  to the related resource — editing a line without touching its order — changes what
  `extra_text` *would* return, but nothing observable happened on the order, so its index
  row keeps the old text. This is the same class of gap as "Writes that bypass Ash" below,
  with the same remedies: call `SearchAsh.reindex_one/3` on the parent after such a write,
  or add a change on the related resource that touches its parent. The staleness is
  cosmetic (a search misses or over-matches until reconciled) — which is exactly why this
  exists for *content* and must never be used to mirror authorization data into the index.

  ## Filtering and sorting: `index_attribute`

  `fields` decides what is *searched*. `index_attribute` decides what can be **filtered and
  sorted on**: a date, a reference, an amount, a foreign key. Declare the column on the
  index resource (a source cannot add a column to a resource it does not own), then say
  here how to fill it:

      index_attribute :document_date, :date_emission              # from an attribute
      index_attribute :montant, &(&1.lignes |> Enum.map(fn l -> l.total end) |> Enum.sum())

  An attribute name is worth preferring: the sync then knows to re-index when *only* that
  attribute changes. A function is opaque, so every write rebuilds the document.

  These columns are ordinary Ash attributes on the index, so nothing new is needed to use
  them:

      |> Ash.Query.filter(document_date >= ^from and document_date <= ^to)
      |> Ash.Query.sort(document_date: :desc)

  ### Many dates, one axis

  A business document has several dates — issued, delivered, due, created — and each entity
  type names them differently. Resist giving each its own index column: what a *results
  page* needs is one **comparable** axis, so "most recent first" means something across
  mixed entity types.

  So point every source at the same column, from whatever attribute means "the date this
  document is from" for it:

      # facture
      index_attribute :document_date, :date_emission

      # bon de livraison
      index_attribute :document_date, :date_livraison

      # produit — no business date of its own
      index_attribute :document_date, &DateTime.to_date(&1.inserted_at)

  Add a *second* column only when you genuinely filter on a second axis (an invoice due
  date, say) — and expect it to be `NULL` for the source types that have no such date,
  which is also how they sort.

  ### Only what is derived from the record

  These columns are rewritten on every sync, which is exactly what keeps them honest.
  That also marks their limit: **never mirror an authorization fact here.** "This document
  belongs to client 42" is content and re-syncs with the document; "user 7 may read this"
  changes on its own, nothing triggers a re-index, and a stale row of that kind is a
  security incident rather than a cosmetic one. Filter on the content column and keep the
  rule in your application.

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

  @index_attribute %Spark.Dsl.Entity{
    name: :index_attribute,
    describe: """
    Fill one extra column of the index from this record, so you can **filter and sort**
    on it (a date, a reference, an amount, a foreign key).

    The column must exist on the index resource — declare it there as a normal Ash
    attribute. Several sources should map their own attribute onto the **same** column
    when it means the same thing (every entity type's "document date"), so a results page
    has one comparable axis to sort on.

    Only values **derived from the record** belong here: they are rewritten on every
    write, so they cannot go stale. Never mirror authorization facts — see "Filtering and
    sorting" in `SearchAsh.Source`.
    """,
    examples: [
      """
      index_attribute :document_date, :date_emission
      index_attribute :montant, &(&1.lignes |> Enum.map(fn l -> l.total end) |> Enum.sum())
      """
    ],
    target: SearchAsh.Source.IndexAttribute,
    args: [:name, :source],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The index attribute to fill. Must exist on the index resource."
      ],
      source: [
        type: {:or, [:atom, {:fun, 1}]},
        required: true,
        doc:
          "Where the value comes from: an attribute name of this resource, or a " <>
            "`record -> value` function. An attribute name lets the sync re-index when " <>
            "only that attribute changes; a function is opaque, so every write re-indexes."
      ]
    ]
  }

  @extra_text %Spark.Dsl.Entity{
    name: :extra_text,
    describe: """
    Append text derived from the record to what gets searched — typically from relations
    made available by `load`, or a value spelled out so a search box can find it.

    Repeatable, and each entry carries its own rank class, so a date you consider
    important can outweigh one you do not.
    """,
    examples: [
      """
      extra_text &Enum.map(&1.lignes, fn l -> l.designation end)
      extra_text &date_in_words(&1.updated_at), weight: :b
      """
    ],
    target: SearchAsh.Source.ExtraText,
    args: [:source],
    schema: [
      source: [
        type: {:fun, 1},
        required: true,
        doc: "A `record -> String.t() | [String.t()]` function, run after `load`."
      ],
      weight: [
        type: {:in, [:a, :b, :c, :d]},
        default: :d,
        doc:
          "Rank class for these words, as in `weights`. `:d` by default — derived text " <>
            "is usually body text, and can span many related records."
      ]
    ]
  }

  @searchable %Spark.Dsl.Section{
    name: :searchable,
    describe: "Mirror this resource into a unified search index.",
    entities: [@index_attribute, @extra_text],
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
      weights: [
        type: {:map, :atom, {:in, [:a, :b, :c, :d]}},
        default: %{},
        doc:
          "How much each field counts towards the rank: `%{numero: :a, description: :c}`. " <>
            "`:a` is the strongest, `:d` (the default for any field left out) the weakest — " <>
            "so a hit in a reference outranks the same hit in a body. Text from " <>
            "`extra_text` always weighs `:d`."
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
      load: [
        type: :any,
        required: false,
        doc:
          "An Ash load statement (relationships, calculations, aggregates) applied to the " <>
            "record before the document is built — so `extra_text` can read them. Loaded " <>
            "with `authorize?: false`, inside the source write's transaction."
      ],
      excerpt_length: [
        type: :pos_integer,
        required: false,
        doc:
          "When set, store the first N characters of the raw (unstemmed) searchable text " <>
            "in the index's `excerpt` column, for display on a results page (truncated on " <>
            "a word boundary, `…`-suffixed). Off by default — an excerpt exposes *content* " <>
            "to whoever can search the index."
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
    verifiers: [
      SearchAsh.Source.Verifiers.VerifyLanguage,
      SearchAsh.Source.Verifiers.VerifyFuzzyLabel
    ]
end
