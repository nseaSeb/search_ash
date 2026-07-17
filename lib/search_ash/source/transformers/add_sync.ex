defmodule SearchAsh.Source.Transformers.AddSync do
  @moduledoc """
  Adds the create/update sync change and the destroy remove change, and forces
  `require_atomic? false` on every update/destroy action.

  The sync change stems each row in Elixir, which cannot run inside an atomic
  SQL statement, so any update/destroy action that carries it must be non-atomic.
  We set that here rather than making each adopter remember it on every action —
  a working `require_atomic? true` action is impossible with this change anyway.
  """
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    {:ok, sync} =
      Ash.Resource.Builder.build_change(SearchAsh.Source.Changes.Sync, on: [:create, :update])

    {:ok, remove} =
      Ash.Resource.Builder.build_change(SearchAsh.Source.Changes.Remove, on: [:destroy])

    dsl =
      dsl
      |> Transformer.add_entity([:changes], sync)
      |> Transformer.add_entity([:changes], remove)
      |> relax_atomic_requirement()

    {:ok, dsl}
  end

  # Set require_atomic? false on every update/destroy action (matched by type, the
  # same way the sync/remove changes are attached).
  defp relax_atomic_requirement(dsl) do
    dsl
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type in [:update, :destroy] and &1.require_atomic?))
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
  def before?(_), do: true
end
