defmodule SearchDemo.Sales.Facture do
  @moduledoc "A demo source entity. On create it mirrors itself into the search index."
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Sales,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "factures"
    repo SearchDemo.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchDemo.Search.Document
    source_type(:facture)
    fields [:numero, :client_nom, :description]
    label_field(:numero)
  end

  actions do
    defaults [:read]

    create :create do
      accept [:numero, :client_nom, :description, :language]
    end

    destroy :destroy do
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :numero, :string, allow_nil?: false, public?: true
    attribute :client_nom, :string, public?: true
    attribute :description, :string, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :fr,
      constraints: [one_of: SearchCore.Language.supported_languages()]

    timestamps()
  end
end
