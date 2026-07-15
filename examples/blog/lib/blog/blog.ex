defmodule Blog.Blog do
  use Ash.Domain

  resources do
    resource Blog.Post do
      define :create_post, action: :create
      define :list_posts, action: :read
      define :search_posts, action: :search, args: [:query, :language]
    end
  end
end
