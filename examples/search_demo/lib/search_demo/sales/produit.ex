defmodule SearchDemo.Sales.Produit do
  @moduledoc "A demo source entity. On create it mirrors itself into the search index."
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Sales,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "produits"
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
      accept [:reference, :libelle, :description, :language]

      change {SearchDemo.Sales.Changes.SyncToIndex,
              source_type: "produit",
              fields: [:reference, :libelle, :description],
              label_field: :libelle}
    end

    destroy :destroy do
      require_atomic? false
      change {SearchDemo.Sales.Changes.RemoveFromIndex, source_type: "produit"}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :reference, :string, allow_nil?: false, public?: true
    attribute :libelle, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :french,
      constraints: [one_of: Stemmers.supported_languages()]

    timestamps()
  end
end
