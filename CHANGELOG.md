# Changelog

## 0.4.0
Everything a **results page** needs, then everything it needs to *filter, sort and rank* —
driven by the first real-world integration. One release, one migration, one reindex from
0.3.x; see [Upgrading to 0.4](documentation/upgrading-0.4.md).

The API is additive and the new columns are nullable, so this is not a breaking release.
Three things do change observably, all deliberate: a query with no usable token now
returns nothing, results rank label matches first, and `search_text` changes storage
format (rows keep matching without a reindex — only ranking goes flat until you run one).

### Added

- **Pagination on the generated actions** (`:search` and `:global_search`): offset and
  keyset, countable, `required?: false` — existing unpaginated calls are untouched.
  `page: [limit: 20, offset: 0, count: true]` is all a results page needs.
- **`types` argument on `:global_search`** — restrict to entity kinds
  (`types: [:facture]` or `["facture"]` — it accepts atoms and strings, so a form can
  submit it directly) for tabs. `nil` and `[]` both mean "no filter", so an empty
  multi-select never turns into zero results.
- **`SearchAsh.counts_by_type/3`** — per-type match counts for tab badges
  (`%{"facture" => 12, "client" => 3}`). Runs the real `:global_search` action, so the
  index's policies compose with the given `:actor`. `types: []` means "not specified",
  the same convention as the action's argument. One count query per type — no hidden
  group-by.
- **`fuzzy? true` on `global_index`** (opt-in) — typo tolerance and substring matching
  on the label via `pg_trgm`: `duont` finds `Dupont`, `12` finds `BL-2024-0012`. One
  trigram GIN index serves both; fuzzy-only matches rank behind full-text matches.
  Requires `"pg_trgm"` in the repo's `installed_extensions`; without the option, no
  extension is needed and nothing changes. A source feeding a fuzzy index without a
  `label_field` gets a compile-time warning — its rows have no normalized label, so
  they would silently never fuzzy-match.
- **`load` + `extra_text` on `searchable`** — index text derived from related records
  ("which orders mention tomatoes?"): `load [:lines]` makes the relation available,
  `extra_text fn order -> Enum.map(order.lines, & &1.description) end` feeds it to the
  stemmer. Applied at the single indexing choke point, so `reindex/2` and
  `reindex_one/3` get it too — and batched on the bulk paths (bulk writes and
  `reindex/2` load one chunk of records per query, not one query per record).
  **Staleness contract:** a direct write to the *related* resource does not re-index
  the parent — reconcile with `reindex_one/3` or any parent write (documented on
  `SearchAsh.Source`).
- **`excerpt_length` on `searchable`** — store the first N characters of the raw
  (unstemmed) text in the index's new `excerpt` column, word-truncated and
  `…`-suffixed, for display. Pair with `SearchCore.highlight/4` (search_core 0.3.0) to
  mark the matching words.


- **`index_attribute` — typed index columns you can filter and sort on.** Declare the
  column on the index resource, and say on each source how to fill it, from an attribute
  or from a function:

  ```elixir
  index_attribute :document_date, :date_emission
  index_attribute :montant, &(&1.lignes |> Enum.map(fn l -> l.total end) |> Enum.sum())
  ```

  They are ordinary Ash attributes, so `Ash.Query.filter(document_date >= ^from)` and
  `Ash.Query.sort(document_date: :desc)` work with no new API. The attribute form is
  watched by the sync, so changing *only* that attribute still re-indexes.

  **Point several sources at the same column** when it means the same thing — a facture's
  `date_emission`, a delivery's `date_livraison`, a product's `inserted_at` all onto
  `document_date` — so a mixed results page has one comparable axis to sort on.

  Only values **derived from the record** belong here; they are rewritten on every write,
  which is what keeps them honest. Never mirror authorization facts.

- **`weights` — per-field rank weights** on both extensions:

  ```elixir
  weights %{numero: :a, client_nom: :b}   # anything unlisted stays :d
  ```

  A hit in the reference now outranks the same hit in a body.

  `extra_text` is now **repeatable and weighted** too — so two things you derive can matter
  differently, which is what lets an updated-date outweigh a created-date:

  ```elixir
  extra_text fn commande -> Enum.map(commande.lignes, & &1.designation) end
  extra_text &date_in_words(&1.updated_at), weight: :b
  ```

- **`weight_values` — what each class is worth** when ranking, on the index (or the
  per-resource `search` block):

  ```elixir
  weight_values %{b: 0.9}   # Postgres' defaults: a: 1.0, b: 0.4, c: 0.2, d: 0.1
  ```

  Fields are assigned to classes by the source (`weights`); classes are priced here, on
  the index, or ranks from different entity types would not be comparable. Note there are
  four classes and no more — a tsvector stores two bits of weight per lexeme.

- **`fuzzy_threshold`** (default `0.35`) — how similar a label must be to count as a fuzzy
  match. The default is measured, not guessed: a real typo (`duont`/`dupont`) scores 0.44
  while two look-alike references (`bl-2024-0012`/`fa-2024-0113`) score 0.30, so `0.35`
  separates them and an exact reference search stops dragging its neighbour back. Lowering
  it below the database's own `pg_trgm.similarity_threshold` has no effect — see the
  `SearchAsh.GlobalIndex` docs.

- **`default_limit`** on both extensions — bound the results when the caller asks for no
  page at all. Unset by default (today's behaviour: an unpaginated search reads every
  matching row). Setting it makes the action paginate by default, so it returns an
  `Ash.Page` rather than a list.

### Changed

- **`:global_search` ranks label matches first.** New composite order: exact label >
  label starts-with > label contains > body-only match (`label_match_tier`, exposed on
  results), then `ts_rank`, then primary key. Backed by a new `label_normalized` column
  holding `SearchCore.normalize/1` of the label (trim + downcase + accents stripped —
  `maraicher` meets `Maraîcher`); the query term goes through the *same function*, so
  the two sides cannot drift. Rows indexed before 0.4.0 rank as body-only until
  reindexed; nothing breaks.


- **`search_text` now stores a weighted tsvector literal** (`'cheval':1A 'foin':2`) rather
  than plain stemmed text, and every SQL site casts it (`search_text::tsvector`) instead of
  calling `to_tsvector('simple', …)` — the GIN index, the filter and `ts_rank` alike. This
  is what makes `weights` possible. Rows written by 0.4.0 still match after the migration;
  they simply rank flat until reindexed.
- The generated `:upsert` action now accepts **every public writable attribute** of the
  index rather than a fixed list, so a column you add for `index_attribute` is accepted
  without the extension having to know about it.

### Fixed

- **A query with no usable token returned the entire base.** `"de"` (all stopwords) or
  `"b"` (below `min_length`) produced an empty tsquery, which `:search` and
  `:global_search` treated as "no filter" — silently listing everything. Such a term now
  matches **zero rows**. A blank/absent query still lists all (the documented list-UI
  behaviour); only a non-blank, tokenless one changed.


- **A very long token no longer fails the write.** Postgres refuses a lexeme over 2046
  bytes: `to_tsvector` only warns and skips one, but a tsvector *literal* carrying it
  fails to parse — and that parse happens inside the source write's transaction, so a
  record holding a base64 blob, a hash or any long unbroken run would have rolled the
  write back. `SearchCore.Pipeline` now drops such tokens (`:max_bytes`, default 2046) on
  both the indexing and the querying side, matching what `to_tsvector` always did.

### Upgrade notes

- One migration (`mix ash_postgres.generate_migrations`): the new index columns, the GIN
  index rebuilt on the new expression, plus any column you add for `index_attribute`.
- Reindex per tenant afterwards. Search keeps working throughout, so it can be done
  progressively — only ranking is flat until a row is rebuilt.
- Custom SQL written against `to_tsvector('simple', search_text)` must switch to the
  `search_text::tsvector` cast.
- A hand-defined `:upsert` action on your index must accept the new attributes (the
  generated one now accepts every public writable attribute, so it needs no edit).

## 0.3.1

### Fixed

- **`prune/2` failed on a source whose read cannot be keyset-streamed.** It forwarded only
  `:tenant` and `:domain` to the source `Ash.stream!/2`, dropping `:stream_with` — so a
  resource whose default read is offset-only (or otherwise not keyset-streamable) raised
  `Ash.Error.Invalid.NonStreamableAction`, the very case for which `reindex/2` already needed
  `stream_with: :offset`. `prune/2` now forwards `:stream_with`, `:allow_stream_with`,
  `:batch_size` and `:timeout` — the options that control *how* the source is streamed. It
  still refuses to forward anything that changes *which* rows the stream yields (`:action`,
  `:filter`, …), since narrowing the live set would misclassify live rows as orphans and
  delete them.

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
