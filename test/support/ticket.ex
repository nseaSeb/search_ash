defmodule SearchAsh.Test.Ticket do
  @moduledoc false
  # `label_field` deliberately OUTSIDE `fields`: you search the body, you display the subject.
  #
  # Every other fixture has its `label_field` included in `fields`, which is why the sync's
  # `recompute?` short-circuit could ignore `label_field` for two releases without a single
  # test noticing: renaming the label changed no *watched* attribute, so no upsert ran and the
  # index kept the old label.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_tickets"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SearchDocument
    source_type :ticket
    fields [:body]
    label_field :subject
    language :fr
  end

  actions do
    defaults [:read]

    create :create do
      accept [:subject, :body]
    end

    update :update do
      accept [:subject, :body]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :subject, :string, public?: true
    attribute :body, :string, public?: true
  end
end
