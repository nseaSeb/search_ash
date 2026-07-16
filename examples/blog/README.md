# blog — search_ash end-to-end

A minimal Ash + AshPostgres app that uses the [`search_ash`](../..) extension. The
`Blog.Post` resource declares search with a single `search do … end` block; the
extension generates the `search_text` column, the keep-in-sync change, the GIN index
and the `:search` action. `Post` also uses **attribute multitenancy** (`org_id`), so
the demo proves search composes with tenant scoping.

## Run it

Requires a reachable Postgres (defaults: `postgres`/`postgres` on `localhost:5432`;
override with `PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT`/`PGDATABASE`).

```sh
mix deps.get
mix ash_postgres.create
mix ash_postgres.migrate
mix run demo.exs
```

Expected: five `[OK]` checks — per-row French/English search, and **tenant isolation**
(two orgs each hold a French "chevaux" document; each org's search returns only its
own row) — plus the stored (stemmed) `search_text` and an `EXPLAIN` plan using
`posts_search_idx` alongside the `org_id` tenant filter.

## Prove the migration round-trips

```sh
mix ash_postgres.generate_migrations --name noop
# => "No changes detected, so no migrations or snapshots have been created."
```

The GIN expression index is tracked in `priv/resource_snapshots`, so regeneration is a
no-op — the extension's "auto-generate the migration" promise holds.

## Global search across entities (Option B)

`demo.exs` shows per-resource search on `Post`. `global_demo.exs` shows a **unified,
cross-entity, tenant-scoped, ranked** search over several source types (factures,
clients, produits) via `Blog.Search.Document`:

```sh
mix run global_demo.exs
```

Each source resource mirrors itself into a single `search_documents` index on
create/update (`Blog.Sales.Changes.SyncToIndex`) and removes itself on destroy
(`RemoveFromIndex`). `Blog.Search.global_search/3` ranks matches with `ts_rank` and
returns `(source_type, source_id, org_id, rank)` — enough to link to the object.
The demo asserts ranking, cross-tenant isolation, and that deleting an object removes
it from the index.

## Browse it in a terminal-style console (GreenAsh)

The app also mounts [GreenAsh](https://hex.pm/packages/green_ash) — an auto-generated
"green screen" admin console over all the Ash resources — at `/cli`:

```sh
PORT=4000 mix run --no-halt   # or: iex -S mix
# open http://localhost:4000/cli
```

Create factures/clients/produits and run the search action from the console; watch the
unified index update live.

> **Note:** GreenAsh mounts its LiveView with `layout: false` and ships no client JS, so
> this example wires the Phoenix/LiveView JS itself — see `lib/blog_web/` (endpoint
> `Plug.Static`, `BlogWeb.Layouts.root/1`, and the router's `:put_root_layout`). In a
> `mix phx.new` app that plumbing already exists.
