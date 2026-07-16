import Config

config :blog,
  ecto_repos: [Blog.Repo],
  ash_domains: [Blog.Blog, Blog.Search, Blog.Sales]

config :blog, Blog.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PGDATABASE", "search_ash_blog_example"),
  pool_size: 5

config :logger, level: :warning

# Minimal Phoenix endpoint just to host the GreenAsh console at /cli (dev tool).
config :blog, BlogWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: "dev_only_secret_key_base_at_least_64_bytes_long________________________",
  live_view: [signing_salt: "greenashsalt"],
  render_errors: [formats: [html: BlogWeb.ErrorHTML], layout: false],
  pubsub_server: Blog.PubSub,
  server: true

config :phoenix, :json_library, Jason
