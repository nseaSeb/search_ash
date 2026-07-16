defmodule Blog.Search do
  @moduledoc """
  Domain for the unified search index. `global_search/3` is the app-wide search entry
  point; `upsert_document/2` is called by source resources to keep the index in sync.
  """
  use Ash.Domain

  resources do
    resource Blog.Search.Document do
      define :upsert_document, action: :upsert
      define :global_search, action: :global_search, args: [:query, :language]
    end
  end
end
