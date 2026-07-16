defmodule SearchDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :search_demo

  @session_options [
    store: :cookie,
    key: "_search_demo_key",
    signing_salt: "greenashsalt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # This example has no esbuild pipeline (it wasn't made with `mix phx.new`), so it serves
  # the vendored Phoenix + LiveView client JS from priv/static/assets. A phx.new app serves
  # its bundled app.js instead — this Plug.Static line is not something GreenAsh requires.
  plug(Plug.Static, at: "/assets", from: {:search_demo, "priv/static/assets"}, gzip: false)

  plug(Plug.Session, @session_options)
  plug(SearchDemoWeb.Router)
end
