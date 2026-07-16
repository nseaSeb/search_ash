defmodule SearchDemo.Sales.Client do
  @moduledoc "A demo source entity. On create it mirrors itself into the search index."
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Sales,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "clients"
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
      accept [:nom, :email, :notes, :language]

      change {SearchDemo.Sales.Changes.SyncToIndex,
              source_type: "client",
              fields: [:nom, :email, :notes],
              label_field: :nom}
    end

    destroy :destroy do
      require_atomic? false
      change {SearchDemo.Sales.Changes.RemoveFromIndex, source_type: "client"}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :nom, :string, allow_nil?: false, public?: true
    attribute :email, :string, public?: true
    attribute :notes, :string, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :french,
      constraints: [one_of: Stemmers.supported_languages()]

    timestamps()
  end
end
