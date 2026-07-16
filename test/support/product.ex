defmodule SearchAsh.Test.Product do
  @moduledoc false
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_products"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SearchDocument
    source_type :product
    fields [:name, :sku]
    language_attribute :language
    label_field :name
    archived :discontinued
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :sku, :language, :discontinued]
    end

    update :update do
      require_atomic? false
      accept [:name, :sku, :language, :discontinued]
    end

    destroy :destroy do
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :sku, :string, public?: true
    attribute :discontinued, :boolean, public?: true, default: false

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :french,
      constraints: [one_of: Stemmers.supported_languages()]
  end
end
