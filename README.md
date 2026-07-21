# search_ash

[![CI](https://github.com/nseaSeb/search_ash/actions/workflows/ci.yml/badge.svg)](https://github.com/nseaSeb/search_ash/actions/workflows/ci.yml)

[Ash](https://ash-hq.org) extensions for **multilingual full-text search** on Postgres —
per-resource (`search do … end`) and **global cross-entity** search (a unified index).
No hand-written migrations, changes or SQL.

Built on [`search_core`](https://hex.pm/packages/search_core), which
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
- a GIN expression index on `search_text::tsvector` — emitted into your
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
  | `weights` | `%{}` | Per-field rank weights (`%{numero: :a}`); unlisted fields weigh `:d` |
  | `index_attribute` | — | Fill a typed index column from the record, to filter and sort on (repeatable) |
  | `load` | — | Ash load statement applied before building the document (for `extra_text`) |
  | `extra_text` | — | `record -> text` appended to the searchable text, with its own `weight:` (repeatable; mind the [staleness contract](documentation/architecture.md#reconciliation--writes-the-sync-never-saw)) |
  | `excerpt_length` | — | When set, store the first N chars of the raw text in the index's `excerpt` column |
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
# => [%{source_type: "bon_de_commande", source_id: "…", label: "BL-2024-0012", …}, …]
```

Results rank **label** matches first — exact, then starts-with, then contains, then a
body-only match — and `ts_rank` within each tier. So the client *named* "Dupont" beats an
invoice that merely mentions one.

From there a results page needs pagination with a total (`page: [limit: 20, count: true]`),
tab badges (`SearchAsh.counts_by_type/3`), range filters and sorting on typed columns
(`index_attribute`), per-field ranking (`weights`), typo tolerance (`fuzzy?`), text pulled
from related records (`load` + `extra_text`), and a highlighted excerpt (`excerpt_length`
plus `SearchCore.highlight/4`).

**→ [Building a global search](documentation/global-search.md) walks all of it, in order,
from nothing to a working page** — including the two decisions that are easy to get wrong:
which attribute to use as your `label_field`, and where to draw the authorization line.

**Backfill existing data** with `SearchAsh.reindex/2` (per tenant):

```elixir
SearchAsh.reindex(MyApp.Sales.BonDeCommande, tenant: "org_42")
```

**After a write that bypassed Ash** — a raw `Repo.query!`, a SQL cascade, a restore — the
sync never fired, so reconcile that record with `SearchAsh.reindex_one/3`:

```elixir
SearchAsh.reindex_one(MyApp.Sales.BonDeCommande, id, tenant: "org_42")
```

It re-reads the record: present → re-indexed, gone → the resource's `on_destroy` decides
(removed, or kept archived), just as destroying it through Ash would have. Idempotent, so
the call site never has to work out whether to add or remove. Call it after the write
commits and outside any transaction.

**To sweep a whole source for stale index rows** whose record no longer exists, use
`SearchAsh.prune/2` (per tenant):

```elixir
SearchAsh.prune(MyApp.Sales.BonDeCommande, tenant: "org_42")
```

It reads which rows are still live and drops every index row without one behind it
(honouring `on_destroy`), returning the count. Pair it with `reindex/2` for a full two-way
reconcile — backfill missing rows, then sweep orphans.

The index is a normal Ash resource, so admin tools (view indexed content, force a
reindex) are just reads/actions on it. `global_index` options: `default_language`,
`search_text_attribute`, `action`, `fuzzy?`. Archived rows are hidden by default (`include_archived?: true` to include them).

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

See [`examples/search_demo`](https://github.com/nseaSeb/search_ash/tree/main/examples/search_demo) for a runnable multi-tenant demo
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
  query as "no filter"** so it composes with list UIs. A *non-blank* query whose tokens
  are all eliminated (stopwords, too short — `"de"`) matches **nothing** (since 0.4.0;
  it used to list everything, which was a bug).
- Both generated actions **paginate** when asked (`page: [limit: …]`, offset or keyset,
  countable) and stay plain lists when not.

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
  columns. If a user may see *some* invoices rather than all or none, this index cannot
  express it, and results would carry the `label` of rows they cannot open. Two things to
  know before that worries you:

  - **You choose what a result exposes.** `label_field` is yours: point it at a reference
    (`label_field :numero`) rather than at something sensitive, and a result reveals that
    a match exists without revealing what it says.
  - **Do not mirror write permissions here.** Routing to the object applies the source
    resource's policies. This index answers "what may this user *find*", not "what may
    they *do*" — don't duplicate an authorization that already lives downstream.

  A result carries `(source_type, source_id)`, so you *can* check rights again when
  rendering. Whether that is sound depends on where the bulk of the filtering happens:

  - **As a safety net, over a policy that already filters in SQL** — fine. It drops nothing
    or almost nothing, ranking is untouched, and a page of ten showing seven is invisible.
  - **As the primary filter** — broken. Postgres ranked and paginated over rows you then
    throw away, so page 1 can come back empty while the real matches sit on page 5.

  Either way, count in the view rather than with `Ash.count` on the action: the action
  counts what SQL matched, before your render-time filtering. With a net that drops nothing
  the two agree — and the day they disagree, the count is the early symptom, before
  pagination goes wrong.

  If you genuinely need row-level *read* filtering with cross-entity ranking, nothing here
  gives it to you today, and copying ACLs into the index is a trap: authorization facts
  change independently of content (an ACL edit, someone leaving a team), so nothing would
  trigger a re-index, and a stale index row is a security incident rather than a cosmetic
  one. Use `search do … end` on each resource instead — it queries the source table, so
  your policies apply, at the cost of cross-entity search.

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
- **Indexing rides on Ash actions.** The sync only fires when Ash builds a changeset, so a
  write that bypasses it — a raw `Repo.query!`, a SQL cascade — leaves the index stale with
  nothing to signal it. `reindex_one/3` is the targeted repair, but you have to call it:
  nothing detects the bypass for you.
- **`reindex/2` streams every row through the write action** (one upsert per record). It's
  built for backfills and small-to-medium tables; it is not a bulk-optimized reindex for
  very large datasets. It only upserts, so it cannot remove the index row of a source that
  is gone — that is `reindex_one/3` (one record) or `prune/2` (a whole source) 's job.
- **Composite string primary keys can collide.** A row's `source_id` joins its primary key
  parts with `":"`. Single-column keys (e.g. `uuid_primary_key`) and integer parts are
  exact, but two or more string columns whose values contain `":"` can render the same
  `source_id` and share one index row. Fine for the common single-uuid-key case.
- **Index creation is not `CONCURRENTLY`.** The generated GIN index is emitted as a plain
  `CREATE INDEX` migration; on a large existing table, plan the migration accordingly.
- **Stemming is pure Elixir, at ~11µs/word.** Invisible on the query path, but a write
  that stems a very large document spends tens of ms of CPU inside the transaction — worth
  knowing if you index very large documents. The stemmer is not swappable: `search_core`
  calls `text_stemmer` directly.

## Status

MVP, `:pre_stemmed` strategy — tested end-to-end against Postgres (`mix test`).

See [the roadmap](documentation/roadmap.md) for what is deferred and why — including the
shape synonym support would take, and what was **refused** (BM25 ranking, and copying
authorization data into the index) with the reasoning. Roughly in order of how often it
bites:

- **Synonyms** — `BL` finds `bon de livraison`, expanded at query time so editing the map
  needs no reindex.
- **Facets** — counting for side filters, generalizing `SearchAsh.counts_by_type/3`.
- **Async indexing** — an `indexing_strategy :sync | :notify | :manual` option on
  `SearchAsh.Source`, with no hard Oban dependency.
- **Cross-language search**, and a `:native` per-row-`regconfig` strategy.
