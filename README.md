# search_ash

[Ash](https://ash-hq.org) extensions for **multilingual full-text search** on Postgres —
per-resource (`search do … end`) and **global cross-entity** search (a unified index).
No hand-written migrations, changes or SQL.

Part of the [search_ash monorepo](../); built on [`search_core`](../search_core), which
stems in pure Elixir via [`text_stemmer`](https://hex.pm/packages/text_stemmer) — 33
languages, no NIF, nothing to install beyond the Hex packages.

Languages are named by their **ISO 639-1 code** (`:fr`, `:en`) — exactly the set the
installed `text_stemmer` reports, which is the single authority for what a language is.

## Usage

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh]

  postgres do
    table "posts"
    repo MyApp.Repo
  end

  search do
    fields [:title, :body]        # text concatenated & indexed
    language_attribute :language  # attribute holding each row's language (:fr, :en, …)
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :language, :atom, allow_nil?: false, public?: true,
      constraints: [one_of: SearchCore.Language.accepted()]
    timestamps()
  end
end
```

That block generates, at compile time:

- a `:search_text` string attribute holding the stemmed tokens;
- a global change that keeps `:search_text` in sync on create/update (stemming each
  row in its own language via `SearchCore`);
- a GIN expression index `to_tsvector('simple', search_text)` — emitted into your
  migrations and tracked in the resource snapshot, so
  `mix ash_postgres.generate_migrations` **round-trips it cleanly** (re-running
  detects no changes);
- a `:search` read action taking `query` + `language` arguments.

```elixir
MyApp.Blog.search_posts!("chevaux", :fr)   # finds rows that stored "cheval"
```

Because the index side and the query side share one pipeline, stemming stays in
lock-step — a search for an inflected form matches the stored stem. Searches are scoped
to the language argument (each row is stemmed in its own language, so a search probes
one language at a time), which composes with Ash multitenancy.

## Global search across resources (Option B)

The `search do … end` block searches **one** resource. To search **across** many entity
types (produits, clients, bons de commande, livraisons…) from a single ranked query, use
the unified-index extensions:

- **`SearchAsh.GlobalIndex`** turns a resource into a unified search index — one row per
  indexed object. It generates the columns, a tenant-aware unique identity, a GIN index,
  an `:upsert` action, and a **`:global_search`** read action that filters + ranks and
  returns `(source_type, source_id, archived, label, search_rank)`:

  ```elixir
  defmodule MyApp.Search.Document do
    use Ash.Resource,
      domain: MyApp.Search, data_layer: AshPostgres.DataLayer,
      extensions: [SearchAsh.GlobalIndex]

    postgres do table "search_documents"; repo MyApp.Repo end
    multitenancy do strategy :attribute; attribute :org_id end
    global_index do default_language :fr end
    attributes do
      uuid_primary_key :id
      attribute :org_id, :string, allow_nil?: false, public?: true
    end
  end
  ```

- **`SearchAsh.Source`** mirrors each source resource into that index:

  ```elixir
  searchable do
    index MyApp.Search.Document
    source_type :bon_de_commande
    fields [:numero, :client_nom, :description]
    label_field :numero

    # Language, one of two ways (see below):
    language_attribute :language  # per row, from an attribute (the default)

    # Soft delete, your way:
    archived :deleted_at        # truthy attribute → archived (a boolean flag works too)
    on_destroy :archive         # or :remove (default, hard delete)
  end
  ```

  **Choosing the language.** Every indexed row is stemmed in one language, resolved one of
  two ways — the two are mutually exclusive:

  | | |
  |---|---|
  | `language_attribute :language` (default) | reads the language **per row** from that attribute, so one resource can hold many languages |
  | `language :fr` | fixes **one** language for every row — for a mono-language resource, which then needs **no language attribute at all** |

  ```elixir
  searchable do
    index MyApp.Search.Document
    source_type :page_statique
    fields [:titre, :corps]
    language :fr                # this resource has no :language attribute
  end
  ```

  A compile-time verifier rejects a block that cannot resolve a language (no `language`
  and no such attribute, an unsupported `language`, or both options at once), and warns
  when the language attribute is nullable with no default — rather than letting the first
  write fail.

  ### Options (`searchable do … end`)

  | Option | Default | Meaning |
  |---|---|---|
  | `index` (required) | — | The `SearchAsh.GlobalIndex` resource to feed |
  | `source_type` (required) | — | Tag identifying this resource's rows in the index |
  | `fields` (required) | — | Attributes whose text is concatenated, stemmed and indexed |
  | `language` | — | One language for every row; mutually exclusive with `language_attribute` |
  | `language_attribute` | `:language` | Attribute holding each row's language |
  | `label_field` | — | Attribute used as the human-readable label stored in the index |
  | `archived` | — | Attribute name (truthiness) or `record -> boolean` deriving the index's `archived` flag |
  | `on_destroy` | `:remove` | `:remove` (hard delete) or `:archive` (keep, flagged) |

  Create/update upserts a stemmed document; destroy either removes it (`on_destroy:
  :remove`, default) or keeps it flagged (`:archive`, for soft-delete via a destroy such
  as AshArchival). `archived` derives the index's boolean flag from a source attribute's
  **truthiness** — a boolean, or a `deleted_at` timestamp — or a `record -> boolean`
  function; it defaults to `false`. The extension sets `require_atomic? false` on the
  update/destroy actions it augments, so you don't set it yourself.

  `:global_search` **hides archived rows by default**, but takes `include_archived?: true`
  to return both — so you can **group results by `archived`** in the UI:

  ```elixir
  MyApp.Search.global_search!("dupont", :fr, %{include_archived?: true}, tenant: "org_42")
  ```

Then one query, ranked, tenant-isolated:

```elixir
MyApp.Search.global_search!("dupont", :fr, tenant: "org_42")
# => [%{source_type: "bon_de_commande", source_id: "…", archived: false, search_rank: 0.9}, …]
```

**Backfill existing data** with `SearchAsh.reindex/2` (per tenant):

```elixir
SearchAsh.reindex(MyApp.Sales.BonDeCommande, tenant: "org_42")
```

The index is a normal Ash resource, so admin tools (view indexed content, force a
reindex) are just reads/actions on it. `global_index` options: `default_language`,
`search_text_attribute`, `action`. Archived rows are hidden by default (`include_archived?: true` to include them).

## Options (`search do … end`)

| Option | Default | Meaning |
|---|---|---|
| `fields` (required) | — | Attributes whose text is indexed |
| `language_attribute` | `:language` | Attribute holding each row's language |
| `search_text_attribute` | `:search_text` | Where stemmed tokens are stored (added if absent) |
| `index_name` | `"<table>_search_idx"` | Name of the generated GIN index |
| `action` | `:search` | Name of the generated read action |
| `default_language` | `:fr` | Language used to stem the query when the `language` argument is omitted |
| `prefix?` | `true` | Match the last token as a prefix (`"boulan"` → `"boulangerie"`); set `false` for exact stemmed matching |

## Verify end-to-end

See [`examples/search_demo`](examples/search_demo) for a runnable multi-tenant demo
against real Postgres — per-resource and global search, a GreenAsh console, and a
Postgres-backed test suite.

## Notes

- **Requires the AshPostgres data layer.** Search is built on Postgres `tsvector`/`ts_rank`,
  so the generated `:search` action only works on `AshPostgres.DataLayer` resources.
- **Atomicity is handled for you.** The keep-in-sync change stems in Elixir, which can't
  run inside an atomic SQL update, so the extension sets `require_atomic? false` on the
  update (and, for `SearchAsh.Source`, destroy) actions it augments — you don't set it.
- **Ranking** is on by default (`rank?`), ordering by `ts_rank` and exposing the score as
  the `:search_rank` calculation; set `rank?: false` to filter only. `:search_rank` is
  loaded only for an actual query — a blank query (list-all) is returned unranked.
- An **unsupported/blank `language`** argument falls back to `default_language` rather than
  raising.
- The search matches the last token as a **prefix** (`prefix?`, on) and treats a **blank
  query as "no filter"** so it composes with list UIs.

## Production notes & limitations

Know these before adopting — they're deliberate trade-offs, not surprises:

- **The index does not inherit your source resources' policies — but you can give it its
  own.** `:global_search` is a plain Ash read action, so policies on your index resource
  compose with it normally. What you can authorize on is limited to the columns an index
  row has: `source_type`, `archived`, `label`, `language` and your tenant attribute.

  **Role → entity type works today.** If a role gates *which kinds of thing* a user may
  see, put the policy on your index resource:

  ```elixir
  # in MyApp.Search.Document
  policies do
    policy action_type(:read) do
      authorize_if expr(source_type in ^actor(:visible_types))
    end
  end
  ```

  (`source_type` is stored as a **string**, so the actor's list must hold strings. Ash
  policies need a SAT solver — add `:picosat_elixir` or `:simple_sat`.)

  **Row-level ownership does not.** There is no way to carry an `owner_id`, a team, or a
  per-record visibility flag into an index row — `SearchAsh.Source` writes a fixed set of
  columns. If a user may only see *some* invoices rather than all or none, this index
  cannot express it: post-filtering the results breaks ranking and pagination (you'd
  filter *after* ranking, so a page can come back empty), which is the standard
  denormalized-index problem. Use `search do … end` on each resource there — it queries
  the source table, so your policies apply, at the cost of cross-entity search. The
  `extra_attrs` hook on the roadmap is what would close this.

- **Indexing is synchronous, in the same transaction as the write.** The sync runs in an
  `after_action` hook using the source's repo, so the index upsert commits (or rolls back)
  with the source write — a failed index write fails the source write, so the two never
  diverge. The flip side: every create/update/destroy on a source pays the stemming +
  index-write cost inline. There is no async (Oban) path yet; if you need one, it's on the
  roadmap.
- **Bulk works transparently for the global index; the per-resource `search do` needs
  `strategy: :stream` for bulk updates.** `SearchAsh.Source` writes only to the separate
  index table, so `Ash.bulk_create`/`bulk_update`/`bulk_destroy` keep the index in sync
  with **no `strategy:` option**. The per-resource `search do` extension instead computes
  `search_text` **on the row itself** in Elixir, which can't run in an atomic SQL update —
  so `Ash.bulk_update` on a `search do` resource must pass `strategy: :stream`. Either way,
  the default atomic strategy fails **loudly** (`NoMatchingBulkStrategy`); the index is
  never silently skipped.
- **One language per query.** Each row is pre-stemmed in its own language and stored in a
  `'simple'` tsvector, so a search probes one language at a time (the `language` argument).
  Cross-language "OR" search is not built in.
- **`reindex/2` streams every row through the write action** (one upsert per record). It's
  built for backfills and small-to-medium tables; it is not a bulk-optimized reindex for
  very large datasets.
- **Index creation is not `CONCURRENTLY`.** The generated GIN index is emitted as a plain
  `CREATE INDEX` migration; on a large existing table, plan the migration accordingly.
- **Stemming is pure Elixir, at ~11µs/word.** Invisible on the query path, but a write
  that stems a very large document spends tens of ms of CPU inside the transaction. If
  you bulk-index large corpora and want ~0.5µs/word, the [`stemmers`](../stemmers) Rust
  NIF is published and produces identical output.

## Status

MVP, `:pre_stemmed` strategy — tested end-to-end against Postgres (`mix test`).

Roadmap, roughly in order of how often it bites:

- **`extra_attrs` on `searchable do`** — a `record -> map` hook letting you carry your own
  columns (an `owner_id`, a team, a visibility flag) into the index row, plus the matching
  filter on `:global_search`. This is what unlocks **intra-tenant authorization** for the
  global index; see the first limitation above.
- **Async indexing** — an `indexing_strategy :sync | :notify | :manual` option on
  `SearchAsh.Source`, with no hard Oban dependency (`:notify` emits an Ash notification,
  `:manual` lets you drive a durable job).
- **Cross-language search** — one query probing several languages at once.
- A `:native` per-row-`regconfig` strategy (Postgres-supported languages only), and
  weighted fields (`setweight`).
