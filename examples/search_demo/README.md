# search_demo — a runnable showcase of `search_ash`

A small Ash + AshPostgres application that demonstrates, end to end, the two ways
[`search_ash`](../..) brings full-text search to Ash — plus a terminal console to poke
at it live. It is the integration test-bed for the extension (13 Postgres-backed tests
live in `test/`).

## The domain

A tiny multi-tenant business app. Every resource is scoped by an `org_id` tenant.

| Resource | Domain | Role |
|---|---|---|
| `SearchDemo.Post` | `SearchDemo.Blog` | Blog posts — demonstrates the **search_ash extension** directly on a resource |
| `SearchDemo.Sales.{Facture,Client,Produit}` | `SearchDemo.Sales` | Business objects — the *sources* fed into the global index |
| `SearchDemo.Search.Document` | `SearchDemo.Search` | The **unified global search index** (Option B) |

## What it shows

**1. Per-resource search — the `search_ash` extension (`SearchDemo.Post`).**
`Post` declares search in one block:

```elixir
search do
  fields [:title, :body]
  language_attribute :language
end
```

From that, the extension generates the `search_text` column, a change that keeps it
stemmed and in sync, a GIN index (round-tripped through migrations), and a `:search`
read action — multilingual (per-row language) and tenant-scoped. See `demo.exs`.

**2. Global cross-entity search — the unified index (Option B).**
Factures, clients and produits each mirror themselves into a single
`SearchDemo.Search.Document` table (`SyncToIndex` on create, `RemoveFromIndex` on
destroy). `SearchDemo.Search.global_search/3` ranks matches with `ts_rank` and returns
`(source_type, source_id, org_id, rank)` — enough to link back to the object, and
tenant-isolated by construction. See `global_demo.exs`.

**3. A terminal admin console — [GreenAsh](https://hex.pm/packages/green_ash).**
Mounted at `/cli`, it introspects the Ash resources so you can create factures/clients,
browse the index, and run the search actions from a keyboard-driven "green screen".

## Run it

Requires a reachable Postgres (defaults: `postgres`/`postgres` on `localhost:5432`;
override with `PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT`/`PGDATABASE`).

```sh
mix setup          # deps + create/migrate DB + seed demo data (two orgs)
mix phx.server     # http://localhost:4000/cli  → the GreenAsh console
```

In the console: pick **"Recherche globale — …"** → its `global_search` action → type a
query (e.g. `chevaux`, or a prefix like `boulan`) into the filter.

### The scripted demos

```sh
mix run demo.exs          # per-resource search on Post: multilingual + tenant isolation
mix run global_demo.exs   # global search: ranking + tenant isolation + delete-from-index
```

Each prints `[OK]` checks and an `EXPLAIN` plan showing the GIN index + `org_id` filter.

### Tests

```sh
mix test   # 13 Postgres-backed tests (auto-creates an isolated test DB)
```

They lock every behaviour found while building this: multilingual + tenant-scoped
search, create-indexes / destroy-de-indexes, ranking order, and the search-as-you-type
edge cases (blank query, too-short query, prefix matching, wrong language).

## Notes

- **Multitenancy** uses `global? true`, so tenant-less reads (the admin console) list
  across orgs while a tenant-scoped query stays isolated — the app/API always passes a
  tenant.
- The search actions accept a **blank query (lists all)** and match the last token as a
  **prefix** (`boulan` → `boulangerie`), which is what a live search box expects.
- This example is a **build-free** Phoenix host (`mix new --sup`, not `mix phx.new`), so it
  has no esbuild/`app.js` pipeline. It therefore vendors the Phoenix/LiveView JS and wires
  the LiveSocket by hand — see `lib/search_demo_web/` (endpoint `Plug.Static`,
  `SearchDemoWeb.Layouts.root/1`, the router's `:put_root_layout`). In a standard
  `mix phx.new` app this is all generated boilerplate and `green_ash "/cli"` is a
  one-liner; the hand-wiring here is a property of this bare host, not of GreenAsh.
