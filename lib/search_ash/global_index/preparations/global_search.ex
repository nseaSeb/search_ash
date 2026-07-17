defmodule SearchAsh.GlobalIndex.Preparations.GlobalSearch do
  @moduledoc """
  Preparation for a `SearchAsh.GlobalIndex` resource's `:global_search` action. Hides
  `archived` rows (unless `include_archived?: true`), filters on the tsvector match, and
  ranks by `ts_rank` (prefix-aware, with a primary-key tiebreaker). A blank query lists
  the matching rows, unranked.
  """
  use Ash.Resource.Preparation
  require Ash.Query

  alias SearchAsh.GlobalIndex.Info

  @impl true
  def prepare(query, _opts, _context) do
    resource = query.resource
    search_text_attribute = Info.search_text_attribute(resource)
    term = Ash.Query.get_argument(query, :query)
    language = normalize_language(Ash.Query.get_argument(query, :language), resource)

    tsquery =
      if is_binary(term),
        do: SearchCore.tsquery(term, language, prefix: true),
        else: ""

    query
    |> maybe_hide_archived(Ash.Query.get_argument(query, :include_archived?))
    |> maybe_filter(search_text_attribute, tsquery)
    |> maybe_rank(tsquery)
  end

  defp maybe_hide_archived(query, true), do: query
  defp maybe_hide_archived(query, _), do: Ash.Query.filter(query, archived == false)

  defp maybe_filter(query, _search_text_attribute, ""), do: query

  defp maybe_filter(query, search_text_attribute, tsquery) do
    Ash.Query.filter(
      query,
      fragment(
        "to_tsvector('simple', ?) @@ to_tsquery('simple', ?)",
        ^ref(search_text_attribute),
        ^tsquery
      )
    )
  end

  defp maybe_rank(query, ""), do: query

  defp maybe_rank(query, tsquery) do
    query
    |> Ash.Query.load(search_rank: %{tsquery: tsquery})
    |> Ash.Query.sort(search_rank: {%{tsquery: tsquery}, :desc})
    |> stable_order()
  end

  defp stable_order(query) do
    case Ash.Resource.Info.primary_key(query.resource) do
      [] -> query
      pkey -> Ash.Query.sort(query, Enum.map(pkey, &{&1, :asc}))
    end
  end

  defp normalize_language(lang, resource) do
    if is_atom(lang) and SearchCore.Language.supported?(lang),
      do: lang,
      else: Info.default_language(resource)
  end
end
