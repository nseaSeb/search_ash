# Changelog

## 0.3.0

### Added

- **`SearchAsh.reindex_one/3` — repair one index row after a write that bypassed Ash.**
  Indexing rides on Ash actions: the sync and remove changes only fire when Ash builds a
  changeset. A raw `Repo.query!` — a denormalized column cascaded across rows, a restore
  from a trash table, a delete cascaded to children — never reaches them, and the index
  goes stale with nothing to signal it. `reindex/2` could not repair that: it reads the
  whole resource, and it only ever *upserts*, so it cannot touch the index row of an
  object that has gone away.

  `reindex_one/3` re-reads the record and reconciles, so the caller never has to know
  whether the row should be added or removed:

  ```elixir
  # after any raw-SQL write touching an indexed object
  SearchAsh.reindex_one(MyApp.Sales.BonDeCommande, id, tenant: "org_42")
  ```

  Present → the document is rebuilt and upserted (`:upserted`). Gone → the resource's
  **`on_destroy`** decides, exactly as destroying it through Ash would have: `:remove`
  deletes the index row (`:removed`), `:archive` keeps it flagged archived (`:archived`).
  Gone and never indexed → `:noop`. It is idempotent, and composite primary keys take a
  map or keyword list, as `Ash.get/3` does.

  Call it **after** the bypassing write has committed and **outside** any surrounding
  transaction — it re-reads the source, and it dispatches the index's notifications
  itself.

  Unlike `reindex/2`, it rejects `:actor` and `authorize?: true`: its source read always
  runs with `authorize?: false`. This one is load-bearing rather than cosmetic. The
  function decides what to do from whether the record is *there*, and a row hidden by a
  policy reads as `nil` exactly like a deleted one — so an authorized read would have it
  delete the index row of a live record. `authorize?: false` disables the policy filter
  and nothing else: `base_filter` and the tenant still apply, so an AshArchival-style soft
  delete is still correctly seen as gone. `reindex/2` can forward `:authorize?` safely
  precisely because it only upserts — an authorized read that hides rows just backfills
  fewer of them.

- **`SearchAsh.prune/2` — sweep a whole source for index rows whose record is gone.** Where
  `reindex_one/3` reconciles one record you know changed, `prune/2` reconciles a source in
  the deletion direction: recovering from a bulk `DELETE`, a botched migration, or any run of
  bypassing writes that was never followed by `reindex_one/3`.

  ```elixir
  SearchAsh.prune(MyApp.Sales.BonDeCommande, tenant: "org_42")
  ```

  It streams the source once into the set of live `source_id`s, then applies each resource's
  `on_destroy` (`:remove` deletes, `:archive` archives) to every index row of that
  `source_type` with no live record behind it, returning the count. It only ever removes;
  pair it with `reindex/2` for a full two-way reconcile. Like `reindex_one/3` it rejects
  `:actor`/`authorize?: true` — and here the reason is sharper: it decides a row is an orphan
  by finding no live source, so a live set read *with a policy applied* would classify every
  hidden row as an orphan and delete it. The live set is always read `authorize?: false`.
  For the same reason it reads existence through the source's primary read action, which must
  return every indexable row (a `filter` on it — not `base_filter` — would make live rows look
  like orphans); and it refuses to run when a multitenant source feeds a non-multitenant index,
  which could not be tenant-scoped and would delete other tenants' rows.

### Fixed

- **A change to `label_field` alone did not refresh the index label.** The sync's recompute
  short-circuit watched the searchable `fields`, the language and `archived` — but not
  `label_field`. For a resource whose label is not itself a searchable field (search the
  body, display the subject), renaming the label changed nothing watched, so no upsert ran
  and the index kept the old label. The label attribute is now watched too. (Latent for any
  resource that includes its `label_field` in `fields`, which is why it went unnoticed.)

### Changed

- **Index writes moved into one internal module** (`SearchAsh.Source.Index`), shared by the
  sync change, the remove change, `reindex/2`, `reindex_one/3` and `prune/2`. What
  `on_destroy` means now has a single implementation, so the manual paths cannot drift from
  the action path — `reindex_one/3` and `prune/2` exist precisely to agree with a destroy
  they never saw. Two consequences for `reindex/2`, both benign outside a transaction: it now
  dispatches its notifications via `Ash.Notifier.notify/1` (equivalent, since it never runs in
  one), and it now skips a partially-loaded record — a narrowed `select` — rather than
  indexing it from incomplete data, matching what the sync change already did.

- **Documented a `source_id` limitation for composite string primary keys.** A row's
  `source_id` joins its primary key parts with `":"`; two or more string columns whose
  values contain `":"` can render the same `source_id` and share one index row. Single-column
  keys (the usual `uuid_primary_key`) and integer parts cannot collide. Documented rather
  than fixed: changing the join would alter every stored `source_id` and force a full
  reindex — a breaking change for a later major version.

## 0.2.2

### Fixed

- **An index carrying policies broke every destroy on its sources — and 0.2.1's docs told
  you to add exactly those policies.** `SearchAsh.Source`'s sync and remove changes read
  and wrote the index with no actor and no `authorize?: false`. Since an Ash domain
  authorizes by default, those internal reads/writes were checked against the index's own
  policies and refused: `on_destroy :remove` raised `Ash.Error.Forbidden`, and `reindex/2`
  and the upsert were one policy away from the same fate.

  Mirroring is machinery, not a user action: the source write it rides on was already
  authorized by the source's own policies, and the index's policies answer a different
  question — what a user may *find*. All internal index access is now `authorize?: false`.
  `reindex/2` still forwards `:authorize?` to the **source** read, so you keep deciding
  whose rows get backfilled.

  Found by giving [`examples/search_demo`](examples/search_demo) real roles rather than
  trusting the documented pattern. It is now covered both there and by regression tests
  that fail without the fix.

### Added

- **`examples/search_demo` demonstrates roles end to end.** A `SearchDemo.Accounts.User`
  with a role (`:admin` finds everything, `:commercial` factures + clients, `:support`
  clients), policies on the index, and tests showing the same query returning different
  rows per role — including that no actor is refused outright rather than served
  everything. The GreenAsh console at `/cli` takes `:actor user <id>`, so you can switch
  role and watch results change.

## 0.2.1

Documentation fix. No code change to the library itself.

### Fixed

- **0.2.0 overstated an authorization limitation, and steered people away from something
  they can do.** It said the index "enforces tenant isolation and nothing finer" and that
  `:global_search` "never consults the actor". The first part is right — the index does not
  *inherit* the policies of the resources feeding it — but the conclusion was wrong:
  `:global_search` is a plain Ash read action, so **policies on the index resource itself
  compose with it normally**.

  A role that gates *which kinds of thing* a user may see therefore works today:

      # in your SearchAsh.GlobalIndex resource
      policies do
        policy action_type(:read) do
          authorize_if expr(source_type in ^actor(:visible_types))
        end
      end

  Two things bite: `source_type` is stored as a **string**, so the actor's list must hold
  strings; and Ash policies need a SAT solver (`:picosat_elixir` or `:simple_sat`).

  What genuinely does not work is **row-level** authorization: no owner, team, or
  per-record visibility flag can reach an index row, so a policy cannot key off one.
  Post-filtering the results breaks ranking and pagination. `search do … end` on the
  source is the answer there — it queries the source table, so its policies apply — at the
  cost of cross-entity search. Note the two are different searches with different security
  models, not one search with both properties.

  The capability is now covered by tests rather than by prose alone.

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
