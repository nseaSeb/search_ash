# Building a global search

From nothing to a working results page: one search box over every entity type in your
app, ranked, paginated, tenant-scoped.

This guide makes the calls rather than listing options — where a choice matters, it says
which one to take and why, and flags the case that deserves the other. Every snippet
mirrors [`examples/search_demo`](https://github.com/nseaSeb/search_ash/tree/main/examples/search_demo),
so you can clone it and watch the same code run.

For the reference (every option, every default), see `SearchAsh.GlobalIndex` and
`SearchAsh.Source`. For how it works underneath, see [Architecture](architecture.md).

## The model, in three minutes

One **index resource** holds one row per indexed object. Each **source resource** mirrors
itself into it on every write, inside the same transaction — so the index cannot drift
from your data, and there is no separate service to run or synchronise.

A row carries: what kind of thing it is (`source_type`), how to find it again
(`source_id`), the stemmed text to match on, a **label** to display, and whatever typed
columns you declare for filtering and sorting.

That is the whole idea. Everything below is choosing what goes in those fields.

## 1. The decision that matters most: your label

Before any code. **`label_field` is the highest-leverage choice in the whole
configuration**, because three separate things are built on it:

- it is what a result *displays*;
- it drives **ranking** — a row whose label *is* what the user typed beats a row that
  merely mentions it often;
- it is the only thing **typo tolerance** looks at.

So point it at what a user would type to find this object *by name*:

| entity | `label_field` | why |
|---|---|---|
| facture, bon de livraison | the **number** | people search `BL-2024-0012`, not the description |
| client, fournisseur | the **name** | |
| produit | the **libellé**, or the reference if that is what staff use | |

Get this wrong — point it at a description, or leave it out — and the ranking tiers and
`fuzzy?` both go inert while everything still "works". That is the failure mode to avoid,
because nothing signals it.

> **The exception.** A label is returned to anyone who may search the index. If your
> "name" is sensitive, point `label_field` at a reference instead: a result then reveals
> that a match exists, not what it says.

## 2. Declare the index

An ordinary Ash resource. Multitenancy, policies, extra attributes — all yours.

```elixir
defmodule SearchDemo.Search.Document do
  use Ash.Resource,
    domain: SearchDemo.Search,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.GlobalIndex]

  postgres do
    table "search_documents"
    repo SearchDemo.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  global_index do
    default_language :fr
    fuzzy? true          # typo tolerance; needs "pg_trgm", see step 4
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true

    # Filled by the sources in step 3. Declared here, on the index — a source cannot add
    # a column to a resource it does not own.
    attribute :document_date, :date, public?: true   # a date:    range filters, sorting
    attribute :statut, :string, public?: true        # a keyword: exact filters, facets
  end
end
```

**Turn `fuzzy?` on.** It costs one extra index and it is what makes `duont` find `Dupont`
and `0012` find `BL-2024-0012`. Leave it off only if you cannot add the `pg_trgm`
extension.

## 3. Feed it from each source

```elixir
# a facture
searchable do
  index SearchDemo.Search.Document
  source_type :facture
  fields [:numero, :client_nom, :description]
  label_field :numero

  # A hit in the number outranks one in the client name, which outranks the body.
  weights %{numero: :a, client_nom: :b}

  index_attribute :document_date, :date_emission
  index_attribute :statut, :statut
  excerpt_length 160
end
```

```elixir
# a client
searchable do
  index SearchDemo.Search.Document
  source_type :client
  fields [:nom, :email, :notes]
  label_field :nom
  weights %{nom: :a}
  index_attribute :document_date, &DateTime.to_date(&1.inserted_at)
end
```

Three calls to make here.

**Put your reference in `fields` *and* in `label_field`.** Not one or the other. In
`fields` it becomes searchable text (so `2024` finds it); as the label it drives ranking
and fuzzy matching.

**Declare `weights`.** Anything you leave out sits at `:d`, the floor. A reference or a
name belongs at `:a`, a secondary name at `:b`, free text nowhere. There are four classes
and no more — a tsvector stores two bits of weight per lexeme — so think in buckets, not
in percentages. (`weight_values` on the index prices the buckets if the defaults do not
suit: `%{b: 0.9}` brings class `:b` almost level with `:a`.)

**Set `excerpt_length` on the sources whose content you will display**, and leave it off
on the others. An excerpt puts *content* in the index, readable by anyone who may search
it — a different exposure from a label.

### Text that lives on related records

To answer "which factures mention tomatoes?", the lines' text has to reach the facture's
document:

```elixir
load [:lignes]
extra_text fn facture -> Enum.map(facture.lignes, & &1.designation) end
```

`extra_text` is repeatable and each entry carries its own weight class, so a date spelled
out can outrank body text:

```elixir
extra_text &date_in_words(&1.date_emission), weight: :c
```

That last one is worth knowing: because indexing and querying run through the same
pipeline, **a date written out is just more text** — `juillet` in the search box finds the
factures of that month, with no support needed from the extension. Month names stem
identically on both sides, accents included.

> **The catch, and it is a real one.** The sync fires on writes to *this* resource. Edit
> a *ligne* directly and the facture's row keeps the old text — nothing observable
> happened on the facture. Reconcile with `SearchAsh.reindex_one/3` (step 8), or add a
> change on the child that touches its parent.

## 4. Migrate and backfill

```sh
mix ash_postgres.generate_migrations --name global_search
mix ecto.migrate
```

If you turned `fuzzy?` on, add the extension to your repo **first**, or the migration
fails when it creates the trigram index:

```elixir
def installed_extensions, do: ["pg_trgm"]
```

Then backfill what already exists, **once per tenant**:

```elixir
SearchAsh.reindex(SearchDemo.Sales.Facture, tenant: org_id)
```

## 5. The results page

Here is the whole thing. Everything below is one action and one helper.

```elixir
def search(query, opts) do
  actor  = opts[:actor]
  tenant = opts[:tenant]

  page =
    SearchDemo.Search.Document
    |> Ash.Query.for_read(:global_search, %{query: query, types: opts[:types]})
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read!(actor: actor, page: [limit: 20, offset: opts[:offset] || 0, count: true])

  %{
    results: page.results,
    total:   page.count,
    tabs:    SearchAsh.counts_by_type(SearchDemo.Search.Document, query,
               tenant: tenant, actor: actor)
  }
end
```

- **`types`** restricts to entity kinds, for tabs. `nil` and `[]` both mean "no filter",
  so an empty multi-select never silently returns nothing.
- **`count: true`** gives the header total; `counts_by_type/3` gives the per-tab badges,
  and both go through the same action, so both honour your policies.
- Results come back ranked: exact label, then starts-with, then contains, then body match
  — and `ts_rank` within each tier.

Each result carries `(source_type, source_id)`, which is how you link back:

```heex
<a href={path_for(result.source_type, result.source_id)}>{result.label}</a>
```

### Highlighting the excerpt

`SearchCore.highlight/4` marks the words that actually matched, and returns segments
rather than markup, so the rendering stays yours:

```elixir
SearchCore.highlight(result.excerpt, query, :fr)
#=> [{:text, "Livraison de "}, {:match, "tomates"}, {:text, " anciennes"}]
```

```heex
<p>
  <%= for segment <- SearchCore.highlight(@result.excerpt, @query, :fr) do %>
    <%= case segment do %>
      <% {:match, text} -> %><mark>{text}</mark>
      <% {:text, text} -> %>{text}
    <% end %>
  <% end %>
</p>
```

It runs the same pipeline as the search, so a word is highlighted exactly when it is a
word that matched — `tomate` highlights `tomates`, `idee` highlights `idées`.

## 6. Filtering and sorting

`index_attribute` gives you the two field types full-text search cannot provide on its
own — and the demo uses all three side by side:

| type | how | what it is for |
|---|---|---|
| **analysed text** | `fields` (+ `extra_text`) | matching words, stemmed and weighted |
| **keyword** | `index_attribute` onto a string column | exact filters and facets — a status, a reference, a foreign key |
| **date / number** | `index_attribute` onto a date or numeric column | range filters and sorting |

A keyword column is stored raw and never analysed, which is exactly what an exact filter
needs:

```elixir
# on the index
attribute :statut, :string, public?: true

# on the source — typed as an atom there, flat on the index
index_attribute :statut, :statut
```

The three compose in one query:

```elixir
|> Ash.Query.for_read(:global_search, %{query: "farine"})   # analysed text
|> Ash.Query.filter(statut == "envoyee")                    # keyword
|> Ash.Query.filter(document_date >= ^~D[2026-07-01])       # date
```

The typed columns are ordinary Ash attributes, so nothing new is needed:

```elixir
|> Ash.Query.filter(document_date >= ^from and document_date <= ^to)
|> Ash.Query.sort(document_date: :desc_nils_last)
```

**One date axis, not one per entity.** A document has several dates — issued, delivered,
due, created — and every entity type names them differently. Point *every* source at the
**same** column, from whatever "the date this is from" means for it:

```elixir
index_attribute :document_date, :date_emission                     # facture
index_attribute :document_date, :date_livraison                    # bon de livraison
index_attribute :document_date, &DateTime.to_date(&1.inserted_at)  # produit — no business date
```

That is what makes "most recent first" mean anything on a page mixing entity types. Add a
*second* column only when you genuinely filter on a second axis, and expect it to be
`NULL` for the types that have none — which is why the sort above says
`:desc_nils_last`, since Postgres puts NULLs **first** in a plain `:desc`.

## 7. Authorization

**The library never evaluates your rights, and never stores them.** It indexes content and
gives you something to filter on. The rule that follows:

> **Derived from content → the index may carry it. An authorization fact → never.**

"This document belongs to client 42" is content: it changes when the document changes, so
the sync rewrites it. "User 7 may read this document" changes on its own, nothing triggers
a re-index, and a stale row of that kind is a security incident rather than a cosmetic
bug.

You have two levers, and they are not equivalent.

**Filter in SQL.** Either a policy on the index resource (`source_type` works today, and
so does any column you added with `index_attribute`), or your own filter on the query:

```elixir
|> Ash.Query.filter(client_id in ^clients_this_user_may_see)
```

**Or filter at render**, after the search returns. This is safe — nothing leaks — but it
is arithmetic you have to accept, because the count and the pages were computed over what
SQL matched, not over what you display. Measured, on 100 matching documents with a page
of 20:

| user's access rate | count shown | results visible on page 1 |
|---|---|---|
| 90 % | 100 | 20/20 |
| 50 % | 100 | 9/20 |
| 5 % | 100 | **1**/20 |

So: **if your users can see nearly everything, filter at render and move on.** If access
is partial or clustered, get the coarse dimension into SQL — which is what
`index_attribute :client_id, :client_id` is for — and keep the fine-grained check at
render as a safety net.

If you would rather not show a total at all, bound the result set instead of paginating:
`default_limit` on the index does that, and the action then returns an `Ash.Page` rather
than a list.

## 8. What breaks in production, and the repair

Indexing rides on Ash actions. A write that goes straight to the database — a raw
`Repo.query!`, a SQL cascade updating a denormalised column, a restore from a trash table
— never reaches the sync, and the index keeps the old document with nothing to signal it.

```elixir
# after the write commits, outside any transaction
SearchAsh.reindex_one(SearchDemo.Sales.Facture, id, tenant: org_id)
```

It re-reads the record and works out what to do: present → re-indexed, gone → removed or
archived exactly as a destroy through Ash would have. Idempotent, so the call site never
has to know which.

To sweep a whole source for rows whose record no longer exists:

```elixir
SearchAsh.prune(SearchDemo.Sales.Facture, tenant: org_id)   # => count of rows acted on
```

That count doubles as a **drift metric**: on a healthy database it is `0`. If it is not,
something is writing around Ash somewhere — that is the signal to go looking.

`prune/2` is the one destructive call in the library, so do not take it on trust:
[`global_demo.exs`](https://github.com/nseaSeb/search_ash/tree/main/examples/search_demo)
plays the whole sequence against a real database — a row inserted in raw SQL stays
invisible until `reindex/2`, a row deleted in raw SQL keeps surfacing in results as an
orphan pointing at nothing, and `prune/2` sweeps it and returns the count. Run it before
you point either at production data.

## Where to look next

- `SearchAsh.GlobalIndex` and `SearchAsh.Source` — every option and its default.
- [Architecture](architecture.md) — the indexing and query paths, and the pipeline
  symmetry the whole design rests on.
- [Roadmap](roadmap.md) — what is deliberately not built, including synonyms, and what
  was refused.
