defmodule SearchAsh.Transformers.AddSearchRank do
  @moduledoc """
  Adds a `:search_rank` calculation (`ts_rank` over the search-text tsvector, taking the
  built tsquery as an argument). The `:search` action loads and sorts by it. Skipped when
  `rank?` is false or a `:search_rank` calculation already exists.
  """
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  import Ash.Expr

  @siblings [
    SearchAsh.Transformers.AddSearchTextAttribute,
    SearchAsh.Transformers.AddSyncChange,
    SearchAsh.Transformers.AddSearchRank,
    SearchAsh.Transformers.AddSearchAction,
    SearchAsh.Transformers.AddSearchIndex
  ]

  @impl true
  def transform(dsl) do
    if rank?(dsl) and not calc_defined?(dsl) do
      search_text = Transformer.get_option(dsl, [:search], :search_text_attribute) || :search_text

      calc_expr =
        Ash.Expr.expr(
          fragment(
            "ts_rank(to_tsvector('simple', ?), to_tsquery('simple', ?))",
            ^ref(search_text),
            ^arg(:tsquery)
          )
        )

      {:ok, argument} =
        Ash.Resource.Builder.build_calculation_argument(:tsquery, :string, allow_nil?: false)

      {:ok, calc} =
        Ash.Resource.Builder.build_calculation(:search_rank, :float, calc_expr,
          arguments: [argument]
        )

      {:ok, Transformer.add_entity(dsl, [:calculations], calc)}
    else
      {:ok, dsl}
    end
  end

  defp rank?(dsl), do: Transformer.get_option(dsl, [:search], :rank?) != false

  defp calc_defined?(dsl) do
    dsl
    |> Transformer.get_entities([:calculations])
    |> Enum.any?(&(&1.name == :search_rank))
  end

  @impl true
  def before?(t), do: t not in @siblings
end
