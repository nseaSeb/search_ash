defmodule SearchDemo.Accounts do
  @moduledoc """
  Domain for console/demo users. Exists so the global search has something to authorize
  *against*: `SearchDemo.Search.Document`'s policies read the actor's `role`.
  """
  use Ash.Domain

  resources do
    resource SearchDemo.Accounts.User do
      define :create_user, action: :create
      define :list_users, action: :read
    end
  end
end
