defmodule SearchAsh.Transformers.AddSyncChange do
  @moduledoc "Adds the global change that keeps `search_text` in sync on create/update."
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @siblings [
    SearchAsh.Transformers.AddSearchTextAttribute,
    SearchAsh.Transformers.AddSyncChange,
    SearchAsh.Transformers.AddSearchAction,
    SearchAsh.Transformers.AddSearchIndex
  ]

  @impl true
  def transform(dsl) do
    {:ok, change} = Ash.Resource.Builder.build_change(SearchAsh.Changes.SyncSearchText, [])
    {:ok, Transformer.add_entity(dsl, [:changes], change)}
  end

  @impl true
  def before?(t), do: t not in @siblings
end
