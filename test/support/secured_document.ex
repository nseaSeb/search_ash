defmodule SearchAsh.Test.SecuredDocument do
  @moduledoc false
  # A `SearchAsh.GlobalIndex` that carries its own policies, over the same table as
  # `SearchAsh.Test.SearchDocument`. Pins the documented capability: the index does not
  # inherit its sources' policies, but `:global_search` is a plain read action, so
  # policies here compose with it.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.GlobalIndex],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "test_search_documents"
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
