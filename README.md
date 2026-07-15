# search_ash

An [Ash](https://ash-hq.org) extension for **multilingual full-text search**. One
`search do … end` block on a resource generates everything needed for Postgres
tsvector search — no hand-written migrations, changes or SQL.

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

## Options

| Option | Default | Meaning |
|---|---|---|
| `fields` (required) | — | Attributes whose text is indexed |
| `language_attribute` | `:language` | Attribute holding each row's language |
| `search_text_attribute` | `:search_text` | Where stemmed tokens are stored (added if absent) |
| `index_name` | `"<table>_search_idx"` | Name of the generated GIN index |
| `action` | `:search` | Name of the generated read action |

## Verify end-to-end

See [`examples/blog`](examples/blog) for a runnable multilingual demo against real
Postgres, including the `EXPLAIN` that confirms the GIN index is used.

## Status

MVP (`:pre_stemmed` strategy). Deferred: a `:native` per-row-`regconfig` strategy
(no NIF, Postgres-supported languages only) and ranking (`ts_rank`/`setweight`).
