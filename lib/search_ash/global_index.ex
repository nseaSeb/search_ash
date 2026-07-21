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
  `archived`, `label`, `label_normalized`, `excerpt`), a `unique_source` identity, a GIN
  index, an `:upsert` action, the `:search_rank` and `:label_match_tier` calculations and
  a **`:global_search`** read action that filters and ranks: label exact > starts-with >
  contains > body match, then `ts_rank` (prefix-aware), then primary key. It hides
  `archived` rows by default (`include_archived?: true` shows both), restricts to the
  `types` you pass (`types: [:facture]` — `nil`/`[]` mean no filter), and paginates
  (`page: [limit: 20, offset: 0, count: true]`; offset and keyset, never required). A
  non-blank query whose tokens are all eliminated (`"de"`) returns nothing; only a
  blank/absent query lists everything. Per-type totals for tab badges come from
  `SearchAsh.counts_by_type/3`.

  ## Typo tolerance (`fuzzy?`)

  `fuzzy? true` additionally matches the *normalized label* by trigram similarity and
  substring — `duont` finds `Dupont`, `12` finds `BL-2024-0012` — served by one trigram
  GIN index, with fuzzy-only matches ranking behind full-text ones. It is opt-in because
  it needs the `pg_trgm` extension: add `"pg_trgm"` to your repo's
  `installed_extensions` before generating migrations. Without the option nothing
  requires the extension.

  `fuzzy_threshold` (default `0.35`) is how similar a label has to be. The default comes
  from measuring the two cases that pull in opposite directions:

  | pair | similarity | |
  |---|---|---|
  | `duont` / `dupont` | 0.44 | a real typo — keep it |
  | `maraichere` / `maraicher` | 0.75 | keep it |
  | `bl-2024-0012` / `fa-2024-0113` | 0.30 | look-alike reference — drop it |
  | `dupont` / `dupond` | 0.56 | a genuine near-neighbour, kept |

  Anything from about 0.32 to 0.44 separates them; `0.35` sits in that band. Raise it for
  stricter matching. **Lowering it below your database's `pg_trgm.similarity_threshold`
  (0.3 by default) does nothing**: the trigram operator that the index can answer filters
  against that setting first, and this option only tightens what survives. To match more
  loosely than the database allows, raise the database setting.

  Source resources feed it with the `SearchAsh.Source` extension. Existing data is
  backfilled with `SearchAsh.reindex/2`, and a single row is reconciled after a write that
  bypassed Ash with `SearchAsh.reindex_one/3`.

  ## Authorization

  This index does **not** inherit the policies of the resources feeding it. It does honour
  its own: `:global_search` is a plain Ash read action, so policies you put on this
  resource compose with it. What they can authorize on is whatever an index row holds —
  `source_type`, `archived`, `label`, `language`, and your tenant attribute.

  So a role that gates **which kinds of thing** a user may see works today:

      policies do
        policy action_type(:read) do
          authorize_if expr(source_type in ^actor(:visible_types))
        end
      end

  `source_type` is stored as a string, so the actor's list must hold strings. Ash policies
  need a SAT solver (`:picosat_elixir` or `:simple_sat`).

  **Row-level ownership does not.** No `owner_id`, team, or per-record visibility flag can
  reach an index row — `SearchAsh.Source` writes a fixed set of columns — so results would
  carry the `label` of rows a user cannot open. Note that `label_field` is yours: point it
  at a reference rather than at something sensitive and a result reveals that a match
  exists, not what it says. The same goes double for `excerpt_length`: an excerpt exposes
  *content* to whoever can search the index, so don't enable it on a sensitive resource —
  or make sure this index's policies account for it. Note too that this index answers
  "what may this user *find*", not "what may they *do*" — routing to the object applies
  the source's policies, so do not mirror write permissions here.

  A result carries `(source_type, source_id)`, so you can re-check rights when rendering.
  That is sound **as a safety net over a policy that already filters in SQL** — it drops
  almost nothing and ranking is untouched. It is not sound **as the primary filter**:
  Postgres ranked and paginated over rows you then discard, so page 1 can come back empty
  while the matches sit on page 5. Either way, count in the view — `Ash.count` on the
  action counts what SQL matched, before any render-time filtering.

  For real row-level *read* filtering, use per-resource `SearchAsh` (`search do … end`): it
  queries the source table, so your policies apply, at the cost of cross-entity search.
  Copying ACLs into the index is a trap — authorization facts change independently of
  content, so nothing would trigger a re-index, and a stale index row is a security
  incident rather than a cosmetic one.
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
      ],
      weight_values: [
        type: {:map, {:in, [:a, :b, :c, :d]}, :float},
        default: %{},
        doc:
          "What each weight class is worth when ranking, 0.0 to 1.0. Postgres' defaults " <>
            "are `%{a: 1.0, b: 0.4, c: 0.2, d: 0.1}`; override any of them, e.g. " <>
            "`%{b: 0.9}` to bring class `:b` almost level with `:a`. Note there are four " <>
            "classes and no more — a tsvector stores two bits of weight per lexeme — so " <>
            "fields are assigned to classes with `weights`, and the classes are priced here."
      ],
      fuzzy?: [
        type: :boolean,
        default: false,
        doc:
          "Also match the *label* by trigram similarity and substring (typo tolerance: " <>
            "`duont` finds `Dupont`, `12` finds `BL-2024-0012`), backed by a trigram GIN " <>
            "index. Requires the `pg_trgm` extension — add `\"pg_trgm\"` to your repo's " <>
            "`installed_extensions` before generating migrations."
      ],
      fuzzy_threshold: [
        type: :float,
        default: 0.35,
        doc:
          "How similar a label must be to count as a fuzzy match, from 0.0 to 1.0. The " <>
            "default keeps real typos while dropping look-alike references — see the " <>
            "\"Typo tolerance\" section, which shows the measurements it comes from and " <>
            "why lowering it below your database's `pg_trgm.similarity_threshold` " <>
            "(0.3 by default) has no effect."
      ],
      default_limit: [
        type: :pos_integer,
        required: false,
        doc:
          "Bound the results when the caller asks for no page at all. Setting it makes " <>
            "the action paginate by default, so it returns an `Ash.Page` rather than a " <>
            "list. Unset (the default) keeps today's behaviour — an unpaginated search " <>
            "reads every matching row."
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
