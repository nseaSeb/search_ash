defmodule SearchAsh.Test.SecuredDocument do
  @moduledoc false
  # A GlobalIndex carrying its own policies, fed by real SearchAsh.Source resources.
  # Two things depend on that being real rather than a table shared with an unpolicied
  # index: the role tests, and the regression that the sync/remove machinery keeps working
  # when an index has policies.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.GlobalIndex],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "test_secured_documents"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  global_index do
    default_language :fr
  end

  policies do
    # `source_type` is stored as a string, so the actor's list holds strings.
    policy action_type(:read) do
      authorize_if expr(source_type in ^actor(:visible_types))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
  end
end
