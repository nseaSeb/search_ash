defmodule SearchAsh.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource SearchAsh.Test.Article do
      define(:create_article, action: :create)
      define(:update_article, action: :update)
      define(:search_articles, action: :search, args: [:query, :language])
    end
  end
end
