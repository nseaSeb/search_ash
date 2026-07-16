defmodule BlogWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :blog

  @session_options [
    store: :cookie,
    key: "_blog_key",
    signing_salt: "greenashsalt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  # Serves the Phoenix + LiveView client JS (copied from deps into priv/static/assets),
  # so GreenAsh's LiveView console becomes interactive without an esbuild pipeline.
  plug Plug.Static, at: "/assets", from: {:blog, "priv/static/assets"}, gzip: false

  plug Plug.Session, @session_options
  plug BlogWeb.Router
end
