defmodule BlogWeb.Layouts do
  @moduledoc """
  Root layout for the GreenAsh console. GreenAsh mounts its LiveView with
  `layout: false` and ships no client JS, so the host app must provide the root layout
  that loads the Phoenix/LiveView JS and connects the LiveSocket. Without this the
  console renders but is not interactive.
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
