# Upgrading to 0.4

0.4.0 brings everything a results page needs — pagination, tabs, excerpts — and then what
it takes to filter, sort and rank properly. The API is additive and the new columns are
nullable, so this is not a breaking release. But `search_text` **changes storage format**,
so it is worth reading the first section before you plan the migration.

## What happens if you only migrate

Measured on a database written by 0.3.x:

| | migration only | after a reindex |
|---|---|---|
| do searches still find their rows? | **yes** | yes |
| ranking | **flat** — every row scores the same | differentiated |
| `weights`, per-field boosts | no effect yet | applied |
| `label_normalized`, `excerpt`, typed columns | `NULL` | filled |

The old format is plain stemmed text (`cheval foin`), and Postgres casts that to a
tsvector quite happily — it simply has no positions and no weights. So **matching is
unaffected and you can reindex progressively, with search running throughout.**

## 1. Migrate

```sh
mix ash_postgres.generate_migrations --name search_ash_0_4
mix ecto.migrate
```

One migration, containing:

- the new index columns `label_normalized` and `excerpt`;
- the GIN index dropped and recreated on the new expression
  (`(search_text::tsvector)` instead of `(to_tsvector('simple', search_text))`);
- the trigram index, if you opt into `fuzzy?`;
- any column you add for `index_attribute`.

On a large table, note that index creation is not `CONCURRENTLY` — plan it like any other
index rebuild.

If you enable `fuzzy? true`, add `"pg_trgm"` to your repo first, or the migration fails
when it tries to create the trigram index:

```elixir
def installed_extensions, do: ["pg_trgm"]
```

## 2. Reindex, per tenant

```elixir
SearchAsh.reindex(MyApp.Sales.Facture, tenant: org_id)
```

Until a row is reindexed it keeps matching but ranks flat, so there is no rush and no
ordering constraint between tenants.

## 3. Three behaviour changes to know

**A query with no usable token now returns nothing.** Before, a term like `"de"` (all
stopwords) or `"b"` (below `min_length`) produced an empty tsquery, which was treated as
"no filter" — the action listed the entire base. That was a bug. A blank or absent query
still lists everything (the documented list-UI behaviour); only a non-blank term whose
tokens are all eliminated now matches zero rows.

**Result order changed.** `:global_search` ranks label matches first: exact label >
starts-with > contains > body-only match, then `ts_rank` within a tier. A user searching
`chevaux` now sees the client *named* "Chevaux & Co" above an invoice that merely mentions
horses often. If you depended on pure `ts_rank` order, sort yourself.

**Custom SQL must switch to the cast.** Anything referencing
`to_tsvector('simple', search_text)` becomes `search_text::tsvector`. The two are no
longer interchangeable: the column holds a tsvector literal, and `to_tsvector` would
re-tokenize it into nonsense.

## 4. One edge case: a hand-defined `:upsert`

If you defined your **own** `:upsert` action on the index resource, it must accept the new
attributes. The generated one now accepts every public writable attribute, so it needs no
edit — this only affects a hand-written one:

```elixir
create :upsert do
  accept [:source_type, :source_id, :language, :search_text, :archived,
          :label, :label_normalized, :excerpt]
  upsert? true
  upsert_identity :unique_source
end
```

## 5. New, all optional

### A results page

- **Pagination** on `:search` and `:global_search` — `page: [limit: 20, offset: 0,
  count: true]`, offset and keyset, never required.
- **`types` argument** on `:global_search` — restrict to entity kinds for tabs; `nil` and
  `[]` both mean "no filter", so an empty multi-select never yields zero results.
- **`SearchAsh.counts_by_type/3`** — per-type counts for tab badges, composing with the
  index's policies.
- **`excerpt_length`** — store a raw excerpt for display, highlighted with
  `SearchCore.highlight/4`.
- **`default_limit`** — bound the results when the caller asks for no page at all. Unset
  by default; **setting it makes the action return an `Ash.Page` rather than a list.**

### Filtering and sorting

```elixir
# on the index resource
attribute :document_date, :date, public?: true

# on each source
searchable do
  index_attribute :document_date, :date_emission
end
```

Then, with no new API:

```elixir
|> Ash.Query.filter(document_date >= ^from and document_date <= ^to)
|> Ash.Query.sort(document_date: :desc)
```

**One axis, many sources.** A document has several dates and every entity type names them
differently. Map each source's own attribute onto the *same* column, so a mixed results
page can sort by recency at all. Add a second column only for a genuinely second axis, and
expect it to be `NULL` for the types that have none — which is also how they sort, so
reach for `:desc_nils_last`.

### Ranking

```elixir
# on the source: which class each field belongs to
weights %{numero: :a, client_nom: :b}

# on the index: what a class is worth
weight_values %{b: 0.9}     # Postgres' defaults: a: 1.0, b: 0.4, c: 0.2, d: 0.1
```

There are four classes and no more — a tsvector stores two bits of weight per lexeme.

### Typo tolerance

`fuzzy? true` matches the normalized label by trigram similarity and substring: `duont`
finds `Dupont`, `12` finds `BL-2024-0012`. `fuzzy_threshold` (default `0.35`) tunes how
close is close enough; lowering it below your database's `pg_trgm.similarity_threshold`
does nothing.

### Text from related records

```elixir
load [:lignes]
extra_text fn commande -> Enum.map(commande.lignes, & &1.designation) end
extra_text &date_in_words(&1.date_emission), weight: :c
```

Repeatable, each entry with its own rank class. Mind the staleness contract documented on
`SearchAsh.Source`: a direct write to the *related* resource does not re-index the parent.

### Dates in words — no option needed

Because indexing and querying run through the same pipeline, a date spelled out is just
more text, so a search box where users type `juillet` needs nothing special:

```elixir
extra_text &format_date_in_words(&1.date_emission)
```

Month names stem identically on both sides (`février` and `fevrier` both reach `fevri`),
in every language the stemmer supports. Keep it alongside the typed `document_date`
column: one serves the search box, the other range filters and sorting.
