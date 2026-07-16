# Changelog

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
