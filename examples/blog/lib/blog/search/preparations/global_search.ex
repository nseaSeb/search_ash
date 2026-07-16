defmodule Blog.Search.Preparations.GlobalSearch do
  @moduledoc """
  Filters the index on the tsvector match and ranks results by `ts_rank` (descending).
  The query term goes through the same `SearchCore` pipeline used at index time, so a
  search for "chevaux" matches a row that stored "cheval". Tenant scoping is applied
  automatically by Ash's attribute multitenancy — this preparation never touches it.
  """
  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    term = Ash.Query.get_argument(query, :query)
    language = Ash.Query.get_argument(query, :language)
    tsquery = SearchCore.tsquery(term, language)

    query
    |> Ash.Query.filter(
      fragment("to_tsvector('simple', search_text) @@ to_tsquery('simple', ?)", ^tsquery)
    )
    |> Ash.Query.load(rank: %{tsquery: tsquery})
    |> Ash.Query.sort(rank: {%{tsquery: tsquery}, :desc})
  end
end
