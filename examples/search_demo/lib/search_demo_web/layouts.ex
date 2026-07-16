defmodule SearchDemoWeb.Layouts do
  @moduledoc """
  Root layout for the GreenAsh console.

  This example is a **deliberately build-free** Phoenix host: it was scaffolded with
  `mix new --sup` (not `mix phx.new`), so there is no esbuild/`app.js` asset pipeline.
  This root layout therefore vendors `phoenix(.min).js` + `phoenix_live_view(.min).js`
  from deps (see the endpoint's `Plug.Static`) and connects the LiveSocket here.

  In a standard `mix phx.new` app none of this is bespoke: the generated `root.html.heex`
  already loads `app.js` (which bundles those libs and calls `liveSocket.connect()`), and
  `green_ash "/cli"` mounts in one line. The root layout comes from the host's `:browser`
  pipeline (`put_root_layout`) — GreenAsh's `layout: false` only disables the *app*
  layout, not this one.
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>GreenAsh console</title>
        <script defer src="/assets/phoenix.min.js">
        </script>
        <script defer src="/assets/phoenix_live_view.min.js">
        </script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var token = document.querySelector("meta[name='csrf-token']").getAttribute("content");
            var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: { _csrf_token: token }
            });
            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
