defmodule SearchDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :search_demo

  @session_options [
    store: :cookie,
    key: "_search_demo_key",
    signing_salt: "greenashsalt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  # Serves the Phoenix + LiveView client JS (copied from deps into priv/static/assets),
  # so GreenAsh's LiveView console becomes interactive without an esbuild pipeline.
  plug Plug.Static, at: "/assets", from: {:search_demo, "priv/static/assets"}, gzip: false

  plug Plug.Session, @session_options
  plug SearchDemoWeb.Router
end
