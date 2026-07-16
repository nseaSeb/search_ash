alias SearchAsh.Test.Repo

# Create the test database if needed, then bring up a minimal schema by hand (no
# migrations needed for a single test resource). The GIN index mirrors what the
# extension generates.
case Repo.__adapter__().storage_up(Repo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
  other -> raise "could not create test DB: #{inspect(other)}"
end

{:ok, _} = Repo.start_link()

# Recreate the schema from scratch each run, so a changed test resource never runs
# against a stale table.
Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_articles", [])

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_articles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  title text,
  body text,
  language text NOT NULL,
  search_text text
)
""")

Ecto.Adapters.SQL.query!(Repo, """
CREATE INDEX test_articles_search_idx
ON test_articles USING GIN (to_tsvector('simple', search_text))
""")

# Unified index (SearchAsh.GlobalIndex) + a source resource (SearchAsh.Source).
Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_search_documents", [])
Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_products", [])

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_search_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  source_type text NOT NULL,
  source_id text NOT NULL,
  language text NOT NULL,
  search_text text,
  state text NOT NULL DEFAULT 'active',
  label text,
  UNIQUE (org_id, source_type, source_id)
)
""")

Ecto.Adapters.SQL.query!(Repo, """
CREATE INDEX test_search_documents_search_idx
ON test_search_documents USING GIN (to_tsvector('simple', search_text))
""")

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  name text,
  sku text,
  status text NOT NULL DEFAULT 'active',
  language text NOT NULL
)
""")

ExUnit.start()
