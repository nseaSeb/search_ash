defmodule SearchAsh.Test.StaticPage do
  @moduledoc false
  # A mono-language source resource with **no** `:language` attribute — it fixes the
  # language statically instead. Guards the regression where such a resource resolved
  # `language` to nil and rolled back every write.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_static_pages"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SearchDocument
    source_type :static_page
    fields [:title, :body]
    language :fr
    label_field :title
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title, :body]
    end

    update :update do
      accept [:title, :body]
    end

    destroy :destroy do
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :body, :string, public?: true
  end
end
