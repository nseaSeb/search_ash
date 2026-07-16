defmodule SearchAsh.Test.Article do
  @moduledoc false
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh]

  postgres do
    table("test_articles")
    repo(SearchAsh.Test.Repo)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:org_id)
    global?(true)
  end

  search do
    fields [:title, :body]
    language_attribute :language
  end

  actions do
    defaults([:read])

    create :create do
      accept([:title, :body, :language])
    end

    # NB: no `require_atomic? false` here — SearchAsh sets it automatically.
    update :update do
      accept([:title, :body, :language])
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :string, allow_nil?: false, public?: true)
    attribute(:title, :string, public?: true)
    attribute(:body, :string, public?: true)

    attribute(:language, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Stemmers.supported_languages()]
    )
  end
end
