defmodule SearchAsh.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource SearchAsh.Test.Article do
      define(:create_article, action: :create)
      define(:update_article, action: :update)
      define(:search_articles, action: :search, args: [:query, :language])
    end

    resource SearchAsh.Test.SearchDocument do
      define(:global_search, action: :global_search, args: [:query, :language])
    end

    resource SearchAsh.Test.Product do
      define(:create_product, action: :create)
      define(:update_product, action: :update)
      define(:destroy_product, action: :destroy)
    end
  end
end
