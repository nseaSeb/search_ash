defmodule SearchAsh.Transformers.AddSyncChange do
  @moduledoc "Adds the global change that keeps `search_text` in sync on create/update."
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
    {:ok, change} = Ash.Resource.Builder.build_change(SearchAsh.Changes.SyncSearchText, [])

    dsl =
      dsl
      |> Transformer.add_entity([:changes], change)
      |> relax_atomic_requirement()

    {:ok, dsl}
  end

  # The sync change stems in Elixir and can't run in an atomic SQL update, so force
  # require_atomic? false on every update action rather than making adopters remember it.
  defp relax_atomic_requirement(dsl) do
    dsl
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type == :update and &1.require_atomic?))
    |> Enum.reduce(dsl, fn action, dsl ->
      Transformer.replace_entity(
        dsl,
        [:actions],
        %{action | require_atomic?: false},
        &(&1.name == action.name and &1.type == action.type)
      )
    end)
  end

  @impl true
  def before?(t), do: t not in @siblings
end
