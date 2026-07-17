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
  archived boolean NOT NULL DEFAULT false,
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
  discontinued boolean NOT NULL DEFAULT false,
  language text NOT NULL
)
""")

# A policied index, with real sources feeding it: the machinery must keep working when an
# index carries policies, and a shared table would not prove that.
for t <- ~w(test_secured_documents test_secured_products test_secured_invoices) do
  Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS #{t}", [])
end

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_secured_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  source_type text NOT NULL,
  source_id text NOT NULL,
  language text NOT NULL,
  search_text text,
  archived boolean NOT NULL DEFAULT false,
  label text,
  UNIQUE (org_id, source_type, source_id)
)
""")

Ecto.Adapters.SQL.query!(Repo, """
CREATE INDEX test_secured_documents_search_idx
ON test_secured_documents USING GIN (to_tsvector('simple', search_text))
""")

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_secured_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  name text
)
""")

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_secured_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  number text
)
""")

Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_static_pages", [])

# Deliberately has no `language` column: this resource fixes its language statically.
Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_static_pages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  title text,
  body text
)
""")

Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_invoices", [])

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  number text,
  deleted_at timestamptz,
  language text NOT NULL
)
""")

# Composite primary key + a filtering read policy: the two properties `reindex_one/3`'s
# riskiest paths need and no other test resource has (see SearchAsh.Test.LineItem).
Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_line_items", [])

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_line_items (
  order_id text NOT NULL,
  line_no integer NOT NULL,
  org_id text NOT NULL,
  description text,
  hidden boolean NOT NULL DEFAULT false,
  PRIMARY KEY (order_id, line_no)
)
""")

# `label_field` outside `fields` (see SearchAsh.Test.Ticket): the subject is displayed, the
# body is searched.
Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_tickets", [])

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  subject text,
  body text
)
""")

# A source whose read is offset-only (not keyset-streamable), for the prune stream_with test
# (see SearchAsh.Test.OffsetPage).
Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_offset_pages", [])

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_offset_pages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  title text
)
""")

# Soft delete via `base_filter`: the row stays, `deleted_at` hides it (see
# SearchAsh.Test.TrashableNote).
Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS test_trashable_notes", [])

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE test_trashable_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  title text,
  deleted_at timestamptz
)
""")

ExUnit.start()
