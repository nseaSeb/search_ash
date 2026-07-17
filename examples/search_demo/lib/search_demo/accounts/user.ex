defmodule SearchDemo.Accounts.User do
  @moduledoc """
  A demo user with a role. The global search index authorizes against this: a role decides
  **which entity types** a user may find (see `SearchDemo.Search.Document`).

  In the GreenAsh console at `/cli`, `:actor user <id>` makes the console read as this
  user, so you can watch the same query return different rows per role. `:actor none`
  drops back to no actor — and the search then returns nothing, because the policies fail
  closed.
  """
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Accounts,
    data_layer: AshPostgres.DataLayer

  resource do
    description "Utilisateurs de la démo (rôle → ce qu'ils peuvent trouver)"
  end

  postgres do
    table "users"
    repo SearchDemo.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:nom, :role]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :nom, :string, allow_nil?: false, public?: true

    # :admin finds everything; :commercial finds invoices and clients; :support finds
    # clients only. Deliberately coarse — that is the granularity this index can enforce.
    attribute :role, :atom,
      allow_nil?: false,
      public?: true,
      default: :support,
      constraints: [one_of: [:admin, :commercial, :support]]
  end
end
