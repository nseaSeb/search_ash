defmodule SearchDemo.Blog do
  use Ash.Domain

  resources do
    resource SearchDemo.Post do
      define :create_post, action: :create
      define :list_posts, action: :read
      define :search_posts, action: :search, args: [:query, :language]
    end
  end
end
