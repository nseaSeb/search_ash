# Design notes & non-goals

Where the design stands on what is **not built yet** — the reasoning, the trade-offs, and
what was **refused**. This is not a roadmap: no dates, no commitments. It records *how we
think about* each direction so the decisions don't get relitigated; some of these may never
ship.

What orders the list: cover what the global search of a business application actually needs
— without a separate search service to run, and with an index that lives in the same
transaction as your data.

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
