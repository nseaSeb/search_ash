# search_ash

[Ash](https://ash-hq.org) extensions for **multilingual full-text search** on Postgres —
per-resource (`search do … end`) and **global cross-entity** search (a unified index).
No hand-written migrations, changes or SQL.

Part of the [search_ash monorepo](../); built on
[`search_core`](../search_core) and the [`stemmers`](../stemmers) Rust NIF.

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
    language_attribute :language  # each row's Stemmers language (:french, :english, …)
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :language, :atom, allow_nil?: false, public?: true,
      constraints: [one_of: Stemmers.supported_languages()]
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
MyApp.Blog.search_posts!("chevaux", :french)   # finds rows that stored "cheval"
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
    global_index do default_language :french end
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

    # Soft delete, your way:
    archived :deleted_at        # truthy attribute → archived (a boolean flag works too)
    on_destroy :archive         # or :remove (default, hard delete)
  end
  ```

  Create/update upserts a stemmed document; destroy either removes it (`on_destroy:
  :remove`, default) or keeps it flagged (`:archive`, for soft-delete via a destroy such
  as AshArchival). `archived` derives the index's boolean flag from a source attribute's
  **truthiness** — a boolean, or a `deleted_at` timestamp — or a `record -> boolean`
  function; it defaults to `false`. The extension sets `require_atomic? false` on the
  update/destroy actions it augments, so you don't set it yourself.

  `:global_search` **hides archived rows by default**, but takes `include_archived?: true`
  to return both — so you can **group results by `archived`** in the UI:

  ```elixir
  MyApp.Search.global_search!("dupont", :french, %{include_archived?: true}, tenant: "org_42")
  ```

Then one query, ranked, tenant-isolated:

```elixir
MyApp.Search.global_search!("dupont", :french, tenant: "org_42")
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
| `default_language` | `:french` | Language used to stem the query when the `language` argument is omitted |
| `prefix?` | `true` | Match the last token as a prefix (`"boulan"` → `"boulangerie"`); set `false` for exact stemmed matching |

## Verify end-to-end

See [`examples/search_demo`](examples/search_demo) for a runnable multi-tenant demo
against real Postgres — per-resource and global search, a GreenAsh console, and a
Postgres-backed test suite.

## Notes

- **Requires the AshPostgres data layer.** Search is built on Postgres `tsvector`/`ts_rank`,
  so the generated `:search` action only works on `AshPostgres.DataLayer` resources.
- **Atomicity is handled for you.** The keep-in-sync change stems via a NIF, which can't
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

Know these before adopting — they're deliberate 0.1 trade-offs, not surprises:

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
  `search_text` **on the row itself** via a NIF, which can't run in an atomic SQL update —
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
- **`stemmers` ships precompiled NIFs** for macOS (arm64/x86_64) and Linux glibc
  (arm64/x86_64). musl/Alpine is **not** prebuilt — set `STEMMERS_BUILD=1` to compile from
  source there (needs a Rust toolchain).

## Status

MVP, `:pre_stemmed` strategy — tested end-to-end against Postgres (`mix test`). Deferred:
a `:native` per-row-`regconfig` strategy (no NIF, Postgres-supported languages only),
weighted fields (`setweight`), and an async (Oban) indexing path.
