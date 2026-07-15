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
