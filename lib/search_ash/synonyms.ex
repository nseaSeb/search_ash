defmodule SearchAsh.Synonyms do
  @moduledoc """
  Shared handling of the `synonyms` option, declared by both extensions — `SearchAsh`
  (per-resource `search do … end`) and `SearchAsh.GlobalIndex` (`global_index do … end`).

  Keeping the type and the resolution in one place is deliberate: the two extensions are
  separate Spark modules, but the option means the same thing in both, and a future change
  to how it resolves must not have to be made twice.
  """

  # Inline per-language map (`%{fr: %{"bl" => ["bon de livraison"]}}`) or a
  # `{module, function}` callback returning that inner map for a language.
  @type_spec {:or,
              [
                {:map, :atom, {:map, :string, {:list, :string}}},
                {:tuple, [:atom, :atom]}
              ]}

  @doc "Spark type for the `synonyms` option (shared so the two extensions cannot drift)."
  def type_spec, do: @type_spec

  @doc """
  Resolve the `synonyms` option value to the `%{key => [phrase]}` map to expand `language`
  with, ready to hand to `SearchCore.tsquery/3`.

  Keyed by the **ISO base** language (`SearchCore.Language.base/1`), the same key stopwords
  use — so `%{en: …}` covers `:en` and its stemmer variants (`:en_porter`, `:en_lovins`),
  rather than silently missing them. The `{module, function}` callback likewise receives the
  base language.

  Returns `%{}` when unset, when there is no entry for the language, or when a callback
  returns anything but a map.

  The callback runs on **every** search — that is what lets an edit take effect without a
  deploy — so keep it fast (cache your own source if it reads a database), have it handle
  every language your resources use, and let it return `%{}` rather than raise for one it
  does not know: an exception propagates out and fails the search.
  """
  def resolve(nil, _language), do: %{}

  def resolve({mod, fun}, language) when is_atom(mod) and is_atom(fun),
    do: as_map(apply(mod, fun, [SearchCore.Language.base(language)]))

  def resolve(map, language) when is_map(map),
    do: as_map(Map.get(map, SearchCore.Language.base(language)))

  defp as_map(map) when is_map(map), do: map
  defp as_map(_), do: %{}
end
