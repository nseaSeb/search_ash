defmodule SearchAsh.Test.SecuredInvoice do
  @moduledoc false
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_secured_invoices"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SecuredDocument
    source_type :invoice
    fields [:number]
    label_field :number
    language :fr
  end

  actions do
    defaults [:read]
    create :create, do: accept([:number])
    destroy :destroy
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :number, :string, public?: true
  end
end
