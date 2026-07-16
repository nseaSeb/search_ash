import Config

# Test-only: a Postgres repo + domain for the extension's integration tests.
if config_env() == :test do
  config :search_ash,
    ecto_repos: [SearchAsh.Test.Repo],
    ash_domains: [SearchAsh.Test.Domain]

  config :search_ash, SearchAsh.Test.Repo,
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "5432")),
    database: System.get_env("PGDATABASE", "search_ash_test"),
    pool_size: 5

  config :logger, level: :warning
end
