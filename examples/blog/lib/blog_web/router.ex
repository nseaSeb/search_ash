defmodule BlogWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import GreenAsh.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Root layout that loads the LiveView JS so GreenAsh's console is interactive.
    plug :put_root_layout, html: {BlogWeb.Layouts, :root}
  end

  scope "/" do
    pipe_through :browser

    # Terminal-style admin console over all configured Ash domains
    # (Blog.Blog, Blog.Search, Blog.Sales). Dev tool only.
    green_ash "/cli"
  end
end
