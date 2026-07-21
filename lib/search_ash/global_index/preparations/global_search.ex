defmodule SearchAsh.GlobalIndex.Preparations.GlobalSearch do
  @moduledoc """
  Preparation for a `SearchAsh.GlobalIndex` resource's `:global_search` action.

  Hides `archived` rows (unless `include_archived?: true`), restricts to the given
  `types` (when non-empty), then branches on the query term:

    * blank/absent term — list the matching rows, unfiltered and unranked (a list UI
      before the user types);
    * a term whose tokens are all eliminated (stopwords, too short: `"de"`) — **no
      results**, rather than the pre-0.4.0 behaviour of silently listing everything;
    * otherwise — filter on the tsvector match (plus, with `fuzzy? true`, a trigram
      similarity/substring match on the folded label) and rank: label exact >
      starts-with > contains > body match (`label_match_tier`), then `ts_rank`, then
      primary key.
  """
  use Ash.Resource.Preparation
  require Ash.Query

  alias SearchAsh.GlobalIndex.Info

  @impl true
  def prepare(query, _opts, _context) do
    term = Ash.Query.get_argument(query, :query)

    query
    |> maybe_hide_archived(Ash.Query.get_argument(query, :include_archived?))
    |> maybe_filter_types(Ash.Query.get_argument(query, :types))
    |> apply_term(term)
  end

  defp maybe_hide_archived(query, true), do: query
  defp maybe_hide_archived(query, _), do: Ash.Query.filter(query, archived == false)

  # `nil` and `[]` both mean "no type filter": an empty multi-select must not become
  # `source_type in []` (zero results). Types are stored as strings (`Info.source_type`
  # does `to_string`), so cast here the same way.
  defp maybe_filter_types(query, [_ | _] = types) do
    Ash.Query.filter(query, source_type in ^Enum.map(types, &to_string/1))
  end

  defp maybe_filter_types(query, _none), do: query

  defp apply_term(query, term) do
    if blank?(term) do
      query
    else
      resource = query.resource
      language = normalize_language(Ash.Query.get_argument(query, :language), resource)
      tsquery = SearchCore.tsquery(term, language, prefix: true)

      # A non-blank term that yields no tokens ("de", "a x") means the user searched
      # for something unsearchable — return nothing, never the whole base.
      if tsquery == "" do
        Ash.Query.filter(query, false)
      else
        folded = fold(term)

        fuzzy = if Info.fuzzy?(resource), do: Info.fuzzy_threshold(resource)

        query
        |> filter_match(Info.search_text_attribute(resource), tsquery, folded, fuzzy)
        |> rank(tsquery, folded)
      end
    end
  end

  defp blank?(term), do: not is_binary(term) or String.trim(term) == ""

  # The whole term in the same normal form `label_normalized` is stored in —
  # `SearchCore.normalize/1` on BOTH sides (see `Document.to_attrs/2`), so `maraicher`
  # meets `Maraîcher` and the two sides cannot drift. No stemming: label comparisons
  # are about how the label *reads*, not what it stems to.
  defp fold(term), do: SearchCore.normalize(term)

  defp filter_match(query, search_text_attribute, tsquery, _folded, nil = _fuzzy) do
    Ash.Query.filter(
      query,
      fragment(
        "?::tsvector @@ to_tsquery('simple', ?)",
        ^ref(search_text_attribute),
        ^tsquery
      )
    )
  end

  # `fuzzy? true`: also match the folded label by trigram similarity (`duont` → `dupont`)
  # or substring (`12` → `bl-…-0012`), both served by the trigram GIN index.
  #
  # The similarity test is written twice on purpose. `%` is what the index can answer, but
  # it compares against the *database's* `pg_trgm.similarity_threshold`; `similarity() >=`
  # then applies the threshold configured here. So the operator does the index lookup and
  # the function does the precision — which is the way to tighten matching without asking
  # anyone to change a database-wide setting.
  #
  # The LIKE pattern escapes `\ % _` so a literal in the query stays a literal.
  defp filter_match(query, search_text_attribute, tsquery, folded, threshold) do
    pattern = "%" <> escape_like(folded) <> "%"

    Ash.Query.filter(
      query,
      fragment(
        "(?::tsvector @@ to_tsquery('simple', ?) OR (? % ? AND similarity(?, ?) >= ?) OR ? LIKE ?)",
        ^ref(search_text_attribute),
        ^tsquery,
        ^ref(:label_normalized),
        ^folded,
        ^ref(:label_normalized),
        ^folded,
        ^threshold,
        ^ref(:label_normalized),
        ^pattern
      )
    )
  end

  defp escape_like(term), do: String.replace(term, ~r/([\\%_])/, "\\\\\\1")

  defp rank(query, tsquery, folded) do
    query
    |> Ash.Query.load(search_rank: %{tsquery: tsquery}, label_match_tier: %{term: folded})
    |> Ash.Query.sort(label_match_tier: {%{term: folded}, :asc})
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
