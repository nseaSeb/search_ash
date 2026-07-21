# Roadmap

What is deliberately not built yet, why, and — where the shape is already settled — how it
would be built. Also what was **refused**, since "why we said no" is the part that gets
relitigated.

The goal that orders this list: cover what the global search of a business application
actually needs — without a separate search service to run, and with an index that lives in
the same transaction as your data.

---

## Synonyms

**The need.** Users type `BL`, the documents say `bon de livraison`. Abbreviations,
internal jargon, product codes. Today neither full-text (different lexemes) nor `fuzzy?`
(trigram distance far too large) bridges that.

**The shape, settled:**

```elixir
global_index do
  synonyms %{fr: %{"bl" => ["bon de livraison"], "cde" => ["commande"]}}
  # or, to let a domain expert edit them without a deploy:
  synonyms {MyApp.Search, :synonyms}     # -> fun(language) :: %{String.t() => [String.t()]}
end
```

### Expansion happens at QUERY time, not at index time

The decision that matters. Expanding at index time (storing `bon livraison` into the
`search_text` of every row whose text says `bl`) would mean **a full reindex of every
tenant every time someone edits the map** — and would inflate `search_text` and blur
`excerpt`. Expanding at query time makes an edit take effect on the next search, at the
cost of a slightly larger `tsquery`. Synonyms are the kind of thing a domain expert tunes
repeatedly; paying a full reindex per edit would make them unusable in practice.

### The expansion goes through the same pipeline

`"bon de livraison"` must be tokenized, stopworded, stemmed and accent-folded exactly like
indexed text, or it cannot match what is stored — `de` is a stopword, so the value becomes
`["bon", "livraison"]`. This is the same index/query symmetry that `searchable_text` and
`tsquery` already guarantee, applied to a third channel; the synonym values must never be
injected raw.

A multi-word value therefore becomes an AND-group inside an OR:

```
query "bl dupont"  ->  (bl | (bon & livraison)) & dupont
```

which means `SearchCore.Tsvector.tsquery/3` has to learn parentheses — it currently emits a
flat `a & b`. That is the one non-trivial piece of work.

### Deliberate limits

- **Single-token keys only.** `%{"bl" => …}` matches however it was typed (lookup happens
  on the *processed* token, so `BL`/`bl`/`Bl` all hit). A multi-word *key* would require
  phrase detection in the query — much harder, and abbreviations are the 90% case.
- **One-way.** `"bl" => ["bon de livraison"]` does not imply the reverse. Someone wanting
  symmetry adds both entries. Predictable beats clever.
- **Per language**, keyed like everything else in the stack by ISO code.
- **Off by default.** Expansion widens the query, so more rows get scored (see the
  `ts_rank` note below) and precision drops — the same trade-off `fuzzy?` makes.
- **Does not affect label ranking.** `label_match_tier` and `fuzzy?` compare the raw
  normalized label, so a synonym will not make `bl` reach tier 0 on a label reading
  `Bon de livraison 12`. Synonyms widen *what matches*, not *how labels rank*.

---

## Facets / aggregations

Counting for the side filters of a results page — matches per date bucket, per status, per
category.

`SearchAsh.counts_by_type/3` already does exactly this, hardwired to `source_type`. Now
that `index_attribute` gives typed columns, the generalization is to count by any of them,
and by date buckets. Deferred because it changes the counting API and adds no column, so it
never needed to share a migration with the schema work.

---

## Async indexing

`indexing_strategy :sync | :notify | :manual` on `SearchAsh.Source`, with **no hard Oban
dependency**: `:notify` emits an Ash notification, `:manual` lets the host drive a durable
job while keeping the DSL, `Document.to_attrs/2` and `reindex/2`.

Today indexing is synchronous inside the source write's transaction — which is the whole
reason the index cannot drift. The async path trades that guarantee for write latency, so
it must be an explicit choice, never a default.

---

## Cross-language search

One query probing several languages at once. Each row is pre-stemmed in its own language
into a `'simple'` tsvector, so a search currently probes one language at a time.

---

## A `:native` per-row `regconfig` strategy

Using Postgres's own stemmers (`to_tsvector('french', …)`) instead of the Elixir pipeline,
for the languages Postgres supports. Would cost the per-row-language freedom that motivated
`:pre_stemmed` in the first place, so it is an alternative strategy, never a replacement.

---

## Semantic / vector search

Vector similarity in Postgres, plus an embedding model to produce the vectors. A different
problem with its own cost model — a possible extension point, not a goal.

---

## Refused, with the reason

**BM25 relevance ranking.** *(Per-field `weights` shipped in 0.4.0 — this is about going
further.)* Its three ideas — inverse document frequency, term-frequency
saturation, length normalization — fix the failure modes of *long, heterogeneous* corpora:
keyword stuffing, and long documents drowning short precise ones. Business documents are
short and structured; nobody keyword-stuffs an invoice. Getting real BM25 in Postgres means
a heavy third-party extension, against this project's no-NIF, minimal-dependency line.
Weighted fields (`setweight`) cover the practical need better: with structured data you
*know* the reference outweighs the description — declaring it is more predictable than
discovering it statistically.

**Copying authorization into the index (`extra_attrs`).** The rule the whole design follows:

> **Derived from content → the index may carry it. Authorization fact → never.**

"This document belongs to client 42" changes when the document changes, so the sync
re-syncs it. "User 7 may read this document" changes on its own — nothing triggers a
re-index, and a stale authorization row is a security incident rather than a cosmetic bug.
Filter on content columns and keep the rule in your application; see the authorization
section of `SearchAsh.GlobalIndex`.

---

## Known limits, not planned as work

- **`ts_rank` has no top-k optimization**: ranking scores every matching row, so cost
  follows how many rows *match*, not table size. Selective queries stay fast on a large
  table; a very broad one is where it would be felt. A tenant filter absorbs most of it.
- **Composite string primary keys can collide** in `source_id` (`":"`-joined). Fixing it
  changes the stored format, so it waits for a major version.
- **Index creation is not `CONCURRENTLY`** — plan the migration on a large existing table.
