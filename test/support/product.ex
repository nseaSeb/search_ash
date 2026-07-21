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
    fields [:name, :sku, :tags]
    language_attribute :language
    label_field :name
    # The reference weighs most, the name next; anything unlisted stays :d.
    weights %{sku: :a, name: :b}
    # Deliberately on an attribute that is NOT in `fields` and is NOT the label: the only
    # thing that can trigger a re-index on a change to it is `guarded_attributes` picking
    # up index_attribute sources. Product has no `extra_text`/`load` and an
    # attribute-driven `archived`, so it is the one fixture that reaches that code.
    index_attribute :client_ref, :ref_interne
    # Les deux chemins sont complémentaires : `fields` rend un tag trouvable dans la barre
    # de recherche, `index_attribute` permet de filtrer et de faire des facettes dessus.
    index_attribute :tags, :tags
    index_attribute :montant, :montant
    archived :discontinued
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :sku, :language, :discontinued, :ref_interne, :tags, :montant]
    end

    # NB: no `require_atomic? false` here — SearchAsh.Source sets it automatically.
    update :update do
      accept [:name, :sku, :language, :discontinued, :ref_interne, :tags, :montant]
    end

    destroy :destroy do
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :sku, :string, public?: true
    attribute :discontinued, :boolean, public?: true, default: false
    attribute :ref_interne, :string, public?: true
    attribute :tags, {:array, :string}, public?: true
    attribute :montant, :decimal, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :fr,
      constraints: [one_of: SearchCore.Language.supported_languages()]
  end
end
