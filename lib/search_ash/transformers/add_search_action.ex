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
      default_language = Transformer.get_option(dsl, [:search], :default_language) || :french

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

      {:ok, action} =
        Ash.Resource.Builder.build_action(:read, action_name,
          arguments: [query_arg, language_arg],
          preparations: [preparation]
        )

      {:ok, Transformer.add_entity(dsl, [:actions], action)}
    end
  end

  defp action_defined?(dsl, name) do
    dsl
    |> Transformer.get_entities([:actions])
    |> Enum.any?(&(&1.name == name))
  end

  @impl true
  def before?(t), do: t not in @siblings
end
