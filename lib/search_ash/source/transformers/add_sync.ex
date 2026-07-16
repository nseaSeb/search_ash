defmodule SearchAsh.Source.Transformers.AddSync do
  @moduledoc "Adds the create/update sync change and the destroy remove change."
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    {:ok, sync} =
      Ash.Resource.Builder.build_change(SearchAsh.Source.Changes.Sync, on: [:create, :update])

    {:ok, remove} =
      Ash.Resource.Builder.build_change(SearchAsh.Source.Changes.Remove, on: [:destroy])

    {:ok,
     dsl
     |> Transformer.add_entity([:changes], sync)
     |> Transformer.add_entity([:changes], remove)}
  end

  @impl true
  def before?(_), do: true
end
