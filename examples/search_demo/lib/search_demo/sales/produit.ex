defmodule SearchDemo.Sales.Produit do
  @moduledoc "A demo source entity. On create it mirrors itself into the search index."
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Sales,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "produits"
    repo SearchDemo.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchDemo.Search.Document
    source_type :produit
    fields [:reference, :libelle, :description]
    label_field :libelle
    weights %{reference: :a, libelle: :b}

    # The SAME index column as Facture's, filled from a DIFFERENT source attribute: a
    # produit has no emission date, so its creation date is what "when is this document
    # from" means for it. That is what keeps one date axis comparable across entity types.
    index_attribute :document_date, &DateTime.to_date(&1.inserted_at)
  end

  actions do
    defaults [:read]

    create :create do
      accept [:reference, :libelle, :description, :language]
    end

    destroy :destroy do
      require_atomic? false
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
      default: :fr,
      constraints: [one_of: SearchCore.Language.supported_languages()]

    timestamps()
  end
end
