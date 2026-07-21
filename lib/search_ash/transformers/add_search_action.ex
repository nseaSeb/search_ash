defmodule SearchAsh.Transformers.AddSearchAction do
  @moduledoc "Adds the `:search` read action (query + language args) unless already defined."
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @siblings [
    SearchAsh.Transformers.AddSearchTextAttribute,
    SearchAsh.Transformers.AddSyncChange,
    SearchAsh.Transformers.AddSearchRank,
    SearchAsh.Transformers.AddSearchAction,
    SearchAsh.Transformers.AddSearchIndex
  ]

  @impl true
  def transform(dsl) do
    action_name = Transformer.get_option(dsl, [:search], :action) || :search

    if action_defined?(dsl, action_name) do
      {:ok, dsl}
    else
      default_language = Transformer.get_option(dsl, [:search], :default_language) || :fr

      # Optional so the action is usable from a generic list UI: a blank query lists
      # everything, a filled query filters. `language` defaults to `:default_language`.
      {:ok, query_arg} =
        Ash.Resource.Builder.build_action_argument(:query, :string, allow_nil?: true, default: "")

      {:ok, language_arg} =
        Ash.Resource.Builder.build_action_argument(:language, :atom,
          allow_nil?: true,
          default: default_language
        )

      {:ok, preparation} =
        Ash.Resource.Builder.build_preparation(SearchAsh.Preparations.Search, [])

      {:ok, pagination} = Ash.Resource.Builder.build_pagination(pagination_opts(dsl))

      {:ok, action} =
        Ash.Resource.Builder.build_action(:read, action_name,
          arguments: [query_arg, language_arg],
          preparations: [preparation],
          pagination: pagination
        )

      {:ok, Transformer.add_entity(dsl, [:actions], action)}
    end
  end

  # Offset and keyset, never required — an unpaginated call still returns a plain list.
  # `default_limit` flips `paginate_by_default?` with it: asking for a default bound only
  # means something if a caller who passes no page gets it.
  defp pagination_opts(dsl) do
    default_limit = Transformer.get_option(dsl, [:search], :default_limit)

    [offset?: true, keyset?: true, countable: true, required?: false]
    |> put_unless_nil(:default_limit, default_limit)
    |> Keyword.put(:paginate_by_default?, not is_nil(default_limit))
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  defp action_defined?(dsl, name) do
    dsl
    |> Transformer.get_entities([:actions])
    |> Enum.any?(&(&1.name == name))
  end

  @impl true
  def before?(t), do: t not in @siblings
end
