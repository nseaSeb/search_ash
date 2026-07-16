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
    language = normalize_language(Ash.Query.get_argument(query, :language))
    # Branch on the *computed* tsquery, not the raw term: a short (< min_length) or
    # all-stopwords query yields no tokens ("") even though the term is non-blank.
    tsquery = if is_binary(term), do: SearchCore.tsquery(term, language), else: ""

    if tsquery == "" do
      # Nothing searchable → list everything (the list UI shows all rows before typing).
      query
    else
      query
      |> Ash.Query.filter(
        fragment("to_tsvector('simple', search_text) @@ to_tsquery('simple', ?)", ^tsquery)
      )
      |> Ash.Query.load(rank: %{tsquery: tsquery})
      |> Ash.Query.sort(rank: {%{tsquery: tsquery}, :desc})
    end
  end

  defp normalize_language(lang) when is_atom(lang) and not is_nil(lang), do: lang
  defp normalize_language(_), do: :french
end
