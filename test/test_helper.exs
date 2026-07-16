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

Ecto.Adapters.SQL.query!(Repo, """
CREATE TABLE IF NOT EXISTS test_articles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id text NOT NULL,
  title text,
  body text,
  language text NOT NULL,
  search_text text
)
""")

Ecto.Adapters.SQL.query!(Repo, """
CREATE INDEX IF NOT EXISTS test_articles_search_idx
ON test_articles USING GIN (to_tsvector('simple', search_text))
""")

ExUnit.start()
