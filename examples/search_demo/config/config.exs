import Config

config :search_demo,
  ecto_repos: [SearchDemo.Repo],
  ash_domains: [SearchDemo.Blog, SearchDemo.Search, SearchDemo.Sales]

config :search_demo, SearchDemo.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  # Per-env DB name so `mix test` uses its own database, isolated from dev data.
  database: System.get_env("PGDATABASE", "search_demo_#{config_env()}"),
  pool_size: 5

# :info so `mix phx.server` prints "Running SearchDemoWeb.Endpoint at http://localhost:4000"
# and request logs. (SQL/Ash debug stays hidden — it's at :debug.)
config :logger, level: :info

# Minimal Phoenix endpoint just to host the GreenAsh console at /cli (dev tool).
config :search_demo, SearchDemoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: "dev_only_secret_key_base_at_least_64_bytes_long________________________",
  live_view: [signing_salt: "greenashsalt"],
  render_errors: [formats: [html: SearchDemoWeb.ErrorHTML], layout: false],
  pubsub_server: SearchDemo.PubSub

# No `server: true`: `mix phx.server` starts the web server; plain `mix run <script>`
# (the demos) does not, so it never tries to bind the port.

config :phoenix, :json_library, Jason
