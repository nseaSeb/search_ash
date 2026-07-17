# Changelog

## 0.2.0

### Fixed

- **A source resource with no `:language` attribute failed every write.** `searchable`
  resolved the language with `Map.get(record, language_attribute)`, which returned `nil`
  when the attribute did not exist. That `nil` then hit the index's `allow_nil?: false`
  from inside the sync's `after_action` — inside the source write's transaction — so the
  whole create was rolled back with an opaque error. `default_language` did not help: it
  is only consulted when reading.

### Added

- **`language` in the `searchable` block** — fixes one language for every row of a
  mono-language resource, which then needs no language attribute at all:

      searchable do
        index MyApp.Search.Document
        source_type :page_statique
        fields [:titre, :corps]
        language :french
      end

  It is mutually exclusive with `language_attribute`, and accepts either an ISO 639-1
  code (`:fr`) or an English name (`:french`). `language_attribute` is unchanged and
  still defaults to `:language`, so existing resources are unaffected.
- **A compile-time verifier** now rejects a `searchable` block that cannot resolve a
  language — no `language` and no such attribute, an unsupported `language`, or both
  options set at once — with an actionable message, instead of letting it fail on the
  first write. It also **warns** when the language attribute is nullable with no default,
  since any row written without a language would roll its write back.
- Languages may be named by ISO 639-1 code (`:fr`) as well as by English name
  (`:french`), anywhere a language is accepted — including `default_language` and the
  `language_attribute` values stored on your rows.

### Changed

- Requires `search_core ~> 0.2`, which stems in pure Elixir via
  [`text_stemmer`](https://hex.pm/packages/text_stemmer) instead of the `stemmers` Rust
  NIF. Installing `search_ash` no longer pulls a NIF or needs a Rust toolchain, and
  language coverage grows from 18 to 33. Stemming costs ~11µs/word instead of ~0.5µs:
  invisible on the query path, though a write of a very large document now spends tens of
  ms of (BEAM-preemptible) CPU in the transaction.
- **The index stores the canonical ISO code.** `:french` and `:fr` are both accepted on
  the way in, but a row is only ever written as `:fr`, so the index stays
  single-vocabulary and a consumer filtering its public `language` attribute has one
  spelling to match. Rows written by 0.1.0 keep their original spelling until reindexed
  (`SearchAsh.reindex/2`).
- The generated `language` attribute validates against `SearchCore.Language.accepted()`
  rather than `Stemmers.supported_languages()`. This only widens the accepted set, so
  existing resources keep working, and it produces **no migration diff** (the constraint
  was never persisted to the schema — the column is plain `text`).
- An unresolvable language now raises an `ArgumentError` naming the resource, the
  attribute and the way out, instead of a bare error from inside the stemmer. The message
  is tailored to how the resource names its language, so a `language :fr` resource is not
  told to fix an attribute it does not have.
- `default_language` now defaults to `:fr` rather than `:french` (see Breaking below).

### Breaking

- **Languages are ISO 639-1 codes only: `:french` is no longer accepted — use `:fr`.**
  `text_stemmer` is the single authority for what languages exist, and `search_ash` carries
  no alias table that could disagree with it. Upgrading requires two steps:

  1. **Your code** — replace `:french`/`:english`/… with `:fr`/`:en`/… everywhere a
     language is named: `language`/`language_attribute` values, `default_language`, the
     `language` argument of `:search`/`:global_search`, and any attribute `default:`.
     `SearchCore.Language.supported_languages/0` is the full list.
  2. **Your data** — a `language` column is `text` holding the atom's name, so existing
     rows still say `'french'`. 0.2.0 cannot cast that back into an atom, so those rows
     **fail to read** until rewritten. `mix ash_postgres.generate_migrations` picks up the
     `default:` change but **cannot write the backfill for you** —
     [`examples/search_demo`](examples/search_demo/priv/repo/migrations) has a complete
     migration (defaults + backfill, reversible) to copy. Do not forget the index table
     itself.

## 0.1.0

Initial release. An Ash extension for multilingual full-text search.

- `search do fields …; language_attribute … end` generates: the `search_text` column,
  a keep-in-sync change (only recomputes when needed; never from partially-loaded data),
  a GIN expression index (round-trips through `mix ash_postgres.generate_migrations`), a
  `:search_rank` calculation, and a tenant-aware `:search` read action.
- Search is **ranked** by `ts_rank` (`rank?`, on by default), matches the last token as a
  **prefix** (`prefix?`, on), and treats a **blank query as no filter** so it composes
  with list UIs.
- DSL options: `fields`, `language_attribute`, `search_text_attribute`, `index_name`,
  `action`, `default_language`, `prefix?`, `rank?`.

Global search across resources (Option B):

- `SearchAsh.GlobalIndex` — turns a resource into a unified cross-entity search index
  (generated columns, tenant-aware identity, GIN index, `:upsert` + ranked
  `:global_search` actions returning `(source_type, source_id, archived, label,
  search_rank)`). Archived rows are hidden by default; `include_archived?: true` returns
  both, for grouping.
- `SearchAsh.Source` — mirrors a resource into an index on create/update/destroy.
  Soft-delete: `archived` derives a boolean flag from a source attribute's truthiness (a
  boolean or a `deleted_at` timestamp) or a `record -> boolean` function; `on_destroy` is
  `:remove` (hard delete) or `:archive` (keep, for AshArchival-style destroy). The sync
  only recomputes when an indexed field/language/archived attribute changes and never
  from a partially-loaded record.
- `SearchAsh.reindex/2` — backfills existing rows (per tenant).

Notes:

- The extensions set `require_atomic? false` on the update (and, for `SearchAsh.Source`,
  destroy) actions they augment — stemming runs in a NIF and can't be atomic, so you don't
  set it yourself.
- `SearchAsh.Source` bulk operations work transparently: it writes only to the separate
  index table, so `Ash.bulk_create`/`bulk_update`/`bulk_destroy` keep the index in sync
  with no `strategy:` option (the sync/remove changes are atomic-compatible and mirror each
  record in `after_batch/3`). The per-resource `search do` extension computes `search_text`
  on the row via a NIF, so `Ash.bulk_update` there must pass `strategy: :stream`. Either
  way the default atomic strategy fails loudly rather than skipping the index.
- Indexing is synchronous and shares the source action's transaction, so a failed index
  write rolls back the source write (no divergence). See the README limitations.
