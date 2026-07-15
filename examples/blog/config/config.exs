import Config

config :blog,
  ecto_repos: [Blog.Repo],
  ash_domains: [Blog.Blog]

config :blog, Blog.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PGDATABASE", "search_ash_blog_example"),
  pool_size: 5

config :logger, level: :warning
