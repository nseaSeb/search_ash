defmodule SearchDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SearchDemo.Repo,
      {Phoenix.PubSub, name: SearchDemo.PubSub},
      SearchDemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SearchDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
